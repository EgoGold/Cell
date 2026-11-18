import Foundation

/// Keeps game launchers from starting themselves whenever Wine starts.
///
/// Steam (and Epic, EA, Battle.net, …) add themselves to `…\CurrentVersion\Run`, and Wine runs those entries
/// every time a container's Wine session starts — also when Cell only runs a tool such as `wineboot` or
/// `regedit` with the engine's plain build. Steam then comes up on its own, on the wrong graphics engine,
/// and Cell's own Steam start is just handed over to it: games crash, or Steam "comes back" after quitting.
/// Cell starts every app itself, so these entries are removed before each new Wine session.
public enum AutostartBlocker {
    /// Programs (lower case) whose Run entries are removed.
    static let launchers = ["steam.exe", "epicgameslauncher.exe", "eadesktop.exe", "ealauncher.exe", "origin.exe",
                            "battle.net.exe", "battle.net launcher.exe", "galaxyclient.exe", "upc.exe", "ubisoftconnect.exe",
                            "riotclientservices.exe", "discord.exe", "--processstart discord"]

    /// Run keys as they are written in Wine's registry files (`user.reg` is HKCU, `system.reg` is HKLM).
    static let runKeys: Set<String> = ["Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run",
                                       "Software\\\\Wow6432Node\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run"]

    /// Removes launcher entries from the Run keys of one registry file's text.
    static func strip(_ text: String) -> (text: String, removed: [String]) {
        var output: [Substring] = []
        var removed: [String] = []
        var inRunKey = false
        var skippingContinuation = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if skippingContinuation {
                skippingContinuation = line.hasSuffix("\\")
                continue
            }
            if line.hasPrefix("[") {
                if let close = line.firstIndex(of: "]") {
                    inRunKey = runKeys.contains(String(line[line.index(after: line.startIndex)..<close]))
                } else {
                    inRunKey = false
                }
                output.append(line)
                continue
            }
            if inRunKey, line.hasPrefix("\"") || line.hasPrefix("@=") {
                let lowered = line.lowercased()
                if launchers.contains(where: { lowered.contains($0) }) {
                    removed.append(valueName(of: line))
                    skippingContinuation = line.hasSuffix("\\")
                    continue
                }
            }
            output.append(line)
        }
        guard !removed.isEmpty else { return (text, []) }
        return (output.joined(separator: "\n"), removed)
    }

    static func valueName(of line: Substring) -> String {
        guard line.hasPrefix("\"") else { return "" }
        var name = ""
        var escaped = false
        for character in line.dropFirst() {
            if escaped { name.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { break }
            name.append(character)
        }
        return name
    }

    /// Edits the prefix's registry files directly. Only call this while the container's Wine session is not
    /// running: wineserver keeps the registry in memory and writes it back when it ends.
    @discardableResult
    public static func removeEntries(prefix: URL) -> [String] {
        var removed: [String] = []
        for name in ["user.reg", "system.reg"] {
            let file = prefix.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: file.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let result = strip(text)
            guard !result.removed.isEmpty else { continue }
            do {
                try Data(result.text.utf8).write(to: file, options: .atomic)
                removed += result.removed
            } catch {
                continue
            }
        }
        return removed
    }
}

extension WineCommands {
    /// Call right before starting a Wine process in a container. When no Wine session is running yet, the new
    /// session would run Windows' start-up entries, so launcher entries are removed first.
    public static func prepareSession(container: Container) {
        guard container.platform == .windows else { return }
        // Leftovers of older sessions (hung crash debuggers, Wine helpers) never end by themselves.
        WineProcessScanner.endOrphans(of: container)
        guard FileManager.default.fileExists(atPath: container.prefixURL.appendingPathComponent("user.reg").path) else { return }
        // Files only: done before every launch, also into a running session (Cell keeps one warm, so a launch
        // nearly always finds one).
        keepUserFoldersInside(container)
        WindowsFontsFolder.link(into: container)
        // The registry files may only be edited while no session runs (wineserver writes them back when it ends).
        guard !isServerRunning(container: container) else { return }
        AutostartBlocker.removeEntries(prefix: container.prefixURL)
    }

    /// Wine links each Windows user's Desktop, Downloads, Music, Pictures and Videos to the Mac's folders. Shortcuts
    /// games and installers "put on the desktop" landed on the Mac's Desktop, and games that look through those
    /// folders ran into macOS's protected libraries (Beholder 2 crashed at start on "Access to the path
    /// 'C:\users\…\Pictures\Photo Booth Library' is denied"). They become folders of the layer's own; Documents stays
    /// linked (many games keep their saves there).
    static let ownUserFolders = ["Desktop", "Downloads", "Music", "Pictures", "Videos"]

    static func keepUserFoldersInside(_ container: Container) {
        let fm = FileManager.default
        let users = container.driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            for name in ownUserFolders {
                let folder = users.appendingPathComponent("\(user)/\(name)")
                guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil else { continue }
                try? fm.removeItem(at: folder)      // removes the link only
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
    }
}
