import XCTest
@testable import CellCore

final class CompatibilityRegressionTests: XCTestCase {
    func testFullscreenDefaultAndPerGameOverride() throws {
        let container = Container(name: "Display defaults")
        var game = AppEntry(containerID: container.id, name: "Game", kind: .steamGame, source: .steam)
        XCTAssertTrue(ProgramSettings.startsFullscreen(game, in: container, fixes: nil))
        game.settings.extraArguments = ["-screen-fullscreen", "0"]
        XCTAssertFalse(ProgramSettings.startsFullscreen(game, in: container, fixes: nil))
        game.settings.extraArguments = []
        game.settings.startFullscreen = false
        XCTAssertFalse(ProgramSettings.startsFullscreen(game, in: container, fixes: nil))
        game.settings.startFullscreen = nil
        game.steamAppID = "3404470"
        let services = CellServices()
        let fixes = services.planner.fixes(for: game, container: container)
        XCTAssertFalse(ProgramSettings.startsFullscreen(game, in: container, fixes: fixes))
        game.settings.startFullscreen = true
        XCTAssertTrue(ProgramSettings.startsFullscreen(game, in: container, fixes: fixes))
        game.kind = .steamClient
        XCTAssertFalse(ProgramSettings.startsFullscreen(game, in: container, fixes: fixes))
        XCTAssertTrue(try JSONDecoder().decode(ContainerSettings.self, from: Data("{}".utf8)).startGamesFullscreen)
    }

    func testMacFocusReplayNeedsPatchedWine() {
        let base = WineRuntime(id: "wine-sikarugir-10.0-revision-2", name: "Metal", version: "10.0", origin: .imported, originDescription: "")
        var fixed = base
        fixed.id = "sikarugir-wine-10.0-revision-8"
        XCTAssertFalse(base.canReplayMacFocus)
        XCTAssertTrue(fixed.canReplayMacFocus)
        XCTAssertTrue(fixed.fixesSikarugirFocusCompared(to: base))
        XCTAssertFalse(base.fixesSikarugirFocusCompared(to: fixed))
        var current = base
        current.version = "11.0"
        XCTAssertTrue(current.canReplayMacFocus)
        XCTAssertFalse(fixed.fixesSikarugirFocusCompared(to: current))
    }

    func testChromiumHelperDoesNotMakeDirectX12GamesUseBrowserFlags() throws {
        let plugin = try XCTUnwrap(PluginManager().plugins.first { $0.id == "dev.cell.engine.chromium-apps" })
        var analysis = AppAnalysis(architecture: .x64)
        analysis.engine = .cef
        XCTAssertTrue(FixResolver.resolve(plugins: [plugin], context: .init(analysis: analysis)).arguments.contains("--disable-gpu"))
        analysis.graphicsAPIs = [.d3d12]
        XCTAssertFalse(FixResolver.resolve(plugins: [plugin], context: .init(analysis: analysis)).arguments.contains("--disable-gpu"))
    }

    func testCitiesSkylinesLauncherArgumentsAreScoped() {
        let services = CellServices()
        let container = Container(name: "Launcher rule test")
        var app = AppEntry(containerID: container.id, name: "Cities: Skylines", kind: .steamGame,
                           source: .steam, steamAppID: "255710")
        let fixes = services.planner.fixes(for: app, container: container)
        XCTAssertNil(fixes.preferGameExecutable)
        XCTAssertEqual(fixes.steamLaunchArguments, ["--pdxlDisableHardwareAcceleration", "--pdxlEnableInProcessGpu"])
        XCTAssertFalse(fixes.arguments.contains("--pdxlDisableHardwareAcceleration"))
        app.steamAppID = "949230"
        let sequel = services.planner.fixes(for: app, container: container)
        XCTAssertTrue(sequel.steamLaunchArguments.isEmpty)
        XCTAssertEqual(sequel.steamCompatibilityLaunchers, ["dowser.exe"])
        XCTAssertEqual(sequel.minimumWineVersion, "11.0")
        XCTAssertEqual(sequel.enginePreference, ["bundled-dxmt"])
        XCTAssertEqual(sequel.preferBackends, [.dxmt])
        XCTAssertTrue(sequel.arguments(for: .dxmt).contains("-force-d3d11"))
        XCTAssertFalse(sequel.arguments(for: .d3dmetal).contains("-force-d3d11"))
        XCTAssertEqual(sequel.preferBorderlessFullscreen, false)
        XCTAssertNil(fixes.minimumWineVersion)
    }

