import Foundation

/// Loose version numbers such as "11.21", "6000.3.15f1", "5.3.2", "v0.80".
public struct LooseVersion: Comparable, Hashable, CustomStringConvertible {
    public let components: [Int]
    public let original: String

    public init(_ string: String) {
        original = string
        var trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("v") { trimmed.removeFirst() }
        components = trimmed
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " })
            .prefix(6)
            .compactMap { part -> Int? in
                let digits = part.prefix { $0.isNumber }
                return digits.isEmpty ? nil : Int(digits)
            }
    }

    public var description: String { original }

    public static func < (lhs: LooseVersion, rhs: LooseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    public static func == (lhs: LooseVersion, rhs: LooseVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    /// Evaluates expressions like ">=2021", "<6000.3", "6000.*", "=5.3", "5.3".
    /// Several conditions can be combined with spaces or commas: ">=2019 <2023".
    public func satisfies(_ expression: String) -> Bool {
        let parts = expression.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !parts.isEmpty else { return true }
        return parts.allSatisfy { part in
            var op = ""
            var rest = Substring(part)
            for candidate in [">=", "<=", "==", "!=", ">", "<", "=", "~"] where rest.hasPrefix(candidate) {
                op = candidate
                rest = rest.dropFirst(candidate.count)
                break
            }
            let target = String(rest)
            if target.hasSuffix("*") || op == "~" {
                let prefix = LooseVersion(String(target.dropLast(target.hasSuffix("*") ? 1 : 0)))
                return Array(components.prefix(prefix.components.count)) == prefix.components
            }
            let other = LooseVersion(target)
            switch op {
            case ">=": return self >= other
            case "<=": return self <= other
            case ">": return self > other
            case "<": return self < other
            case "!=": return self != other
            default: return self == other
            }
        }
    }
}

/// Glob matching with `*` and `?`, case-insensitive (used by plugin match rules).
public func globMatch(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.lowercased())
    let t = Array(text.lowercased())
    var pi = 0, ti = 0, star = -1, mark = 0
    while ti < t.count {
        if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
            pi += 1; ti += 1
        } else if pi < p.count, p[pi] == "*" {
            star = pi; mark = ti; pi += 1
        } else if star >= 0 {
            pi = star + 1; mark += 1; ti = mark
        } else {
            return false
        }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}
