import XCTest
@testable import CellCore

/// Round 9: hung crash debuggers and force stop, Steam games started on their own, bundled Mac versions,
/// games that need a display mode the Mac doesn't list, .NET text rules.
final class RoundNineTests: XCTestCase {
    private func process(_ pid: pid_t, _ secondsAgo: TimeInterval, server: Bool = false, now: Date) -> WineProcessScanner.SessionProcess {
        WineProcessScanner.SessionProcess(pid: pid, startedAt: now.addingTimeInterval(-secondsAgo), isServer: server)
    }

    /// Programs older than the running wineserver belong to a session that is gone (they hung for days).
    func testLeftoversOfOlderSessionsAreFound() {
        let now = Date()
        let processes = [
            process(10, 3600, now: now),                // crash debugger from an hour ago
            process(11, 86_400 * 3, now: now),          // Wine helper from three days ago
            process(20, 300, server: true, now: now),   // today's wineserver
            process(21, 303, now: now),                 // the program that started it, a moment earlier
            process(22, 100, now: now),                 // a game started later
        ]
        XCTAssertEqual(Set(WineProcessScanner.orphans(in: processes, now: now)), [10, 11])
        // Without a wineserver every program is a leftover, except one that has only just started (it starts the server).
        let serverless = [process(30, 2, now: now), process(31, 600, now: now)]
        XCTAssertEqual(WineProcessScanner.orphans(in: serverless, now: now), [31])
        XCTAssertTrue(WineProcessScanner.orphans(in: [], now: now).isEmpty)
    }

