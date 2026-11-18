import Foundation

public enum RegistryHive: String, Codable, Hashable, Sendable {
    case currentUser = "HKEY_CURRENT_USER"
    case localMachine = "HKEY_LOCAL_MACHINE"
    case classesRoot = "HKEY_CLASSES_ROOT"
    case users = "HKEY_USERS"

    /// Parses "HKCU\\Software\\X" or "HKEY_CURRENT_USER\\Software\\X" into hive + subkey.
    public static func split(_ fullPath: String) -> (RegistryHive, String)? {
        let normalized = fullPath.replacingOccurrences(of: "/", with: "\\")
        let parts = normalized.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let hive: RegistryHive
        switch first.uppercased() {
        case "HKCU", "HKEY_CURRENT_USER": hive = .currentUser
        case "HKLM", "HKEY_LOCAL_MACHINE": hive = .localMachine
        case "HKCR", "HKEY_CLASSES_ROOT": hive = .classesRoot
        case "HKU", "HKEY_USERS": hive = .users
        default: return nil
        }
        return (hive, parts.count > 1 ? String(parts[1]) : "")
    }
}

public enum RegistryValue: Hashable, Codable, Sendable {
    case string(String)
    case expandString(String)
    case multiString([String])
    case dword(UInt32)
    case qword(UInt64)
    case binary([UInt8])
    case delete
}

/// One change to apply to a Wine prefix registry.
public struct RegistryEdit: Hashable, Codable, Sendable {
    public var hive: RegistryHive
    public var key: String
    /// nil = the key's default value (`@`).
    public var name: String?
    public var value: RegistryValue
    /// Deletes the whole key (and subkeys) instead of setting a value.
    public var deletesKey: Bool

    public init(hive: RegistryHive, key: String, name: String?, value: RegistryValue) {
        self.hive = hive
        self.key = key
        self.name = name
        self.value = value
        self.deletesKey = false
    }

    public static func set(_ hive: RegistryHive, _ key: String, _ name: String?, _ value: RegistryValue) -> RegistryEdit {
        RegistryEdit(hive: hive, key: key, name: name, value: value)
    }

    public static func deleteKey(_ hive: RegistryHive, _ key: String) -> RegistryEdit {
        var edit = RegistryEdit(hive: hive, key: key, name: nil, value: .delete)
        edit.deletesKey = true
        return edit
    }

    public var fullKey: String { "\(hive.rawValue)\\\(key)" }
}

/// Writes `.reg` files for `wine regedit /S` (UTF-16LE with BOM so any language survives).
public enum RegFile {
    public static func text(for edits: [RegistryEdit]) -> String {
        var lines = ["Windows Registry Editor Version 5.00", ""]
        var currentKey: String?
        for edit in edits {
            if edit.deletesKey {
                if currentKey != nil { lines.append("") }
                lines.append("[-\(edit.fullKey)]")
                lines.append("")
                currentKey = nil
                continue
            }
            if currentKey?.caseInsensitiveCompare(edit.fullKey) != .orderedSame {
                if currentKey != nil { lines.append("") }
                lines.append("[\(edit.fullKey)]")
                currentKey = edit.fullKey
            }
            let name = edit.name.map { "\"\(escape($0))\"" } ?? "@"
            lines.append("\(name)=\(encode(edit.value))")
        }
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    public static func data(for edits: [RegistryEdit]) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text(for: edits).utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    static func escape(_ string: String) -> String {
        string.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func encode(_ value: RegistryValue) -> String {
        switch value {
        case .string(let s): return "\"\(escape(s))\""
        case .dword(let v): return String(format: "dword:%08x", v)
        case .qword(let v): return "hex(b):" + hex(withUnsafeBytes(of: v.littleEndian, Array.init))
        case .binary(let bytes): return "hex:" + hex(bytes)
        case .expandString(let s): return "hex(2):" + hex(utf16z(s))
        case .multiString(let list):
            var bytes: [UInt8] = []
            for item in list { bytes += utf16z(item) }
            bytes += [0, 0]
            return "hex(7):" + hex(bytes)
        case .delete: return "-"
        }
    }

    private static func utf16z(_ s: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for unit in s.utf16 { bytes.append(UInt8(unit & 0xFF)); bytes.append(UInt8(unit >> 8)) }
        return bytes + [0, 0]
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ",")
    }
}

// MARK: - Reading Wine hive files (system.reg / user.reg)

public struct RegistryValueEntry: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Empty string = default value.
    public var name: String
    public var type: String
    public var display: String
}

