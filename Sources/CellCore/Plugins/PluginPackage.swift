import CellArchive
import Foundation

/// A portable .cell file is a ZIP with plugin.json and its assets. Cell extracts file bytes
/// itself so a package cannot materialize links, devices or paths outside the working directory.
enum PluginPackage {
    static func unpack(_ package: URL, into directory: URL) throws {
        let fm = FileManager.default
        guard let archive = archive_read_new() else { throw PluginError.invalid("could not open package") }
        defer { _ = archive_read_free(archive) }
        func failure() -> PluginError {
            .invalid(archive_error_string(archive).map { String(cString: $0) } ?? "could not read package")
        }
        guard archive_read_support_format_zip(archive) == 0,
              archive_read_open_filename(archive, package.path, 64 * 1024) == 0 else { throw failure() }

        var entry: OpaquePointer?
        var paths = Set<String>()
        var buffer = Data(count: 64 * 1024)
        var extracted: Int64 = 0
        while true {
            let status = archive_read_next_header(archive, &entry)
            if status == 1 { return }
            guard status == 0, let entry, let name = archive_entry_pathname(entry),
                  let raw = String(validatingCString: name) else { throw failure() }
            let type = archive_entry_filetype(entry)
            guard type == 0o100000 || type == 0o040000, archive_entry_hardlink(entry) == nil else {
                throw PluginError.invalid("packages may only contain files and folders")
            }
            let parts = raw.split(separator: "/", omittingEmptySubsequences: true).drop(while: { $0 == "." })
            guard !raw.hasPrefix("/"), !raw.contains("\\"), !raw.contains(":"),
                  !parts.contains(".."), !parts.contains(".") else {
                throw PluginError.invalid("unsafe package path")
            }
            guard let first = parts.first else { continue }
            if first == "__MACOSX" || parts.last == ".DS_Store" { continue }
            let relative = parts.joined(separator: "/")
            guard paths.insert(relative.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  paths.count <= 50_000 else { throw PluginError.invalid("duplicate or too many package files") }
            let file = directory.appendingPathComponent(relative)
            if type == 0o040000 {
                try fm.createDirectory(at: file, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard !fm.fileExists(atPath: file.path), fm.createFile(atPath: file.path, contents: nil) else {
                throw PluginError.invalid("package file conflicts with a folder")
            }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            while true {
                let count = buffer.withUnsafeMutableBytes { archive_read_data(archive, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { throw failure() }
                extracted += Int64(count)
                guard extracted <= 64 * 1024 * 1024 * 1024 else { throw PluginError.invalid("extracted package exceeds 64 GB") }
                try output.write(contentsOf: buffer.prefix(count))
            }
            if archive_entry_perm(entry) & 0o111 != 0 { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        }
    }

    static func pack(_ source: URL, to url: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        guard let files = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys)) else {
            throw PluginError.invalid("could not read plugin files")
        }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw PluginError.invalid("packages may only contain files and folders")
            }
        }
        try ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--norsrc", source.path, url.path])
    }

    static func manifestFolder(in directory: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("plugin.json").path) { return directory }
        let roots = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard roots.count == 1, fm.fileExists(atPath: roots[0].appendingPathComponent("plugin.json").path) else {
            throw PluginError.invalid("plugin.json must be at the package root")
        }
        return roots[0]
    }
}
