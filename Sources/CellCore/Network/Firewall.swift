import Foundation

/// macOS Application Firewall.
public enum FirewallHelper {
    static let tool = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")

    public enum State: Sendable { case off, on, blockingAll, unknown }

    /// The firewall's state and whether every Wine engine may accept connections.
    public struct Status: Sendable {
        public var state: State
        /// Wine programs (of every engine and graphics flavor) not on the firewall's allowed list yet.
        public var notAllowed: [URL]
        public var engineBinaryCount: Int

        public var wineAllowed: Bool { notAllowed.isEmpty }
        public static let unknown = Status(state: .unknown, notAllowed: [], engineBinaryCount: 0)

        /// Nothing to do: the firewall is off, or Wine is allowed and the firewall doesn't block everything.
        public var isFine: Bool { state == .off || (state == .on && wineAllowed) }
    }

    public static func state() -> State {
        guard let result = try? ProcessRunner.run(tool, arguments: ["--getglobalstate"], timeout: 10) else { return .unknown }
        let text = result.combinedOutput.lowercased()
        if text.contains("disabled") || text.contains("state = 0") { return .off }
        if let blockAll = try? ProcessRunner.run(tool, arguments: ["--getblockall"], timeout: 10) {
            let answer = blockAll.combinedOutput.lowercased()
            if answer.contains("block"), !answer.contains("disabled") { return .blockingAll }
        }
        if text.contains("enabled") || text.contains("state = 1") || text.contains("state = 2") { return .on }
        return .unknown
    }

    public static func status(binaries: [URL]) -> Status {
        let state = state()
        guard state == .on || state == .blockingAll else {
            return Status(state: state, notAllowed: [], engineBinaryCount: binaries.count)
        }
        let listed = listedApplications()
        let notAllowed = binaries.filter { binary in
            listed[binary.path] != true && listed[binary.resolvingSymlinksInPath().path] != true
        }
        return Status(state: state, notAllowed: notAllowed, engineBinaryCount: binaries.count)
    }

    /// Programs on the firewall's list, and whether each may accept incoming connections.
    public static func listedApplications() -> [String: Bool] {
        guard let result = try? ProcessRunner.run(tool, arguments: ["--listapps"], timeout: 15) else { return [:] }
        return parseAppList(result.combinedOutput)
    }

    /// Parses `socketfilterfw --listapps`:
    ///
    ///     3 : /path/to/program
    ///                  (Allow incoming connections)
    static func parseAppList(_ text: String) -> [String: Bool] {
        var apps: [String: Bool] = [:]
        var pending: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("("), let path = pending {
                apps[path] = line.lowercased().contains("allow")
                pending = nil
            } else if let colon = line.range(of: " : "), Int(line[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)) != nil {
                if let path = pending { apps[path] = false }
                pending = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let path = pending { apps[path] = false }
        return apps
    }

    /// Adds the Wine programs to the firewall's allow list (asks for an administrator password once).
    public static func allowIncomingConnections(for binaries: [URL]) throws {
        let existing = binaries.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let commands = existing.flatMap { binary in
            ["\(quote(tool.path)) --add \(quote(binary.path))", "\(quote(tool.path)) --unblockapp \(quote(binary.path))"]
        }.joined(separator: "; ")
        let appleScript = "do shell script \"\(commands.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", appleScript], timeout: 300)
    }

    /// Cell's helper starts each Windows program from a hard link of Wine's loader named after it ("Steam",
    /// "winedevice"), so the process carries the program's name; those links are the same program to the firewall.
    static func namedLoaders(in bin: URL) -> [URL] {
        func inode(_ path: String) -> UInt64? {
            var info = stat()
            return stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
        }
        let loaders = Set(["wine", "wine64"].compactMap { inode(bin.appendingPathComponent($0).path) })
        guard !loaders.isEmpty, let names = try? FileManager.default.contentsOfDirectory(atPath: bin.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") && $0 != "wine" && $0 != "wine64" }
            .map { bin.appendingPathComponent($0) }
            .filter { inode($0.path).map(loaders.contains) ?? false }
    }

    /// Wine programs of an engine and its flavors (each flavor is a separate copy on disk, and the
    /// firewall remembers programs by path).
    public static func wineBinaries(for runtime: WineRuntime) -> [URL] {
        var roots = [runtime.wineRoot]
        roots += ((try? FileManager.default.contentsOfDirectory(at: runtime.flavorsDirectory, includingPropertiesForKeys: nil)) ?? [])
        var seen = Set<String>()
        return roots.flatMap { root in
            ["bin/wine", "bin/wine64", "bin/wine-preloader", "bin/wine64-preloader", "bin/wineserver"].map { root.appendingPathComponent($0) }
                + namedLoaders(in: root.appendingPathComponent("bin"))
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { $0.resolvingSymlinksInPath() }
            .filter { seen.insert($0.path).inserted }
    }
}
