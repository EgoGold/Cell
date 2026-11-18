import XCTest
@testable import CellCore

/// Round 4: engine checks, auto-start blocking, display fixes, virtual machines.
final class EngineCheckTests: XCTestCase {
    func testWorkingPairIsRecognized() {
        let output = """
        probe 1
        factory 0x00000000
        adapter 0x106b 0x00000000 Apple M5
        d3d11 0x00000000 0xb100
        window 1
        swapchain 0x00000000
        present 0x00000000
        d3d12 0x80004002
        done
        """
        let check = EngineProbe.parse(output, runtimeID: "pk", backend: .dxmt, fingerprint: "f", exitCode: 0)
        XCTAssertTrue(check.runsDirect3D11)
        XCTAssertFalse(check.direct3D12)
        XCTAssertNil(check.stoppedAt)
        XCTAssertEqual(check.adapter, "Apple M5")
        XCTAssertEqual(check.vendorID, 0x106b)
        XCTAssertEqual(check.summary, "Draws Direct3D 11 on Apple M5")
    }

    /// Wine 11.21 + DXMT 0.80: the device works, then the process dies creating the swap chain.
    func testCrashCreatingTheSwapChainIsBroken() {
        let output = "probe 1\nfactory 0x00000000\nadapter 0x106b 0x00000000 Apple M5\nd3d11 0x00000000 0xb100\nwindow 1\n"
        let check = EngineProbe.parse(output, runtimeID: "gcenx", backend: .dxmt, fingerprint: "f", exitCode: 3)
        XCTAssertTrue(check.direct3D11)
        XCTAssertFalse(check.runsDirect3D11)
        XCTAssertEqual(check.stoppedAt, "swapchain")
        XCTAssertFalse(check.isConclusive)
        XCTAssertEqual(check.summary, "Check incomplete — rendering capability unknown")
    }

    /// Wine's own renderer without a usable GPU: Wine's stand-in adapter and no Direct3D 11 device.
    func testWineStandInAdapterWithoutDevice() {
        let output = "probe 1\nfactory 0x00000000\nadapter 0x10de 0x00000041 NVIDIA GeForce 6800\nd3d11 0x80004005 0x0000\nd3d12 0x00000000\ndone\n"
        let check = EngineProbe.parse(output, runtimeID: "gcenx", backend: .wined3d, fingerprint: "f", exitCode: 0)
        XCTAssertFalse(check.direct3D11)
        XCTAssertTrue(check.direct3D12)
        XCTAssertEqual(check.adapter, "NVIDIA GeForce 6800")
        XCTAssertEqual(check.summary, "Only Direct3D 12 works")
    }

    func testEmptyOutputMeansItDidNotStart() {
        let check = EngineProbe.parse("", runtimeID: "x", backend: .d3dmetal, fingerprint: "f", exitCode: nil)
        XCTAssertFalse(check.runsDirect3D11)
        XCTAssertFalse(check.isConclusive)
        XCTAssertNil(check.stoppedAt)
        XCTAssertEqual(check.summary, "Check incomplete — rendering capability unknown")
    }

    func testGraphicsNeedFromAnalysis() {
        var game = AppAnalysis(architecture: .x64)
        game.graphicsAPIs = [.d3d11, .d3d12]
        XCTAssertEqual(GraphicsNeed(analysis: game), .direct3D11)
        game.graphicsAPIs = [.d3d12]
        XCTAssertEqual(GraphicsNeed(analysis: game), .direct3D12)
        game.graphicsAPIs = [.d3d9]
        XCTAssertEqual(GraphicsNeed(analysis: game), .legacy)
        game.graphicsAPIs = []
        XCTAssertEqual(GraphicsNeed(analysis: game), .none, "installers and tools aren't judged by graphics checks")
        XCTAssertEqual(GraphicsNeed(analysis: nil), .direct3D11)
    }

