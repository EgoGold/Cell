import XCTest
@testable import CellCore

final class InputIsolationTests: XCTestCase {
    func testOldSettingsKeepCaptureDefaultsAndNewSettingsRoundTrip() throws {
        let old = try JSONStore.decoder.decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertNil(old.cursorCapture)
        XCTAssertNil(old.lockWindowWhenCaptured)
        XCTAssertNil(old.recoverInputOnFocus)
        var settings = old
        settings.cursorCapture = .eventTap
        settings.lockWindowWhenCaptured = false
        settings.recoverInputOnFocus = true
        XCTAssertEqual(try JSONStore.decoder.decode(AppSettings.self, from: JSONStore.encoder.encode(settings)), settings)
    }

    func testGameCaptureOverridesStayInItsAppDefaults() {
        let services = CellServices()
        let container = Container(name: "Input isolation")
        var game = AppEntry(containerID: container.id, name: "Game", kind: .steamGame, source: .steam,
                            windowsPath: "C:\\Game.exe", steamAppID: "123")
        game.analysis = AppAnalysis(architecture: .x64)
        game.analysis?.analyzedExecutable = "/games/Game.exe"
        game.settings.cursorCapture = .eventTap
        game.settings.lockWindowWhenCaptured = false
        let edits = services.planner.appDefaults(for: game, container: container)
        for name in ["UseConfinementCursorClipping", "CursorClippingLocksWindows"] {
            let edit = edits.first { $0.name == name }
            XCTAssertEqual(edit?.value, .string("n"))
            XCTAssertEqual(edit?.key, "Software\\Wine\\AppDefaults\\Game.exe\\Mac Driver")
        }
        game.settings.cursorCapture = nil
        game.settings.lockWindowWhenCaptured = nil
        XCTAssertFalse(services.planner.appDefaults(for: game, container: container).contains {
            $0.name == "UseConfinementCursorClipping" || $0.name == "CursorClippingLocksWindows"
        })
    }

    func testFocusRecoveryUserChoiceOverridesPluginAndNeverEnablesSteam() {
        let container = Container(name: "Focus isolation")
        let runtime = WineRuntime(id: "test", name: "test", version: "10", origin: .imported, originDescription: "test")
        var fixes = ResolvedFixes()
        fixes.recoverInputOnFocus = true
        var app = AppEntry(containerID: container.id, name: "Game", kind: .steamGame, source: .steam,
                           windowsPath: "C:\\Game.exe", steamAppID: "123")
        XCTAssertEqual(ProgramSettings.focusRecoveryVariables(for: app, fixes: nil, program: "game.exe"),
                       ["CELL_FOCUS_RECOVERY": "1", "CELL_FOCUS_RECOVERY_PROGRAM": "game.exe"])
        func env(_ app: AppEntry) -> [String: String] {
            WineEnvironment.build(container: container, runtime: runtime, flavorRoot: runtime.wineRoot,
                                  backend: .d3dmetal, fixes: fixes, app: app, dllOverrides: [:])
        }
        XCTAssertEqual(env(app)["CELL_FOCUS_RECOVERY"], "1")
        XCTAssertEqual(env(app)["CELL_FOCUS_RECOVERY_PROGRAM"], "game.exe")
        app.settings.recoverInputOnFocus = false
        XCTAssertEqual(env(app)["CELL_FOCUS_RECOVERY"], "0")
        app.kind = .steamClient
        app.settings.recoverInputOnFocus = true
        XCTAssertEqual(env(app)["CELL_FOCUS_RECOVERY"], "0")
    }

    func testCapturePluginMatchesOnlyItsGameAndCanBeDisabled() throws {
        let manifest = try JSONStore.decoder.decode(PluginManifest.self, from: Data(#"""
        {"schemaVersion":1,"id":"test.capture","name":"Capture","version":"1",
         "match":{"all":[{"steamAppID":"3103840"}]},
         "fixes":{"wine":{"cursorCapture":"confinement","lockWindowWhenCaptured":false,"recoverInputOnFocus":true}}}
        """#.utf8))
        let plugin = InstalledPlugin(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/test.capture.cell"), isBuiltin: true)
        let matched = MatchContext(steamAppID: "3103840", appKind: .steamGame)
        let fixes = FixResolver.resolve(plugins: [plugin], context: matched)
        XCTAssertEqual(fixes.cursorCapture, .confinement)
        XCTAssertEqual(fixes.lockWindowWhenCaptured, false)
        XCTAssertEqual(fixes.recoverInputOnFocus, true)
        XCTAssertNil(FixResolver.resolve(plugins: [plugin], context: MatchContext(steamAppID: "1161170", appKind: .steamGame)).recoverInputOnFocus)
        XCTAssertNil(FixResolver.resolve(plugins: [plugin], context: matched, disabled: [plugin.id]).recoverInputOnFocus)
    }
}
