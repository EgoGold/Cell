import Foundation

/// Makes games use the display's full resolution instead of a blurry lower one.
///
/// Many games remember the resolution they first started with. Started once without Retina mode (or in
/// another wrapper) they keep using the display's size in points — 1470×956 on a 2940×1912 screen — and
/// Unreal games often also lower their "3D resolution" to 70–90%. Exclusive fullscreen switches the Mac's
/// display mode as well, which locks Mission Control and Cmd-Tab.
///
/// Before a game starts (and before Steam starts, since games are started from its window too) Cell
/// sets Unreal and Unity games to the display's full resolution, borderless fullscreen and 100% 3D
/// resolution. Only resolution and fullscreen mode are changed — quality settings (shadows, textures,
/// effects…) stay as the player set them. Windowed games are left alone.
public enum GameDisplayFixer {
    public struct Size: Hashable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    /// The resolution games should use: the display's pixels with Retina mode, its points without.
    public static func targetSize(highResolution: Bool, display: DisplayInfo = .main()) -> Size? {
        let size = highResolution ? Size(width: display.pixelWidth, height: display.pixelHeight)
                                  : Size(width: display.pointWidth, height: display.pointHeight)
        return size.width >= 640 && size.height >= 480 ? size : nil
    }

    // MARK: Unreal Engine

