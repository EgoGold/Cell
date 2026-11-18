import Foundation

/// Minimal, defensive parser for Windows PE files (EXE/DLL).
///
/// Reads what Cell needs to make decisions: architecture, subsystem, imported DLLs
/// (including delay-loaded ones), .NET marker, icons and version strings.
public struct PEFile {
    public let architecture: PEArchitecture
    public let is64Bit: Bool
    public let subsystem: UInt16
    public let imports: [String]
    public let delayImports: [String]
    public let isDotNet: Bool
    public let timestamp: UInt32

    private let data: Data
    private let sections: [Section]
    private let resourceOffset: Int?

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawPointer: UInt32
        let rawSize: UInt32
    }

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        guard data.u16(at: 0) == 0x5A4D, let lfanew32 = data.u32(at: 0x3C) else { return nil }
        let lfanew = Int(lfanew32)
        guard lfanew > 0, lfanew < data.count - 24, data.u32(at: lfanew) == 0x0000_4550 else { return nil }
        self.data = data

        let coff = lfanew + 4
        let machine = data.u16(at: coff) ?? 0
        let sectionCount = Int(data.u16(at: coff + 2) ?? 0)
        timestamp = data.u32(at: coff + 4) ?? 0
        let optionalSize = Int(data.u16(at: coff + 16) ?? 0)
        let optional = coff + 20
        let magic = data.u16(at: optional) ?? 0
        is64Bit = magic == 0x20B

        switch machine {
        case 0x014C: architecture = .x86
        case 0x8664: architecture = .x64
        case 0xAA64: architecture = .arm64
        case 0xA641: architecture = .arm64ec
        default: architecture = .unknown
        }

        subsystem = data.u16(at: optional + 68) ?? 0
        let imageBase: UInt64 = is64Bit ? (data.u64(at: optional + 24) ?? 0) : UInt64(data.u32(at: optional + 28) ?? 0)
        let directoryCount = Int(data.u32(at: optional + (is64Bit ? 108 : 92)) ?? 0)
        let directoriesStart = optional + (is64Bit ? 112 : 96)

        var sections: [Section] = []
        let sectionTable = optional + optionalSize
        for index in 0..<min(sectionCount, 96) {
            let base = sectionTable + index * 40
            guard let vsize = data.u32(at: base + 8), let va = data.u32(at: base + 12),
                  let rawSize = data.u32(at: base + 16), let rawPointer = data.u32(at: base + 20) else { break }
            sections.append(Section(virtualAddress: va, virtualSize: vsize, rawPointer: rawPointer, rawSize: rawSize))
        }
        self.sections = sections

        func directory(_ index: Int) -> (rva: UInt32, size: UInt32) {
            guard index < directoryCount else { return (0, 0) }
            return (data.u32(at: directoriesStart + index * 8) ?? 0, data.u32(at: directoriesStart + index * 8 + 4) ?? 0)
        }

        func fileOffset(_ rva: UInt32) -> Int? {
            for section in sections {
                let span = max(section.virtualSize, section.rawSize)
                if rva >= section.virtualAddress, rva < section.virtualAddress &+ span {
                    let delta = rva - section.virtualAddress
                    guard delta < section.rawSize else { return nil }
                    return Int(section.rawPointer) + Int(delta)
                }
            }
            if let first = sections.first, rva < first.rawPointer { return Int(rva) }
            return nil
        }

        // Regular imports.
        var imports: [String] = []
        let importDirectory = directory(1)
        if importDirectory.rva != 0, var offset = fileOffset(importDirectory.rva) {
            for _ in 0..<4096 {
                guard let lookup = data.u32(at: offset), let nameRVA = data.u32(at: offset + 12),
                      let thunk = data.u32(at: offset + 16) else { break }
                if lookup == 0 && nameRVA == 0 && thunk == 0 { break }
                if let nameOffset = fileOffset(nameRVA), let name = data.cString(at: nameOffset, maxLength: 260), !name.isEmpty {
                    imports.append(name.lowercased())
                }
                offset += 20
            }
        }
        self.imports = imports

        // Delay-loaded imports (many engines load Direct3D this way).
        var delayImports: [String] = []
        let delayDirectory = directory(13)
        if delayDirectory.rva != 0, var offset = fileOffset(delayDirectory.rva) {
            for _ in 0..<1024 {
                guard let attributes = data.u32(at: offset), let nameField = data.u32(at: offset + 4) else { break }
                if attributes == 0 && nameField == 0 { break }
                var nameRVA = nameField
                if attributes & 1 == 0, !is64Bit, UInt64(nameField) > imageBase {
                    nameRVA = UInt32(truncatingIfNeeded: UInt64(nameField) - imageBase)
                }
                if let nameOffset = fileOffset(nameRVA), let name = data.cString(at: nameOffset, maxLength: 260), !name.isEmpty {
                    delayImports.append(name.lowercased())
                }
                offset += 32
            }
        }
        self.delayImports = delayImports

        isDotNet = directory(14).rva != 0 && directory(14).size != 0
        let resources = directory(2)
        resourceOffset = resources.rva != 0 ? fileOffset(resources.rva) : nil
    }

    public var isGUI: Bool { subsystem == 2 }
    public var allImports: [String] { imports + delayImports }

    // MARK: - Resources

    private struct ResourceEntry {
        let id: UInt32?
        let name: String?
        let isDirectory: Bool
        let offset: Int
    }

    private func entries(atDirectory directoryOffset: Int) -> [ResourceEntry] {
        guard let base = resourceOffset else { return [] }
        let start = base + directoryOffset
        guard let named = data.u16(at: start + 12), let ids = data.u16(at: start + 14) else { return [] }
        var result: [ResourceEntry] = []
        for index in 0..<min(Int(named) + Int(ids), 4096) {
            let entry = start + 16 + index * 8
            guard let nameField = data.u32(at: entry), let offsetField = data.u32(at: entry + 4) else { break }
            var id: UInt32?
            var name: String?
            if nameField & 0x8000_0000 != 0 {
                let nameOffset = base + Int(nameField & 0x7FFF_FFFF)
                if let length = data.u16(at: nameOffset) {
                    name = data.countedUTF16String(at: nameOffset + 2, characters: Int(length))
                }
            } else {
                id = nameField
            }
            result.append(ResourceEntry(id: id, name: name, isDirectory: offsetField & 0x8000_0000 != 0,
                                        offset: Int(offsetField & 0x7FFF_FFFF)))
        }
        return result
    }

    private func dataEntry(at entryOffset: Int) -> Data? {
        guard let base = resourceOffset, let rva = data.u32(at: base + entryOffset),
              let size = data.u32(at: base + entryOffset + 4), size > 0, size < 64 * 1024 * 1024 else { return nil }
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            if rva >= section.virtualAddress, rva < section.virtualAddress &+ span {
                let offset = Int(section.rawPointer) + Int(rva - section.virtualAddress)
                return data.slice(offset, Int(size))
            }
        }
        return nil
    }

    /// Resources of one type as (id, name, bytes), first language of each.
    private func resources(ofType type: UInt32) -> [(id: UInt32?, name: String?, data: Data)] {
        guard resourceOffset != nil else { return [] }
        guard let typeEntry = entries(atDirectory: 0).first(where: { $0.id == type && $0.isDirectory }) else { return [] }
        var result: [(id: UInt32?, name: String?, data: Data)] = []
        for item in entries(atDirectory: typeEntry.offset) where item.isDirectory {
            guard let language = entries(atDirectory: item.offset).first(where: { !$0.isDirectory }),
                  let bytes = dataEntry(at: language.offset) else { continue }
            result.append((item.id, item.name, bytes))
        }
        return result
    }

    /// The application manifest (`RT_MANIFEST`) as text.
    public func manifest() -> String? {
        guard let bytes = resources(ofType: 24).first?.data else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether the manifest declares the program DPI-aware. Programs that don't are "DPI-unaware": on a Retina
    /// display Wine shows them a screen half the size (1470×956 instead of 2940×1912) and stretches what they
    /// draw, so games look blurry even at "full" resolution. Most Unreal games are like that; Unity declares it.
    public var declaresDPIAwareness: Bool { manifest().map(Self.declaresDPIAwareness(manifest:)) ?? false }

    public static func declaresDPIAwareness(manifest text: String) -> Bool {
        func values(of tag: String) -> [String] {
            // <dpiAware>, <ms_windowsSettings:dpiAware xmlns="…">: the text up to the next tag.
            let pattern = "<(?:[A-Za-z0-9_]+:)?\(tag)(?:\\s[^>]*)?>([^<]*)<"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            }
        }
        // Windows 10 reads <dpiAwareness> first; its first value it knows wins ("PerMonitorV2, PerMonitor").
        for value in values(of: "dpiAwareness") {
            for item in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                switch item {
                case "permonitorv2", "permonitor", "system": return true
                case "unaware", "unaware_gdiscaled": return false
                default: continue
                }
            }
        }
        // Older form: "true", "true/pm", "per monitor".
        return values(of: "dpiAware").contains { $0.hasPrefix("true") || $0.hasPrefix("per monitor") || $0 == "permonitor" }
    }

    /// The main icon group rebuilt as an `.ico` file (readable by ImageIO).
    public func iconFileData() -> Data? {
        let groups = resources(ofType: 14)
        guard let group = groups.first?.data, let count = group.u16(at: 4), count > 0 else { return nil }
        var images: [UInt32: Data] = [:]
        for icon in resources(ofType: 3) { if let id = icon.id { images[id] = icon.data } }

        var entries: [(header: Data, image: Data)] = []
        for index in 0..<Int(min(count, 64)) {
            let base = 6 + index * 14
            guard let width = group.u8(at: base), let height = group.u8(at: base + 1),
                  let colors = group.u8(at: base + 2), let planes = group.u16(at: base + 4),
                  let bits = group.u16(at: base + 6), let resourceID = group.u16(at: base + 12),
                  let image = images[UInt32(resourceID)] else { continue }
            var header = Data()
            header.append(contentsOf: [width, height, colors, 0])
            header.append(contentsOf: withUnsafeBytes(of: planes.littleEndian, Array.init))
            header.append(contentsOf: withUnsafeBytes(of: bits.littleEndian, Array.init))
            header.append(contentsOf: withUnsafeBytes(of: UInt32(image.count).littleEndian, Array.init))
            entries.append((header, image))
        }
        guard !entries.isEmpty else { return nil }

        var ico = Data([0, 0, 1, 0])
        ico.append(contentsOf: withUnsafeBytes(of: UInt16(entries.count).littleEndian, Array.init))
        var offset = UInt32(6 + entries.count * 16)
        for entry in entries {
            ico.append(entry.header)
            ico.append(contentsOf: withUnsafeBytes(of: offset.littleEndian, Array.init))
            offset += UInt32(entry.image.count)
        }
        for entry in entries { ico.append(entry.image) }
        return ico
    }

    /// Version resource strings (ProductName, CompanyName, FileDescription, FileVersion, ProductVersion, …).
    public func versionStrings() -> [String: String] {
        guard let resource = resources(ofType: 16).first?.data else { return [:] }
        var strings: [String: String] = [:]
        var fixed: String?
        Self.parseVersionBlock(resource, start: 0, limit: resource.count, depth: 0, inStrings: false,
                               strings: &strings, fixed: &fixed)
        if strings["FileVersion"] == nil, let fixed { strings["FileVersion"] = fixed }
        return strings
    }

    private static func parseVersionBlock(_ data: Data, start: Int, limit: Int, depth: Int, inStrings: Bool,
                                          strings: inout [String: String], fixed: inout String?) {
        guard depth < 6, let length16 = data.u16(at: start) else { return }
        let length = Int(length16)
        guard length >= 6, start + length <= limit else { return }
        let end = start + length
        let valueLength = Int(data.u16(at: start + 2) ?? 0)
        let type = data.u16(at: start + 4) ?? 0
        guard let (key, afterKey) = data.utf16String(at: start + 6, end: end, maxCharacters: 128) else { return }
        let valueStart = align4(afterKey)

        if depth == 0, key == "VS_VERSION_INFO", valueLength >= 52, data.u32(at: valueStart) == 0xFEEF_04BD,
           let ms = data.u32(at: valueStart + 8), let ls = data.u32(at: valueStart + 12) {
            fixed = "\(ms >> 16).\(ms & 0xFFFF).\(ls >> 16).\(ls & 0xFFFF)"
        }

        if inStrings && depth == 3 {
            if let (value, _) = data.utf16String(at: valueStart, end: end, maxCharacters: 1024) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, strings[key] == nil { strings[key] = trimmed }
            }
            return
        }

        let valueBytes = type == 1 ? valueLength * 2 : valueLength
        var child = align4(valueStart + valueBytes)
        let childrenInStrings = inStrings || key == "StringFileInfo"
        while child + 6 <= end {
            guard let childLength = data.u16(at: child), childLength >= 6 else { break }
            parseVersionBlock(data, start: child, limit: end, depth: depth + 1, inStrings: childrenInStrings,
                              strings: &strings, fixed: &fixed)
            child = align4(child + Int(childLength))
        }
    }
}
