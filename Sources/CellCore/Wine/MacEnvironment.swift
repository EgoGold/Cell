import AppKit
import Foundation
import CoreGraphics
import CoreText
import Carbon

/// Facts about one of the Mac's displays.
public struct DisplayInfo: Sendable, Hashable, Identifiable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Int
    public var pointHeight: Int
    public var scale: Double
    public var refreshRate: Double
    /// Stays the same across restarts and reconnecting (the display's UUID).
    public var id: String
    public var name: String
    /// The display with the menu bar. Windows programs open there first: Wine makes it the primary monitor.
    public var isMain: Bool
    /// Place in Windows' monitor list (Wine lists the main display first, then the others as macOS orders them).
    public var index: Int

    public init(pixelWidth: Int, pixelHeight: Int, pointWidth: Int, pointHeight: Int, scale: Double, refreshRate: Double,
                id: String = "main", name: String = "Display", isMain: Bool = true, index: Int = 0) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.refreshRate = refreshRate
        self.id = id
        self.name = name
        self.isMain = isMain
        self.index = index
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: [DisplayInfo] = []

    /// The main display. Read on the main thread by `prime()` and cached, so background work never
    /// touches window-server APIs.
    public static func main() -> DisplayInfo {
        all().first { $0.isMain } ?? fallback
    }

    /// Every connected display, the main one first.
    public static func all() -> [DisplayInfo] {
        if let displays = cacheLock.withLock({ cached.isEmpty ? nil : cached }) { return displays }
        let displays = read()
        cacheLock.withLock { cached = displays }
        return displays
    }

    /// The chosen display when it's connected, otherwise the main one.
    public static func resolve(_ id: String?) -> DisplayInfo {
        guard let id else { return main() }
        return all().first { $0.id == id } ?? main()
    }

    /// Refreshes the cached display information (call on the main thread, e.g. at launch or when displays change).
    public static func prime() {
        let displays = read()
        cacheLock.withLock { cached = displays }
    }

    static let fallback = DisplayInfo(pixelWidth: 2560, pixelHeight: 1600, pointWidth: 1280, pointHeight: 800, scale: 2, refreshRate: 60)

    private static func read() -> [DisplayInfo] {
        // NSScreen lists the menu-bar display first, like Wine's monitor list.
        var ordered: [(CGDirectDisplayID, String)] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(number.uint32Value), screen.localizedName)
        }
        if ordered.isEmpty { ordered = [(CGMainDisplayID(), "Display")] }
        var result: [DisplayInfo] = []
        for (index, (display, name)) in ordered.enumerated() {
            guard let mode = CGDisplayCopyDisplayMode(display) else { continue }
            let scale = mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 1
            let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue()
            let id = uuid.flatMap { CFUUIDCreateString(nil, $0) as String? } ?? "display-\(display)"
            result.append(DisplayInfo(pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, pointWidth: mode.width,
                                      pointHeight: mode.height, scale: max(scale, 1), refreshRate: mode.refreshRate > 0 ? mode.refreshRate : 60,
                                      id: id, name: name, isMain: index == 0, index: index))
        }
        return result.isEmpty ? [fallback] : result
    }

    /// Windows DPI so that Windows UI is the same physical size as Mac UI in high-resolution mode.
    public var automaticDPI: Int { min(max(Int((96 * scale).rounded()), 96), 288) }

    /// Frame-rate caps that divide the refresh rate evenly (DXMT requires this).
    public var validFrameRateLimits: [Int] {
        let refresh = Int(refreshRate.rounded())
        return [15, 20, 24, 30, 40, 45, 60, 72, 90, 120, 144, 165, 240].filter { $0 <= refresh && refresh % $0 == 0 }
    }

    /// The ID of the display an NSScreen shows (matches `id`).
    public static func id(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// "Studio Display — 5120 × 2880"
    public var summary: String { "\(name) — \(pixelWidth) × \(pixelHeight)" }
}

/// Picks the Windows locale for a container.
public enum LanguageResolver {
    public struct Resolution: Sendable {
        public var language: ContainerLanguage
        public var reason: String
    }

    /// The language programs show (Wine's user locale: `LANG`, `LC_MESSAGES`).
    /// Automatic is English: games and programs show English, the way most are made and tested. Chinese, Japanese
    /// and Korean still display (Cell's fonts) and typing them still works (`textLanguage`). Pick a language in the
    /// layer's settings to have programs show it instead.
    public static func resolve(_ setting: ContainerLanguage) -> Resolution {
        if setting != .automatic { return Resolution(language: setting, reason: "Chosen in container settings.") }
        return Resolution(language: .english, reason: "English unless you choose another language; other scripts still display and can be typed.")
    }

