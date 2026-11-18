import Foundation

/// Well-known locations used by Cell.
///
/// Everything lives under `~/Library/Application Support/Cell` unless the `CELL_HOME`
/// environment variable points somewhere else (used by tests and for portable setups).
public enum CellPaths {
    /// `CELL_HOME` (or `CHAMBER_HOME`, its name before Cell was renamed).
    static var customHome: String? {
        let environment = ProcessInfo.processInfo.environment
        return [environment["CELL_HOME"], environment["CHAMBER_HOME"]].compactMap { $0 }.first { !$0.isEmpty }
    }

    public static let root: URL = {
        if let custom = customHome {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        // Cell was called Chamber: its folder moves over the first time nothing from it is running.
        return LegacyFolder.adopt(base.appendingPathComponent("Chamber", isDirectory: true),
                                  as: base.appendingPathComponent("Cell", isDirectory: true))
    }()

    private static var usesCustomHome: Bool { customHome != nil }

    public static var containers: URL { root.appendingPathComponent("Containers", isDirectory: true) }
    public static var runtimes: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public static var components: URL { root.appendingPathComponent("Components", isDirectory: true) }
    public static var plugins: URL { root.appendingPathComponent("Plugins", isDirectory: true) }
    public static var icons: URL { root.appendingPathComponent("Icons", isDirectory: true) }
    /// Virtual machine bundles (`<id>.cellvm`).
    public static var virtualMachines: URL { root.appendingPathComponent("Virtual Machines", isDirectory: true) }
    public static var settingsFile: URL { root.appendingPathComponent("settings.json") }
    public static var pluginStateFile: URL { plugins.appendingPathComponent("state.json") }

    public static var caches: URL {
        if usesCustomHome { return root.appendingPathComponent("Caches", isDirectory: true) }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Cell", isDirectory: true)
    }

    public static var downloads: URL { caches.appendingPathComponent("Downloads", isDirectory: true) }
    public static var temporary: URL { caches.appendingPathComponent("Temp", isDirectory: true) }

    public static var logs: URL {
        if usesCustomHome { return root.appendingPathComponent("Logs", isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Cell", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, containers, runtimes, components, plugins, icons, virtualMachines, caches, downloads, temporary, logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// A fresh, empty scratch directory (callers remove it when done).
    public static func makeScratchDirectory(prefix: String) throws -> URL {
        let dir = temporary.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Locates resources shipped with Cell (built-in plugins, catalog).
    ///
    /// Works for the app (`Contents/Resources`), the CLI inside the app (`Contents/Helpers`),
    /// and during development (repository checkout).
    public static func bundledResource(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = ProcessInfo.processInfo.environment["CELL_PACKAGED_RESOURCES"], resources.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: resources, isDirectory: true).appendingPathComponent(relativePath))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(relativePath))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let execDir = executable.deletingLastPathComponent()
        candidates.append(execDir.appendingPathComponent("../Resources/\(relativePath)").standardizedFileURL)
        // Development: <repo>/Sources/CellCore/Support/Paths.swift -> <repo>
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent(relativePath))
        // Development via `swift run` from the repository root.
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(relativePath))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    /// Path of the `cell` command line helper, used by shortcuts.
    public static func cliExecutable() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if Bundle.main.bundleURL.pathExtension == "app" {
            candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cell"))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let execDir = executable.deletingLastPathComponent()
        // A command-line launch can start another instance of the companion.
        let runningCLI = executable.lastPathComponent == "cell-cli"
            || (executable.lastPathComponent == "cell" && execDir.lastPathComponent == "Helpers")
        if runningCLI, fm.isExecutableFile(atPath: executable.path) { return executable }
        candidates.append(execDir.appendingPathComponent("../Helpers/cell").standardizedFileURL)
        candidates.append(execDir.appendingPathComponent("cell-cli"))
        candidates.append(URL(fileURLWithPath: "/Applications/Cell.app/Contents/Helpers/cell"))
        // The file system is usually case-insensitive: never return the GUI binary ("Cell") itself.
        let selfPath = executable.path.lowercased()
        return candidates.first { url in
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fm.isExecutableFile(atPath: url.path) else { return false }
            return url.resolvingSymlinksInPath().path.lowercased() != selfPath
        }
    }
}