    func testIdleEAServiceAllowsNewerWineButEAProgramsStillBlock() {
        let directory = #"C:\Program Files\Electronic Arts\EA Desktop\EA Desktop\"#
        var process = WineProcess(pid: 10, containerID: UUID(), executable: directory + "EABackgroundService.exe")
        XCTAssertFalse(Launcher.blocksCompatibilityEngineSwitch(process))
        process.executable = directory + "EADesktop.exe"
        XCTAssertTrue(Launcher.blocksCompatibilityEngineSwitch(process))
        process.executable = #"C:\Games\EABackgroundService.exe"#
        XCTAssertTrue(Launcher.blocksCompatibilityEngineSwitch(process))
    }

    func testIronLungEngineProfileIsOptInAndScoped() throws {
        let plugin = try XCTUnwrap(PluginManager().plugins.first { $0.id == "dev.cell.game.iron-lung" })
        let ironLung = MatchContext(steamAppID: "1846170")
        XCTAssertNil(FixResolver.resolve(plugins: [plugin], context: ironLung).minimumWineVersion)
        var options = PluginState()
        options.optionValues[plugin.id] = ["wine11DXMT": "true"]
        let fixes = FixResolver.resolve(plugins: [plugin], context: ironLung, options: options)
        XCTAssertEqual(fixes.minimumWineVersion, "11.0")
        XCTAssertEqual(fixes.preferBackends, [.dxmt])
        XCTAssertEqual(fixes.steamOverlay, .disabled)
        XCTAssertNil(FixResolver.resolve(plugins: [plugin], context: .init(steamAppID: "255710"),
                                         options: options).minimumWineVersion)
    }

    func testIronLungKeepsItsSavedDisplayMode() {
        let plugins = PluginManager().plugins
        var analysis = AppAnalysis(architecture: .x64)
        analysis.engine = .unity
        analysis.engineVersion = "2021.1.15"
        let ironLung = FixResolver.resolve(plugins: plugins, context: .init(steamAppID: "1846170", analysis: analysis))
        XCTAssertEqual(ironLung.preferBorderlessFullscreen, false)
        let generic = FixResolver.resolve(plugins: plugins, context: .init(analysis: analysis))
        XCTAssertEqual(generic.preferBorderlessFullscreen, true)

        let hive = WineRegistryHive.parse("""
        [Software\\\\David Szymanski\\\\Iron Lung] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000000
        "Screenmanager Resolution Width_h182942802"=dword:00000a00
        "Screenmanager Resolution Height_h2627697771"=dword:00000680
        """, rootName: "HKEY_CURRENT_USER")
        let size = GameDisplayFixer.Size(width: 2940, height: 1912)
        XCTAssertTrue(GameDisplayFixer.unityEdits(company: "David Szymanski", product: "Iron Lung", saved: hive, size: size,
                                                preferBorderlessFullscreen: ironLung.preferBorderlessFullscreen != false).isEmpty)
        XCTAssertFalse(GameDisplayFixer.unityEdits(company: "David Szymanski", product: "Iron Lung", saved: hive, size: size).isEmpty)
    }

    func testKnownBrokenUnityDisplayRepairsLiveValuesEvenWhenDiskLooksCorrect() {
        let hive = WineRegistryHive.parse("""
        [Software\\\\MistyMountainStudio\\\\Rewinder] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000001
        "Screenmanager Resolution Height_h2627697771"=dword:00000778
        "Screenmanager Resolution Width_h182942802"=dword:00000b7c
        """, rootName: "HKEY_CURRENT_USER")
        let edits = GameDisplayFixer.unityEdits(company: "MistyMountainStudio", product: "Rewinder", saved: hive,
                                               size: .init(width: 2940, height: 1912), choiceBroken: true)
        XCTAssertEqual(edits.count, 5, "Wine's live registry can differ from its last on-disk snapshot")
        XCTAssertTrue(edits.contains { $0.name == GameDisplayFixer.unityValueName("Screenmanager Resolution Width") && $0.value == .dword(2940) })
    }

