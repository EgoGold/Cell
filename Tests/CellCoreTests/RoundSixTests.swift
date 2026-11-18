import XCTest
@testable import CellCore

/// Round 6: sticky engines, installers that can't work, plugin options and devices, sharp Chromium pages, .NET.
final class RoundSixTests: XCTestCase {
    func testGraphicsEnginesThatHandleEachKindOfDirect3D() {
        XCTAssertTrue(LaunchPlanner.handles(.d3dmetal, need: .direct3D12))
        XCTAssertFalse(LaunchPlanner.handles(.dxmt, need: .direct3D12), "DXMT has no Direct3D 12")
        XCTAssertTrue(LaunchPlanner.handles(.dxmt, need: .direct3D11))
        XCTAssertFalse(LaunchPlanner.handles(.wined3d, need: .direct3D11), "WineD3D has no Direct3D 11 on macOS")
        XCTAssertTrue(LaunchPlanner.handles(.wined3d, need: .none))
    }

    func testInstallersThatCantWorkAreExplained() {
        func verdict(_ name: String) -> KnownInstallers.Verdict { KnownInstallers.verdict(for: URL(fileURLWithPath: "/tmp/\(name)")) }
        guard case .unsupported = verdict("XboxInstaller.exe") else { return XCTFail("the Xbox app needs the Microsoft Store") }
        guard case .unsupported = verdict("Game.msixbundle") else { return XCTFail("Store packages can't install") }
        XCTAssertEqual(verdict("EpicGamesLauncherSetup.exe"), .normal)   // runs as it is (after its prerequisites)
        XCTAssertEqual(verdict("SteamSetup.exe"), .normal)
    }

    func testShortEngineNames() {
        XCTAssertEqual(WineRuntime.shortName(for: "Metal engine (wine sikarugir 10.0 (revision 2 D3DMetal-v2.1))"), "Metal")
        XCTAssertEqual(WineRuntime.shortName(for: "DXMT engine (wine-11.0 (PK_DXMT revision 1))"), "DXMT")
        XCTAssertEqual(WineRuntime.shortName(for: "Wine Staging 11.21"), "Wine Staging")
    }

