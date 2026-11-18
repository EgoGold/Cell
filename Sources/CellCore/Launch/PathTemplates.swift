import Foundation

/// Expands plugin path templates such as `{localAppData}/{unrealProject}/Saved/Config/Windows/GameUserSettings.ini`.
public struct PathTemplateContext {
    public var container: Container
    public var app: AppEntry?
    public var gameDirectory: URL?
    public var executableDirectory: URL?
    public var pluginDirectory: URL?

    public init(container: Container, app: AppEntry?, pluginDirectory: URL? = nil) {
        self.container = container
        self.app = app
        self.pluginDirectory = pluginDirectory
        let mapper = WinePathMapper(prefix: container.prefixURL)
        if let app, let url = AppAnalyzer.executable(for: app, in: container) {
            executableDirectory = url.deletingLastPathComponent()
            gameDirectory = AppAnalyzer.gameRootDirectory(for: url)
        } else if let path = app?.windowsPath, let url = mapper.unixURL(forWindowsPath: path) {
            executableDirectory = url.deletingLastPathComponent()
            gameDirectory = executableDirectory
        }
    }

    /// Locations a template may write to: the prefix and the game's folder.
    public var writableRoots: [URL] { [container.prefixURL] + (gameDirectory.map { [$0] } ?? []) }

    public func values() -> [String: String] {
        var values: [String: String] = [
            "prefix": container.prefixURL.path,
            "driveC": container.driveC.path,
        ]
        let mapper = WinePathMapper(prefix: container.prefixURL)
        if let profile = mapper.userProfile {
            values["userProfile"] = profile.path
            values["appData"] = profile.appendingPathComponent("AppData/Roaming").path
            values["localAppData"] = profile.appendingPathComponent("AppData/Local").path
            values["localLow"] = profile.appendingPathComponent("AppData/LocalLow").path
            values["documents"] = profile.appendingPathComponent("Documents").path
            values["savedGames"] = profile.appendingPathComponent("Saved Games").path
        }
        if let gameDirectory { values["gameDir"] = gameDirectory.path }
        if let executableDirectory { values["exeDir"] = executableDirectory.path }
        if let pluginDirectory { values["pluginDir"] = pluginDirectory.path }
        if let steam = SteamIntegration.steamDirectory(in: container) { values["steamDir"] = steam.path }
        if let analysis = app?.analysis {
            if let project = analysis.unrealProject { values["unrealProject"] = project }
            if let company = analysis.unityCompany { values["unityCompany"] = company }
            if let product = analysis.unityProduct { values["unityProduct"] = product }
            if let localLow = values["localLow"], let company = analysis.unityCompany, let product = analysis.unityProduct {
                values["unityPlayerLog"] = "\(localLow)/\(company)/\(product)/Player.log"
            }
        }
        if let display = Optional(DisplayInfo.main()) {
            values["screenWidth"] = String(display.pixelWidth)
            values["screenHeight"] = String(display.pixelHeight)
        }
        return values
    }

    /// Expands `{token}` placeholders; returns nil when a token is unknown.
    public func expand(_ template: String) -> String? {
        let values = values()
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "{", let close = template[index...].firstIndex(of: "}") {
                let token = String(template[template.index(after: index)..<close])
                guard let value = values[token] else { return nil }
                result += value
                index = template.index(after: close)
            } else {
                result.append(character)
                index = template.index(after: index)
            }
        }
        return result
    }

    /// Expands a path template and checks that it stays within the prefix or the game folder.
    public func resolveWritablePath(_ template: String) -> URL? {
        guard let expanded = expand(template) else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        guard writableRoots.contains(where: { FileOps.isContained(url, in: $0) }) else { return nil }
        return url
    }
}

/// Minimal INI editor that keeps everything it does not touch (handles UTF-8 and UTF-16 files).
public enum IniEditor {
    public static func apply(_ values: [String: String], section: String, to url: URL, create: Bool) throws -> Bool {
        let fm = FileManager.default
        var encoding: String.Encoding = .utf8
        var text = ""
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
                encoding = .utf16
                text = String(data: data, encoding: .utf16) ?? ""
            } else {
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
        } else if !create {
            return false
        }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: newline)
        var remaining = values
        var sectionStart: Int?
        var sectionEnd = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                if sectionStart != nil { sectionEnd = index; break }
                if trimmed.dropFirst().dropLast().caseInsensitiveCompare(section) == .orderedSame { sectionStart = index }
            }
        }
        if let start = sectionStart {
            for index in (start + 1)..<sectionEnd {
                let line = lines[index]
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces)
                if let match = remaining.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                    lines[index] = "\(key)=\(remaining[match]!)"
                    remaining.removeValue(forKey: match)
                }
            }
            let additions = remaining.keys.sorted().map { "\($0)=\(remaining[$0]!)" }
            var insertAt = sectionEnd
            while insertAt > start + 1, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert(contentsOf: additions, at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines.append("[\(section)]")
            lines += values.keys.sorted().map { "\($0)=\(values[$0]!)" }
            lines.append("")
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let output = lines.joined(separator: newline)
        guard let data = output.data(using: encoding) else { return false }
        try data.write(to: url, options: .atomic)
        return true
    }
}
