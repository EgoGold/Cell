import Foundation

public struct SteamGame: Identifiable, Hashable, Sendable {
    public var id: String { appID }
    public var appID: String
    public var name: String
    public var installDirectory: URL
    public var libraryRoot: URL
    public var sizeOnDisk: Int64?
    public var isFullyInstalled: Bool
}

public struct SteamArtwork: Hashable, Sendable {
    public var portrait: URL?
    public var header: URL?
    public var hero: URL?
    public var logo: URL?
    public var icon: URL?
    public var best: URL? { portrait ?? header ?? hero }
}

/// Steam client inside a Windows container.
public enum SteamIntegration {
    /// Redistributables, runtimes and tools that are not games.
    public static let ignoredAppIDs: Set<String> = ["228980", "1070560", "1391110", "1628350", "1493710", "2180100", "250820"]

    public static func steamDirectory(in container: Container) -> URL? {
        for relative in ["Program Files (x86)/Steam", "Program Files/Steam"] {
            let dir = container.driveC.appendingPathComponent(relative, isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("steam.exe").path) { return dir }
        }
        return nil
    }

    public static func steamWindowsPath(in container: Container) -> String? {
        guard let dir = steamDirectory(in: container) else { return nil }
        return WinePathMapper(prefix: container.prefixURL).windowsPath(for: dir.appendingPathComponent("steam.exe"))
    }

    public static func isInstalled(in container: Container) -> Bool { steamDirectory(in: container) != nil }

    /// Arguments for starting the Steam client under Wine on macOS.
    public static func clientArguments(settings: ContainerSettings, fixes: ResolvedFixes? = nil, silent: Bool) -> [String] {
        var arguments: [String] = []
        if silent { arguments.append("-silent") }
        if settings.steamStabilityMode {
            // Steam's web UI is drawn in-process through Cell's steamwebhelper launcher (SteamWebHelperWrapper);
            // Steam's own -cef-disable-gpu-compositing makes the window black, so it is not used. -noverifyfiles
            // keeps Steam from putting Valve's steamwebhelper.exe back at startup; the Chromium sandbox doesn't work in Wine.
            arguments += ["-no-cef-sandbox", "-noverifyfiles"]
        }
        for argument in (fixes?.steamClientArguments ?? []) + settings.steamExtraArguments where !arguments.contains(argument) {
            arguments.append(argument)
        }
        return arguments
    }

    public static func libraryFolders(steamDirectory: URL, mapper: WinePathMapper) -> [URL] {
        var folders = [steamDirectory]
        let vdf = steamDirectory.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let root = VDFNode.parse(contentsOf: vdf) {
            let container = root["libraryfolders"] ?? root
            for (_, value) in container.children {
                guard let path = value["path"]?.string ?? value.string,
                      let url = mapper.unixURL(forWindowsPath: path.replacingOccurrences(of: "\\\\", with: "\\")) else { continue }
                if !folders.contains(where: { $0.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() }) {
                    folders.append(url)
                }
            }
        }
        return folders
    }

    public static func installedGames(in container: Container, includingPartial: Bool = false) -> [SteamGame] {
        guard let steam = steamDirectory(in: container) else { return [] }
        let mapper = WinePathMapper(prefix: container.prefixURL)
        var games: [SteamGame] = []
        for library in libraryFolders(steamDirectory: steam, mapper: mapper) {
            let steamapps = library.appendingPathComponent("steamapps")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let root = VDFNode.parse(contentsOf: steamapps.appendingPathComponent(file)),
                      let state = root["AppState"] ?? root.children.first?.value,
                      let appID = state["appid"]?.string, let name = state["name"]?.string,
                      let installDir = state["installdir"]?.string else { continue }
                if ignoredAppIDs.contains(appID) || name.hasPrefix("Proton") || name.hasPrefix("Steam Linux Runtime")
                    || name.hasPrefix("Steamworks Common") { continue }
                let flags = Int(state["StateFlags"]?.string ?? "") ?? 0
                games.append(SteamGame(appID: appID, name: name,
                                       installDirectory: steamapps.appendingPathComponent("common").appendingPathComponent(installDir),
                                       libraryRoot: library, sizeOnDisk: Int64(state["SizeOnDisk"]?.string ?? ""),
                                       isFullyInstalled: flags & 4 != 0))
            }
        }
        return games.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func artwork(appID: String, in container: Container) -> SteamArtwork {
        guard let steam = steamDirectory(in: container) else { return SteamArtwork() }
        return artwork(appID: appID, steamDirectory: steam)
    }