    /// The language Windows' "non-Unicode" code page must cover (Wine's system locale: `LC_CTYPE`).
    ///
    /// Typing Chinese, Japanese or Korean in Steam and games goes through that code page under Wine on
    /// macOS; with an English one every character turns into "?". So whenever such an input method is
    /// enabled on the Mac, the code page covers it — while programs keep showing the display language.
    public static func textLanguage(for setting: ContainerLanguage) -> Resolution {
        let display = resolve(setting).language
        if display.cjkScript != nil { return Resolution(language: display, reason: "Matches the display language.") }
        for source in enabledInputSources() {
            let language = language(forCode: source.language)
            if language.cjkScript != nil {
                return Resolution(language: language,
                                  reason: "The \(source.name) input method is enabled, so typing it in Steam and games works.")
            }
        }
        return Resolution(language: display, reason: "Matches the display language.")
    }

    public static func language(forCode code: String) -> ContainerLanguage {
        let lower = code.lowercased()
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") { return .traditionalChinese }
            return .simplifiedChinese
        }
        let prefixes: [(String, ContainerLanguage)] = [
            ("ja", .japanese), ("ko", .korean), ("ru", .russian), ("de", .german), ("fr", .french), ("es", .spanish),
            ("pt", .portuguese), ("it", .italian), ("pl", .polish), ("tr", .turkish), ("en", .english),
        ]
        return prefixes.first { lower.hasPrefix($0.0) }?.1 ?? .english
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedSources: [(language: String, name: String)]?

    /// Reads the enabled input methods. Text Input Sources must only be used on the main thread
    /// (calling it from a background thread crashes inside HIToolbox), so the app and the CLI call this
    /// at startup and whenever the app becomes active; background code reads the cached copy.
    public static func prime() {
        guard Thread.isMainThread else { return }
        let sources = readInputSources()
        cacheLock.withLock { cachedSources = sources }
    }

    /// Enabled keyboard input sources and their primary language (cached; see `prime()`).
    public static func enabledInputSources() -> [(language: String, name: String)] {
        if let cached = cacheLock.withLock({ cachedSources }) { return cached }
        guard Thread.isMainThread else { return [] }
        prime()
        return cacheLock.withLock { cachedSources } ?? []
    }

    private static func readInputSources() -> [(language: String, name: String)] {
        guard let unmanaged = TISCreateInputSourceList(nil, false) else { return [] }
        let list = unmanaged.takeRetainedValue() as NSArray
        var result: [(String, String)] = []
        for item in list {
            let source = item as! TISInputSource
            guard let categoryPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { continue }
            let category = Unmanaged<CFString>.fromOpaque(categoryPointer).takeUnretainedValue() as String
            guard category == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard let languagesPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { continue }
            let languages = Unmanaged<CFArray>.fromOpaque(languagesPointer).takeUnretainedValue() as? [String] ?? []
            var name = ""
            if let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) {
                name = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
            }
            if let first = languages.first { result.append((first, name)) }
        }
        return result
    }
}

/// Maps Windows CJK fonts to fonts installed on this Mac (FontSubstitutes, Replacements, SystemLink).
public enum FontConfigurator {
    static let windowsFonts: [CJKScript: [String]] = [
        .simplifiedChinese: ["SimSun", "NSimSun", "SimHei", "Microsoft YaHei", "Microsoft YaHei UI", "DengXian", "KaiTi", "FangSong"],
        .traditionalChinese: ["PMingLiU", "MingLiU", "Microsoft JhengHei", "Microsoft JhengHei UI", "DFKai-SB"],
        .japanese: ["MS Gothic", "MS PGothic", "MS UI Gothic", "MS Mincho", "MS PMincho", "Meiryo", "Meiryo UI", "Yu Gothic", "Yu Gothic UI"],
        .korean: ["Gulim", "GulimChe", "Dotum", "DotumChe", "Batang", "BatangChe", "Gungsuh", "Malgun Gothic"],
    ]

