import Foundation

/// Converts between Windows paths (C:\Games\x.exe) and Mac paths inside a prefix.
public struct WinePathMapper {
    public let prefix: URL

    public init(prefix: URL) { self.prefix = prefix }

    public static func normalize(_ windowsPath: String) -> String {
        var path = windowsPath.replacingOccurrences(of: "/", with: "\\")
        if path.hasPrefix("\\\\?\\") { path.removeFirst(4) }
        if path.hasPrefix("\\??\\") { path.removeFirst(4) }
        return path
    }

    /// Mac location of a Windows path, honouring the prefix's drive mappings.
    public func unixURL(forWindowsPath windowsPath: String) -> URL? {
        let path = Self.normalize(windowsPath)
        guard path.count >= 2, path.dropFirst().first == ":", let letter = path.first?.lowercased() else { return nil }
        guard let driveRoot = driveRoot(letter: letter) else { return nil }
        let rest = path.dropFirst(2).split(separator: "\\").map(String.init).filter { !$0.isEmpty && $0 != "." }
        var url = driveRoot
        for component in rest {
            if component == ".." { url.deleteLastPathComponent() } else { url.appendPathComponent(component) }
        }
        return url
    }

    public func driveRoot(letter: String) -> URL? {
        let device = prefix.appendingPathComponent("dosdevices/\(letter):")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: device.path) {
            let resolved = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination, isDirectory: true)
                : prefix.appendingPathComponent("dosdevices").appendingPathComponent(destination).standardizedFileURL
            return resolved
        }
        switch letter {
        case "c": return prefix.appendingPathComponent("drive_c", isDirectory: true)
        case "z": return URL(fileURLWithPath: "/", isDirectory: true)
        default: return nil
        }
    }

    /// Windows path for a Mac file (C: for files inside the prefix, Z: for everything else).
    public func windowsPath(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var best: (letter: String, root: String)?
        let devices = prefix.appendingPathComponent("dosdevices")
        let letters = ((try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? [])
            .filter { $0.count == 2 && $0.hasSuffix(":") }
            .map { String($0.prefix(1)).lowercased() }
        for letter in Set(letters + ["c"]) where letter != "z" {
            guard let root = driveRoot(letter: letter)?.resolvingSymlinksInPath().standardizedFileURL.path, root != "/" else { continue }
            let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
            if path == root || path.lowercased().hasPrefix(rootWithSlash.lowercased()) {
                if best == nil || root.count > best!.root.count { best = (letter, root) }
            }
        }
        if let best {
            let relative = path == best.root ? "" : String(path.dropFirst(best.root.count + (best.root.hasSuffix("/") ? 0 : 1)))
            return best.letter.uppercased() + ":\\" + relative.replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Typical Windows user folders inside the prefix.
    public var userProfile: URL? {
        let users = prefix.appendingPathComponent("drive_c/users")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        let user = names.first { $0 != "Public" && !$0.hasPrefix(".") && $0 != "crossover" }
        return user.map { users.appendingPathComponent($0, isDirectory: true) }
    }
}