    func testDirect3D11GamesPreferDXMT() {
        var game = AppAnalysis(architecture: .x64)
        game.graphicsAPIs = [.d3d11]
        XCTAssertEqual(BackendSelector.policy(analysis: game).order.first, .dxmt)
    }
}

final class AutostartBlockerTests: XCTestCase {
    func testSteamRunEntryIsRemoved() {
        let text = """
        [Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1794110195
        #time=1dd6f3526531200
        "Steam"="\\"C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe\\" -silent"
        "Helper"="C:\\\\tools\\\\helper.exe"

        [Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\ThemeManager] 1794109883
        "ColorName"="Blue"
        """
        let result = AutostartBlocker.strip(text)
        XCTAssertEqual(result.removed, ["Steam"])
        XCTAssertFalse(result.text.contains("steam.exe"))
        XCTAssertTrue(result.text.contains("\"Helper\""), "other start-up entries stay")
        XCTAssertTrue(result.text.contains("ColorName"))
        XCTAssertTrue(result.text.contains("#time=1dd6f3526531200"))
    }

    func testOtherKeysMentioningSteamAreLeftAlone() {
        let text = """
        [Software\\\\Valve\\\\Steam] 1794110195
        "SteamExe"="c:/program files (x86)/steam/steam.exe"
        """
        XCTAssertTrue(AutostartBlocker.strip(text).removed.isEmpty)
    }

    func testContinuationLinesAreRemovedWithTheirValue() {
        let text = """
        [Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1
        "EpicGamesLauncher"=hex(2):43,00,3a,00,5c,00,65,00,70,00,69,00,63,00,67,00,61,00,6d,00,65,00,73,00,\\
          6c,00,61,00,75,00,6e,00,63,00,68,00,65,00,72,00,2e,00,65,00,78,00,65,00,00,00 epicgameslauncher.exe
        "Keep"="x"
        """
        let result = AutostartBlocker.strip(text)
        XCTAssertTrue(result.removed.isEmpty, "the launcher's name is only in the continuation line here")
        let named = text.replacingOccurrences(of: "\"EpicGamesLauncher\"=hex(2)", with: "\"EpicGamesLauncher.exe\"=hex(2)")
        let stripped = AutostartBlocker.strip(named)
        XCTAssertEqual(stripped.removed, ["EpicGamesLauncher.exe"])
        XCTAssertFalse(stripped.text.contains("6c,00,61"), "its continuation line goes too")
        XCTAssertTrue(stripped.text.contains("\"Keep\""))
    }

    func testRegistryFilesAreEditedInPlace() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("cell-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let user = "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run] 1\n\"Steam\"=\"steam.exe -silent\"\n"
        try user.write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AutostartBlocker.removeEntries(prefix: prefix), ["Steam"])
        let after = try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        XCTAssertTrue(after.hasPrefix("WINE REGISTRY Version 2"))
        XCTAssertFalse(after.contains("steam.exe"))
    }
}

final class GameDisplayFixerTests: XCTestCase {
    /// Escape the Backrooms' real settings: point-sized resolution, exclusive fullscreen, 87% 3D resolution.
    let escapeTheBackrooms = """
    [/Script/Engine.GameUserSettings]
    bUseDynamicResolution=False
    ResolutionSizeX=1470
    ResolutionSizeY=956
    LastUserConfirmedResolutionSizeX=1470
    LastUserConfirmedResolutionSizeY=956
    WindowPosX=-1
    FullscreenMode=0
    LastConfirmedFullscreenMode=1
    PreferredFullscreenMode=0
    DesiredScreenWidth=1280

    [ScalabilityGroups]
    sg.ResolutionQuality=87.000000
    sg.ShadowQuality=0
    sg.TextureQuality=2
    """