    /// The kernel reports the wineserver's folder as /private/tmp/…; Foundation's resolving says /tmp/…. Comparing
    /// those would miss the running server and take every program for a leftover.
    func testPathsMatchHowTheKernelReportsThem() {
        XCTAssertEqual(WineProcessScanner.canonicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(WineProcessScanner.canonicalPath("/nonexistent-\(UUID().uuidString)").hasPrefix("/nonexistent-"), true)
    }

    /// Wine's crash debugger never attaches on a Mac; a crashed program must simply end (both registry views).
    func testCrashDebuggerIsOff() throws {
        let services = CellServices()
        let edits = services.planner.registryConfiguration(for: Container(name: "Games"))
        for key in ["Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
                    "Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"] {
            let edit = try XCTUnwrap(edits.first { $0.key == key && $0.name == "Debugger" }, key)
            XCTAssertEqual(edit.value, .string(""))
            XCTAssertEqual(edit.hive, .localMachine)
        }
    }

    /// .NET 5+ games use Windows' NLS text rules: a foreign icu.dll in system32 stopped Stardew Valley at start.
    func testDotNetDoesNotLoadICU() {
        let runtime = WineRuntime(id: "w", name: "w", version: "10.0", origin: .imported, originDescription: "/tmp/w")
        let env = WineEnvironment.build(container: Container(name: "Games"), runtime: runtime, flavorRoot: runtime.wineRoot,
                                        backend: nil, fixes: nil, app: nil, dllOverrides: [:])
        XCTAssertEqual(env["DOTNET_SYSTEM_GLOBALIZATION_USENLS"], "1")
    }

    /// A Unity game whose own resolution choice failed (The Rewinder: "Resolution" = 3, windowed) gets its choice reset
    /// to borderless fullscreen at full resolution, with virtual modes scoped to that game.
    func testBrokenUnityResolutionChoiceIsReset() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rewinder-\(UUID().uuidString).reg")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        WINE REGISTRY Version 2
        ;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

        [Software\\\\MistyMountainStudio\\\\Rewinder] 1794374474
        "FullScreen_h3418622618"=dword:00000000
        "Resolution_h2981718891"=dword:00000003
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000003
        "Screenmanager Resolution Height_h2627697771"=dword:00000778
        "Screenmanager Resolution Width_h182942802"=dword:00000b7c

        """.write(to: file, atomically: true, encoding: .utf8)
        let hive = try WineRegistryHive.load(file, rootName: "HKEY_CURRENT_USER")
        let size = GameDisplayFixer.Size(width: 2940, height: 1912)
        // A window as big as the screen becomes borderless fullscreen (Draw & Guess); a smaller window is left alone.
        XCTAssertTrue(GameDisplayFixer.unityEdits(company: "MistyMountainStudio", product: "Rewinder", saved: hive, size: size)
            .contains { $0.name == "Screenmanager Fullscreen mode_h3630240806" && $0.value == .dword(1) })
        XCTAssertTrue(GameDisplayFixer.unityEdits(company: "MistyMountainStudio", product: "Rewinder", saved: hive,
                                                  size: GameDisplayFixer.Size(width: 3840, height: 2160)).isEmpty,
                      "a window smaller than the screen stays a window")
        let edits = GameDisplayFixer.unityEdits(company: "MistyMountainStudio", product: "Rewinder", saved: hive, size: size, choiceBroken: true)
        XCTAssertEqual(Set(edits.filter { $0.value == .delete }.compactMap(\.name)), ["Resolution_h2981718891", "FullScreen_h3418622618"])
        XCTAssertTrue(edits.contains { $0.name == "Screenmanager Fullscreen mode_h3630240806" && $0.value == .dword(1) })

        let services = CellServices()
        var app = AppEntry(containerID: UUID(), name: "The Rewinder", kind: .steamGame, source: .steam, steamAppID: "1161170")
        var analysis = AppAnalysis(architecture: .x64)
        analysis.analyzedExecutable = "/games/The Rewinder/Rewinder.exe"
        app.analysis = analysis
        app.learned.needsDisplayModes = true
        let appEdits = services.planner.appDefaults(for: app, container: Container(name: "Games"))
        XCTAssertEqual(appEdits.first { $0.name == "EmulateModeset" }?.value, .string("y"))
        XCTAssertNotNil(appEdits.first { $0.key.hasSuffix("Rewinder.exe\\X11 Driver") && $0.deletesKey })
        app.learned.needsDisplayModes = false
        app.steamAppID = nil // The bundled Rewinder rule now supplies this independently of local learning.
        XCTAssertNil(services.planner.appDefaults(for: app, container: Container(name: "Games")).first { $0.name == "EmulateModeset" })
    }

    /// Vulkan games see the Mac's GPU as an AMD card (Sky stops on every GPU it doesn't know); DXVK keeps Apple's IDs.
    func testVulkanGPUIsPresentedAsWindowsGamesKnowIt() {
        let settings = Container(name: "Games").settings
        XCTAssertEqual(WineEnvironment.backendEnvironment(settings: settings, backend: .d3dmetal)["CELL_VULKAN_GPU"], "windows")
        XCTAssertEqual(WineEnvironment.backendEnvironment(settings: settings, backend: nil)["CELL_VULKAN_GPU"], "windows")
        XCTAssertEqual(WineEnvironment.backendEnvironment(settings: settings, backend: .dxvk)["CELL_VULKAN_GPU"], "apple")
    }

    func testLearnedFlagsSurviveOldFiles() throws {
        let old = try JSONDecoder().decode(LearnedCompat.self, from: Data(#"{"failedBackends":["dxmt"]}"#.utf8))
        XCTAssertFalse(old.needsDisplayModes)
        XCTAssertFalse(old.startsOnlyThroughSteam)
        var learned = LearnedCompat()
        learned.needsDisplayModes = true
        let again = try JSONDecoder().decode(LearnedCompat.self, from: JSONEncoder().encode(learned))
        XCTAssertTrue(again.needsDisplayModes)
    }

    func testSteamworksIsFoundInsideTheGame() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("steamworks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let plugins = folder.appendingPathComponent("Game_Data/Plugins/x86_64")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        XCTAssertFalse(SteamIntegration.usesSteamworks(folder))
        try Data().write(to: plugins.appendingPathComponent("steam_api64.dll"))
        XCTAssertTrue(SteamIntegration.usesSteamworks(folder))
    }
}

final class UnrealSubclassSettingsTests: XCTestCase {
    /// app.info says "Draw_Guess", the registry key is "Draw&Guess".
    func testUnityKeyIsFoundByItsRealName() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dg-\(UUID().uuidString).reg")
        defer { try? FileManager.default.removeItem(at: file) }
        try "WINE REGISTRY Version 2\n\n[Software\\\\Acureus\\\\Draw&Guess] 1\n\"A\"=dword:00000001\n".write(to: file, atomically: true, encoding: .utf8)
        let hive = try WineRegistryHive.load(file, rootName: "HKEY_CURRENT_USER")
        let key = GameDisplayFixer.unityKey(company: "Acureus", product: "Draw_Guess", in: hive)
        XCTAssertEqual(key.product, "Draw&Guess")
        XCTAssertEqual(GameDisplayFixer.unityKey(company: "X", product: "Y", in: hive).product, "Y")
    }

    /// Little Nightmares keeps its display settings in a subclass section (TarGameUserSettings).
    func testSubclassSectionIsFixed() throws {
        let text = """
        [/Script/Engine.GameUserSettings]
        bUseDesiredScreenHeight=False

        [/Script/TarsierUtilities.TarGameUserSettings]
        ResolutionSizeX=1470
        ResolutionSizeY=956
        LastUserConfirmedResolutionSizeX=1470
        LastUserConfirmedResolutionSizeY=956
        FullscreenMode=0
        LastConfirmedFullscreenMode=0
        PreferredFullscreenMode=0
        """
        let fixed = try XCTUnwrap(GameDisplayFixer.fixUnreal(text, size: GameDisplayFixer.Size(width: 2940, height: 1912)))
        XCTAssertTrue(fixed.contains("FullscreenMode=1"))
        XCTAssertTrue(fixed.contains("ResolutionSizeX=2940"))
        XCTAssertFalse(fixed.contains("FullscreenMode=0"))
    }
}
