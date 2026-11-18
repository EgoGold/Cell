import Foundation

/// Reads the text of Windows message boxes from a launch log.
///
/// A game that hits an error usually says so in a message box. Fullscreen games can hide it, and some engines
/// (Porting Kit's Wine 11.0 test build has no font renderer) show it as an empty title bar. Cell keeps Wine's
/// `msgbox` trace on (`WINEDEBUG=-all,trace+msgbox`, nothing else is logged), finds the text in the log and
/// shows it in its own window.
public enum WineMessageBoxes {
    static let marker = "trace:msgbox:MSGBOX_OnInit L\""

    /// The message texts in a piece of log, in order.
    public static func messages(in log: String) -> [String] {
        var result: [String] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard let start = line.range(of: marker) else { continue }
            var body = line[start.upperBound...]
            if let end = body.lastIndex(of: "\"") { body = body[..<end] }
            let text = decode(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(text) }
        }
        return result
    }

    /// Undoes Wine's debug string escapes: `\n`, `\r`, `\t`, `\"`, `\\` and `\xxxx` (UTF-16 code units).
    static func decode(_ escaped: Substring) -> String {
        var units: [UInt16] = []
        var index = escaped.startIndex
        while index < escaped.endIndex {
            let character = escaped[index]
            guard character == "\\", let next = escaped.index(index, offsetBy: 1, limitedBy: escaped.endIndex), next < escaped.endIndex else {
                units.append(contentsOf: String(character).utf16)
                index = escaped.index(after: index)
                continue
            }
            switch escaped[next] {
            case "n": units.append(10); index = escaped.index(after: next)
            case "r": units.append(13); index = escaped.index(after: next)
            case "t": units.append(9); index = escaped.index(after: next)
            case "\"": units.append(34); index = escaped.index(after: next)
            case "\\": units.append(92); index = escaped.index(after: next)
            default:
                if let end = escaped.index(next, offsetBy: 4, limitedBy: escaped.endIndex),
                   let value = UInt16(escaped[next..<end], radix: 16) {
                    units.append(value)
                    index = end
                } else {
                    units.append(92)
                    index = next
                }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// New text appended to `url` since `offset` (limited to 1 MB at a time), and the new offset.
    public static func newText(of url: URL, from offset: UInt64) -> (text: String, offset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return nil }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: Int(min(size - offset, 1 << 20)))) ?? Data()
        return (String(decoding: data, as: UTF8.self), offset + UInt64(data.count))
    }
}