    /// Finds artwork in both cache layouts: `librarycache/<appid>_header.jpg` (old) and
    /// `librarycache/<appid>/<hash>/library_600x900.jpg` (Steam 2024+).
    public static func artwork(appID: String, steamDirectory steam: URL) -> SteamArtwork {
        let fm = FileManager.default
        let cache = steam.appendingPathComponent("appcache/librarycache")
        let folder = cache.appendingPathComponent(appID, isDirectory: true)
        var files: [String: URL] = [:]
        var icon: URL?
        for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            if FileOps.isDirectory(item) {
                for file in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    files[file.lastPathComponent.lowercased()] = file
                }
            } else if item.pathExtension.lowercased() == "jpg", item.deletingPathExtension().lastPathComponent.count == 40 {
                icon = item
            } else {
                files[item.lastPathComponent.lowercased()] = item
            }
        }
        func pick(_ names: [String], legacy: [String]) -> URL? {
            names.compactMap { files[$0] }.first
                ?? legacy.map { cache.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        }
        return SteamArtwork(
            portrait: pick(["library_600x900_2x.jpg", "library_600x900.jpg"], legacy: ["\(appID)_library_600x900_2x.jpg", "\(appID)_library_600x900.jpg"]),
            header: pick(["library_header_2x.jpg", "library_header.jpg", "header.jpg"], legacy: ["\(appID)_header.jpg"]),
            hero: pick(["library_hero.jpg"], legacy: ["\(appID)_library_hero.jpg"]),
            logo: pick(["logo.png"], legacy: ["\(appID)_logo.png"]),
            icon: icon ?? pick([], legacy: ["\(appID)_icon.jpg"]))
    }

    /// Picks the game's main executable inside its install folder.
    /// Whether a game folder carries Steam's API (steam_api.dll / steam_api64.dll, a few folders deep).
    public static func usesSteamworks(_ directory: URL) -> Bool {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(directory, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let (folder, depth) = queue.removeFirst()
            visited += 1
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let name = item.lastPathComponent.lowercased()
                if name == "steam_api.dll" || name == "steam_api64.dll" { return true }
                if depth < 4, FileOps.isDirectory(item) { queue.append((item, depth + 1)) }
            }
        }
        return false
    }

    public static func mainExecutable(in directory: URL, gameName: String) -> URL? {
        let fm = FileManager.default
        let skip = ["unitycrashhandler", "crashreport", "crashpad", "unins", "setup", "redist", "vcredist", "dxsetup",
                    "easyanticheat", "beservice", "battleye", "prereq", "dotnet", "cefprocess", "qtwebengine", "steamerrorreporter",
                    "installer", "uninstall", "update", "helper", "reporter", "unrealcefsubprocess", "epicwebhelper", "crs-"]
        let normalizedName = gameName.lowercased().filter { $0.isLetter || $0.isNumber }
        var best: (url: URL, score: Double)?
        var queue: [(URL, Int)] = [(directory, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                let name = item.lastPathComponent.lowercased()
                if FileOps.isDirectory(item) {
                    if depth < 4, !["_commonredist", "commonredist", "redist", "directx", "support", "__installer", "engine", "jre", "mono", "monobleedingedge"].contains(name) {
                        queue.append((item, depth + 1))
                    }
                    continue
                }
                guard name.hasSuffix(".exe"), !skip.contains(where: { name.contains($0) }) else { continue }
                let base = item.deletingPathExtension().lastPathComponent.lowercased()
                let normalizedBase = base.filter { $0.isLetter || $0.isNumber }
                var score = 0.0
                if !normalizedName.isEmpty && (normalizedBase == normalizedName || normalizedName.hasPrefix(normalizedBase) || normalizedBase.hasPrefix(normalizedName)) { score += 50 }
                if dir.standardizedFileURL == directory.standardizedFileURL { score += 30 }
                if fm.fileExists(atPath: dir.appendingPathComponent("UnityPlayer.dll").path) { score += 25 }
                if FileOps.isDirectory(dir.appendingPathComponent("\(item.deletingPathExtension().lastPathComponent)_Data")) { score += 25 }
                if name.contains("-shipping") { score += 20 }
                if name.contains("launcher") { score -= 35 }
                if name.contains("server") || name.contains("editor") || name.contains("benchmark") || name.contains("config") { score -= 25 }
                let size = Double((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                score += log2(max(size, 1)) / 2
                score -= Double(depth) * 5
                if best == nil || score > best!.score { best = (item, score) }
            }
        }
        return best?.url
    }
}
