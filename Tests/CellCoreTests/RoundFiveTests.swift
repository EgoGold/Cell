import CoreText
import XCTest
@testable import CellCore

/// Round 5: fonts for every script, Dock names, plugin scopes, Godot, displays.
final class FontFallbackTests: XCTestCase {
    private let replacements = "Software\\Wine\\Fonts\\Replacements"
    private let fonts = "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts"

    func testWineFallbackNamesBecomeMacFonts() throws {
        let installed: Set<String> = ["PingFang SC", "Apple SD Gothic Neo", "Geeza Pro", "Kohinoor Devanagari"]
        let edits = FontConfigurator.scriptFallbackEdits(primary: nil, installed: installed, files: { "/System/Library/Fonts/\($0).ttc" })
        func alias(_ name: String) -> RegistryValue? { edits.first { $0.key == replacements && $0.name == name }?.value }
        XCTAssertEqual(alias("Noto Sans CJK JP"), .multiString(["PingFang SC"]), "Han characters without a language fall back to JP")
        XCTAssertEqual(alias("Noto Sans CJK KR"), .multiString(["Apple SD Gothic Neo"]))
        XCTAssertEqual(alias("Noto Sans Arabic"), .multiString(["Geeza Pro"]))
        XCTAssertEqual(alias("Noto Sans Devanagari"), .multiString(["Kohinoor Devanagari"]))
        XCTAssertNil(alias("Noto Sans Thai"), "no alias for a script whose Mac fonts aren't installed")
        let file = try XCTUnwrap(edits.first { $0.key == fonts && $0.name == "Geeza Pro (Mac)" })
        XCTAssertEqual(file.hive, .localMachine, "DirectWrite reads installed fonts from HKLM")
        XCTAssertEqual(file.value, .string("Z:\\System\\Library\\Fonts\\Geeza Pro.ttc"))
        XCTAssertEqual(edits.filter { $0.key == fonts }.count, installed.count, "each font file is registered once")
    }

    func testJapaneseMacPrefersHiragino() {
        let edits = FontConfigurator.scriptFallbackEdits(primary: .japanese, installed: ["Hiragino Sans", "PingFang SC"], files: { _ in nil })
        XCTAssertEqual(edits.first { $0.name == "Noto Sans CJK JP" }?.value, .multiString(["Hiragino Sans", "PingFang SC"]))
    }

    func testContainersGetTheFallbacks() {
        let services = CellServices()
        var container = Container(name: "Games")
        container.settings.cjkFontFallbacks = true
        let edits = services.planner.registryConfiguration(for: container)
        let installed = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        if installed.contains("PingFang SC") {
            XCTAssertTrue(edits.contains { $0.key == replacements && $0.name == "Noto Sans CJK SC" })
        }
    }
}

final class DockNameTests: XCTestCase {
    func testEveryProgramOfAnAppIsListed() {
        let container = Container(name: "Games")
        let steam = AppEntry(containerID: container.id, name: "Steam", kind: .steamClient, source: .steam,
                             windowsPath: "C:\\Program Files (x86)\\Steam\\steam.exe")
        var game = AppEntry(containerID: container.id, name: "Escape the Backrooms", kind: .steamGame, source: .steam,
                            windowsPath: "C:\\Program Files (x86)\\Steam\\steamapps\\common\\EscapeTheBackrooms\\Backrooms.exe")
        var analysis = AppAnalysis(architecture: .x64)
        analysis.analyzedExecutable = "/x/EscapeTheBackrooms/Binaries/Win64/Backrooms-Win64-Shipping.exe"
        game.analysis = analysis
        let entries = DockNames.entries(for: [steam, game, game])
        let names = Dictionary(uniqueKeysWithValues: entries.map { ($0.program, $0.name) })
        XCTAssertEqual(names["steam.exe"], "Steam")
        XCTAssertEqual(names["steamwebhelper.exe"], "Steam", "Steam's window belongs to its web helper")
        XCTAssertEqual(names["backrooms.exe"], "Escape the Backrooms")
        XCTAssertEqual(names["backrooms-win64-shipping.exe"], "Escape the Backrooms")
        XCTAssertEqual(entries.count, names.count, "no program twice")
    }

    func testTheLibraryIsUniversal() throws {
        let data = try XCTUnwrap(DockNames.library)
        XCTAssertEqual(Array(data.prefix(4)), [0xCA, 0xFE, 0xBA, 0xBE], "a fat Mach-O")
        XCTAssertNotNil(data.range(of: Data("CELL_DOCK_NAMES".utf8)))
    }
}