public final class RegistryKeyNode: Identifiable, Hashable {
    public let path: String
    public let name: String
    public var values: [RegistryValueEntry]
    public var childNodes: [RegistryKeyNode]
    public var id: String { path }
    /// For OutlineGroup: nil when there are no children.
    public var children: [RegistryKeyNode]? { childNodes.isEmpty ? nil : childNodes }

    init(path: String, name: String) {
        self.path = path
        self.name = name
        self.values = []
        self.childNodes = []
    }

    public static func == (lhs: RegistryKeyNode, rhs: RegistryKeyNode) -> Bool { lhs.path == rhs.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// Reads Wine's text registry hives without starting Wine (so the registry can be browsed natively).
public struct WineRegistryHive {
    public let rootName: String
    /// Key path (backslash separated, original case) -> values.
    public private(set) var keys: [String: [RegistryValueEntry]] = [:]
    public private(set) var keyOrder: [String] = []

    public static func load(_ url: URL, rootName: String) throws -> WineRegistryHive {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text, rootName: rootName)
    }

    public static func parse(_ text: String, rootName: String) -> WineRegistryHive {
        var hive = WineRegistryHive(rootName: rootName)
        var currentKey: String?
        var pending = ""
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if !pending.isEmpty {
                pending += line.trimmingCharacters(in: .whitespaces)
                if pending.hasSuffix("\\") { pending.removeLast(); continue }
                line = pending
                pending = ""
            } else if line.hasSuffix("\\"), line.contains("=hex") {
                pending = String(line.dropLast())
                continue
            }
            if line.hasPrefix("[") {
                guard let close = closingBracket(in: line) else { continue }
                let rawKey = String(line[line.index(after: line.startIndex)..<close])
                let key = unescape(rawKey)
                currentKey = key
                if hive.keys[key] == nil { hive.keys[key] = []; hive.keyOrder.append(key) }
                continue
            }
            guard let key = currentKey, !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if let entry = parseValueLine(line) { hive.keys[key, default: []].append(entry) }
        }
        return hive
    }

    public func values(at path: String) -> [RegistryValueEntry]? {
        if let exact = keys[path] { return exact }
        let lower = path.lowercased()
        return keys.first { $0.key.lowercased() == lower }?.value
    }

    public func value(_ path: String, _ name: String) -> String? {
        values(at: path)?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.display
    }

    /// Builds the key hierarchy (sorted alphabetically).
    public func tree() -> [RegistryKeyNode] {
        let root = RegistryKeyNode(path: "", name: rootName)
        var index: [String: RegistryKeyNode] = ["": root]
        for path in keyOrder {
            var parent = root
            var accumulated = ""
            for component in path.split(separator: "\\").map(String.init) {
                accumulated = accumulated.isEmpty ? component : accumulated + "\\" + component
                let lookup = accumulated.lowercased()
                if let existing = index[lookup] {
                    parent = existing
                } else {
                    let node = RegistryKeyNode(path: accumulated, name: component)
                    parent.childNodes.append(node)
                    index[lookup] = node
                    parent = node
                }
            }
            parent.values = keys[path] ?? []
        }
        func sort(_ node: RegistryKeyNode) {
            node.childNodes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            node.childNodes.forEach(sort)
        }
        sort(root)
        return root.childNodes
    }

    // MARK: Parsing helpers

    private static func closingBracket(in line: String) -> String.Index? {
        var escaped = false
        var index = line.index(after: line.startIndex)
        while index < line.endIndex {
            let c = line[index]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "]" { return index }
            index = line.index(after: index)
        }
        return nil
    }

