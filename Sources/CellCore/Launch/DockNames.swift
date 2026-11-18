import CryptoKit
import Foundation

/// Every Wine process is the same Mac program, so the Dock and the app switcher called them all "wine". A small
/// library (Tools/dock-name) is loaded into Cell's Wine processes and renames each one after the Windows program
/// it runs, using a list Cell keeps next to each container: "steam.exe" → "Steam", "PEAK.exe" → "PEAK".
/// The variables reach every program a container runs, including games Steam starts.
public enum DockNames {
    static var libraryURL: URL { CellPaths.root.appendingPathComponent("Support/libdockname.dylib") }

    public static func listURL(for container: Container) -> URL { container.directory.appendingPathComponent("dock-names.tsv") }

    static var library: Data? { Data(base64Encoded: base64, options: .ignoreUnknownCharacters) }

    /// Puts the library in place (again when Cell brings a newer one). Returns false if it can't.
    @discardableResult
    public static func installLibrary() -> Bool {
        _ = GameHotkey.install()
        guard let data = library, !data.isEmpty else { return false }
        let url = libraryURL
        if let existing = try? Data(contentsOf: url), existing == data { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Write next to it and swap, so a running Wine process never maps a half-written file.
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".libdockname-\(UUID().uuidString).dylib")
            try data.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
            return true
        } catch {
            return false
        }
    }

    /// The names: every program file of an app is listed under the app's name.
    public static func entries(for apps: [AppEntry]) -> [(program: String, name: String)] {
        var result: [(String, String)] = []
        var seen: Set<String> = []
        func add(_ program: String?, _ name: String) {
            guard let program else { return }
            let file = program.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)?.lowercased() ?? ""
            let clean = name.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard file.hasSuffix(".exe"), !clean.isEmpty, seen.insert(file).inserted else { return }
            result.append((file, clean))
        }
        for app in apps {
            if app.kind == .steamClient {
                for program in ["steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe"] { add(program, "Steam") }
                continue
            }
            add(app.windowsPath, app.name)
            add(app.analysis?.analyzedExecutable, app.name)
        }
        return result
    }

    /// Writes the container's list (read by each program when it starts, so new games are named even while
    /// Steam keeps running).
    public static func writeList(for container: Container, apps: [AppEntry]) {
        let text = entries(for: apps).map { "\($0.program)\t\($0.name)\n" }.joined()
        let url = listURL(for: container)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: container.directory, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Variables for Wine processes of a container (empty when the library isn't installed).
    public static func environment(for container: Container) -> [String: String] {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return [:] }
        var libraries = libraryURL.path
        // Test hook: CELL_TEST_PRELOAD adds a library of Cell's own tests (e.g. one that keeps windows invisible).
        if let extra = ProcessInfo.processInfo.environment["CELL_TEST_PRELOAD"], !extra.isEmpty { libraries += ":" + extra }
        return ["DYLD_INSERT_LIBRARIES": libraries, "CELL_DOCK_NAMES": listURL(for: container).path,
                "CELL_HOST_REWRITES": HostRewrites.url(for: container).path,
                "CELL_PROGRAM_SETTINGS": ProgramSettings.fileURL(for: container).path]
            .merging(GameHotkey.environment) { _, new in new }
    }

    /// Checksum of the bundled library (for diagnostics).
    static var bundledChecksum: String? {
        library.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}