    func testUnrealGameGetsFullResolutionButKeepsQuality() throws {
        let size = GameDisplayFixer.Size(width: 2940, height: 1912)
        let fixed = try XCTUnwrap(GameDisplayFixer.fixUnreal(escapeTheBackrooms, size: size))
        XCTAssertTrue(fixed.contains("ResolutionSizeX=2940"))
        XCTAssertTrue(fixed.contains("ResolutionSizeY=1912"))
        XCTAssertTrue(fixed.contains("LastUserConfirmedResolutionSizeX=2940"))
        XCTAssertTrue(fixed.contains("FullscreenMode=1\n"))
        XCTAssertFalse(fixed.contains("PreferredFullscreenMode=0"))
        XCTAssertTrue(fixed.contains("sg.ResolutionQuality=100.000000"))
        XCTAssertTrue(fixed.contains("sg.ShadowQuality=0"), "quality settings stay as the player set them")
        XCTAssertTrue(fixed.contains("sg.TextureQuality=2"))
        XCTAssertTrue(fixed.contains("DesiredScreenWidth=2940"), "the fallback size follows")
        XCTAssertNil(GameDisplayFixer.fixUnreal(fixed, size: size), "nothing left to change the second time")
    }

    /// What Escape the Backrooms saved on the Mac: full size already, but no 3D resolution at all.
    func testMissing3DResolutionIsWrittenAsFull() throws {
        let size = GameDisplayFixer.Size(width: 2940, height: 1912)
        let saved = """
        [/Script/Engine.GameUserSettings]
        ResolutionSizeX=2940
        ResolutionSizeY=1912
        LastUserConfirmedResolutionSizeX=2940
        LastUserConfirmedResolutionSizeY=1912
        FullscreenMode=1
        DesiredScreenWidth=1280
        DesiredScreenHeight=720

        [ScalabilityGroups]
        sg.ShadowQuality=0
        sg.TextureQuality=2

        [D3DRHIPreference]
        PreferredRHI=dx11
        """
        let fixed = try XCTUnwrap(GameDisplayFixer.fixUnreal(saved, size: size))
        XCTAssertTrue(fixed.contains("sg.TextureQuality=2\nsg.ResolutionQuality=100.000000\n\n[D3DRHIPreference]"), fixed)
        XCTAssertTrue(fixed.contains("DesiredScreenHeight=1912"))
        XCTAssertNil(GameDisplayFixer.fixUnreal(fixed, size: size))

        let noGroups = "[/Script/Engine.GameUserSettings]\r\nResolutionSizeX=2940\r\nResolutionSizeY=1912\r\nFullscreenMode=1\r\n"
        let added = try XCTUnwrap(GameDisplayFixer.fixUnreal(noGroups, size: size))
        XCTAssertTrue(added.hasSuffix("[ScalabilityGroups]\r\nsg.ResolutionQuality=100.000000\r\n"), added)
        XCTAssertNil(GameDisplayFixer.fixUnreal(added, size: size))
    }

    func testWindowedUnrealGamesAreLeftAlone() {
        let windowed = escapeTheBackrooms.replacingOccurrences(of: "FullscreenMode=0\n", with: "FullscreenMode=2\n")
        XCTAssertNil(GameDisplayFixer.fixUnreal(windowed, size: .init(width: 2940, height: 1912)))
    }

    func testWindowsLineEndingsSurvive() throws {
        let crlf = escapeTheBackrooms.replacingOccurrences(of: "\n", with: "\r\n")
        let fixed = try XCTUnwrap(GameDisplayFixer.fixUnreal(crlf, size: .init(width: 2940, height: 1912)))
        XCTAssertTrue(fixed.contains("ResolutionSizeX=2940\r\n"))
    }

    func testUnrealProjectFromExecutablePath() {
        var app = AppEntry(containerID: UUID(), name: "Escape the Backrooms", kind: .steamGame, source: .steam)
        app.windowsPath = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\EscapeTheBackrooms\\EscapeTheBackrooms\\Binaries\\Win64\\Backrooms-Win64-Shipping.exe"
        XCTAssertEqual(GameDisplayFixer.unrealProject(of: app), "EscapeTheBackrooms")
    }

