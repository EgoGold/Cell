import Foundation

/// A Wine prefix made by another app (Porting Kit/Wineskin/Sikarugir wrapper, CrossOver, Whisky).
public struct ExistingBottle: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case wrapper = "Porting Kit / Wineskin"
        case crossover = "CrossOver"
        case whisky = "Whisky"
        case folder = "Wine prefix"
    }

    public var id: String { prefix.path }
    public var name: String
    public var source: Source
    /// Folder with system.reg and drive_c.
    public var prefix: URL
    /// Wine engine shipped with the bottle (wrappers only).
    public var engine: URL?
    public var appBundle: URL?
    public var hasSteam: Bool
    public var steamGames: [String]
    public var windowsUser: String?

    public var summary: String {
        var parts = [source.rawValue]
        if hasSteam { parts.append(steamGames.isEmpty ? "Steam" : "Steam · \(steamGames.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

public enum BottleImporter {
    /// Every bottle found on this Mac.
    public static func discover() -> [ExistingBottle] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var bottles: [ExistingBottle] = []

        // Wrapper apps (Porting Kit, Wineskin, Sikarugir, Kegworks).
        let appFolders = ["Applications", "Applications/Porting Kit", "Applications/Wineskin", "Applications/Sikarugir", "Applications/Kegworks"]
            .map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/Applications")]
        for folder in appFolders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".app") {
                let app = folder.appendingPathComponent(name)
                if let bottle = wrapperBottle(app) { bottles.append(bottle) }
            }
        }

        // CrossOver bottles.
        let crossover = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        for name in (try? fm.contentsOfDirectory(atPath: crossover.path)) ?? [] {
            if let bottle = bottle(at: crossover.appendingPathComponent(name), name: name, source: .crossover) { bottles.append(bottle) }
        }

        // Whisky bottles.
        for root in [home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky/Bottles"),
                     home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Bottles")] {
            for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
                let folder = root.appendingPathComponent(name)
                var title = name
                if let metadata = NSDictionary(contentsOf: folder.appendingPathComponent("Metadata.plist")),
                   let info = metadata["info"] as? [String: Any], let bottleName = info["name"] as? String {
                    title = bottleName
                }
                if let bottle = bottle(at: folder, name: title, source: .whisky) { bottles.append(bottle) }
            }
        }

        // The classic ~/.wine prefix.
        if let bottle = bottle(at: home.appendingPathComponent(".wine"), name: "Wine (~/.wine)", source: .folder) { bottles.append(bottle) }

        // Unique by real path.
        var seen = Set<String>()
        return bottles.filter { seen.insert($0.prefix.resolvingSymlinksInPath().path).inserted }
    }

    static func wrapperBottle(_ app: URL) -> ExistingBottle? {
        let prefix = app.appendingPathComponent("Contents/SharedSupport/prefix")
        let engine = app.appendingPathComponent("Contents/SharedSupport/wine")
        var name = app.deletingPathExtension().lastPathComponent
        if let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
           let bundleName = info["CFBundleName"] as? String, !bundleName.isEmpty, bundleName != name {
            name = "\(name) (\(bundleName))"
        }
        guard var bottle = bottle(at: prefix, name: name, source: .wrapper) else { return nil }
        bottle.appBundle = app
        bottle.engine = FileOps.isDirectory(engine.appendingPathComponent("lib/wine")) ? engine : nil
        return bottle
    }

    /// Describes a prefix folder, or nil if it isn't one.
    public static func bottle(at prefix: URL, name: String, source: ExistingBottle.Source) -> ExistingBottle? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              FileOps.isDirectory(prefix.appendingPathComponent("drive_c")) else { return nil }
        let users = prefix.appendingPathComponent("drive_c/users")
        // Real profile folders (Wineskin/CrossOver add symlinks such as nico -> Wineskin).
        let profiles = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).filter { name in
            name != "Public" && !name.hasPrefix(".") && !FileOps.isSymlink(users.appendingPathComponent(name))
        }
        var bottle = ExistingBottle(name: name, source: source, prefix: prefix, engine: nil, appBundle: nil,
                                    hasSteam: false, steamGames: [], windowsUser: profiles.count == 1 ? profiles[0] : nil)
        if let steam = ["Program Files (x86)/Steam", "Program Files/Steam"]
            .map({ prefix.appendingPathComponent("drive_c").appendingPathComponent($0) })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("steam.exe").path) }) {
            bottle.hasSteam = true
            let steamapps = steam.appendingPathComponent("steamapps")
            for file in (try? fm.contentsOfDirectory(atPath: steamapps.path)) ?? [] where file.hasPrefix("appmanifest_") {
                guard let root = VDFNode.parse(contentsOf: steamapps.appendingPathComponent(file)),
                      let state = root["AppState"], let appName = state["name"]?.string, let appID = state["appid"]?.string,
                      !SteamIntegration.ignoredAppIDs.contains(appID), !appName.hasPrefix("Steamworks") else { continue }
                bottle.steamGames.append(appName)
            }
        }
        return bottle
    }

    /// The bottle a file lives in (e.g. a steam.exe picked inside a Porting Kit wrapper).
    public static func bottle(containing file: URL) -> ExistingBottle? {
        var directory = file.deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("system.reg").path),
               FileOps.isDirectory(directory.appendingPathComponent("drive_c")) {
                if directory.lastPathComponent == "prefix", directory.deletingLastPathComponent().lastPathComponent == "SharedSupport" {
                    let app = directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    if app.pathExtension == "app", let bottle = wrapperBottle(app) { return bottle }
                }
                let source: ExistingBottle.Source = directory.path.contains("/CrossOver/Bottles/") ? .crossover
                    : (directory.path.contains("Whisky") ? .whisky : .folder)
                return bottle(at: directory, name: directory.lastPathComponent, source: source)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Points absolute drive links that referred to the old location at the new one.
    static func repairDriveLinks(in prefix: URL, oldPrefix: URL) {
        let fm = FileManager.default
        let devices = prefix.appendingPathComponent("dosdevices")
        for name in (try? fm.contentsOfDirectory(atPath: devices.path)) ?? [] {
            let link = devices.appendingPathComponent(name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path), destination.hasPrefix(oldPrefix.path) else { continue }
            let rewritten = prefix.path + destination.dropFirst(oldPrefix.path.count)
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: rewritten)
        }
    }
}