final class PluginScopeTests: XCTestCase {
    private func plugin(_ id: String, chosen: Bool = false, platforms: [String]? = nil) -> InstalledPlugin {
        var manifest = PluginManifest(id: id, name: id)
        if chosen || platforms != nil { manifest.scope = PluginScope(containers: chosen ? "chosen" : nil, platforms: platforms) }
        return InstalledPlugin(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/\(id)"), isBuiltin: false)
    }

    func testOffInOneLayerStaysOnElsewhere() {
        let games = Container(name: "Games"), work = Container(name: "Work")
        let fix = plugin("fix.one")
        var state = PluginState()
        XCTAssertTrue(state.isActive(fix, in: games))
        state.setActive(false, plugin: fix, in: games)
        XCTAssertFalse(state.isActive(fix, in: games))
        XCTAssertTrue(state.isActive(fix, in: work))
        state.setActive(true, plugin: fix, in: games)
        XCTAssertTrue(state.isActive(fix, in: games))
    }

    func testChosenLayersOnly() {
        let games = Container(name: "Games"), work = Container(name: "Work")
        let fix = plugin("fix.two")
        var state = PluginState()
        state.setScope([work.id], plugin: fix)
        XCTAssertFalse(state.isActive(fix, in: games))
        XCTAssertTrue(state.isActive(fix, in: work))
        state.setActive(true, plugin: fix, in: games)
        XCTAssertEqual(state.scope(of: fix), [work.id, games.id])
        state.setScope(nil, plugin: fix)
        XCTAssertTrue(state.isActive(fix, in: games) && state.isActive(fix, in: work))
    }

    func testPluginsCanAskToBeChosenAndNameTheirPlatform() {
        let games = Container(name: "Games")
        let linux = Container(name: "Linux", platform: .linux)
        var state = PluginState()
        let chosen = plugin("fix.three", chosen: true)
        XCTAssertFalse(state.isActive(chosen, in: games), "off until turned on in a layer")
        state.setActive(true, plugin: chosen, in: games)
        XCTAssertTrue(state.isActive(chosen, in: games))
        let windowsOnly = plugin("fix.four", platforms: ["windows"])
        XCTAssertTrue(state.isActive(windowsOnly, in: games))
        XCTAssertFalse(state.isActive(windowsOnly, in: linux))
    }

    func testOffEverywhereThenOnInOneLayer() {
        let games = Container(name: "Games"), work = Container(name: "Work")
        let fix = plugin("fix.five")
        var state = PluginState()
        state.disabled.insert(fix.id)
        state.setActive(true, plugin: fix, in: games)
        XCTAssertTrue(state.isActive(fix, in: games))
        XCTAssertFalse(state.isActive(fix, in: work))
    }

    func testOldStateFilesStillLoad() throws {
        let old = #"{"disabled":["a.b.c"],"trustedScripts":[]}"#
        let state = try JSONDecoder().decode(PluginState.self, from: Data(old.utf8))
        XCTAssertEqual(state.disabled, ["a.b.c"])
        XCTAssertTrue(state.onlyIn.isEmpty && state.disabledIn.isEmpty)
    }

    func testScopeIsValidated() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest = PluginManifest(id: "test.scope", name: "Scope", match: PluginMatch(any: [{ var r = MatchRule(); r.executable = "a.exe"; return r }()]))
        manifest.scope = PluginScope(containers: "some", platforms: nil)
        XCTAssertThrowsError(try PluginManager.validate(manifest, directory: folder))
        manifest.scope = PluginScope(containers: "chosen", platforms: ["playstation"])
        XCTAssertThrowsError(try PluginManager.validate(manifest, directory: folder))
        manifest.scope = PluginScope(containers: "all", platforms: ["windows"])
        XCTAssertNoThrow(try PluginManager.validate(manifest, directory: folder))
    }
}

final class GodotAndDisplayTests: XCTestCase {
    private func pack(major: UInt32, minor: UInt32, patch: UInt32) -> Data {
        var data = Data("GDPC".utf8)
        for value in [UInt32(3), major, minor, patch] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data + Data(count: 64)
    }

    func testGodotVersionFromEmbeddedAndSeparatePacks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("godot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let packed = pack(major: 4, minor: 8, patch: 0)
        var executable = Data(repeating: 0x90, count: 4096) + packed
        withUnsafeBytes(of: UInt64(packed.count).littleEndian) { executable.append(contentsOf: $0) }
        executable.append(Data("GDPC".utf8))
        let exe = folder.appendingPathComponent("Game.exe")
        try executable.write(to: exe)
        XCTAssertEqual(AppAnalyzer.godotVersion(pack: exe, embedded: true), "4.8.0")
        let separate = folder.appendingPathComponent("Game.pck")
        try pack(major: 3, minor: 5, patch: 2).write(to: separate)
        XCTAssertEqual(AppAnalyzer.godotVersion(pack: separate, embedded: false), "3.5.2")

        var analysis = AppAnalysis(architecture: .x64)
        AppAnalyzer.describeGodot(version: "4.8.0", analysis: &analysis)
        XCTAssertEqual(analysis.graphicsAPIs, [.vulkan], "Godot 4 draws with Vulkan by default")
    }