    func testUnityValueNamesMatchUnity() {
        XCTAssertEqual(GameDisplayFixer.unityValueName("Screenmanager Resolution Width"), "Screenmanager Resolution Width_h182942802")
        XCTAssertEqual(GameDisplayFixer.unityValueName("Screenmanager Resolution Height"), "Screenmanager Resolution Height_h2627697771")
        XCTAssertEqual(GameDisplayFixer.unityValueName("Screenmanager Fullscreen mode"), "Screenmanager Fullscreen mode_h3630240806")
    }

    func testUnityEditsOnlyWhatIsNeeded() {
        let saved = WineRegistryHive.parse("""
        [Software\\\\LandCrab\\\\PEAK] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000000
        "Screenmanager Resolution Height_h2627697771"=dword:000003bc
        "Screenmanager Resolution Width_h182942802"=dword:000005be
        """, rootName: "HKEY_CURRENT_USER")
        let edits = GameDisplayFixer.unityEdits(company: "LandCrab", product: "PEAK", saved: saved, size: .init(width: 2940, height: 1912))
        XCTAssertEqual(edits.count, 3)
        let already = WineRegistryHive.parse("""
        [Software\\\\LandCrab\\\\PEAK] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000001
        "Screenmanager Resolution Height_h2627697771"=dword:00000778
        "Screenmanager Resolution Width_h182942802"=dword:00000b7c
        """, rootName: "HKEY_CURRENT_USER")
        XCTAssertTrue(GameDisplayFixer.unityEdits(company: "LandCrab", product: "PEAK", saved: already, size: .init(width: 2940, height: 1912)).isEmpty)
        let windowed = WineRegistryHive.parse("""
        [Software\\\\LandCrab\\\\PEAK] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000003
        """, rootName: "HKEY_CURRENT_USER")
        XCTAssertTrue(GameDisplayFixer.unityEdits(company: "LandCrab", product: "PEAK", saved: windowed, size: .init(width: 2940, height: 1912)).isEmpty)
    }

    func testTargetSizeFollowsRetinaMode() {
        let display = DisplayInfo(pixelWidth: 2940, pixelHeight: 1912, pointWidth: 1470, pointHeight: 956, scale: 2, refreshRate: 60)
        XCTAssertEqual(GameDisplayFixer.targetSize(highResolution: true, display: display), .init(width: 2940, height: 1912))
        XCTAssertEqual(GameDisplayFixer.targetSize(highResolution: false, display: display), .init(width: 1470, height: 956))
    }
}

final class VirtualMachineTests: XCTestCase {
    func testGuestSystems() {
        XCTAssertEqual(GuestSystem.linux.support, .ready)
        XCTAssertFalse(GuestSystem.allCases.map(\.rawValue).contains("iOS"), "iOS and iPadOS are not offered")
        XCTAssertEqual(GuestSystem.macOS.installerTypes, ["ipsw"])
        XCTAssertTrue(GuestSystem.windows.installerTypes.contains("iso"))
    }

    func testVirtualMachineSettingsRoundTrip() throws {
        var machine = VirtualMachine(name: "Ubuntu", guest: .linux, cpuCount: 4, memoryMiB: 4096, diskGiB: 64, installMedia: "Installer.iso")
        machine.kernelCommandLine = "console=hvc0"
        let decoded = try JSONDecoder().decode(VirtualMachine.self, from: JSONEncoder().encode(machine))
        XCTAssertEqual(decoded, machine)
        XCTAssertEqual(decoded.nextStartSummary, "Starts the installer")
        XCTAssertEqual(decoded.bundle.pathExtension, "cellvm")
    }

    func testDisksAreSparse() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell-disk-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: url) }
        try VirtualMachineLibrary.createDisk(at: url, gibibytes: 8)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        XCTAssertEqual(values.fileSize, 8 << 30)
        XCTAssertLessThan(values.totalFileAllocatedSize ?? Int.max, 1 << 20, "an empty disk takes no space")
    }
}