    private func optionsPlugin() -> InstalledPlugin {
        var manifest = PluginManifest(id: "test.options", name: "Options", match: PluginMatch(any: [{ var r = MatchRule(); r.executable = "Game.exe"; return r }()]))
        manifest.options = [PluginOption(id: "fps", title: "Frame-rate cap", type: "choice", defaultValue: "60", choices: ["30", "60", "120"]),
                            PluginOption(id: "skipIntro", title: "Skip intro videos", type: "toggle", defaultValue: "false")]
        var fixes = PluginFixes()
        fixes.arguments = ArgumentsFix(append: ["-fps={option.fps}"], whenBackend: nil)
        fixes.devices = DeviceFix(serialPorts: ["com3": "/dev/cu.usbserial-*"])
        manifest.fixes = fixes
        var intro = PluginFixes()
        intro.arguments = ArgumentsFix(append: ["-nointro"], whenBackend: nil)
        manifest.optionFixes = ["skipIntro=true": intro]
        return InstalledPlugin(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/test.cell"), isBuiltin: false)
    }

    func testPluginOptionsShapeTheFixes() {
        let plugin = optionsPlugin()
        let context = MatchContext(executableName: "Game.exe")
        var state = PluginState()
        var fixes = FixResolver.resolve(plugins: [plugin], context: context, options: state)
        XCTAssertEqual(fixes.arguments, ["-fps=60"], "defaults until someone changes them")
        XCTAssertEqual(fixes.serialPorts["COM3"], "/dev/cu.usbserial-*")
        state.optionValues[plugin.id] = ["fps": "120", "skipIntro": "true"]
        fixes = FixResolver.resolve(plugins: [plugin], context: context, options: state)
        XCTAssertTrue(fixes.arguments.contains("-fps=120"))
        XCTAssertTrue(fixes.arguments.contains("-nointro"), "fixes that apply while an option is on")
    }

    func testPluginOptionsAndDevicesAreValidated() throws {
        let folder = FileManager.default.temporaryDirectory
        var manifest = optionsPlugin().manifest
        XCTAssertNoThrow(try PluginManager.validate(manifest, directory: folder))
        manifest.options?[0].type = "slider"
        XCTAssertThrowsError(try PluginManager.validate(manifest, directory: folder))
        manifest = optionsPlugin().manifest
        manifest.optionFixes = ["missing=true": PluginFixes()]
        XCTAssertThrowsError(try PluginManager.validate(manifest, directory: folder))
        manifest = optionsPlugin().manifest
        manifest.fixes?.devices = DeviceFix(serialPorts: ["COM3": "/Users/me/file"])
        XCTAssertThrowsError(try PluginManager.validate(manifest, directory: folder), "devices must be /dev paths")
    }

    func testChromiumHelpersAreFoundAndMadeSharp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qq-\(UUID().uuidString)")
        let browser = root.appendingPathComponent("qmbrowser")
        try FileManager.default.createDirectory(at: browser, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["icudtl.dat", "qb.pak", "qmbrowser.exe", "BugReport.exe"] { FileManager.default.createFile(atPath: browser.appendingPathComponent(name).path, contents: Data()) }
        XCTAssertEqual(AppAnalyzer.chromiumHelpers(in: root), ["qmbrowser.exe"], "crash reporters are left alone")

        let services = CellServices()
        var container = Container(name: "Games")
        container.settings.highResolution = true
        container.settings.dpiMode = .custom
        container.settings.customDPI = 192
        var app = AppEntry(containerID: container.id, name: "QQ Music", kind: .windowsExecutable, source: .manual,
                           windowsPath: "C:\\Program Files (x86)\\Tencent\\QQMusic\\QQMusic.exe")
        var analysis = AppAnalysis(architecture: .x86)
        analysis.declaresDPIAwareness = false
        analysis.chromiumHelpers = ["qmbrowser.exe"]
        app.analysis = analysis
        let edits = services.planner.appDefaults(for: app, container: container)
        let flag = try XCTUnwrap(edits.first { $0.key == LaunchPlanner.appCompatLayers && $0.name == "qmbrowser.exe" })
        XCTAssertEqual(flag.value, .string("~ HIGHDPIAWARE"))
    }

    func testDotNetProblemsAreNotGraphicsCrashes() {
        let log = """
        Unhandled Exception:
        System.TypeInitializationException: The type initializer for 'PCL.ModMain' threw an exception. ---> System.MissingMethodException: Method not found: object Microsoft.VisualBasic.Conversion.CTypeDynamic(object,System.Type)
        """
        let findings = LogAnalyzer.analyze(text: log, rules: LogAnalyzer.builtinRules, source: "wine")
        XCTAssertTrue(findings.contains { $0.id == LogAnalyzer.dotNetGap })
    }

    func testMicrosoftsDotNetIsTellingApartFromWinesStub() throws {
        let drive = FileManager.default.temporaryDirectory.appendingPathComponent("drive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: drive) }
        let framework = drive.appendingPathComponent("windows/Microsoft.NET/Framework64/v4.0.30319")
        let system32 = drive.appendingPathComponent("windows/system32")
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: framework.appendingPathComponent("clr.dll").path, contents: Data("MZ".utf8))
        try (Data("MZ".utf8) + Data(count: 60) + Data("Wine builtin DLL".utf8)).write(to: system32.appendingPathComponent("mscoree.dll"))
        XCTAssertFalse(CellServices.hasDotNetFramework(driveC: drive), "Wine's stub loader means .NET can't start")
        try (Data("MZ".utf8) + Data(count: 200)).write(to: system32.appendingPathComponent("mscoree.dll"))
        XCTAssertTrue(CellServices.hasDotNetFramework(driveC: drive))
    }
}