    private static func parseValueLine(_ line: String) -> RegistryValueEntry? {
        var name = ""
        var rest: Substring
        if line.hasPrefix("@=") {
            rest = line.dropFirst(2)
        } else if line.hasPrefix("\"") {
            guard let (rawName, end) = quoted(line, from: line.startIndex) else { return nil }
            name = unescape(rawName)
            rest = line[end...]
            guard rest.hasPrefix("=") else { return nil }
            rest = rest.dropFirst()
        } else {
            return nil
        }

        if rest.hasPrefix("\"") {
            let text = String(rest)
            guard let (raw, _) = quoted(text, from: text.startIndex) else { return nil }
            return RegistryValueEntry(name: name, type: "REG_SZ", display: unescape(raw))
        }
        if rest.hasPrefix("str(2):\"") || rest.hasPrefix("str(7):\"") {
            let isMulti = rest.hasPrefix("str(7)")
            let tail = String(rest.dropFirst(7))
            guard let (raw, _) = quoted(tail, from: tail.startIndex) else { return nil }
            if isMulti {
                let parts = unescape(raw).split(separator: "\0").map(String.init)
                return RegistryValueEntry(name: name, type: "REG_MULTI_SZ", display: parts.joined(separator: " · "))
            }
            return RegistryValueEntry(name: name, type: "REG_EXPAND_SZ", display: unescape(raw))
        }
        if rest.hasPrefix("dword:") {
            let hexDigits = String(rest.dropFirst(6))
            let value = UInt32(hexDigits, radix: 16) ?? 0
            return RegistryValueEntry(name: name, type: "REG_DWORD", display: String(format: "0x%08x (%u)", value, value))
        }
        if rest.hasPrefix("hex") {
            var type = "REG_BINARY"
            var payload = rest.dropFirst(3)
            if payload.hasPrefix("("), let close = payload.firstIndex(of: ")") {
                let code = payload[payload.index(after: payload.startIndex)..<close]
                switch code.lowercased() {
                case "2": type = "REG_EXPAND_SZ"
                case "7": type = "REG_MULTI_SZ"
                case "b": type = "REG_QWORD"
                case "4": type = "REG_DWORD"
                default: type = "REG_BINARY (\(code))"
                }
                payload = payload[payload.index(after: close)...]
            }
            if payload.hasPrefix(":") { payload = payload.dropFirst() }
            let bytes = payload.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
            switch type {
            case "REG_EXPAND_SZ", "REG_MULTI_SZ":
                var units: [UInt16] = []
                var i = 0
                while i + 1 < bytes.count { units.append(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8); i += 2 }
                let strings = units.split(separator: 0).map { String(decoding: $0, as: UTF16.self) }
                return RegistryValueEntry(name: name, type: type, display: strings.joined(separator: " · "))
            case "REG_QWORD" where bytes.count == 8:
                var value: UInt64 = 0
                for (shift, byte) in bytes.enumerated() { value |= UInt64(byte) << (8 * UInt64(shift)) }
                return RegistryValueEntry(name: name, type: type, display: "0x\(String(value, radix: 16)) (\(value))")
            default:
                let preview = bytes.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
                return RegistryValueEntry(name: name, type: type, display: preview + (bytes.count > 24 ? " … (\(bytes.count) bytes)" : ""))
            }
        }
        return RegistryValueEntry(name: name, type: "REG_UNKNOWN", display: String(rest))
    }

    /// Reads a double-quoted, backslash-escaped token. Returns the raw (still escaped) content and the index after the closing quote.
    private static func quoted(_ line: String, from start: String.Index) -> (String, String.Index)? {
        guard start < line.endIndex, line[start] == "\"" else { return nil }
        var index = line.index(after: start)
        var raw = ""
        var escaped = false
        while index < line.endIndex {
            let c = line[index]
            if escaped {
                raw.append("\\"); raw.append(c); escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return (raw, line.index(after: index))
            } else {
                raw.append(c)
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Wine escapes: \\ \" \n \r \t \0 and \xHHHH (UTF-16 code units).
    static func unescape(_ raw: String) -> String {
        var units: [UInt16] = []
        let scalars = Array(raw.utf16)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            guard c == 0x5C, i + 1 < scalars.count else { units.append(c); i += 1; continue }
            let next = scalars[i + 1]
            switch next {
            case 0x6E: units.append(0x0A); i += 2           // \n
            case 0x72: units.append(0x0D); i += 2           // \r
            case 0x74: units.append(0x09); i += 2           // \t
            case 0x30: units.append(0x00); i += 2           // \0
            case 0x78:                                      // \xHHHH
                var j = i + 2
                var value: UInt32 = 0
                var digits = 0
                while j < scalars.count, digits < 4, let digit = hexValue(scalars[j]) {
                    value = value * 16 + digit
                    j += 1
                    digits += 1
                }
                if digits == 0 { units.append(next); i += 2 } else { units.append(UInt16(value)); i = j }
            default: units.append(next); i += 2              // \\ \" and anything else
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func hexValue(_ unit: UInt16) -> UInt32? {
        switch unit {
        case 0x30...0x39: return UInt32(unit - 0x30)
        case 0x41...0x46: return UInt32(unit - 0x41 + 10)
        case 0x61...0x66: return UInt32(unit - 0x61 + 10)
        default: return nil
        }
    }
}
