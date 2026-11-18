import Foundation

/// Bounds-checked little-endian reads. Every accessor returns nil instead of trapping.
extension Data {
    @inline(__always) func u8(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    @inline(__always) func u16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    @inline(__always) func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    @inline(__always) func u64(at offset: Int) -> UInt64? {
        guard let low = u32(at: offset), let high = u32(at: offset + 4) else { return nil }
        return UInt64(low) | UInt64(high) << 32
    }

    /// NUL-terminated 8-bit string (ASCII / Latin-1).
    func cString(at offset: Int, maxLength: Int = 1024) -> String? {
        guard offset >= 0, offset < count else { return nil }
        var bytes: [UInt8] = []
        var i = offset
        while i < count, bytes.count < maxLength {
            let byte = self[startIndex + i]
            if byte == 0 { break }
            bytes.append(byte)
            i += 1
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
    }

    /// NUL-terminated UTF-16LE string, limited to `end` (exclusive).
    func utf16String(at offset: Int, end: Int? = nil, maxCharacters: Int = 4096) -> (String, Int)? {
        let limit = Swift.min(end ?? count, count)
        guard offset >= 0, offset < limit else { return nil }
        var units: [UInt16] = []
        var i = offset
        while i + 1 < limit, units.count < maxCharacters {
            guard let unit = u16(at: i) else { break }
            i += 2
            if unit == 0 { break }
            units.append(unit)
        }
        return (String(decoding: units, as: UTF16.self), i)
    }

    /// Counted UTF-16LE string (length prefix in characters).
    func countedUTF16String(at offset: Int, characters: Int) -> String? {
        guard characters >= 0, offset >= 0, offset + characters * 2 <= count else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(characters)
        for n in 0..<characters { units.append(u16(at: offset + n * 2) ?? 0) }
        return String(decoding: units, as: UTF16.self)
    }

    func slice(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        return subdata(in: (startIndex + offset)..<(startIndex + offset + length))
    }
}

@inline(__always) func align4(_ value: Int) -> Int { (value + 3) & ~3 }
