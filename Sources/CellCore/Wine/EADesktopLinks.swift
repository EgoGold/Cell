import Darwin
import Foundation

/// EA's current Windows installer moves its payload into a version directory before starting
/// EABackgroundService. On Wine builds that cannot create its junction, StartServices then fails.
public final class EADesktopLinks: @unchecked Sendable {
    public static let shared = EADesktopLinks()
    private let queue = DispatchQueue(label: "com.cell.ea-desktop-links", qos: .userInitiated)
    private var watches: [URL: [URL: DispatchSourceFileSystemObject]] = [:]

    public func watch(_ containers: [Container]) {
        let drives = Set(containers.filter { $0.platform == .windows }.map(\.driveC))
        queue.async {
            for drive in Array(self.watches.keys) where !drives.contains(drive) {
                self.watches.removeValue(forKey: drive)?.values.forEach { $0.cancel() }
            }
            for drive in drives { self.refresh(drive) }
        }
    }

    /// Arm the watcher before handing off to a Wine process, including command-line launches.
    func watchBeforeLaunch(_ container: Container) {
        guard container.platform == .windows else { return }
        queue.sync { refresh(container.driveC) }
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink == false
    }

    static func repair(in root: URL) {
        let fm = FileManager.default
        guard isRealDirectory(root) else { return }
        let alias = root.appendingPathComponent("EA Desktop")
        guard !fm.fileExists(atPath: alias.path), !FileOps.isSymlink(alias),
              let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let versions = entries.filter { item in
            let parts = item.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            }), isRealDirectory(item) else { return false }
            let payload = item.appendingPathComponent("EA Desktop")
            guard isRealDirectory(payload) else { return false }
            return ["EABackgroundService.exe", "EADesktop.exe", "EASteamLauncher.exe"].allSatisfy { name in
                let file = payload.appendingPathComponent(name)
                return !FileOps.isSymlink(file) && !FileOps.isDirectory(file) && (FileOps.fileSize(file) ?? 0) > 0
            }
        }
        guard let version = versions.first, versions.count == 1 else { return }
        // POSIX symlink creation is atomic and fails if Wine or the installer already created this path.
        // The relative target remains inside the Wine prefix if the container moves.
        try? fm.createSymbolicLink(atPath: alias.path, withDestinationPath: version.lastPathComponent + "/EA Desktop")
    }

    func watch(drive: URL) {
        queue.sync { refresh(drive) }
    }

    private func refresh(_ drive: URL) {
        let ancestors = ["Program Files", "Program Files/Electronic Arts", "Program Files/Electronic Arts/EA Desktop"]
        var paths = [URL]()
        if Self.isRealDirectory(drive) {
            paths = [drive]
            for path in ancestors {
                let url = drive.appendingPathComponent(path)
                guard Self.isRealDirectory(url) else { break }
                paths.append(url)
            }
        }
        var current = watches[drive] ?? [:]
        for key in Array(current.keys) where !paths.contains(key) {
            current.removeValue(forKey: key)?.cancel()
        }
        for path in paths where current[path] == nil {
            let fd = open(path.path, O_EVTONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self, let source = self.watches[drive]?[path] else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.watches[drive]?.removeValue(forKey: path)?.cancel()
                }
                self.refresh(drive)
            }
            source.setCancelHandler { close(fd) }
            current[path] = source
            source.resume()
        }
        watches[drive] = current
        if paths.count == ancestors.count + 1, let root = paths.last { Self.repair(in: root) }
    }

    deinit {
        for sources in watches.values { sources.values.forEach { $0.cancel() } }
    }
}
