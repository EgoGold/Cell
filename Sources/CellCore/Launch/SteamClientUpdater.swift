import Foundation

/// Makes Steam's own updates fast.
///
/// Steam's updater downloads the client (300+ MB on a fresh install) over one connection from whichever
/// server it knows; inside Wine, and from regions where that server is slow, this often crawls at
/// 20–200 KB/s. Before Steam starts, Cell reads the same update manifest Steam uses, downloads the
/// missing package files from all of Valve's update servers in parallel (each file checked against the
/// manifest's SHA-256) and puts them where Steam looks first. Steam then finds them and only unpacks.
public enum SteamClientUpdater {
    public struct Package: Hashable, Sendable {
        public var fileName: String
        public var size: Int64
        public var sha256: String?
    }

    public struct Manifest: Sendable {
        public var name: String
        public var version: String
        public var packages: [Package]
    }

    public struct Report: Sendable {
        public var version: String?
        public var downloaded: [Package] = []
        public var alreadyPresent = 0
        public var bytes: Int64 { downloaded.reduce(0) { $0 + $1.size } }
    }

    /// Valve's client update servers (from Steam's signed host list), with their path prefix.
    public static let updateHosts: [(host: String, path: String)] = [
        ("client-update.akamai.steamstatic.com", "/"),
        ("client-update.fastly.steamstatic.com", "/"),
        ("client-update.steamstatic.com", "/"),
        ("cdn.steamstatic.com", "/client/"),
        ("media.st.dl.eccdnx.com", "/client/"),
        ("client-update.queniuqe.com", "/"),
    ]

    /// Which manifests Steam will ask for: a fresh install still starts with the 32-bit updater.
    public static func manifestNames(steamDirectory: URL) -> [String] {
        let installed = steamDirectory.appendingPathComponent("package/steam_client_win64.installed")
        return FileManager.default.fileExists(atPath: installed.path) ? ["steam_client_win64"]
            : ["steam_client_win32", "steam_client_win64"]
    }

    /// Parses `steam_client_win64`-style manifests. Steam downloads the compressed `.zip.vz` file when
    /// the manifest lists one, otherwise the `.zip`.
    public static func parseManifest(_ text: String, name: String) -> Manifest? {
        guard let root = VDFNode.parse(text), let body = root.children.first?.value,
              let version = body["version"]?.string else { return nil }
        var packages: [Package] = []
        for (key, entry) in body.children {
            guard let file = entry["file"]?.string else { continue }
            // Packages with per-realm variants (a nested "steamchina" block) are stored and served as
            // "<name>_steamrow…" for the global realm.
            let hasRealmVariants = entry.children.contains { !$0.value.children.isEmpty }
            func stored(_ name: String) -> String {
                hasRealmVariants && name.hasPrefix(key + ".") ? key + "_steamrow" + name.dropFirst(key.count) : name
            }
            if let compressed = entry["zipvz"]?.string,
               let size = compressed.split(separator: "_").last.flatMap({ Int64($0) }) {
                packages.append(Package(fileName: stored(compressed), size: size, sha256: entry["sha2vz"]?.string?.lowercased()))
            } else if let size = entry["size"]?.string.flatMap({ Int64($0) }) {
                packages.append(Package(fileName: stored(file), size: size, sha256: entry["sha2"]?.string?.lowercased()))
            }
        }
        return packages.isEmpty ? nil : Manifest(name: name, version: version, packages: packages)
    }

