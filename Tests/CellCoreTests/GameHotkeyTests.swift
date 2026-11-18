import XCTest
@testable import CellCore

final class GameHotkeyTests: XCTestCase {
    func testGameShortcutDoesNotLeakIntoSteamOrNonGamePrograms() {
        let container = Container(name: "Hotkey policy")
        let runtime = WineRuntime(id: "test", name: "test", version: "10", origin: .imported, originDescription: "test")
        let game = AppEntry(containerID: container.id, name: "Game", kind: .steamGame, source: .steam,
                            windowsPath: "C:\\Game.exe", steamAppID: "123")
        let steam = AppEntry(containerID: container.id, name: "Steam", kind: .steamClient, source: .steam,
                             windowsPath: "C:\\Steam.exe")
        let editor = AppEntry(containerID: container.id, name: "Editor", kind: .windowsExecutable, source: .manual,
                              windowsPath: "C:\\Editor.exe")
        for (app, enabled) in [(game, "1"), (steam, "0"), (editor, "0")] {
            let env = WineEnvironment.build(container: container, runtime: runtime, flavorRoot: runtime.wineRoot,
                                             backend: nil, fixes: nil, app: app, dllOverrides: [:])
            XCTAssertEqual(env["CELL_GAME_FORCE_QUIT"], enabled)
            XCTAssertEqual(env["CELL_GAME_FORCE_QUIT_PROGRAM"], app.windowsPath.flatMap(ProgramSettings.programName))
        }
    }

    func testRecognizedNonSteamGameGetsShortcut() {
        var game = AppEntry(containerID: UUID(), name: "Game", kind: .windowsExecutable, source: .manual, windowsPath: "C:\\Game.exe")
        game.analysis = AppAnalysis(architecture: .x64)
        game.analysis?.engine = .unity
        XCTAssertEqual(ProgramSettings.gameHotkeyVariables(for: game, program: "game.exe")["CELL_GAME_FORCE_QUIT"], "1")
        game.settings.isGame = false
        XCTAssertEqual(ProgramSettings.gameHotkeyVariables(for: game, program: "game.exe")["CELL_GAME_FORCE_QUIT"], "0")
    }

    func testRequestedStopsAreConsumedAndStalePidMarkersAreIgnored() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("12345.request")
        let start = Date().addingTimeInterval(-5)
        try "\(Date().timeIntervalSince1970)\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(GameHotkey.consumeUserStop(pid: 12345, since: start, directory: folder))
        XCTAssertFalse(GameHotkey.consumeUserStop(pid: 12345, since: start, directory: folder))
        try "\(start.addingTimeInterval(-60).timeIntervalSince1970)".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(GameHotkey.consumeUserStop(pid: 12345, since: start, directory: folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testShortcutStopIsNotTreatedAsAnEarlyCrashOrRelaunched() throws {
        let services = CellServices()
        let container = Container(name: "Shortcut outcome")
        let app = AppEntry(containerID: container.id, name: "Shortcut test", kind: .windowsExecutable,
                           source: .manual, windowsPath: "C:\\CellShortcutTest.exe")
        let runtime = WineRuntime(id: "test", name: "test", version: "10", origin: .imported, originDescription: "test")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        try Data().write(to: log)
        let decision = BackendDecision(backend: .d3dmetal, reason: "test", fallbacks: [.wined3d], extraArguments: [], source: .automatic)
        let plan = LaunchPlan(app: app, container: container, runtime: runtime, decision: decision,
                              flavorRoot: runtime.wineRoot, flavorKey: "test", loader: URL(fileURLWithPath: "/bin/sleep"),
                              arguments: ["10"], environment: [:], workingDirectory: log.deletingLastPathComponent(),
                              fixes: ResolvedFixes(), kind: .direct, warnings: [], ports: [], engineReason: "test", engineFallbacks: [])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let session = RunningSession(plan: plan, process: process, logURL: log, attempt: 1, isHandoff: false, portMapper: nil)
        session.startedSteam = true
        try FileManager.default.createDirectory(at: GameHotkey.requestsURL, withIntermediateDirectories: true)
        let marker = GameHotkey.requestsURL.appendingPathComponent("\(process.processIdentifier).request")
        defer { try? FileManager.default.removeItem(at: marker) }
        try "\(Date().timeIntervalSince1970)".write(to: marker, atomically: true, encoding: .utf8)
        process.terminate()
        process.waitUntilExit()
        let outcome = services.launcher.finish(session, exitCode: process.terminationStatus)
        XCTAssertTrue(session.stopRequested)
        XCTAssertFalse(outcome.crashedEarly)
        XCTAssertFalse(outcome.waitsForSteam)
        XCTAssertFalse(services.launcher.willRetry(after: outcome, session: session))
    }
}
