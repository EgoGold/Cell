import Foundation

/// Parser for Windows Shell Link (.lnk) files, as written by installers into the Start Menu.
public struct LnkFile: Hashable {
    public var targetPath: String?
    public var arguments: String?
    public var workingDirectory: String?
    public var iconLocation: String?
    public var name: String?
    public var relativePath: String?

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        guard data.u32(at: 0) == 0x4C, let flags = data.u32(at: 20) else { return nil }
        let hasIDList = flags & 0x1 != 0
        let hasLinkInfo = flags & 0x2 != 0
        let hasName = flags & 0x4 != 0
        let hasRelativePath = flags & 0x8 != 0
        let hasWorkingDir = flags & 0x10 != 0
        let hasArguments = flags & 0x20 != 0
        let hasIconLocation = flags & 0x40 != 0
        let isUnicode = flags & 0x80 != 0

        var offset = 76
        if hasIDList {
            guard let size = data.u16(at: offset) else { return nil }
            offset += 2 + Int(size)
        }

        if hasLinkInfo {
            let start = offset
            guard let size = data.u32(at: start), let headerSize = data.u32(at: start + 4),
                  let linkInfoFlags = data.u32(at: start + 8) else { return nil }
            if linkInfoFlags & 0x1 != 0 {
                var base: String?
                var suffix: String?
                if headerSize >= 0x24, let unicodeBase = data.u32(at: start + 28), unicodeBase != 0 {
                    base = data.utf16String(at: start + Int(unicodeBase))?.0
                    if let unicodeSuffix = data.u32(at: start + 32), unicodeSuffix != 0 {
                        suffix = data.utf16String(at: start + Int(unicodeSuffix))?.0
                    }
                }
                if base == nil, let baseOffset = data.u32(at: start + 16) {
                    base = data.cString(at: start + Int(baseOffset), maxLength: 1024)
                }
                if suffix == nil, let suffixOffset = data.u32(at: start + 24), suffixOffset != 0 {
                    suffix = data.cString(at: start + Int(suffixOffset), maxLength: 1024)
                }
                if let base, !base.isEmpty { targetPath = base + (suffix ?? "") }
            }
            offset = start + Int(size)
        }

        func readString() -> String? {
            guard let count = data.u16(at: offset) else { return nil }
            let characters = Int(count)
            offset += 2
            if isUnicode {
                let value = data.countedUTF16String(at: offset, characters: characters)
                offset += characters * 2
                return value
            }
            guard let bytes = data.slice(offset, characters) else { return nil }
            offset += characters
            return String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        }

        if hasName { name = readString() }
        if hasRelativePath { relativePath = readString() }
        if hasWorkingDir { workingDirectory = readString() }
        if hasArguments { arguments = readString() }
        if hasIconLocation { iconLocation = readString() }

        // Extra data: EnvironmentVariableDataBlock carries a target like %ProgramFiles%\App\app.exe.
        if targetPath == nil {
            var block = offset
            for _ in 0..<32 {
                guard let size = data.u32(at: block), size >= 8, let signature = data.u32(at: block + 4) else { break }
                if signature == 0xA000_0001 {
                    let unicode = data.utf16String(at: block + 8 + 260, end: block + Int(size))?.0
                    let ansi = data.cString(at: block + 8, maxLength: 260)
                    targetPath = (unicode?.isEmpty == false ? unicode : ansi).map(Self.expandEnvironment)
                    break
                }
                block += Int(size)
            }
        }
    }

    private static func expandEnvironment(_ path: String) -> String {
        let replacements = [
            "%ProgramFiles%": "C:\\Program Files",
            "%ProgramFiles(x86)%": "C:\\Program Files (x86)",
            "%SystemRoot%": "C:\\windows",
            "%windir%": "C:\\windows",
            "%ProgramData%": "C:\\ProgramData",
        ]
        var result = path
        for (key, value) in replacements {
            result = result.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
        }
        return result
    }

    /// Splits a Windows command line the way CommandLineToArgvW does (simplified).
    public static func splitArguments(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for character in line {
            switch character {
            case "\"":
                inQuotes.toggle()
                hasToken = true
            case " " where !inQuotes, "\t" where !inQuotes:
                if hasToken { result.append(current); current = ""; hasToken = false }
            default:
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}
