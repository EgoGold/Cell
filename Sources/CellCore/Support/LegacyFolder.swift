import Darwin
import Foundation

/// Cell used to be called Chamber. Its data folder (containers with Steam and games, engines, plugins) moves to the
/// new name with one rename on the same disk — nothing is copied — but only while no Wine engine or old Chamber app
/// is using it; until then Cell keeps using the old folder. Links that pointed inside the old folder are fixed.
enum LegacyFolder {
    static func adopt(_ legacy: URL, as current: URL, inUse: (URL) -> Bool = isInUse) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: current.path) || !fm.fileExists(atPath: legacy.path) { return current }
        // Only Cell itself moves the folder (a test run never does).
        guard !inUse(legacy), !isTestRun else { return legacy }
        do {
            try fm.moveItem(at: legacy, to: current)
        } catch {
            return legacy
        }
        repairLinks(in: current, from: legacy)
        return current
    }

    static var isTestRun: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.processName == "xctest"
            || NSClassFromString("XCTestCase") != nil
    }

    /// A process running from the folder (a Wine engine), or the old app itself.
    static func isInUse(_ folder: URL) -> Bool {
        let prefix = folder.resolvingSymlinksInPath().path + "/"
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 && pid != getpid() {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            let path = String(cString: buffer)
            if path.hasPrefix(prefix) || path.hasSuffix("/Chamber.app/Contents/MacOS/Chamber") { return true }
        }
        return false
    }

    /// Absolute links into the old folder (engine flavors' `share`) point into the new one again.
    static func repairLinks(in folder: URL, from legacy: URL) {
        let fm = FileManager.default
        let oldPrefix = legacy.path + "/"
        guard let walker = fm.enumerator(at: folder.appendingPathComponent("Runtimes"), includingPropertiesForKeys: [.isSymbolicLinkKey],
                                         options: [.skipsPackageDescendants]) else { return }
        for case let item as URL in walker {
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let destination = try? fm.destinationOfSymbolicLink(atPath: item.path), destination.hasPrefix(oldPrefix) else { continue }
            let target = folder.appendingPathComponent(String(destination.dropFirst(oldPrefix.count)))
            try? fm.removeItem(at: item)
            try? fm.createSymbolicLink(atPath: item.path,
                                       withDestinationPath: FileOps.relativePath(from: item.deletingLastPathComponent(), to: target))
        }
    }
}