extension CellServices {
    /// Imports an engine plus the graphics layers it contains, so other engines can use them too.
    @discardableResult
    public func importRuntimeWithComponents(from source: URL) throws -> WineRuntime {
        if let existing = runtimes.runtimes.first(where: { $0.originDescription == source.path }) { return existing }
        let runtime = try runtimes.importRuntime(from: source)
        let info = RuntimeManager.inspect(wineRoot: runtime.wineRoot)
        if info.bundled.contains(where: { $0.kind == .d3dmetal }), components.best(.d3dmetal) == nil {
            _ = try? components.importD3DMetal(from: runtime.wineRoot)
        }
        if info.bundled.contains(where: { $0.kind == .dxmt }), components.best(.dxmt) == nil {
            _ = try? components.importDXMT(from: runtime.wineRoot)
        }
        adoptRuntimeForContainersWithoutEngine()
        return runtime
    }

    /// Containers without an engine start using the recommended one.
    public func adoptRuntimeForContainersWithoutEngine() {
        guard let recommended = runtimes.recommendedRuntime else { return }
        for var container in library.containers where container.platform == .windows && container.runtimeID == nil {
            container.runtimeID = recommended.id
            try? library.save(container)
        }
    }

    public func isImported(_ bottle: ExistingBottle) -> Bool {
        library.containers.contains { $0.importedFrom == bottle.prefix.path }
    }

    /// Clones a bottle into a new container (copy-on-write: instant, no extra disk space) and finds its apps.
    @discardableResult
    public func importBottle(_ bottle: ExistingBottle, status: (@Sendable (String) -> Void)? = nil) throws -> Container {
        if let existing = library.containers.first(where: { $0.importedFrom == bottle.prefix.path }) { return existing }

        // Keep the prefix on the engine that created it: no prefix update, best compatibility.
        var runtimeID: String?
        if let source = bottle.appBundle ?? bottle.engine {
            status?("Importing the engine of “\(bottle.name)”…")
            runtimeID = try importRuntimeWithComponents(from: source).id
        }
        let names = Set(library.containers.map(\.name))
        var name = bottle.name
        var counter = 2
        while names.contains(name) { name = "\(bottle.name) \(counter)"; counter += 1 }

        var container = try library.createContainer(name: name, platform: .windows,
                                                    runtimeID: runtimeID ?? runtimes.recommendedRuntime?.id)
        status?("Copying “\(bottle.name)” (no extra disk space)…")
        try? FileManager.default.removeItem(at: container.prefixURL)
        try FileOps.cloneItem(at: bottle.prefix, to: container.prefixURL)
        BottleImporter.repairDriveLinks(in: container.prefixURL, oldPrefix: bottle.prefix)
        container.importedFrom = bottle.prefix.path
        // Wine names the Windows profile after the Mac user: point it at the bottle's existing profile
        // (saves, settings, logins), the same way Wineskin does.
        let users = container.prefixURL.appendingPathComponent("drive_c/users")
        let mine = users.appendingPathComponent(NSUserName())
        if let profile = bottle.windowsUser, profile != NSUserName(),
           !FileManager.default.fileExists(atPath: mine.path), !FileOps.isSymlink(mine) {
            try? FileManager.default.createSymbolicLink(atPath: mine.path, withDestinationPath: profile)
        }
        container.initializedRuntimeID = runtimeID
        container.appliedConfigHash = nil
        try library.save(container)

        status?("Looking for apps and games…")
        _ = try discoverApps(in: container)
        return library.container(id: container.id) ?? container
    }
}
