import Foundation

/// Installation estimates have different scopes, so an executable in a shared folder does not
/// get credited with the whole folder and Steam does not get credited with its games.
public struct AppStorageUsage: Sendable {
    public enum Scope: Sendable {
        case steamInstallation, installationFolder, programFile, steamProgramFiles
    }
    public let bytes: Int64
    public let scope: Scope

    public static func measure(_ app: AppEntry, in container: Container) -> Self? {
        if app.kind == .steamGame {
            guard let game = SteamIntegration.installedGames(in: container).first(where: {
                $0.appID == app.steamAppID && $0.isFullyInstalled && FileOps.isDirectory($0.installDirectory)
            }) else { return nil }
            let bytes = game.sizeOnDisk.flatMap { $0 > 0 ? $0 : nil }
                ?? FileOps.allocatedSize(of: game.installDirectory)
            return Self(bytes: bytes, scope: .steamInstallation)
        }
        if app.kind == .steamClient, let steam = SteamIntegration.steamDirectory(in: container) {
            return Self(bytes: FileOps.allocatedSize(of: steam, excludingTopLevel: ["steamapps", "userdata"]),
                        scope: .steamProgramFiles)
        }
        guard let path = app.windowsPath, let url = WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: path),
              let bytes = FileOps.fileSize(url), !FileOps.isDirectory(url) else { return nil }
        let file = url.resolvingSymlinksInPath().standardizedFileURL
        let drive = container.driveC.resolvingSymlinksInPath().standardizedFileURL
        if file.path.hasPrefix(drive.path + "/") {
            let parts = file.path.dropFirst(drive.path.count + 1).split(separator: "/")
            let roots = ["program files", "program files (x86)", "games", "apps"]
            if parts.count >= 3, roots.contains(parts[0].lowercased()),
               !["common files", "windowsapps"].contains(parts[1].lowercased()) {
                let folder = drive.appendingPathComponent(String(parts[0])).appendingPathComponent(String(parts[1]))
                return Self(bytes: FileOps.allocatedSize(of: folder), scope: .installationFolder)
            }
        }
        return Self(bytes: bytes, scope: .programFile)
    }
}

public enum ContainerCleanup {
    public struct Candidate: Identifiable, Hashable, Sendable {
        public var id: URL { url }
        public let url: URL
        public let bytes: Int64
        public let category: Category
        fileprivate let modification: Date?
    }

    public enum Category: String, CaseIterable, Sendable {
        case temporary = "Old Windows temporary files"
        case browserCache = "Steam browser cache"
        case shaderCache = "Steam shader cache"
    }

    public struct Plan: Sendable {
        public let candidates: [Candidate]
        public var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
    }

    public struct Result: Sendable {
        public var moved = 0
        public var skipped = 0
    }

    public static func plan(for container: Container, now: Date = .now) -> Plan {
        guard container.platform == .windows else { return Plan(candidates: []) }
        return plan(directory: container.directory, drive: container.driveC,
                    steam: SteamIntegration.steamDirectory(in: container), now: now)
    }

    static func plan(directory: URL, drive: URL, steam: URL?, now: Date) -> Plan {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                          .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        var candidates: [Candidate] = []
        func items(_ parent: URL) -> [URL] {
            guard isLocal(parent, inside: directory) else { return [] }
            return (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: Array(keys))) ?? []
        }
        func collect(_ directory: URL, as category: Category) {
            for item in items(directory) {
                guard let values = try? item.resourceValues(forKeys: keys), values.isSymbolicLink == false,
                      let modified = values.contentModificationDate, modified < cutoff else { continue }
                // Don't classify whole temp directories or registry/installer files as disposable.
                if category == .temporary && (values.isRegularFile != true ||
                    !["tmp", "temp", "dmp", "log"].contains(item.pathExtension.lowercased())) { continue }
                guard values.isDirectory == true || values.isRegularFile == true else { continue }
                let bytes = values.isDirectory == true ? FileOps.allocatedSize(of: item)
                    : Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                candidates.append(Candidate(url: item, bytes: bytes, category: category, modification: modified))
            }
        }
        collect(drive.appendingPathComponent("windows/temp"), as: .temporary)
        for user in items(drive.appendingPathComponent("users")) {
            let local = user.appendingPathComponent("AppData/Local")
            collect(local.appendingPathComponent("Temp"), as: .temporary)
            // Keep cookies, preferences, local storage and login state.
            let html = local.appendingPathComponent("Steam/htmlcache")
            for cache in ["Cache", "Code Cache", "GPUCache", "Default/Cache", "Default/Code Cache", "Default/GPUCache"] {
                collect(html.appendingPathComponent(cache), as: .browserCache)
            }
        }
        if let steam {
            collect(steam.appendingPathComponent("steamapps/shadercache"), as: .shaderCache)
        }
        return Plan(candidates: candidates.sorted { $0.url.path < $1.url.path })
    }

    /// Move only the reviewed items. Don't follow links, clean active containers, or empty the macOS Trash.
    public static func moveToTrash(_ plan: Plan, in container: Container) throws -> Result {
        guard WineProcessScanner.sessionProcesses(of: container).allSatisfy(\.isServer) else {
            throw CleanupError.inUse
        }
        return moveReviewed(plan, directory: container.directory) {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    }

    static func moveReviewed(_ plan: Plan, directory: URL, move: (URL) throws -> Void) -> Result {
        var result = Result()
        for item in plan.candidates {
            let url = URL(fileURLWithPath: item.url.path)
            guard isLocal(url, inside: directory),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isRegularFileKey]),
                  values.contentModificationDate == item.modification,
                  values.isDirectory == true || values.isRegularFile == true else {
                result.skipped += 1
                continue
            }
            do {
                try move(url)
                result.moved += 1
            } catch {
                result.skipped += 1
            }
        }
        return result
    }

    private static func isLocal(_ url: URL, inside directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        var cursor = url.standardizedFileURL
        guard cursor.path.hasPrefix(root + "/") else { return false }
        while cursor.path != root {
            guard !FileOps.isSymlink(cursor) else { return false }
            cursor.deleteLastPathComponent()
        }
        return !FileOps.isSymlink(directory) &&
            url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                directory.resolvingSymlinksInPath().standardizedFileURL.path + "/")
    }

    enum CleanupError: LocalizedError {
        case inUse
        var errorDescription: String? { "Quit the programs in this layer and wait for Wine to finish before cleaning." }
    }
}