    func testRewinderRecoveryShipsWithoutPersonalLearning() {
        let services = CellServices()
        let container = Container(name: "Display rule test")
        var game = AppEntry(containerID: container.id, name: "The Rewinder", kind: .steamGame,
                            source: .steam, steamAppID: "1161170")
        game.analysis = AppAnalysis(architecture: .x64)
        game.analysis?.analyzedExecutable = "/games/Rewinder.exe"
        XCTAssertFalse(game.learned.needsDisplayModes)
        XCTAssertTrue(services.planner.appDefaults(for: game, container: container).contains {
            $0.name == "EmulateModeset" && $0.value == .string("y")
        })
        game.steamAppID = "3103840"
        XCTAssertFalse(services.planner.appDefaults(for: game, container: container).contains { $0.name == "EmulateModeset" })
    }
    func testDegenerateUnityWindowIsRepairedWithoutChangingMode() {
        let hive = WineRegistryHive.parse("""
        [Software\\\\OPNeonGames\\\\Card Shop Simulator Prologue] 1
        "Screenmanager Fullscreen mode_h3630240806"=dword:00000003
        "Screenmanager Resolution Height_h2627697771"=dword:00000002
        "Screenmanager Resolution Width_h182942802"=dword:00000002
        """, rootName: "HKEY_CURRENT_USER")
        let edits = GameDisplayFixer.unityEdits(company: "OPNeonGames", product: "Card Shop Simulator Prologue",
                                               saved: hive, size: .init(width: 2940, height: 1912))
        XCTAssertEqual(edits.count, 4)
        XCTAssertFalse(edits.contains { $0.name == GameDisplayFixer.unityValueName("Screenmanager Fullscreen mode") })
        XCTAssertTrue(edits.contains { $0.name == GameDisplayFixer.unityValueName("Screenmanager Resolution Width") && $0.value == .dword(1280) })
        XCTAssertTrue(edits.contains { $0.name == GameDisplayFixer.unityValueName("Screenmanager Resolution Window Height") && $0.value == .dword(720) })
    }

    func testEmbeddedProbeUsesCurrentOutputVariable() {
        let current = "CELL_PROBE_OUT".data(using: .utf16LittleEndian)!
        let obsolete = "CHAMBER_PROBE_OUT".data(using: .utf16LittleEndian)!
        XCTAssertNotNil(EngineProbe.image.range(of: current))
        XCTAssertNil(EngineProbe.image.range(of: obsolete))
    }

    func testMovieQueueFixIsScopedToCapcom() {
        let services = CellServices()
        let container = Container(name: "Media rule test")
        let capcom = AppEntry(containerID: container.id, name: "Capcom Arcade Stadium", kind: .steamGame,
                              source: .steam, steamAppID: "1515950")
        let other = AppEntry(containerID: container.id, name: "Other", kind: .steamGame,
                             source: .steam, steamAppID: "1549440")
        XCTAssertEqual(services.planner.fixes(for: capcom, container: container).environment(for: .d3dmetal)["CELL_MEDIA_QUEUE_MB"], "32")
        XCTAssertNil(services.planner.fixes(for: other, container: container).environment(for: .d3dmetal)["CELL_MEDIA_QUEUE_MB"])
    }

    func testAudioDriverFixIsScopedToLoveCurse() {
        let services = CellServices()
        let container = Container(name: "Audio rule test")
        let love = AppEntry(containerID: container.id, name: "Love Curse", kind: .steamGame,
                            source: .steam, steamAppID: "3069120")
        let other = AppEntry(containerID: container.id, name: "Other", kind: .steamGame,
                             source: .steam, steamAppID: "1549440")
        XCTAssertEqual(services.planner.fixes(for: love, container: container).environment(for: .d3dmetal)["SDL_AUDIODRIVER"], "winmm")
        XCTAssertNil(services.planner.fixes(for: other, container: container).environment(for: .d3dmetal)["SDL_AUDIODRIVER"])
    }

