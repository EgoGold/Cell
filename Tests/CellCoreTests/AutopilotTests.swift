import XCTest
@testable import CellCore

final class AutopilotTests: XCTestCase {
    private func support(_ backends: [GraphicsBackend], d3d11WineD3D: Bool = true, dxmt32: Bool = false) -> [GraphicsBackend: RuntimeManager.BackendSupport] {
        var result: [GraphicsBackend: RuntimeManager.BackendSupport] = [:]
        for backend in backends {
            result[backend] = RuntimeManager.BackendSupport(backend: backend, confident: true,
                                                            supports32Bit: backend == .wined3d || (backend == .dxmt && dxmt32),
                                                            coversModernDirect3D: backend != .wined3d || d3d11WineD3D)
        }
        return result
    }

    private func analysis(_ apis: Set<GraphicsAPI>, engine: EngineKind? = nil, version: String? = nil,
                          arch: PEArchitecture = .x64, agility: Bool = false) -> AppAnalysis {
        var a = AppAnalysis(architecture: arch)
        a.graphicsAPIs = apis
        a.engine = engine
        a.engineVersion = version
        a.hasD3D12AgilitySDK = agility
        return a
    }

    func testD3D11PrefersDXMT() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertEqual(decision.backend, .dxmt)
        XCTAssertEqual(decision.fallbacks, [.d3dmetal, .wined3d])
        XCTAssertEqual(decision.source, .automatic)
    }

    func testD3D12OnlyPrefersD3DMetal() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d12]), support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertEqual(decision.backend, .d3dmetal)
        XCTAssertFalse(decision.fallbacks.contains(.dxmt), "DXMT can't run a D3D12-only game")
    }

    func testUnityWithD3D12UsesDXMTAndForcesD3D11() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d11], engine: .unity, version: "6000.3.15f1", agility: true),
                                              support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertEqual(decision.backend, .dxmt)
        XCTAssertEqual(decision.extraArguments, ["-force-d3d11"])
    }

    func testUnreal5PrefersD3DMetalAndUsesDX11Fallback() {
        let unreal = analysis([.d3d11, .d3d12], engine: .unreal, version: "5.3")
        let decision = BackendSelector.decide(analysis: unreal, support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertEqual(decision.backend, .d3dmetal)
        let retry = BackendSelector.decide(analysis: unreal, support: support([.d3dmetal, .dxmt, .wined3d]), forced: .dxmt)
        XCTAssertEqual(retry.backend, .dxmt)
        XCTAssertEqual(retry.extraArguments, ["-dx11"])
        XCTAssertEqual(retry.source, .retry)
    }

    func test32BitGamesNeverGetD3DMetal() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d11], arch: .x86), support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertNotEqual(decision.backend, .d3dmetal)
        XCTAssertFalse(decision.fallbacks.contains(.d3dmetal))
    }

    func testLegacyDirectXUsesWineD3D() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d9]), support: support([.d3dmetal, .dxmt, .wined3d]))
        XCTAssertEqual(decision.backend, .wined3d)
    }

    func testLearnedAndFailedBackends() {
        var learned = LearnedCompat()
        learned.failedBackends = [.dxmt]
        let decision = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]), learned: learned)
        XCTAssertEqual(decision.backend, .d3dmetal, "a backend that crashed goes to the end")
        learned.workingBackend = .wined3d
        let remembered = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]), learned: learned)
        XCTAssertEqual(remembered.backend, .wined3d)
        XCTAssertEqual(remembered.source, .learned)
    }

    func testUserOverrideWins() {
        var learned = LearnedCompat()
        learned.workingBackend = .dxmt
        let decision = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]),
                                              learned: learned, userOverride: .d3dmetal)
        XCTAssertEqual(decision.backend, .d3dmetal)
        XCTAssertEqual(decision.source, .user)
    }

    func testUnavailableBackendsAreSkipped() {
        let decision = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.wined3d]))
        XCTAssertEqual(decision.backend, .wined3d)
        let noWineD3DForModern = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .wined3d], d3d11WineD3D: false),
                                                        baseBackend: .d3dmetal)
        XCTAssertEqual(noWineD3DForModern.backend, .d3dmetal)
        XCTAssertTrue(noWineD3DForModern.fallbacks.isEmpty)
    }

    func testPluginPreferenceAndAvoid() {
        var fixes = ResolvedFixes()
        fixes.preferBackends = [.d3dmetal]
        let decision = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]), fixes: fixes)
        XCTAssertEqual(decision.backend, .d3dmetal)
        XCTAssertEqual(decision.source, .plugin)

        var avoid = ResolvedFixes()
        avoid.avoidBackends = [.dxmt]
        let avoided = BackendSelector.decide(analysis: analysis([.d3d11]), support: support([.d3dmetal, .dxmt, .wined3d]), fixes: avoid)
        XCTAssertEqual(avoided.backend, .d3dmetal)
        XCTAssertEqual(avoided.fallbacks.last, .dxmt, "avoided backends stay as a last resort")
    }
}