    /// Fetches a manifest from whichever update server answers first.
    public static func fetchManifest(_ name: String, timeout: TimeInterval = 8) async -> Manifest? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: Manifest?.self) { group in
            for (host, path) in updateHosts {
                guard let url = URL(string: "https://\(host)\(path)\(name)") else { continue }
                group.addTask {
                    guard let (data, response) = try? await session.data(from: url),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return parseManifest(text, name: name)
                }
            }
            var best: Manifest?
            for await manifest in group {
                guard let manifest else { continue }
                // Servers can lag behind for a few minutes; prefer the newest version.
                if best == nil || (Int64(manifest.version) ?? 0) > (Int64(best!.version) ?? 0) { best = manifest }
                if best != nil { group.cancelAll() }
            }
            return best
        }
    }

    /// What Steam would download right now: (packages missing, packages already present, newest version).
    public static func check(steamDirectory: URL, timeout: TimeInterval = 8) async -> (missing: [Package], present: Int, version: String?) {
        let packageDirectory = steamDirectory.appendingPathComponent("package", isDirectory: true)
        var missing: [Package] = []
        var present = 0
        var version: String?
        var seen = Set<String>()
        for name in manifestNames(steamDirectory: steamDirectory) {
            guard let manifest = await fetchManifest(name, timeout: timeout) else { continue }
            if name == "steam_client_win64" { version = manifest.version }
            for package in manifest.packages where seen.insert(package.fileName).inserted {
                if FileOps.fileSize(packageDirectory.appendingPathComponent(package.fileName)) == package.size {
                    present += 1
                } else {
                    missing.append(package)
                }
            }
        }
        return (missing, present, version)
    }

    /// Downloads every package Steam is missing. Returns what was done; throws only when a download fails.
    @discardableResult
    public static func prefetch(steamDirectory: URL, timeout: TimeInterval = 8, status: (@Sendable (String) -> Void)? = nil) async throws -> Report {
        let packageDirectory = steamDirectory.appendingPathComponent("package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let state = await check(steamDirectory: steamDirectory, timeout: timeout)
        var report = Report(version: state.version, downloaded: [], alreadyPresent: state.present)
        let needed = state.missing
        guard !needed.isEmpty else { return report }
        let total = needed.reduce(Int64(0)) { $0 + $1.size }
        status?("Downloading Steam's update (\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)), all servers at once)…")
        // Largest first; a few files at a time so every server stays busy.
        let queue = needed.sorted { $0.size > $1.size }
        try await withThrowingTaskGroup(of: Package?.self) { group in
            var iterator = queue.makeIterator()
            func addNext() {
                guard let package = iterator.next() else { return }
                group.addTask {
                    let sources = updateHosts.compactMap { host, path in
                        URL(string: "https://\(host)\(path)\(package.fileName)").map { DownloadSource(url: $0, maxConnections: 8) }
                    }
                    let destination = packageDirectory.appendingPathComponent(package.fileName)
                    do {
                        _ = try await Downloader.download(sources: sources, to: destination,
                                                          title: "Steam update · \(package.fileName.components(separatedBy: ".zip").first ?? package.fileName)",
                                                          sha256: package.sha256, expectedSize: package.size)
                    } catch {
                        // Only a head start: Steam fetches what's missing itself. A package the servers don't
                        // have (404) used to stay in Downloads retrying forever, which also kept Cell running.
                        DownloadManager.shared.discard(destination: destination)
                        return nil
                    }
                    return package
                }
            }
            for _ in 0..<3 { addNext() }
            while let finished = try await group.next() {
                if let finished { report.downloaded.append(finished) }
                addNext()
            }
        }
        return report
    }

    // MARK: Faster Steam downloads

    /// Settings Steam reads from `steam_dev.cfg`: without HTTP/2, Steam opens several connections per
    /// download server instead of squeezing everything through one (much faster under Wine and through
    /// proxies), and it adds servers whenever that improves the speed at all.
    static let developerSettings: [(key: String, value: String)] = [
        ("@nClientDownloadEnableHTTP2PlatformWindows", "0"),
        ("@fDownloadRateImprovementToAddAnotherConnection", "1.0"),
    ]

    /// Writes Cell's download settings into `steam_dev.cfg`, keeping any other lines.
    public static func applyDownloadSettings(steamDirectory: URL) {
        let file = steamDirectory.appendingPathComponent("steam_dev.cfg")
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines).filter { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
                && !developerSettings.contains { line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix($0.key.lowercased() + " ") }
        }
        lines += developerSettings.map { "\($0.key) \($0.value)" }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        if text != existing { try? text.write(to: file, atomically: true, encoding: .utf8) }
    }

    /// A fresh Steam only knows one (often slow) update server until it has fetched Valve's signed
    /// server list. Copy a still-valid list from another Steam on this Mac.
    public static func shareUpdateHosts(to steamDirectory: URL, from otherSteamDirectories: [URL]) {
        let target = steamDirectory.appendingPathComponent("update_hosts_cached.vdf")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let now = Date().timeIntervalSince1970
        let candidates = otherSteamDirectories.map { $0.appendingPathComponent("update_hosts_cached.vdf") }.compactMap { file -> (URL, Double)? in
            guard let root = VDFNode.parse(contentsOf: file),
                  let validUntil = root.children.first?.value["ClientInfo"]?["valid_until"]?.string.flatMap(Double.init)
                    ?? root["ClientInfo"]?["valid_until"]?.string.flatMap(Double.init),
                  validUntil > now else { return nil }
            return (file, validUntil)
        }
        if let best = candidates.max(by: { $0.1 < $1.1 }) {
            try? FileManager.default.copyItem(at: best.0, to: target)
        }
    }
}
