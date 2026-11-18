import Foundation

/// Keeps Steam's window from staying black or blank.
///
/// Steam draws its whole interface with Chromium (`steamwebhelper.exe`). Under Wine on macOS Chromium
/// only gets OpenGL ES 2.0, turns GPU drawing off and draws in software from a separate process, which
/// can't draw into Steam's window there — so the window stays empty. Drawing inside the main web helper
/// process (`--in-process-gpu --disable-gpu`, what CrossOver passes) works, but Steam ignores its own
/// `-cef-*` options for that.
///
/// Cell therefore renames Valve's `steamwebhelper.exe` to `steamwebhelper_real.exe` and puts a tiny
/// launcher in its place that starts the real one with those switches (source:
/// Tools/steamwebhelper-wrapper/wrapper.c). The launcher is padded to the size of Valve's file and Steam
/// is started with `-noverifyfiles`, so Steam doesn't put its own file back. When a Steam update replaces
/// the file, the next start from Cell installs the launcher again.
public enum SteamWebHelperWrapper {
    public static let helperName = "steamwebhelper.exe"
    public static let realName = "steamwebhelper_real.exe"
    /// Chromium switches the launcher adds unless `CELL_WEBHELPER_FLAGS` says otherwise.
    public static let defaultFlags = "--in-process-gpu --disable-gpu"

    static let image: Data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()

    /// Folders holding a `steamwebhelper.exe` (`bin/cef/cef.win64`, older `cef.win7x64`, …).
    public static func helperDirectories(steamDirectory: URL) -> [URL] {
        let cef = steamDirectory.appendingPathComponent("bin/cef", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { folder in
            FileOps.exists(folder.appendingPathComponent(helperName)) || FileOps.exists(folder.appendingPathComponent(realName))
        }.sorted { $0.path < $1.path }
    }

    /// Text every version of the launcher contains (UTF-16), and Valve's program doesn't.
    static let marker = Data("CELL_WEBHELPER_FLAGS".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    /// What launchers made before Cell was renamed contain: they are replaced, never mistaken for Valve's program.
    static let legacyMarker = Data("CHAMBER_WEBHELPER_FLAGS".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })

    /// Whether `file` is Cell's launcher — this version or an older one (possibly padded).
    public static func isWrapper(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16 * 1024), head.starts(with: Data("MZ".utf8)) else { return false }
        return head.range(of: marker) != nil || head.range(of: legacyMarker) != nil
    }

    /// Whether `file` is this version of the launcher.
    static func isCurrentWrapper(_ file: URL) -> Bool {
        guard !image.isEmpty, let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: image.count)) == image
    }

    static func writeLauncher(to helper: URL, matching real: URL) throws {
        var padded = image
        if let size = FileOps.fileSize(real), size > Int64(padded.count) {
            padded.append(Data(count: Int(size) - padded.count))
        }
        try padded.write(to: helper)
    }

    /// Whether the launcher is in place for every web helper.
    public static func isInstalled(steamDirectory: URL) -> Bool {
        let folders = helperDirectories(steamDirectory: steamDirectory)
        return !folders.isEmpty && folders.allSatisfy { folder in
            isCurrentWrapper(folder.appendingPathComponent(helperName)) && FileOps.exists(folder.appendingPathComponent(realName))
        }
    }

    /// Puts the launcher in place (again, after a Steam update). Returns true when it is active.
    @discardableResult
    public static func install(steamDirectory: URL) -> Bool {
        guard !image.isEmpty else { return false }
        let fm = FileManager.default
        var active = false
        for folder in helperDirectories(steamDirectory: steamDirectory) {
            let helper = folder.appendingPathComponent(helperName)
            let real = folder.appendingPathComponent(realName)
            if isWrapper(helper) {
                guard FileOps.exists(real) else { try? fm.removeItem(at: helper); continue }
                // An older launcher: replace it, keeping Valve's program.
                if !isCurrentWrapper(helper) { try? writeLauncher(to: helper, matching: real) }
                active = true
                continue
            }
            guard FileOps.exists(helper) else {
                // Only the renamed original is left: put it back.
                try? fm.moveItem(at: real, to: helper)
                continue
            }
            do {
                // Valve's binary, possibly a new version: it becomes the real one.
                if FileOps.exists(real) { try fm.removeItem(at: real) }
                try fm.moveItem(at: helper, to: real)
                try writeLauncher(to: helper, matching: real)
                active = true
            } catch {
                // Never leave Steam without its web helper.
                if !FileOps.exists(helper), FileOps.exists(real) { try? fm.moveItem(at: real, to: helper) }
            }
        }
        return active
    }

    /// Restores Valve's own `steamwebhelper.exe`.
    public static func uninstall(steamDirectory: URL) {
        let fm = FileManager.default
        for folder in helperDirectories(steamDirectory: steamDirectory) {
            let helper = folder.appendingPathComponent(helperName)
            let real = folder.appendingPathComponent(realName)
            guard FileOps.exists(real) else { continue }
            if !FileOps.exists(helper) || isWrapper(helper) {
                try? fm.removeItem(at: helper)
                try? fm.moveItem(at: real, to: helper)
            } else {
                // Steam already put a newer original back; the renamed copy is stale.
                try? fm.removeItem(at: real)
            }
        }
    }
}