    func testUnrealRendererRecommendationRespectsExplicitAPI() {
        let services = CellServices()
        let container = Container(name: "Unreal API rule test")
        let meiqi = AppEntry(containerID: container.id, name: "MeiQi", kind: .steamGame,
                             source: .steam, steamAppID: "1549440")
        let other = AppEntry(containerID: container.id, name: "Other", kind: .steamGame,
                             source: .steam, steamAppID: "1515950")
        let preference = services.planner.fixes(for: meiqi, container: container).environment(for: .d3dmetal)["CELL_UNREAL_RHI"]
        XCTAssertEqual(preference, "dx11")
        XCTAssertNil(services.planner.fixes(for: other, container: container).environment(for: .d3dmetal)["CELL_UNREAL_RHI"])
        XCTAssertTrue(GameDisplayFixer.prefersUnrealDirect3D11(backend: .d3dmetal, arguments: [], preference: preference))
        XCTAssertFalse(GameDisplayFixer.prefersUnrealDirect3D11(backend: .d3dmetal, arguments: ["-d3d12"], preference: preference))
        XCTAssertTrue(GameDisplayFixer.prefersUnrealDirect3D11(backend: .d3dmetal, arguments: ["-DX11"], preference: nil))
        XCTAssertFalse(GameDisplayFixer.prefersUnrealDirect3D11(backend: .d3dmetal, arguments: [], preference: nil))
        XCTAssertTrue(GameDisplayFixer.prefersUnrealDirect3D11(backend: .dxmt, arguments: [], preference: nil))
    }

    func testPreexistingUnrealRendererPreferenceIsNotClaimedAndRemoved() throws {
        let container = Container(name: "Existing API preference test")
        defer { try? FileManager.default.removeItem(at: container.directory) }
        let folder = container.driveC.appendingPathComponent("users/test/AppData/Local/Game/Saved/Config/Windows")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Engine.ini")
        let original = "[/Script/WindowsTargetPlatform.WindowsTargetSettings]\nDefaultGraphicsRHI=DefaultGraphicsRHI_DX11\n"
        try original.write(to: file, atomically: true, encoding: .utf8)
        GameDisplayFixer.setUnrealDirect3D11(true, container: container, projects: ["Game"], only: "Game")
        GameDisplayFixer.setUnrealDirect3D11(false, container: container, projects: ["Game"], only: "Game")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    func testSourceLoadsItsRendererFromBin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let exe = root.appendingPathComponent("left4dead2.exe")
        try PEFixture.make(machine: 0x014c, imports: ["kernel32.dll"]).write(to: exe)
        try Data().write(to: root.appendingPathComponent("bin/engine.dll"))
        try Data().write(to: root.appendingPathComponent("bin/shaderapidx9.dll"))
        let analysis = AppAnalyzer.analyze(executable: exe)
        XCTAssertEqual(analysis.engine, .source)
        XCTAssertEqual(analysis.graphicsAPIs, [.d3d9])
        XCTAssertEqual(BackendSelector.policy(analysis: analysis).order, [.wined3d, .dxvk])
        XCTAssertEqual(GraphicsNeed(analysis: analysis), .legacy)
    }

    func testMovedPrefixUsesCurrentExecutableAndRefreshesCache() throws {
        let container = Container(name: "Relocated test")
        defer { try? FileManager.default.removeItem(at: container.directory) }
        let game = container.driveC.appendingPathComponent("Games/Test")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let executable = game.appendingPathComponent("Test.exe")
        try PEFixture.make(imports: []).write(to: executable)
        var app = AppEntry(containerID: container.id, name: "Test", kind: .windowsExecutable,
                           source: .manual, windowsPath: "C:\\Games\\Test\\Test.exe")
        var analysis = AppAnalysis()
        analysis.revision = AppAnalyzer.revision
        analysis.analyzedExecutable = "/old/Chamber/prefix/drive_c/Games/Test/Test.exe"
        app.analysis = analysis
        XCTAssertEqual(AppAnalyzer.executable(for: app, in: container), executable)
        XCTAssertTrue(AppAnalyzer.needsRefresh(app, in: container))
        XCTAssertEqual(PathTemplateContext(container: container, app: app).expand("{exeDir}"), game.path)
        app.analysis?.analyzedExecutable = executable.path
        XCTAssertFalse(AppAnalyzer.needsRefresh(app, in: container))
    }

