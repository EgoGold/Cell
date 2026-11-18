import Foundation

/// Valve KeyValues text format (appmanifest_*.acf, libraryfolders.vdf, localconfig.vdf).
public indirect enum VDFNode: Hashable {
    case string(String)
    case object([(key: String, value: VDFNode)])

    public static func == (lhs: VDFNode, rhs: VDFNode) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .string(let value): hasher.combine(value)
        case .object(let pairs): for pair in pairs { hasher.combine(pair.key); hasher.combine(pair.value) }
        }
    }

    /// Case-insensitive child lookup.
    public subscript(key: String) -> VDFNode? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var children: [(key: String, value: VDFNode)] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    public static func parse(_ text: String) -> VDFNode? {
        var parser = VDFParser(Array(text.unicodeScalars))
        return parser.parseRoot()
    }

    public static func parse(contentsOf url: URL) -> VDFNode? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }
}

private struct VDFParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    enum Token { case string(String), open, close }

    mutating func skipWhitespaceAndComments() {
        while index < scalars.count {
            let c = scalars[index]
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" {
                index += 1
            } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
            } else {
                break
            }
        }
    }

    mutating func nextToken() -> Token? {
        skipWhitespaceAndComments()
        guard index < scalars.count else { return nil }
        let c = scalars[index]
        if c == "{" { index += 1; return .open }
        if c == "}" { index += 1; return .close }
        var value = String.UnicodeScalarView()
        if c == "\"" {
            index += 1
            while index < scalars.count, scalars[index] != "\"" {
                var s = scalars[index]
                if s == "\\", index + 1 < scalars.count {
                    index += 1
                    switch scalars[index] {
                    case "n": s = "\n"
                    case "t": s = "\t"
                    case "\\": s = "\\"
                    case "\"": s = "\""
                    default: s = scalars[index]
                    }
                }
                value.append(s)
                index += 1
            }
            index += 1
            return .string(String(value))
        }
        while index < scalars.count {
            let s = scalars[index]
            if s == " " || s == "\t" || s == "\n" || s == "\r" || s == "{" || s == "}" || s == "\"" { break }
            value.append(s)
            index += 1
        }
        // Skip conditional suffixes like [$WIN32].
        return .string(String(value))
    }

    mutating func parseObjectBody() -> VDFNode {
        var pairs: [(key: String, value: VDFNode)] = []
        while let token = nextToken() {
            switch token {
            case .close: return .object(pairs)
            case .open: _ = parseObjectBody()
            case .string(let key):
                guard let valueToken = nextToken() else { return .object(pairs) }
                switch valueToken {
                case .string(let value): pairs.append((key, .string(value)))
                case .open: pairs.append((key, parseObjectBody()))
                case .close: pairs.append((key, .string(""))); return .object(pairs)
                }
            }
        }
        return .object(pairs)
    }

    mutating func parseRoot() -> VDFNode? {
        let root = parseObjectBody()
        return root.children.isEmpty ? nil : root
    }
}