/// Round 4b: Unreal games on DXMT, engines without fonts, message boxes.
final class UnrealAndDialogTests: XCTestCase {
    func testEngineWithoutFontsIsReported() {
        let output = "probe 1\nfactory 0x00000000\nadapter 0x106b 0x00000000 Apple M5\nd3d11 0x00000000 0xb100\nwindow 1\nswapchain 0x00000000\npresent 0x00000000\nd3d12 0x80004002\ntext 0x0000 0x0000 0x00000000\ndone\n"
        let check = EngineProbe.parse(output, runtimeID: "pk", backend: .dxmt, fingerprint: "f", exitCode: 0)
        XCTAssertTrue(check.runsDirect3D11)
        XCTAssertEqual(check.drawsText, false)
        XCTAssertTrue(check.summary.contains("Windows dialogs show no text"))
        let good = output.replacingOccurrences(of: "text 0x0000 0x0000 0x00000000", with: "text 0x0031 0x000f 0x00100008")
        XCTAssertEqual(EngineProbe.parse(good, runtimeID: "sk", backend: .dxmt, fingerprint: "f", exitCode: 0).drawsText, true)
    }

    /// The message Escape the Backrooms showed in an empty title bar (Simplified Chinese).
    func testMessageBoxTextIsDecoded() {
        let log = """
        msync: up and running.
        0024:trace:msgbox:MSGBOX_OnInit L"\\60a8\\7684\\7cfb\\7edf\\4e0d\\652f\\6301DX12\\3002\\8bf7\\5c1d\\8bd5\\5728\\6ca1\\6709-dx12 \\6216-d3d12\\53c2\\6570\\7684\\60c5\\51b5\\4e0b\\8fd0\\884c\\3002"
        warn:  DXGIAdapter: Unknown interface query
        0030:trace:msgbox:MSGBOX_OnInit L"Line one\\nSays \\"hi\\" \\\\ done"
        """
        let messages = WineMessageBoxes.messages(in: log)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0], "您的系统不支持DX12。请尝试在没有-dx12 或-d3d12参数的情况下运行。")
        XCTAssertEqual(messages[1], "Line one\nSays \"hi\" \\ done")
    }

    func testUnrealGamesAreSetToDirect3D11AndBack() throws {
        let container = Container(name: "Test \(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: container.directory) }
        let folder = container.driveC.appendingPathComponent("users/nico/AppData/Local/EscapeTheBackrooms/Saved/Config/WindowsNoEditor")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[/Script/Engine.GameUserSettings]\nFullscreenMode=1\n\n[D3DRHIPreference]\nPreferredRHI=dx12\n"
            .write(to: folder.appendingPathComponent("GameUserSettings.ini"), atomically: true, encoding: .utf8)
        try "[Core.System]\nPaths=../../../Engine/Content\n".write(to: folder.appendingPathComponent("Engine.ini"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GameDisplayFixer.setUnrealDirect3D11(true, container: container).count, 1)
        let engine = try String(contentsOf: folder.appendingPathComponent("Engine.ini"), encoding: .utf8)
        XCTAssertTrue(engine.contains("[/Script/WindowsTargetPlatform.WindowsTargetSettings]\nDefaultGraphicsRHI=DefaultGraphicsRHI_DX11"))
        XCTAssertTrue(engine.contains("Paths=../../../Engine/Content"), "the game's own lines stay")
        XCTAssertTrue(try String(contentsOf: folder.appendingPathComponent("GameUserSettings.ini"), encoding: .utf8).contains("PreferredRHI=dx11"))
        XCTAssertTrue(GameDisplayFixer.setUnrealDirect3D11(true, container: container).isEmpty, "nothing to do the second time")

        XCTAssertEqual(GameDisplayFixer.setUnrealDirect3D11(false, container: container).count, 1)
        XCTAssertFalse(try String(contentsOf: folder.appendingPathComponent("Engine.ini"), encoding: .utf8).contains("DefaultGraphicsRHI_DX11"))
        XCTAssertTrue(GameDisplayFixer.setUnrealDirect3D11(false, container: container).isEmpty)
    }

    func testGamesThatNeverRanGetAConfigToo() throws {
        let container = Container(name: "Test \(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: container.directory) }
        try FileManager.default.createDirectory(at: container.driveC.appendingPathComponent("users/nico/AppData/Local"), withIntermediateDirectories: true)
        GameDisplayFixer.setUnrealDirect3D11(true, container: container, projects: ["Helios"])
        let engine = container.driveC.appendingPathComponent("users/nico/AppData/Local/Helios/Saved/Config/WindowsNoEditor/Engine.ini")
        XCTAssertTrue(try String(contentsOf: engine, encoding: .utf8).contains("DefaultGraphicsRHI=DefaultGraphicsRHI_DX11"))
    }

    func testBundledDXMTKeepsItsWineGeneration() throws {
        let runtime = FileManager.default.temporaryDirectory.appendingPathComponent("cell-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("wine"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtime) }
        try #"{"version": "11.0"}"#.write(to: runtime.appendingPathComponent("runtime.json"), atomically: true, encoding: .utf8)
        let bundled = GraphicsComponent(kind: .dxmt, version: "bundled", origin: runtime.appendingPathComponent("wine").path, has32Bit: false)
        XCTAssertEqual(bundled.minimumWineVersion, "11.0", "DXMT copied out of a Wine 11 engine doesn't run on Wine 10")
    }
}

/// Round 5: Unreal games were drawn at half the Retina resolution and stretched (Wine's DPI scaling).
final class SharpGamesTests: XCTestCase {
    /// Escape the Backrooms' manifest (no DPI entry) and PEAK's (Unity: per-monitor aware).
    func testManifestDPIAwareness() {
        let unreal = """
        <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3"><asmv3:application><ms_asmv1:windowsSettings xmlns:ms_asmv1="urn:schemas-microsoft-com:asm.v1" xmlns:ws2="http://schemas.microsoft.com/SMI/2016/WindowsSettings"><ws2:longPathAware>true</ws2:longPathAware></ms_asmv1:windowsSettings></asmv3:application></assembly>
        """
        XCTAssertFalse(PEFile.declaresDPIAwareness(manifest: unreal))
        let unity = """
        <application xmlns="urn:schemas-microsoft-com:asm.v3"><windowsSettings>
          <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">True/PM</dpiAware>
          <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
        </windowsSettings></application>
        """
        XCTAssertTrue(PEFile.declaresDPIAwareness(manifest: unity))
        XCTAssertTrue(PEFile.declaresDPIAwareness(manifest: "<dpiAware>true</dpiAware>"))
        XCTAssertTrue(PEFile.declaresDPIAwareness(manifest: "<asmv3:dpiAware>Per Monitor</asmv3:dpiAware>"))
        XCTAssertFalse(PEFile.declaresDPIAwareness(manifest: "<dpiAware>false</dpiAware>"))
        XCTAssertFalse(PEFile.declaresDPIAwareness(manifest: "<dpiAwareness>unaware</dpiAwareness><dpiAware>true</dpiAware>"),
                       "Windows 10 reads dpiAwareness first")
        XCTAssertTrue(PEFile.declaresDPIAwareness(manifest: "<dpiAwareness>bogus, System</dpiAwareness>"))
    }

    private func game(engine: EngineKind?, apis: Set<GraphicsAPI>, aware: Bool?) -> AppEntry {
        var app = AppEntry(containerID: UUID(), name: "Game", kind: .windowsExecutable, source: .manual,
                           windowsPath: "C:\\Games\\EscapeTheBackrooms\\Binaries\\Win64\\Backrooms-Win64-Shipping.exe")
        var analysis = AppAnalysis(architecture: .x64)
        analysis.engine = engine
        analysis.graphicsAPIs = apis
        analysis.declaresDPIAwareness = aware
        analysis.analyzedExecutable = "/games/EscapeTheBackrooms/Binaries/Win64/Backrooms-Win64-Shipping.exe"
        app.analysis = analysis
        app.settings.isGame = true
        return app
    }

    func testOnlyUnawareModernGamesAreMarked() throws {
        let services = CellServices()   // the planner only borrows it
        let planner = services.planner
        var container = Container(name: "Games")
        container.settings.highResolution = true
        container.settings.dpiMode = .custom
        container.settings.customDPI = 192
        XCTAssertTrue(planner.drawsAtFullPixels(game(engine: .unreal, apis: [.d3d11], aware: false), container: container))
        XCTAssertTrue(planner.drawsAtFullPixels(game(engine: nil, apis: [.d3d12], aware: false), container: container))
        XCTAssertFalse(planner.drawsAtFullPixels(game(engine: .unity, apis: [.d3d11], aware: true), container: container),
                       "already DPI-aware: Wine leaves it alone")
        XCTAssertFalse(planner.drawsAtFullPixels(game(engine: .unreal, apis: [], aware: nil), container: container),
                       "not analysed yet")
        XCTAssertFalse(planner.drawsAtFullPixels(game(engine: nil, apis: [.d3d9], aware: false), container: container),
                       "older games keep being scaled up (often small windows)")
        var forced = game(engine: nil, apis: [.d3d9], aware: false)
        forced.settings.nativeResolution = true
        XCTAssertTrue(planner.drawsAtFullPixels(forced, container: container))
        var off = game(engine: .unreal, apis: [.d3d11], aware: false)
        off.settings.nativeResolution = false
        XCTAssertFalse(planner.drawsAtFullPixels(off, container: container))

        container.settings.dpiMode = .standard
        XCTAssertFalse(planner.drawsAtFullPixels(game(engine: .unreal, apis: [.d3d11], aware: false), container: container),
                       "at 96 DPI Wine doesn't scale anything")
    }

    func testFlagIsWrittenByFileNameAndRemovedAgain() throws {
        let services = CellServices()   // the planner only borrows it
        let planner = services.planner
        var container = Container(name: "Games")
        container.settings.highResolution = true
        container.settings.dpiMode = .custom
        container.settings.customDPI = 192
        let layers = "Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers"
        let edits = planner.appDefaults(for: game(engine: .unreal, apis: [.d3d11], aware: false), container: container)
        let flag = try XCTUnwrap(edits.first { $0.key == layers && $0.name == "Backrooms-Win64-Shipping.exe" })
        XCTAssertEqual(flag.value, .string("~ HIGHDPIAWARE"))
        XCTAssertEqual(flag.hive, .currentUser, "Wine reads it from HKCU only")

        var off = game(engine: .unreal, apis: [.d3d11], aware: false)
        off.settings.nativeResolution = false
        let removed = try XCTUnwrap(planner.appDefaults(for: off, container: container).first { $0.key == layers })
        XCTAssertEqual(removed.value, .delete)
    }

    func testLeft4Dead2DPIOverrideRespectsAppSettings() throws {
        let services = CellServices()
        let planner = services.planner
        var container = Container(name: "Games")
        container.settings.highResolution = true
        container.settings.dpiMode = .custom
        container.settings.customDPI = 192
        var app = game(engine: .source, apis: [.d3d9], aware: false)
        app.kind = .steamGame
        app.steamAppID = "550"
        app.analysis?.analyzedExecutable = "/games/Left 4 Dead 2/left4dead2.exe"
        let layers = LaunchPlanner.appCompatLayers

        func dpiSetting(_ app: AppEntry) -> RegistryValue? {
            planner.appDefaults(for: app, container: container)
                .first { $0.key == layers && $0.name == "left4dead2.exe" }?.value
        }

        XCTAssertEqual(dpiSetting(app), .string("~ HIGHDPIAWARE"))
        app.settings.nativeResolution = false
        XCTAssertEqual(dpiSetting(app), .delete)
    }
}
