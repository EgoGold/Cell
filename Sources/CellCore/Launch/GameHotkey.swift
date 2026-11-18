import Foundation

/// Command-Q is handled outside the game, so a blocked Windows or Cocoa thread cannot prevent quitting.
enum GameHotkey {
    static var executableURL: URL { CellPaths.root.appendingPathComponent("Support/cell-game-hotkey") }
    static var requestsURL: URL { CellPaths.root.appendingPathComponent("Support/ForceQuitRequests", isDirectory: true) }

    @discardableResult
    static func install() -> Bool {
        guard let image = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !image.isEmpty else { return false }
        do {
            try FileManager.default.createDirectory(at: requestsURL, withIntermediateDirectories: true)
            if (try? Data(contentsOf: executableURL)) != image { try image.write(to: executableURL, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            return true
        } catch { return false }
    }

    static var environment: [String: String] {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return [:] }
        return ["CELL_GAME_HOTKEY_HELPER": executableURL.path, "CELL_GAME_QUIT_REQUESTS": requestsURL.path]
    }

    /// The PID's timestamp prevents an old marker being applied after PID reuse.
    static func consumeUserStop(pid: Int32, since startedAt: Date, directory: URL = requestsURL) -> Bool {
        guard pid > 1 else { return false }
        let file = directory.appendingPathComponent("\(pid).request")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let stamp = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return stamp >= startedAt.timeIntervalSince1970 && stamp <= Date().timeIntervalSince1970 + 5
    }
}