    static let macCandidates: [CJKScript: [String]] = [
        .simplifiedChinese: ["PingFang SC", "Hiragino Sans GB", "Heiti SC", "STHeiti", "Songti SC"],
        .traditionalChinese: ["PingFang TC", "PingFang HK", "Heiti TC", "Songti TC"],
        .japanese: ["Hiragino Sans", "Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic Pro", "Osaka"],
        .korean: ["Apple SD Gothic Neo", "AppleGothic", "Nanum Gothic", "NanumGothic"],
    ]

    static let linkedBaseFonts = ["Tahoma", "Segoe UI", "Microsoft Sans Serif", "MS Shell Dlg", "MS Shell Dlg 2",
                                  "Arial", "Lucida Sans Unicode", "Verdana", "Times New Roman", "Courier New"]

    public struct Choice: Hashable, Sendable {
        public var script: CJKScript
        public var family: String
        public var fileName: String?
    }

    /// The best installed Mac font for each script.
    public static func installedChoices() -> [Choice] {
        let families = installedFamilies()
        return CJKScript.allCases.compactMap { script in
            guard let family = macCandidates[script]?.first(where: { families.contains($0) }) else { return nil }
            return Choice(script: script, family: family, fileName: fontFileName(family: family))
        }
    }

    static func fontFileName(family: String) -> String? {
        if let path = fontFilePath(family: family) { return URL(fileURLWithPath: path).lastPathComponent }
        let attributes = [kCTFontFamilyNameAttribute as String: family] as CFDictionary
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil),
              let url = CTFontDescriptorCopyAttribute(matched, kCTFontURLAttribute) as? URL else { return nil }
        return url.lastPathComponent
    }

    public static func registryEdits(primary: CJKScript?, choices: [Choice] = installedChoices()) -> [RegistryEdit] {
        guard !choices.isEmpty else { return [] }
        var edits: [RegistryEdit] = []
        let substitutes = "Software\\Microsoft\\Windows NT\\CurrentVersion\\FontSubstitutes"
        let replacements = "Software\\Wine\\Fonts\\Replacements"
        for choice in choices {
            for windowsFont in windowsFonts[choice.script] ?? [] {
                edits.append(.set(.localMachine, substitutes, windowsFont, .string(choice.family)))
                edits.append(.set(.currentUser, replacements, windowsFont, .string(choice.family)))
            }
        }
        // Fallback chain for common UI fonts: the container's language first.
        let ordered = choices.sorted { lhs, rhs in
            if lhs.script == primary { return true }
            if rhs.script == primary { return false }
            return CJKScript.allCases.firstIndex(of: lhs.script)! < CJKScript.allCases.firstIndex(of: rhs.script)!
        }
        let links = ordered.compactMap { choice in choice.fileName.map { "\($0),\(choice.family)" } }
        if !links.isEmpty {
            let systemLink = "Software\\Microsoft\\Windows NT\\CurrentVersion\\FontLink\\SystemLink"
            for base in linkedBaseFonts {
                edits.append(.set(.localMachine, systemLink, base, .multiString(links)))
            }
        }
        return edits
    }

    // MARK: Text in other scripts drawn by games (DirectWrite fallback)

    /// Wine's DirectWrite falls back to Linux font names when a game's own font lacks a character (Godot and Unity
    /// games ask it for Chinese, Japanese, Korean, Arabic, Hindi… text). A Mac has none of those fonts, so the text
    /// showed as boxes. Each name becomes an alias of the Mac font that covers the script (the first one installed).
    static let scriptFallbacks: [(name: String, mac: [String])] = [
        ("Noto Sans CJK SC", ["PingFang SC", "Hiragino Sans GB", "Heiti SC", "STHeiti", "Arial Unicode MS"]),
        ("Noto Sans CJK TC", ["PingFang TC", "PingFang HK", "Heiti TC", "Arial Unicode MS"]),
        ("Noto Sans CJK KR", ["Apple SD Gothic Neo", "AppleGothic", "Arial Unicode MS"]),
        ("Noto Sans Arabic", ["Geeza Pro", "Noto Nastaliq Urdu", "Arial Unicode MS"]),
        ("Noto Sans Hebrew", ["Arial Hebrew", "Lucida Grande", "Arial Unicode MS"]),
        ("Noto Sans Devanagari", ["Kohinoor Devanagari", "Devanagari Sangam MN", "ITF Devanagari"]),
        ("Noto Sans Bengali", ["Kohinoor Bangla", "Bangla Sangam MN"]),
        ("Noto Sans Gurmukhi", ["Gurmukhi MN", "Gurmukhi Sangam MN"]),
        ("Noto Sans Gujarati", ["Gujarati Sangam MN", "Kohinoor Gujarati"]),
        ("Noto Sans Tamil", ["Tamil Sangam MN", "Tamil MN"]),
        ("Noto Sans Telugu", ["Telugu Sangam MN", "Kohinoor Telugu"]),
        ("Noto Sans Malayalam", ["Malayalam Sangam MN"]),
        ("Noto Sans Sinhala", ["Sinhala Sangam MN"]),
        ("Noto Sans Thai", ["Thonburi", "Ayuthaya", "Arial Unicode MS"]),
        ("Noto Sans Lao", ["Lao Sangam MN"]),
        ("Noto Sans Myanmar", ["Myanmar Sangam MN", "Noto Serif Myanmar"]),
        ("Noto Serif Tibetan", ["Kailasa"]),
        ("Noto Sans Armenian", ["Mshtakan", "Arial Unicode MS"]),
        ("Noto Sans Georgian", ["Arial Unicode MS"]),
    ]

    /// Japanese has no language tag in Wine's table: it is the fallback for all Han characters, so it gets the font
    /// that covers Chinese and Japanese both (PingFang), unless the Mac itself is set to Japanese.
    static func japaneseFallback(primary: CJKScript?) -> [String] {
        primary == .japanese ? ["Hiragino Sans", "PingFang SC", "Arial Unicode MS"] : ["PingFang SC", "Hiragino Sans", "Arial Unicode MS"]
    }

    /// Aliases for Wine's fallback names plus the Mac font files behind them, registered like installed Windows
    /// fonts: engines that don't load the Mac's fonts themselves (PK Wine 11) need them to find any font at all.
    public static func scriptFallbackEdits(primary: CJKScript?,
                                           installed: Set<String> = installedFamilies(),
                                           files: (String) -> String? = fontFilePath(family:)) -> [RegistryEdit] {
        let table = scriptFallbacks + [("Noto Sans CJK JP", japaneseFallback(primary: primary))]
        var edits: [RegistryEdit] = []
        var registered: Set<String> = []
        for (name, candidates) in table {
            let available = candidates.filter(installed.contains)
            guard !available.isEmpty else { continue }
            edits.append(.set(.currentUser, "Software\\Wine\\Fonts\\Replacements", name, .multiString(available)))
            for family in available where !registered.contains(family) {
                registered.insert(family)
                guard let path = files(family) else { continue }
                edits.append(.set(.localMachine, "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", "\(family) (Mac)",
                                  .string("Z:" + path.replacingOccurrences(of: "/", with: "\\"))))
            }
        }
        return edits
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var familiesCache: Set<String>?
    nonisolated(unsafe) private static var pathCache: [String: String?] = [:]

    /// The Mac's font families (looked up once per run: CoreText lookups added time to every launch).
    public static func installedFamilies() -> Set<String> {
        if let cached = cacheLock.withLock({ familiesCache }) { return cached }
        let families = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        cacheLock.withLock { familiesCache = families }
        return families
    }

    /// The file of a font family's regular face (Hiragino ships one file per weight: W3 is the regular one).
    public static func fontFilePath(family: String) -> String? {
        if let cached = cacheLock.withLock({ pathCache[family] }) { return cached }
        let path = lookUpFontFilePath(family: family)
        cacheLock.withLock { pathCache[family] = path }
        return path
    }

    static func lookUpFontFilePath(family: String) -> String? {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: family] as CFDictionary)
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor]) ?? []
        let paths = Set(matches.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontURLAttribute) as? URL }.map(\.path)).sorted()
        return paths.first { $0.contains("W3") || $0.localizedCaseInsensitiveContains("regular") } ?? paths.first
    }
}