    func testPluginAndOverridesCannotReinsertUnsupported32BitBackend() {
        var analysis = AppAnalysis(architecture: .x86)
        analysis.graphicsAPIs = [.d3d11]
        var fixes = ResolvedFixes()
        fixes.preferBackends = [.dxmt, .d3dmetal]
        let support: [GraphicsBackend: RuntimeManager.BackendSupport] = [
            .dxmt: .init(backend: .dxmt, confident: true, supports32Bit: false, coversModernDirect3D: true),
            .d3dmetal: .init(backend: .d3dmetal, confident: true, supports32Bit: false, coversModernDirect3D: true),
            .dxvk: .init(backend: .dxvk, confident: true, supports32Bit: true, coversModernDirect3D: true)]
        let decision = BackendSelector.decide(analysis: analysis, support: support, fixes: fixes,
                                              userOverride: .d3dmetal, forced: .dxmt)
        XCTAssertEqual(decision.backend, .dxvk)
        XCTAssertTrue(decision.fallbacks.isEmpty)
    }

    func testUnityDynamicD3D11IsCheckedEvenWhenImportsOnlyShowOpenGL() {
        var analysis = AppAnalysis(architecture: .x64)
        analysis.engine = .unity
        analysis.graphicsAPIs = [.opengl]
        XCTAssertEqual(GraphicsNeed(analysis: analysis), .direct3D11)
    }

    func testChangingOneUnrealRendererDoesNotChangeAnotherGame() throws {
        let container = Container(name: "Isolated renderer test")
        defer { try? FileManager.default.removeItem(at: container.directory) }
        let local = container.driveC.appendingPathComponent("users/test/AppData/Local")
        for project in ["GameA", "GameB"] {
            let folder = local.appendingPathComponent("\(project)/Saved/Config/Windows")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "[UserSettings]\n".write(to: folder.appendingPathComponent("GameUserSettings.ini"), atomically: true, encoding: .utf8)
        }
        GameDisplayFixer.setUnrealDirect3D11(true, container: container, projects: ["GameA"], only: "GameA")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.appendingPathComponent("GameA/Saved/Config/Windows/Engine.ini").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("GameB/Saved/Config/Windows/Engine.ini").path))
    }
}

final class ComponentProvenanceTests: XCTestCase {
    func testUnknownBundledComponentIsNotAssumedCompatible() {
        let c = GraphicsComponent(kind: .dxmt, version: "bundled", origin: "/missing/Chamber/wine", has32Bit: true)
        for version in ["10.0", "11.0"] {
            let runtime = WineRuntime(id: "test", name: "test", version: version, origin: .imported, originDescription: "test")
            XCTAssertFalse(c.isCompatible(with: runtime))
            XCTAssertFalse(c.isCompatible(with: runtime, for32Bit: true))
        }
    }
    func testProvenanceSurvivesSerializationAndMissingOrigin() throws {
        var c = GraphicsComponent(kind: .dxmt, version: "bundled", origin: "/missing/Chamber/wine", has32Bit: false)
        c.sourceWineVersion = "11.0"
        c.sourceRuntimeID = "donor"
        let copy = try JSONDecoder().decode(GraphicsComponent.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(copy.sourceRuntimeID, "donor")
        XCTAssertEqual(copy.minimumWineVersion, "11.0")
        for (version, expected) in [("10.0", false), ("11.0", true), ("12.0", false)] {
            let runtime = WineRuntime(id: "test", name: "test", version: version, origin: .imported, originDescription: "test")
            XCTAssertEqual(copy.isCompatible(with: runtime), expected)
        }
    }
    func testOldMetadataDecodesWithUnknownProvenance() throws {
        let c = GraphicsComponent(kind: .dxmt, version: "bundled", origin: "/missing/wine", has32Bit: false)
        let encoded = try JSONEncoder().encode(c)
        let copy = try JSONDecoder().decode(GraphicsComponent.self, from: encoded)
        XCTAssertNil(copy.sourceWineVersion)
        XCTAssertNil(copy.sourceRuntimeID)
    }
}

final class DiagnosticCaptureTests: XCTestCase {
    func testTimeoutKeepsRequestedDiagnosticOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf diagnostic-before-timeout; exec sleep 5"], timeout: 0.2,
            outputDirectory: root))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("stdout"), encoding: .utf8),
                       "diagnostic-before-timeout")
    }
}