    func testUnknownDisplaysFallBackToTheMainOne() {
        DisplayInfo.prime()
        XCTAssertEqual(DisplayInfo.resolve(nil).id, DisplayInfo.main().id)
        XCTAssertEqual(DisplayInfo.resolve("not-connected").id, DisplayInfo.main().id)
        XCTAssertTrue(DisplayInfo.all().first?.isMain ?? false, "the main display comes first, like Wine's primary monitor")
        var settings = ContainerSettings()
        settings.highResolution = true
        let retina = DisplayInfo(pixelWidth: 2940, pixelHeight: 1912, pointWidth: 1470, pointHeight: 956, scale: 2, refreshRate: 120)
        let external = DisplayInfo(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 1920, pointHeight: 1080, scale: 1, refreshRate: 60, id: "ext", isMain: false, index: 1)
        XCTAssertEqual(LaunchPlanner.dpi(for: settings, display: retina), 192)
        XCTAssertEqual(LaunchPlanner.dpi(for: settings, display: external), 96, "text size follows the chosen display")
    }

    func testUnityGamesCanStartOnAnotherMonitor() {
        let edit = GameDisplayFixer.unityMonitorEdit(company: "Landfall", product: "PEAK", index: 1)
        XCTAssertEqual(edit.key, "Software\\Landfall\\PEAK")
        XCTAssertEqual(edit.value, .dword(1))
        XCTAssertTrue(edit.name?.hasPrefix("UnitySelectMonitor_h") ?? false)
    }
}

/// Chamber was renamed Cell: existing data, plugins, machines and Steam's launcher keep working.
final class RenameTests: XCTestCase {
    func testTheOldDataFolderMovesAndItsLinksFollow() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let legacy = base.appendingPathComponent("Chamber"), current = base.appendingPathComponent("Cell")
        let wine = legacy.appendingPathComponent("Runtimes/engine/wine/share")
        let flavor = legacy.appendingPathComponent("Runtimes/engine/flavors/dxmt")
        try FileManager.default.createDirectory(at: wine, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flavor, withIntermediateDirectories: true)
        try "inf".write(to: wine.appendingPathComponent("wine.inf"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: flavor.appendingPathComponent("share").path, withDestinationPath: wine.path)

        XCTAssertEqual(LegacyFolder.adopt(legacy, as: current, inUse: { _ in true }), legacy, "never while something runs from it")
        XCTAssertEqual(LegacyFolder.adopt(legacy, as: current, inUse: { _ in false }), legacy, "never from a test run")
        try FileManager.default.moveItem(at: legacy, to: current)   // what adopt does in Cell
        LegacyFolder.repairLinks(in: current, from: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let moved = current.appendingPathComponent("Runtimes/engine/flavors/dxmt/share/wine.inf")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "inf", "the engine flavor still finds Wine's data")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: current.appendingPathComponent("Runtimes/engine/flavors/dxmt/share").path),
                       "../../wine/share")
        XCTAssertEqual(LegacyFolder.adopt(legacy, as: current, inUse: { _ in false }), current, "nothing to move twice")
    }

    func testRelativePaths() {
        XCTAssertEqual(FileOps.relativePath(from: URL(fileURLWithPath: "/a/b/flavors/x"), to: URL(fileURLWithPath: "/a/b/wine/share")), "../../wine/share")
        XCTAssertEqual(FileOps.relativePath(from: URL(fileURLWithPath: "/a"), to: URL(fileURLWithPath: "/a/b")), "b")
    }

    func testLaunchersFromBeforeTheRenameAreRecognized() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("steamwebhelper-\(UUID().uuidString).exe")
        defer { try? FileManager.default.removeItem(at: file) }
        var old = Data("MZ".utf8) + Data(count: 64)
        old.append(Data("CHAMBER_WEBHELPER_FLAGS".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        try old.write(to: file)
        XCTAssertTrue(SteamWebHelperWrapper.isWrapper(file), "an old launcher must never be taken for Valve's program")
        XCTAssertFalse(SteamWebHelperWrapper.isCurrentWrapper(file), "and it gets replaced")
    }
}
