import Foundation
import Darwin

public enum FileOpsError: LocalizedError {
    case unsupportedArchive(String)
    case outsideAllowedRoot(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchive(let name): return "Unsupported archive: \(name)"
        case .outsideAllowedRoot(let path): return "Refusing to write outside the allowed folder: \(path)"
        case .notFound(let what): return "Not found: \(what)"
        }
    }
}

public enum FileOps {
    /// Copy-on-write clone on APFS (instant, no extra disk space). Falls back to a regular copy.
    /// Removes `destination` first if it exists.
    public static func cloneItem(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) || isSymlink(destination) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            try fm.copyItem(at: source, to: destination)
        }
    }

    /// Recursively merges `source` into `destination`, replacing files that exist.
    /// Symlinks are recreated as symlinks (D3DMetal ships relative `.so` links).
    public static func overlay(_ source: URL, onto destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                if fm.fileExists(atPath: target.path) || isSymlink(target) { try fm.removeItem(at: target) }
                let link = try fm.destinationOfSymbolicLink(atPath: item.path)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else if values.isDirectory == true {
                if isSymlink(target) { try fm.removeItem(at: target) }
                try overlay(item, onto: target)
            } else {
                try cloneItem(at: item, to: target)
            }
        }
    }

    public static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Size in bytes, or nil when the file doesn't exist.
    public static func fileSize(_ url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Allocated size of a folder in bytes (follows no symlinks).
    public static func allocatedSize(of url: URL, excludingTopLevel: Set<String> = []) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if enumerator.level == 1, excludingTopLevel.contains(file.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Breadth-first search for a file or folder whose relative path ends with `suffix`.
    public static func find(where predicate: (URL) -> Bool, in root: URL, maxDepth: Int) -> URL? {
        var queue: [(URL, Int)] = [(root, 0)]
        let fm = FileManager.default
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if predicate(item) { return item }
                if depth < maxDepth, isDirectory(item), !isSymlink(item) { queue.append((item, depth + 1)) }
            }
        }
        return nil
    }

    /// Extracts .tar.xz/.tar.gz/.tgz/.tar/.zip/.7z (and Wineskin's .tar.7z) into `directory`.
    public static func extractArchive(_ archive: URL, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") || PluginManager.pluginExtensions.contains(where: { name.hasSuffix(".\($0)") }) {
            try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, directory.path])
        } else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") || name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
                    || name.hasSuffix(".tar") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".7z") {
            // bsdtar (libarchive) reads xz, gzip, bzip2 and 7-Zip.
            try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", archive.path, "-C", directory.path])
            // Wineskin engines are a tar inside a 7z: extract the inner tar too.
            if name.hasSuffix(".7z") {
                let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for inner in contents where inner.pathExtension.lowercased() == "tar" {
                    try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xf", inner.path, "-C", directory.path])
                    try? fm.removeItem(at: inner)
                }
            }
        } else {
            throw FileOpsError.unsupportedArchive(archive.lastPathComponent)
        }
        removeAppleDoubleFiles(in: directory)
    }

    /// Archives packed on a Mac by other tools carry each file's Finder data as a separate "._name" file
    /// (AppleDouble). Extracted, they are clutter, and harmful in an engine: GStreamer tried to load every
    /// "._libgst….dylib" as a plugin in every Wine process (about 7,000 failures per Steam session, slower starts).
    @discardableResult
    public static func removeAppleDoubleFiles(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return 0 }
        var removed = 0
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("._") {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let magic = (try? handle.read(upToCount: 4)) ?? Data()
            try? handle.close()
            if magic == Data([0x00, 0x05, 0x16, 0x07]), (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Mounts a disk image read-only and returns the mount point.
    public static func attachDiskImage(_ dmg: URL) throws -> URL {
        let result = try ProcessRunner.runChecked(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path],
            timeout: 300
        )
        guard let data = result.stdout.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw FileOpsError.notFound("mount point for \(dmg.lastPathComponent)")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    public static func detachDiskImage(_ mountPoint: URL) {
        _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", "-quiet", mountPoint.path], timeout: 60)
    }

    /// `target` as seen from inside `directory` ("../../wine/share"), for links that survive moving both.
    public static func relativePath(from directory: URL, to target: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents
        let to = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count) && from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    /// A name that is safe as a file or bundle name.
    public static func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\\0").union(.controlCharacters)
        let cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
    }

    /// True when `url` (after resolving `..` and symlinks of existing parents) is inside `root`.
    public static func isContained(_ url: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var probe = url.standardizedFileURL
        var suffix: [String] = []
        // Resolve the deepest existing ancestor so symlinks inside the root are honoured.
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            suffix.insert(probe.lastPathComponent, at: 0)
            probe.deleteLastPathComponent()
        }
        var resolved = probe.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { resolved.appendPathComponent(component) }
        let path = resolved.standardizedFileURL.path
        let rootWithSlash = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return path == resolvedRoot || path.lowercased().hasPrefix(rootWithSlash.lowercased())
    }

    /// SHA-256 of a file, hex encoded.
    public static func sha256(of url: URL) throws -> String {
        let result = try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/shasum"), arguments: ["-a", "256", url.path], timeout: 600)
        return String(result.stdout.prefix(64))
    }

    /// Searches a binary file for an ASCII token, case-insensitively (bounded to `limit` bytes).
    /// With `includeUTF16` it also finds UTF-16LE strings (Windows "wide" strings such as Unreal's TEXT()).
    public static func fileContains(_ url: URL, token: String, limit: Int = 256 * 1024 * 1024, includeUTF16: Bool = false) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        let needle = Array(token.lowercased().utf8)
        if containsCaseInsensitive(data, needle: needle, stride: 1, limit: limit) { return true }
        return includeUTF16 && containsCaseInsensitive(data, needle: needle, stride: 2, limit: limit)
    }

    static func containsCaseInsensitive(_ data: Data, needle: [UInt8], stride: Int, limit: Int) -> Bool {
        guard let first = needle.first else { return true }
        let firstUpper = (97...122).contains(first) ? first - 32 : first
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let count = min(raw.count, limit)
            let span = (needle.count - 1) * stride + 1
            guard count >= span else { return false }
            var index = 0
            while index <= count - span {
                // Jump to the next byte that can start a match.
                let remaining = count - span - index + 1
                let lowerHit = memchr(base + index, Int32(first), remaining).map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base }
                let upperHit = firstUpper == first ? nil
                    : memchr(base + index, Int32(firstUpper), remaining).map { UnsafePointer<UInt8>($0.assumingMemoryBound(to: UInt8.self)) - base }
                guard let hit = [lowerHit, upperHit].compactMap({ $0 }).min() else { return false }
                var matched = true
                for j in 1..<needle.count {
                    let position = hit + j * stride
                    if stride == 2 && base[position - 1] != 0 { matched = false; break }
                    var byte = base[position]
                    if (65...90).contains(byte) { byte += 32 }
                    if byte != needle[j] { matched = false; break }
                }
                if matched { return true }
                index = hit + 1
            }
            return false
        }
    }
}