final class PluginTests: XCTestCase {
    private func plugin(_ json: String, builtin: Bool = true) throws -> InstalledPlugin {
        let manifest = try JSONStore.decoder.decode(PluginManifest.self, from: Data(json.utf8))
        return InstalledPlugin(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/\(manifest.id).cell"), isBuiltin: builtin)
    }

    private var unityContext: MatchContext {
        var analysis = AppAnalysis(architecture: .x64)
        analysis.engine = .unity
        analysis.engineVersion = "6000.3.15f1"
        analysis.graphicsAPIs = [.d3d11]
        return MatchContext(executableName: "PEAK.exe", executablePath: "/games/PEAK/PEAK.exe", steamAppID: "3527290",
                            analysis: analysis, appKind: .steamGame)
    }

    func testMatchingRules() throws {
        let generic = try plugin(#"{"schemaVersion":1,"id":"a.unity","name":"Unity","version":"1","match":{"all":[{"engine":"unity","engineVersion":">=2019"}]}}"#)
        let old = try plugin(#"{"schemaVersion":1,"id":"a.old","name":"Old","version":"1","match":{"all":[{"engine":"unity","engineVersion":"<2019"}]}}"#)
        let byID = try plugin(#"{"schemaVersion":1,"id":"a.peak","name":"PEAK","version":"1","match":{"any":[{"steamAppID":"3527290"}]}}"#)
        let excluded = try plugin(#"{"schemaVersion":1,"id":"a.x","name":"X","version":"1","match":{"any":[{"executable":"*.exe"}],"none":[{"graphicsAPI":"d3d11"}]}}"#)
        XCTAssertTrue(FixResolver.matches(generic.manifest, context: unityContext))
        XCTAssertFalse(FixResolver.matches(old.manifest, context: unityContext))
        XCTAssertTrue(FixResolver.matches(byID.manifest, context: unityContext))
        XCTAssertFalse(FixResolver.matches(excluded.manifest, context: unityContext))
    }

    func testMergeOrderSpecificPluginWins() throws {
        let generic = try plugin(#"""
        {"schemaVersion":1,"id":"a.unity","name":"Unity","version":"1","match":{"all":[{"engine":"unity"}]},
         "fixes":{"graphics":{"prefer":["dxmt"]},"arguments":{"append":["-window-mode","borderless"],"whenBackend":{"dxmt":["-force-d3d11"]}},
                  "wine":{"scrollMode":"smooth"}}}
        """#)
        let specific = try plugin(#"""
        {"schemaVersion":1,"id":"a.peak","name":"PEAK","version":"1","match":{"any":[{"steamAppID":"3527290"}]},
         "fixes":{"graphics":{"prefer":["d3dmetal"]},"arguments":{"append":["-window-mode","borderless"],"whenBackend":{"dxmt":["-force-d3d11"]}},
                  "wine":{"scrollMode":"notched"},"notes":["n"]}}
        """#)
        let fixes = FixResolver.resolve(plugins: [specific, generic], context: unityContext)
        XCTAssertEqual(fixes.plugins.map(\.id), ["a.unity", "a.peak"])
        XCTAssertEqual(fixes.preferBackends.first, .d3dmetal)
        XCTAssertEqual(fixes.scrollMode, .notched)
        XCTAssertEqual(fixes.arguments(for: .dxmt), ["-window-mode", "borderless", "-force-d3d11"], "argument groups are not duplicated")
        XCTAssertEqual(fixes.notes.count, 1)

        let disabled = FixResolver.resolve(plugins: [specific, generic], context: unityContext, disabled: ["a.peak"])
        XCTAssertEqual(disabled.scrollMode, .smooth)
    }

    func testValidationRejectsEscapes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plugin-\(UUID().uuidString).cell")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = #"{"schemaVersion":1,"id":"bad.plugin","name":"Bad","version":"1","match":{"any":[{"executable":"a.exe"}]},"fixes":{"files":[{"from":"../../etc/passwd","to":"{gameDir}/x"}]}}"#
        try bad.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginManager.loadManifest(in: dir))

        let unknownBackend = #"{"schemaVersion":1,"id":"bad.backend","name":"Bad","version":"1","match":{"any":[{"executable":"a.exe"}]},"fixes":{"graphics":{"prefer":["vulkan9000"]}}}"#
        try unknownBackend.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginManager.loadManifest(in: dir))

        let noRules = #"{"schemaVersion":1,"id":"bad.rules","name":"Bad","version":"1","match":{}}"#
        try noRules.write(to: dir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try PluginManager.loadManifest(in: dir))
    }

    func testBuiltinPluginsAreValid() throws {
        let builtin = try XCTUnwrap(CellPaths.bundledResource("Plugins"))
        let folders = try FileManager.default.contentsOfDirectory(at: builtin, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "cell" }
        XCTAssertGreaterThanOrEqual(folders.count, 5)
        for folder in folders {
            XCTAssertNoThrow(try PluginManager.loadManifest(in: folder), folder.lastPathComponent)
        }
    }

    func testPeakUsesDirectX11OnEveryBackendAndRecognizesAnInvalidRegionList() throws {
        let builtin = try XCTUnwrap(CellPaths.bundledResource("Plugins"))
        let peakDirectory = builtin.appendingPathComponent("peak.cell")
        let peak = InstalledPlugin(manifest: try PluginManager.loadManifest(in: peakDirectory),
                                   directory: peakDirectory, isBuiltin: true)
        let fixes = FixResolver.resolve(plugins: [peak], context: unityContext)
        for backend in GraphicsBackend.allCases {
            XCTAssertTrue(fixes.arguments(for: backend).contains("-force-d3d11"), backend.rawValue)
        }
        let otherGame = MatchContext(executableName: "OtherGame.exe", steamAppID: "123456",
                                     analysis: unityContext.analysis, appKind: .steamGame)
        XCTAssertTrue(FixResolver.resolve(plugins: [peak], context: otherGame).arguments.isEmpty)

        let pattern = try XCTUnwrap(fixes.diagnostics.first { $0.rule.id == "peak.photon-invalid-region" }?.rule.pattern)
        let response = "OperationResponse 230: ReturnCode: 32756 (Cloud peak / Region %@ is not available.)"
        XCTAssertNotNil(String(format: response, "asia,au,hk").range(of: pattern, options: .regularExpression))
        XCTAssertNil(String(format: response, "hk").range(of: pattern, options: .regularExpression))
    }
}

final class SupportTests: XCTestCase {
    func testLooseVersion() {
        XCTAssertTrue(LooseVersion("6000.3.15f1") > LooseVersion("2022.3.1"))
        XCTAssertTrue(LooseVersion("6000.3.15f1").satisfies(">=2021"))
        XCTAssertTrue(LooseVersion("6000.3.15f1").satisfies("6000.*"))
        XCTAssertFalse(LooseVersion("2019.4.1").satisfies(">=2020 <6000"))
        XCTAssertTrue(LooseVersion("5.3").satisfies(">=5 <6"))
        XCTAssertEqual(LooseVersion("v0.80"), LooseVersion("0.80.0"))
    }

    func testGlob() {
        XCTAssertTrue(globMatch("*-Win64-Shipping.exe", "Backrooms-Win64-Shipping.exe"))
        XCTAssertTrue(globMatch("peak.exe", "PEAK.exe"))
        XCTAssertTrue(globMatch("game?.exe", "game2.exe"))
        XCTAssertFalse(globMatch("*.dll", "game.exe"))
    }

    func testRegFileEncoding() {
        let edits: [RegistryEdit] = [
            .set(.currentUser, "Software\\Wine\\Mac Driver", "RetinaMode", .string("y")),
            .set(.currentUser, "Control Panel\\Desktop", "LogPixels", .dword(192)),
            .deleteKey(.currentUser, "Software\\Wine\\AppDefaults\\Game.exe\\DllOverrides"),
            .set(.localMachine, "Software\\Test", "Multi", .multiString(["A", "B"])),
            .set(.localMachine, "Software\\Test", "Quote", .string(#"C:\Path "x""#)),
            .set(.localMachine, "Software\\Test", "Gone", .delete),
        ]
        let text = RegFile.text(for: edits)
        XCTAssertTrue(text.hasPrefix("Windows Registry Editor Version 5.00"))
        XCTAssertTrue(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver]\r\n\"RetinaMode\"=\"y\""))
        XCTAssertTrue(text.contains("\"LogPixels\"=dword:000000c0"))
        XCTAssertTrue(text.contains("[-HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\Game.exe\\DllOverrides]"))
        XCTAssertTrue(text.contains("\"Multi\"=hex(7):41,00,00,00,42,00,00,00,00,00"))
        XCTAssertTrue(text.contains(#""Quote"="C:\\Path \"x\"""#))
        XCTAssertTrue(text.contains("\"Gone\"=-"))
        let data = RegFile.data(for: edits)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE], "UTF-16LE with BOM")
    }

    func testWineHiveParsing() {
        let hive = WineRegistryHive.parse("""
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        #arch=win64

        [Software\\\\Wine\\\\Mac Driver] 1791969106
        #time=1dd5bbc09bd8d6e
        "RetinaMode"="y"
        "Name\\x4e2d"="\\x4e2d\\x6587"
        @="default"

        [Control Panel\\\\Desktop] 1791969106
        "LogPixels"=dword:000000c0
        "Blob"=hex:01,02,\\
          03
        "Multi"=str(7):"a\\0b\\0"
        """, rootName: "HKEY_CURRENT_USER")
        XCTAssertEqual(hive.value("Software\\Wine\\Mac Driver", "RetinaMode"), "y")
        XCTAssertEqual(hive.value("software\\wine\\mac driver", "Name中"), "中文")
        XCTAssertEqual(hive.value("Software\\Wine\\Mac Driver", ""), "default")
        XCTAssertEqual(hive.value("Control Panel\\Desktop", "LogPixels"), "0x000000c0 (192)")
        XCTAssertEqual(hive.value("Control Panel\\Desktop", "Blob"), "01 02 03")
        XCTAssertEqual(hive.value("Control Panel\\Desktop", "Multi"), "a · b")
        let tree = hive.tree()
        XCTAssertEqual(tree.map(\.name), ["Control Panel", "Software"])
        XCTAssertEqual(tree.last?.childNodes.first?.childNodes.first?.name, "Mac Driver")
    }

    func testWinePathMapping() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/Games"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        let mapper = WinePathMapper(prefix: prefix)
        let unix = try XCTUnwrap(mapper.unixURL(forWindowsPath: #"C:\Games\x.exe"#))
        XCTAssertEqual(unix.standardizedFileURL.path, prefix.appendingPathComponent("drive_c/Games/x.exe").standardizedFileURL.path)
        XCTAssertEqual(mapper.windowsPath(for: prefix.appendingPathComponent("drive_c/Games")), #"C:\Games"#)
        XCTAssertEqual(mapper.windowsPath(for: URL(fileURLWithPath: "/Applications")), #"Z:\Applications"#)
        XCTAssertEqual(mapper.unixURL(forWindowsPath: #"\\?\Z:\Users"#)?.path, "/Users")
    }

    func testIniEditor() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("GameUserSettings-\(UUID().uuidString).ini")
        defer { try? FileManager.default.removeItem(at: file) }
        try "[Other]\r\nA=1\r\n\r\n[/Script/Engine.GameUserSettings]\r\nFullscreenMode=0\r\nbUseVSync=True\r\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try IniEditor.apply(["FullscreenMode": "1", "ResolutionSizeX": "2940"], section: "/Script/Engine.GameUserSettings", to: file, create: false))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("FullscreenMode=1\r\n"))
        XCTAssertTrue(text.contains("ResolutionSizeX=2940"))
        XCTAssertTrue(text.contains("[Other]\r\nA=1"))
        XCTAssertTrue(text.contains("bUseVSync=True"))
        let missing = file.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).ini")
        XCTAssertFalse(try IniEditor.apply(["A": "1"], section: "S", to: missing, create: false))
    }

    func testLanguageCodes() {
        XCTAssertEqual(LanguageResolver.language(forCode: "zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(LanguageResolver.language(forCode: "zh-Hant-TW"), .traditionalChinese)
        XCTAssertEqual(LanguageResolver.language(forCode: "ja-JP"), .japanese)
        XCTAssertEqual(LanguageResolver.language(forCode: "en-GB"), .english)
        XCTAssertEqual(ContainerLanguage.simplifiedChinese.localeIdentifier, "zh_CN.UTF-8")
    }

    func testFontRegistryPutsPrimaryScriptFirst() {
        let choices = [FontConfigurator.Choice(script: .japanese, family: "Hiragino Sans", fileName: "Hiragino.ttc"),
                       FontConfigurator.Choice(script: .simplifiedChinese, family: "PingFang SC", fileName: "PingFang.ttc")]
        let edits = FontConfigurator.registryEdits(primary: .simplifiedChinese, choices: choices)
        guard let link = edits.first(where: { $0.key.hasSuffix("SystemLink") && $0.name == "Tahoma" }),
              case .multiString(let list) = link.value else { return XCTFail("missing SystemLink") }
        XCTAssertEqual(list.first, "PingFang.ttc,PingFang SC")
        XCTAssertTrue(edits.contains { $0.name == "Microsoft YaHei" && $0.value == .string("PingFang SC") })
        XCTAssertTrue(edits.contains { $0.name == "MS Gothic" && $0.value == .string("Hiragino Sans") })
    }

    func testCatalogEntriesLookRight() {
        XCTAssertTrue(Catalog.entries.allSatisfy { $0.url.scheme == "https" })
        XCTAssertNotNil(Catalog.wineEngines.first(where: \.recommended))
    }
}
