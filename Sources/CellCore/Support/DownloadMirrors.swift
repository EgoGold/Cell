import Foundation

/// Finds extra servers for a download.
///
/// - GitHub release files get public GitHub download proxies, which are often 50–100× faster where
///   github.com is slow (mainland China). They are only used once the file's SHA-256 is known (Cell's
///   catalog or GitHub's own asset digest), and the finished file is checked against it, so a proxy can't
///   change what you install.
/// - Steam installer files can come from any of Valve's CDNs.
public enum DownloadMirrors {
    public struct Plan: Sendable {
        public var sources: [DownloadSource]
        public var sha256: String?
        public var size: Int64?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _enabled = true
    nonisolated(unsafe) private static var _githubProxies = ["https://ghfast.top/", "https://gh-proxy.com/", "https://gh.monlor.com/"]
    nonisolated(unsafe) private static var digestCache: [URL: (sha256: String?, size: Int64?)] = [:]

    /// Whether mirrors are used at all (Settings ▸ Downloads).
    public static var enabled: Bool {
        get { lock.withLock { _enabled } }
        set { lock.withLock { _enabled = newValue } }
    }

    /// Prefixes of public GitHub download proxies: each serves `<prefix>https://github.com/…`.
    public static var githubProxies: [String] {
        get { lock.withLock { _githubProxies } }
        set { lock.withLock { _githubProxies = newValue } }
    }

    /// Valve CDNs that serve `/client/installer/…`.
    static let steamInstallerHosts = ["cdn.akamai.steamstatic.com", "cdn.cloudflare.steamstatic.com", "steamcdn-a.akamaihd.net",
                                      "cdn.steamstatic.com", "media.st.dl.eccdnx.com"]

    public static func plan(for url: URL, sha256: String?) async -> Plan {
        var plan = Plan(sources: [DownloadSource(url: url)], sha256: sha256, size: nil)
        guard enabled, let host = url.host?.lowercased() else { return plan }

        if let asset = GitHubAsset(url) {
            if plan.sha256 == nil {
                let digest = await githubDigest(for: asset)
                plan.sha256 = digest.sha256
                plan.size = digest.size
            }
            if plan.sha256 != nil {
                for prefix in githubProxies {
                    if let mirror = URL(string: prefix + url.absoluteString) {
                        plan.sources.append(DownloadSource(url: mirror, maxConnections: 4, isMirror: true))
                    }
                }
            }
        } else if steamInstallerHosts.contains(host), url.path.hasPrefix("/client/installer/") {
            plan.sources = steamInstallerHosts.compactMap { other in
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.host = other
                return components?.url.map { DownloadSource(url: $0, maxConnections: 8) }
            }
            if let index = plan.sources.firstIndex(where: { $0.url == url }), index > 0 {
                plan.sources.swapAt(0, index)
            }
        }
        return plan
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>`
    struct GitHubAsset: Hashable {
        var owner, repo, tag, name: String
        var url: URL

        init?(_ url: URL) {
            guard url.host?.lowercased() == "github.com" else { return nil }
            let parts = url.path.split(separator: "/").map(String.init)
            guard parts.count == 6, parts[2] == "releases", parts[3] == "download" else { return nil }
            owner = parts[0]; repo = parts[1]; tag = parts[4]; name = parts[5]
            self.url = url
        }
    }

    /// SHA-256 and size that GitHub publishes for a release file (assets uploaded since mid-2025 have one).
    static func githubDigest(for asset: GitHubAsset) async -> (sha256: String?, size: Int64?) {
        if let cached = lock.withLock({ digestCache[asset.url] }) { return cached }
        guard let api = URL(string: "https://api.github.com/repos/\(asset.owner)/\(asset.repo)/releases/tags/\(asset.tag)") else {
            return (nil, nil)
        }
        var request = URLRequest(url: api, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Cell/0.2 (macOS)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let match = release.assets.first(where: { $0.name == asset.name }) else { return (nil, nil) }
        var sha: String?
        if let digest = match.digest, digest.lowercased().hasPrefix("sha256:") {
            sha = String(digest.dropFirst("sha256:".count)).lowercased()
        }
        let result = (sha256: sha, size: match.size)
        lock.withLock { digestCache[asset.url] = result }
        return result
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            var name: String
            var size: Int64?
            var digest: String?
        }
        var assets: [Asset]
    }
}
