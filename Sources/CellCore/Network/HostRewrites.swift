import Darwin
import Foundation

/// Per-layer aliases used by Wine's system resolver. Only the address lookup changes.
public struct HostRewrites: Codable, Hashable, Sendable {
    public var rules: [String: String] = [:]
    public var retryOriginal: Bool = true
    public var preferIPv4: Bool?

    public init() {}

    public static func url(for container: Container) -> URL {
        container.directory.appendingPathComponent("host-rewrites.tsv")
    }

    static func normalizedName(_ source: String) -> String? {
        let name = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        guard trimmed.count <= 253,
              trimmed.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$"#,
                            options: .regularExpression) != nil else { return nil }
        return trimmed
    }

    static func isAddress(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }

    public func validated() throws -> HostRewrites {
        var result = HostRewrites()
        result.retryOriginal = retryOriginal
        result.preferIPv4 = preferIPv4
        guard rules.count <= 256 else { throw HostRewriteError.invalid("Use at most 256 rules per layer.") }
        for (host, target) in rules {
            let address = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = Self.normalizedName(host), !Self.isAddress(key),
                  let value = Self.isAddress(address) ? address : Self.normalizedName(address),
                  key != value, result.rules[key] == nil else {
                throw HostRewriteError.invalid("Check “\(host) → \(target)”. Use a unique hostname and a hostname or IP address as the destination.")
            }
            result.rules[key] = value
        }
        return result
    }

    public func write(for container: Container) throws {
        let value = try validated()
        let url = Self.url(for: container)
        let rows = value.rules.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }
        let settings = ["#retry-original\t\(value.retryOriginal ? "1" : "0")",
                        "#prefer-ipv4\t\(value.preferIPv4 == true ? "1" : "0")"]
        let contents = (settings + rows).joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) != contents {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Each target is checked through the host resolver using a bounded process.
    public func unresolvedTargets() throws -> [String] {
        let targets = Set(try validated().rules.values)
        return targets.sorted().filter { host in
            if Self.isAddress(host) { return false }
            let result = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/dscacheutil"),
                                                arguments: ["-q", "host", "-a", "name", host], timeout: 4)
            return result?.status != 0 || result?.stdout.contains("address:") != true
        }
    }
}

enum HostRewriteError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}