/// The Mac's fonts for scripts Wine's own fonts don't have, inside the layer's `C:\windows\Fonts`, as links.
///
/// Wine leaves that folder empty, and Unity (and other engines) look there for a font that has the characters their
/// own font lacks: Beholder's menu was blank in Chinese, Volcano Princess had no Korean. Only fonts that add such a
/// script (Chinese, Japanese, Korean, Thai, Indic, …) are linked. Linking every Mac font (433 files, round 10) also put
/// the Mac's Arial, Tahoma and Symbol in place of Wine's: Steam's own text measuring failed ("Couldn't get string
/// length") and its window never appeared. Links Cell made earlier that aren't wanted any more are removed; Windows'
/// own and the user's fonts there are never touched.
public enum WindowsFontsFolder {
    static var macFontFolders: [URL] {
        ["/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").path].map { URL(fileURLWithPath: $0) }
    }

    static let fontExtensions: Set<String> = ["ttf", "ttc", "otf", "otc"]

    /// One character of each script Wine's fonts lack: Han, kana, Hangul, Thai, Lao, Khmer, Myanmar, Tibetan,
    /// Devanagari, Bengali, Tamil, Telugu, Sinhala, Ethiopic.
    static let missingScripts: [UTF32Char] = [0x4E00, 0x3042, 0xAC00, 0x0E01, 0x0E81, 0x1780, 0x1000, 0x0F40,
                                              0x0915, 0x0995, 0x0B95, 0x0C15, 0x0D9A, 0x1200]

    /// Families Wine or Windows itself has. The Mac's fonts of these names (Tahoma and Microsoft Sans Serif include
    /// Thai) would take the place of Wine's, which programs such as Steam measure their text with.
    static let windowsFamilies: Set<String> = ["tahoma", "microsoft sans serif", "ms sans serif", "arial", "times new roman",
                                               "courier new", "symbol", "wingdings", "webdings", "marlett", "verdana",
                                               "georgia", "trebuchet ms", "comic sans ms", "impact", "lucida console",
                                               "segoe ui", "calibri", "cambria", "consolas"]

    /// Whether a font file adds one of those scripts. Placeholder and picture fonts, and fonts of a family Windows
    /// has, never count.
    static func addsMissingScript(_ file: URL) -> Bool {
        let name = file.lastPathComponent.lowercased()
        guard !name.contains("lastresort"), !name.contains("emoji") else { return false }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] else { return false }
        let families = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        guard !families.contains(where: { windowsFamilies.contains($0.lowercased()) }) else { return false }
        for descriptor in descriptors {
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            let characters = CTFontCopyCharacterSet(font)
            if missingScripts.contains(where: { CFCharacterSetIsLongCharacterMember(characters, $0) }) { return true }
        }
        return false
    }

    /// The Mac's font files to link (worked out once per run of Cell).
    static let wantedFiles: [URL] = {
        let fm = FileManager.default
        var files: [URL] = macFontFolders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        // Fonts macOS downloads on demand (Chinese, Japanese and Korean ones among them) that Cell uses as fallbacks.
        files += FontConfigurator.installedFamilies().compactMap { FontConfigurator.fontFilePath(family: $0) }.filter { $0.contains("/AssetsV2/") }
            .map { URL(fileURLWithPath: $0) }
        var seen: Set<String> = []
        return files.filter { file in
            fontExtensions.contains(file.pathExtension.lowercased()) && seen.insert(file.lastPathComponent.lowercased()).inserted
                && addsMissingScript(file)
        }
    }()

    /// Whether a link in the folder is one Cell made (it points into one of the Mac's font folders).
    static func isCellLink(_ destination: String) -> Bool {
        destination.hasPrefix("/System/Library/") || destination.hasPrefix("/Library/Fonts/")
            || destination.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts").path)
    }

    /// Adds the wanted links and removes Cell's links that aren't wanted. Returns how many were added.
    @discardableResult
    public static func link(into container: Container) -> Int {
        link(windowsFolder: container.driveC.appendingPathComponent("windows", isDirectory: true))
    }

    @discardableResult
    static func link(windowsFolder: URL) -> Int {
        let fm = FileManager.default
        let folder = windowsFolder.appendingPathComponent("Fonts", isDirectory: true)
        guard fm.fileExists(atPath: windowsFolder.path) else { return 0 }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = Dictionary(wantedFiles.map { ($0.lastPathComponent.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var present: Set<String> = []
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let item = folder.appendingPathComponent(name)
            if let destination = try? fm.destinationOfSymbolicLink(atPath: item.path), isCellLink(destination),
               wanted[name.lowercased()]?.path != destination {
                try? fm.removeItem(at: item)        // removes the link only
                continue
            }
            present.insert(name.lowercased())
        }
        var added = 0
        for (name, file) in wanted where !present.contains(name) {
            if (try? fm.createSymbolicLink(at: folder.appendingPathComponent(file.lastPathComponent), withDestinationURL: file)) != nil { added += 1 }
        }
        return added
    }
}
