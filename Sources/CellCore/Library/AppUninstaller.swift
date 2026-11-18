import Foundation

/// Uninstalling a program from a container the way Windows would: Steam games through Steam, installed
/// programs with their own uninstaller (registered under `…\Windows\CurrentVersion\Uninstall`), and
/// anything else by moving its folder to the Trash.
public struct UninstallPlan: Sendable {
    public enum Method: Sendable, Equatable {
        /// A Steam game: Cell deletes its files and Steam's record of it, without opening Steam.
        case steam(appID: String)
        /// The program's own uninstaller (registry key, display name).
        case uninstaller(key: String, name: String)
        /// No uninstaller: the program's folder goes to the Trash.
        case trashFolder(URL)
        /// Only the library entry can be removed (the program lives in a shared or system folder).
        case removeEntry
    }

    public var method: Method

    public var explanation: String {
        switch method {
        case .steam: return "Cell moves the game's folder to the Trash and removes Steam's record of it, without opening Steam. Saved games stay. If Steam is open, it shows the game as not installed after you restart it."
        case .uninstaller(_, let name): return "Runs the uninstaller of “\(name)”, then removes it from Cell."
        case .trashFolder(let folder): return "No uninstaller was found, so Cell moves the folder “\(folder.lastPathComponent)” to the Trash (you can put it back from there) and removes the app."
        case .removeEntry: return "Cell removes the app from its library. Its files stay in the container."
        }
    }
}

public struct UninstallEntry: Hashable, Sendable {
    /// Registry key name under `…\Uninstall` (a GUID for MSI packages).
    public var key: String
    public var displayName: String
    /// Folder the program installed into (Windows path, lowercase), when known.
    public var folder: String?
}

extension CellServices {
    /// Programs registered for uninstalling in a container.
    public func uninstallEntries(in container: Container) -> [UninstallEntry] {
        guard let hive = try? WineRegistryHive.load(container.prefixURL.appendingPathComponent("system.reg"), rootName: "HKEY_LOCAL_MACHINE") else { return [] }
        var entries: [UninstallEntry] = []
        for root in ["Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\", "Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\"] {
            for path in hive.keyOrder where path.lowercased().hasPrefix(root.lowercased()) {
                let key = String(path.dropFirst(root.count))
                guard !key.isEmpty, !key.contains("\\"), let name = hive.value(path, "DisplayName"), !name.isEmpty,
                      hive.value(path, "UninstallString") != nil else { continue }
                var folder = hive.value(path, "InstallLocation").map(Self.normalizedFolder)
                if folder == nil || folder?.isEmpty == true {
                    for candidate in [hive.value(path, "DisplayIcon"), hive.value(path, "UninstallString")].compactMap({ $0 }) {
                        if let executable = Self.executablePath(in: candidate), !executable.lowercased().contains("msiexec") {
                            folder = Self.normalizedFolder(String(executable[..<(executable.lastIndex(of: "\\") ?? executable.endIndex)]))
                            break
                        }
                    }
                }
                entries.append(UninstallEntry(key: key, displayName: name, folder: folder))
            }
        }
        return entries
    }

    /// What uninstalling `app` will do.
    public func uninstallPlan(for app: AppEntry) -> UninstallPlan {
        if app.kind == .steamGame, let id = app.steamAppID { return UninstallPlan(method: .steam(appID: id)) }
        guard let container = library.container(id: app.containerID), let path = app.windowsPath?.lowercased(),
              let slash = path.lastIndex(of: "\\") else { return UninstallPlan(method: .removeEntry) }
        let folder = String(path[..<slash])
        let matching = uninstallEntries(in: container).filter { entry in
            guard let installed = entry.folder, !installed.isEmpty else { return false }
            return folder == installed || folder.hasPrefix(installed + "\\")
        }
        if let best = matching.max(by: { ($0.folder?.count ?? 0) < ($1.folder?.count ?? 0) }) {
            return UninstallPlan(method: .uninstaller(key: best.key, name: best.displayName))
        }
        if let unix = WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: String(app.windowsPath![..<app.windowsPath!.lastIndex(of: "\\")!])),
           Self.isSafeToTrash(unix, container: container) {
            return UninstallPlan(method: .trashFolder(unix))
        }
        return UninstallPlan(method: .removeEntry)
    }

    /// Uninstalls `app` (see `uninstallPlan(for:)`) and removes it from the library.
    public func uninstall(_ app: AppEntry) async throws {
        guard let container = library.container(id: app.containerID) else { throw LaunchError.containerMissing }
        let plan = uninstallPlan(for: app)
        switch plan.method {
        case .steam(let id):
            // What Steam's own uninstall does to the disk: the game's folder and its record (appmanifest) go. Steam
            // isn't started for it (that could take a minute, or start it on another engine).
            let fm = FileManager.default
            for game in SteamIntegration.installedGames(in: container, includingPartial: true) where game.appID == id {
                let steamapps = game.libraryRoot.appendingPathComponent("steamapps")
                if fm.fileExists(atPath: game.installDirectory.path), game.installDirectory.deletingLastPathComponent().lastPathComponent == "common" {
                    try fm.trashItem(at: game.installDirectory, resultingItemURL: nil)
                }
                try? fm.removeItem(at: steamapps.appendingPathComponent("appmanifest_\(id).acf"))
                for extra in ["downloading/\(id)", "temp/\(id)", "shadercache/\(id)"] {
                    try? fm.removeItem(at: steamapps.appendingPathComponent(extra))
                }
            }
        case .uninstaller(let key, _):
            guard let runtime = launcher.activeRuntime(for: container) else { throw LaunchError.noRuntime(container.name) }
            // Wine's own Add/Remove Programs tool runs the registered uninstall command.
            _ = try await WineCommands.run(["uninstaller", "--remove", key], container: container, runtime: runtime, timeout: 3600)
        case .trashFolder(let folder):
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        case .removeEntry:
            break
        }
        if let shortcut = app.shortcutPath { ShortcutBuilder.removeShortcut(at: shortcut) }
        try library.remove(app)
    }

    /// Folders that hold more than this one program are never deleted.
    static func isSafeToTrash(_ folder: URL, container: Container) -> Bool {
        let path = folder.standardizedFileURL.path
        let driveC = container.driveC.standardizedFileURL.path
        guard path.hasPrefix(driveC + "/") else { return false }
        let relative = String(path.dropFirst(driveC.count + 1)).lowercased()
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return false }
        if ["windows", "programdata", "users"].contains(first) && parts.count < 4 { return false }
        if first == "windows" { return false }
        if ["program files", "program files (x86)"].contains(first) && parts.count < 2 { return false }
        if relative.contains("/steam") && (relative.hasSuffix("steam") || relative.contains("steamapps")) { return false }
        return true
    }

    static func normalizedFolder(_ value: String) -> String {
        var folder = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).replacingOccurrences(of: "/", with: "\\").lowercased()
        while folder.hasSuffix("\\") { folder.removeLast() }
        return folder
    }

    /// `"C:\Games\X\unins000.exe" /SILENT` or `C:\Games\X\game.exe,0` → `C:\Games\X\unins000.exe`.
    static func executablePath(in command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        guard let range = trimmed.range(of: ".exe", options: .caseInsensitive) else { return nil }
        return String(trimmed[..<range.upperBound])
    }
}