    /// `GameUserSettings.ini` of every Unreal game in the container
    /// (`%LOCALAPPDATA%\<Project>\Saved\Config\Windows*\GameUserSettings.ini`), keyed by project name.
    public static func unrealSettingsFiles(in container: Container) -> [(project: String, file: URL)] {
        let fm = FileManager.default
        let users = container.driveC.appendingPathComponent("users", isDirectory: true)
        var result: [(String, URL)] = []
        // Some games keep their settings in their own folder (`<game>/<Project>/Saved/Config/…`: Little Nightmares).
        func addPlatforms(of project: URL) {
            let config = project.appendingPathComponent("Saved/Config", isDirectory: true)
            guard let platforms = try? fm.contentsOfDirectory(at: config, includingPropertiesForKeys: nil) else { return }
            for platform in platforms where platform.lastPathComponent.hasPrefix("Windows") || platform.lastPathComponent.hasPrefix("WinGDK") {
                let file = platform.appendingPathComponent("GameUserSettings.ini")
                if fm.fileExists(atPath: file.path) { result.append((project.lastPathComponent, file)) }
            }
        }
        var gameRoots = [container.driveC.appendingPathComponent("Games", isDirectory: true)]
        if let steam = SteamIntegration.steamDirectory(in: container) {
            gameRoots += SteamIntegration.libraryFolders(steamDirectory: steam, mapper: WinePathMapper(prefix: container.prefixURL))
                .map { $0.appendingPathComponent("steamapps/common") }
        }
        for root in gameRoots {
            for game in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                for project in (try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: nil)) ?? []
                    where fm.fileExists(atPath: project.appendingPathComponent("Saved/Config").path) {
                    addPlatforms(of: project)
                }
            }
        }
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let local = user.appendingPathComponent("AppData/Local", isDirectory: true)
            for project in (try? fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil)) ?? [] {
                let config = project.appendingPathComponent("Saved/Config", isDirectory: true)
                guard let platforms = try? fm.contentsOfDirectory(at: config, includingPropertiesForKeys: nil) else { continue }
                for platform in platforms where platform.lastPathComponent.hasPrefix("Windows") || platform.lastPathComponent.hasPrefix("WinGDK") {
                    let file = platform.appendingPathComponent("GameUserSettings.ini")
                    if fm.fileExists(atPath: file.path) { result.append((project.lastPathComponent, file)) }
                }
            }
        }
        return result
    }

    /// The Unreal project an app belongs to: the folder above `Binaries` (`EscapeTheBackrooms\Binaries\Win64\…`).
    public static func unrealProject(of app: AppEntry) -> String? {
        let path = app.analysis?.analyzedExecutable ?? app.windowsPath ?? ""
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let binaries = parts.lastIndex(where: { $0.caseInsensitiveCompare("Binaries") == .orderedSame }), binaries > 0 else { return nil }
        return parts[binaries - 1]
    }

    /// Returns the fixed settings text, or nil when nothing needs to change.
    static func fixUnreal(_ text: String, size: Size) -> String? {
        var lines = text.components(separatedBy: "\n")
        var section = ""
        var values: [String: (index: Int, value: String)] = [:]
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.hasPrefix("[") { section = line; continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            // Games may keep these in a subclass of Unreal's settings (Little Nightmares: TarGameUserSettings).
            if section.hasSuffix("GameUserSettings]") {
                values["[/Script/Engine.GameUserSettings]\(key)"] = (index, value)
            } else if section == "[ScalabilityGroups]" {
                values["\(section)\(key)"] = (index, value)
            }
        }
        var changed = false
        func set(_ section: String, _ key: String, _ value: String) {
            guard let entry = values["\(section)\(key)"], entry.value != value else { return }
            let suffix = lines[entry.index].hasSuffix("\r") ? "\r" : ""
            lines[entry.index] = "\(key)=\(value)\(suffix)"
            changed = true
        }
        let settings = "[/Script/Engine.GameUserSettings]"
        // 0 = exclusive fullscreen, 1 = borderless fullscreen, 2 = windowed.
        let mode = values["\(settings)FullscreenMode"].flatMap { Int($0.value) }
        guard mode != 2 else { return nil }
        for key in ["FullscreenMode", "LastConfirmedFullscreenMode", "PreferredFullscreenMode"] {
            if values["\(settings)\(key)"]?.value == "0" { set(settings, key, "1") }
        }
        // The "desired" size is a fallback Unreal uses when a display mode is reset; keep it on the same pixels.
        for (key, value) in [("ResolutionSizeX", size.width), ("ResolutionSizeY", size.height),
                             ("LastUserConfirmedResolutionSizeX", size.width), ("LastUserConfirmedResolutionSizeY", size.height),
                             ("DesiredScreenWidth", size.width), ("DesiredScreenHeight", size.height),
                             ("LastUserConfirmedDesiredScreenWidth", size.width), ("LastUserConfirmedDesiredScreenHeight", size.height)] {
            set(settings, key, String(value))
        }
        let groups = "[ScalabilityGroups]"
        if let quality = values["\(groups)sg.ResolutionQuality"].flatMap({ Double($0.value) }) {
            if quality < 100 { set(groups, "sg.ResolutionQuality", "100.000000") }
        } else if values["\(settings)ResolutionSizeX"] != nil {
            // Never saved: the 3D resolution then comes from the game's defaults or a quality preset, often below
            // 100%. Write 100% next to the saved quality groups (or in a new group).
            let crlf = lines.contains { $0.hasSuffix("\r") } ? "\r" : ""
            if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == groups }) {
                var end = header + 1
                while end < lines.count, !lines[end].hasPrefix("["), !lines[end].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { end += 1 }
                lines.insert("sg.ResolutionQuality=100.000000\(crlf)", at: end)
            } else {
                while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
                lines += ["\(crlf)", "\(groups)\(crlf)", "sg.ResolutionQuality=100.000000\(crlf)", ""]
            }
            changed = true
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Fixes every Unreal game's settings except the projects in `skipping`. Returns the files changed.
    @discardableResult
    public static func applyUnreal(container: Container, size: Size, skipping: Set<String> = [], only: String? = nil) -> [URL] {
        var changed: [URL] = []
        for (project, file) in unrealSettingsFiles(in: container) where !skipping.contains(project.lowercased()) {
            if let only, project.lowercased() != only.lowercased() { continue }
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard let fixed = fixUnreal(text, size: size) else { continue }
            if (try? Data(fixed.utf8).write(to: file, options: .atomic)) != nil { changed.append(file) }
        }
        return changed
    }

    // MARK: Unreal graphics API

    static let rhiSection = "/Script/WindowsTargetPlatform.WindowsTargetSettings"
    static let forcedMarker = ".chamber-direct3d11"

    /// The config folders (`…\Saved\Config\<platform>`) of every Unreal game in the container, including games
    /// in the library that haven't run yet (their folder is created; UE4 reads `WindowsNoEditor`, UE5 `Windows`).
    static func unrealConfigFolders(in container: Container, projects: [String]) -> [(project: String, folder: URL)] {
        var result = unrealSettingsFiles(in: container).map { ($0.project, $0.file.deletingLastPathComponent()) }
        let users = container.driveC.appendingPathComponent("users", isDirectory: true)
        let profiles = ((try? FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileOps.isDirectory($0.appendingPathComponent("AppData/Local")) && $0.lastPathComponent != "Public" }
        for project in projects where !result.contains(where: { $0.0.caseInsensitiveCompare(project) == .orderedSame }) {
            for profile in profiles {
                for platform in ["WindowsNoEditor", "Windows"] {
                    result.append((project, profile.appendingPathComponent("AppData/Local/\(project)/Saved/Config/\(platform)", isDirectory: true)))
                }
            }
        }
        return result
    }

    /// A game's explicit renderer takes precedence over a compatibility recommendation. D3DMetal supports both
    /// APIs; the other backends need Direct3D 11. Persisting the result also covers launches from Steam's library.
    static func prefersUnrealDirect3D11(backend: GraphicsBackend, arguments: [String], preference: String?) -> Bool {
        guard backend == .d3dmetal else { return true }
        for argument in arguments.reversed() {
            switch argument.lowercased() {
            case "-dx11", "-d3d11": return true
            case "-dx12", "-d3d12": return false
            default: continue
            }
        }
        return preference?.lowercased() == "dx11"
    }

    /// Unreal games start with Direct3D 12 when their project says so. DXMT — the fastest engine for them — only
    /// has Direct3D 11, and the game then stops with "your system doesn't support DX12" in a message box. Cell
    /// passes `-dx11` when it starts a game, but not when you start it from Steam's window, so the choice goes
    /// into the game's own config (`Engine.ini`, plus UE5's `[D3DRHIPreference]` in GameUserSettings.ini).
    /// `force: false` removes only what Cell added. Returns the folders changed.
    @discardableResult
    public static func setUnrealDirect3D11(_ force: Bool, container: Container, projects: [String] = [],
                                           skipping: Set<String> = [], only: String? = nil) -> [URL] {
        let fm = FileManager.default
        var changed: [URL] = []
        for (project, folder) in unrealConfigFolders(in: container, projects: projects) where !skipping.contains(project.lowercased()) {
            if let only, project.caseInsensitiveCompare(only) != .orderedSame { continue }
            let engine = folder.appendingPathComponent("Engine.ini")
            let settings = folder.appendingPathComponent("GameUserSettings.ini")
            let marker = folder.appendingPathComponent(forcedMarker)
            if force {
                let already = (try? String(contentsOf: engine, encoding: .utf8))?.contains("DefaultGraphicsRHI=DefaultGraphicsRHI_DX11") ?? false
                // An existing user preference is not ours to remove when a recommendation is disabled later.
                if already { continue }
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                guard (try? IniEditor.apply(["DefaultGraphicsRHI": "DefaultGraphicsRHI_DX11"], section: rhiSection, to: engine, create: true)) != nil else { continue }
                _ = try? IniEditor.apply(["PreferredRHI": "dx11"], section: "D3DRHIPreference", to: settings, create: false)
                fm.createFile(atPath: marker.path, contents: Data("Cell selected Direct3D 11 for this game.\n".utf8))
                changed.append(folder)
            } else if fm.fileExists(atPath: marker.path) {
                removeLine("DefaultGraphicsRHI=DefaultGraphicsRHI_DX11", from: engine)
                removeLine("PreferredRHI=dx11", from: settings)
                try? fm.removeItem(at: marker)
                changed.append(folder)
            }
        }
        return changed
    }

    /// Unreal checks the graphics driver's version and warns about "known issues": D3DMetal presents itself as an
    /// AMD driver with a version Unreal's list flags, so Poppy Playtime asked at every start whether to visit AMD's site.
    /// The warning is switched off for every Unreal game (`r.WarnOfBadDrivers=0` in its Engine.ini).
    @discardableResult
    public static func silenceDriverWarning(container: Container, projects: [String]) -> [URL] {
        var changed: [URL] = []
        for (_, folder) in unrealConfigFolders(in: container, projects: projects) {
            let engine = folder.appendingPathComponent("Engine.ini")
            if (try? String(contentsOf: engine, encoding: .utf8))?.contains("r.WarnOfBadDrivers=0") == true { continue }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? IniEditor.apply(["r.WarnOfBadDrivers": "0"], section: "SystemSettings", to: engine, create: true)) != nil {
                changed.append(folder)
            }
        }
        return changed
    }

    static func removeLine(_ line: String, from file: URL) {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains(line) else { return }
        let kept = text.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r ")) != line }
        try? Data(kept.joined(separator: "\n").utf8).write(to: file, options: .atomic)
    }

    // MARK: Unity

    /// Unity's PlayerPrefs names carry a hash of the name: `Screenmanager Resolution Width_h182942802`.
    static func unityHash(_ name: String) -> UInt32 {
        var hash: UInt32 = 5381
        for byte in name.utf8 { hash = (hash &* 33) ^ UInt32(byte) }
        return hash
    }

    static func unityValueName(_ name: String) -> String { "\(name)_h\(unityHash(name))" }

    /// Company and product name of a Unity game (`<Game>_Data/app.info`), which name its registry key.
    public static func unityIdentity(executable: URL) -> (company: String, product: String)? {
        let dataFolder = executable.deletingPathExtension().path + "_Data"
        guard let text = try? String(contentsOfFile: dataFolder + "/app.info", encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
        return (lines[0], lines[1])
    }

    /// The game's registry key as it really is. `app.info` keeps a file-safe product name ("Draw_Guess") while Unity
    /// names the key after the real one ("Draw&Guess"): the key whose name matches once both are made file-safe.
    public static func unityKey(company: String, product: String, in hive: WineRegistryHive?) -> (company: String, product: String) {
        guard let hive, hive.values(at: "Software\\\(company)\\\(product)") == nil else { return (company, product) }
        func safe(_ text: String) -> String { String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
        for path in hive.keyOrder {
            let parts = path.split(separator: "\\").map(String.init)
            guard parts.count == 3, parts[0].caseInsensitiveCompare("Software") == .orderedSame,
                  safe(parts[1]) == safe(company), safe(parts[2]) == safe(product) else { continue }
            return (parts[1], parts[2])
        }
        return (company, product)
    }

    /// Registry edits that put a Unity game at full resolution, read against the values it saved
    /// (`HKCU\Software\<Company>\<Product>`). Empty when nothing needs to change.
    /// Experimental: which monitor a Unity game starts on (Unity's own "Display" choice, 0 = the main display).
    public static func unityMonitorEdit(company: String, product: String, index: Int) -> RegistryEdit {
        .set(.currentUser, "Software\\\(company)\\\(product)", unityValueName("UnitySelectMonitor"), .dword(UInt32(max(index, 0))))
    }

    /// `choiceBroken`: the game failed to apply its own resolution choice (see LearnedCompat.needsDisplayModes). Its own
    /// "Resolution"/"FullScreen" values are removed and Unity's borderless fullscreen at full resolution is set instead.
    public static func unityEdits(company: String, product: String, saved hive: WineRegistryHive?, size: Size,
                                  choiceBroken: Bool = false, preferBorderlessFullscreen: Bool = true) -> [RegistryEdit] {
        let key = "Software\\\(company)\\\(product)"
        let width = unityValueName("Screenmanager Resolution Width")
        let height = unityValueName("Screenmanager Resolution Height")
        let mode = unityValueName("Screenmanager Fullscreen mode")
        func saved(_ name: String) -> UInt32? {
            // DWORDs read back as "0x00000b7c (2940)".
            guard let raw = hive?.value(key, name), raw.hasPrefix("0x") else { return nil }
            return UInt32(raw.dropFirst(2).prefix { $0.isHexDigit }, radix: 16)
        }
        // Unity can persist a minimized/degenerate client rectangle (e.g. 2×2).
        // Repair both current and restore dimensions without changing a valid window mode.
        if !choiceBroken, let w = saved(width), let h = saved(height), w < 64 || h < 64 {
            let safeWidth = UInt32(min(size.width, 1280))
            let safeHeight = UInt32(min(size.height, 720))
            return [(width, safeWidth), (height, safeHeight),
                    (unityValueName("Screenmanager Resolution Window Width"), safeWidth),
                    (unityValueName("Screenmanager Resolution Window Height"), safeHeight)].map {
                .set(.currentUser, key, $0.0, .dword($0.1))
            }
        }
        guard preferBorderlessFullscreen else { return [] }
        if choiceBroken {
            // The Rewinder kept "Resolution" = 3 and "FullScreen" = 0: on a Mac screen (no 16:9 modes) its start-up code
            // ran past its list of resolutions and asked for an exclusive fullscreen twice the screen's size.
            // A running wineserver can hold newer game-written values than user.reg on disk.
            // For an established broken display choice, always repair the live registry.
            return [
                .set(.currentUser, key, unityValueName("Resolution"), .delete),
                .set(.currentUser, key, unityValueName("FullScreen"), .delete),
                .set(.currentUser, key, mode, .dword(1)),
                .set(.currentUser, key, width, .dword(UInt32(size.width))),
                .set(.currentUser, key, height, .dword(UInt32(size.height)))
            ]
        }
        // Nothing saved yet: Unity starts at the desktop resolution by itself.
        guard let savedMode = saved(mode) else { return [] }
        // 0 = exclusive fullscreen, 1 = borderless fullscreen, 2 = maximized window, 3 = windowed.
        // A window as big as the screen is meant to fill it, but with its title bar it can't: macOS pushed it under the
        // menu bar and partly off the screen, and clicks missed (Draw & Guess, The Rewinder). It becomes borderless.
        let fillsScreen = (saved(width) ?? 0) + 16 >= UInt32(size.width) && (saved(height) ?? 0) + 16 >= UInt32(size.height)
        guard savedMode <= 1 || fillsScreen else { return [] }
        var edits: [RegistryEdit] = []
        if savedMode != 1 { edits.append(.set(.currentUser, key, mode, .dword(1))) }
        if saved(width) != UInt32(size.width) { edits.append(.set(.currentUser, key, width, .dword(UInt32(size.width)))) }
        if saved(height) != UInt32(size.height) { edits.append(.set(.currentUser, key, height, .dword(UInt32(size.height)))) }
        return edits
    }
}
