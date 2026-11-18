import Foundation

public enum PluginError: LocalizedError {
    case invalid(String)
    case rollback(name: String, installed: String, incoming: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid plugin: \(reason)"
        case .rollback(let name, let installed, let incoming):
            return "Replace \(name) \(installed) with older version \(incoming)?"
        }
    }
}

/// Loads built-in and user plugins, imports new ones and validates them.
public final class PluginManager: @unchecked Sendable {
    /// Plugin folders: `.cell`, and the names used before (`.cellplug`, `.cellplugin`, `.chamberplugin`).
    public static let pluginExtensions = ["cell", "cellplug", "cellplugin", "chamberplugin"]

    /// Installed plugins made with an earlier name get the `.cell` name (unless one by that name exists).
    static func renameOldPluginFolders(in directory: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items where item.pathExtension != "cell" && pluginExtensions.contains(item.pathExtension) && FileOps.isDirectory(item) {
            let renamed = item.deletingPathExtension().appendingPathExtension("cell")
            if !fm.fileExists(atPath: renamed.path) { try? fm.moveItem(at: item, to: renamed) }
        }
    }

    private var storedPlugins: [InstalledPlugin] = []
    private var storedState = PluginState()
    private var storedErrors: [String] = []
    private let lock = NSLock()
    private let installationLock = NSRecursiveLock()
    public var plugins: [InstalledPlugin] { lock.withLock { storedPlugins } }
    public var state: PluginState { lock.withLock { storedState } }
    public var loadErrors: [String] { lock.withLock { storedErrors } }

    public init() { reload() }

    public static var builtinDirectory: URL? { CellPaths.bundledResource("Plugins") }

    public func reload() {
        var found: [InstalledPlugin] = []
        var errors: [String] = []
        if let builtin = Self.builtinDirectory {
            let (plugins, problems) = Self.scan(builtin, isBuiltin: true)
            found += plugins
            errors += problems
        }
        Self.renameOldPluginFolders(in: CellPaths.plugins)
        let (user, problems) = Self.scan(CellPaths.plugins, isBuiltin: false)
        errors += problems
        // A user plugin with the same id replaces the built-in one (lets people patch fixes locally).
        for plugin in user {
            found.removeAll { $0.id == plugin.id }
            found.append(plugin)
        }
        let loadedState = JSONStore.loadIfPresent(PluginState.self, from: CellPaths.pluginStateFile) ?? PluginState()
        lock.withLock {
            storedPlugins = found.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
            storedState = loadedState
            storedErrors = errors
        }
    }

    private static func scan(_ directory: URL, isBuiltin: Bool) -> ([InstalledPlugin], [String]) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return ([], []) }
        var plugins: [InstalledPlugin] = []
        var errors: [String] = []
        // ".chamberplugin": plugins made before Cell was renamed.
        for item in items where pluginExtensions.contains(item.pathExtension.lowercased()) {
            do {
                if FileOps.isDirectory(item) {
                    if isBuiltin {
                        plugins.append(InstalledPlugin(manifest: try loadManifest(in: item), directory: item, isBuiltin: true))
                    } else {
                        plugins.append(try migrateFolder(item))
                    }
                } else {
                    plugins.append(try readPackage(item, isBuiltin: isBuiltin))
                }
            } catch {
                errors.append("\(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (plugins, errors)
    }

    private struct PackageStamp: Equatable {
        var modified: Date?
        var size: UInt64?
        var inode: UInt64?
    }
    private static let packageCacheLock = NSLock()
    private static var packageCache: [URL: (stamp: PackageStamp, plugin: InstalledPlugin)] = [:]

    private static func readPackage(_ url: URL, isBuiltin: Bool = false) throws -> InstalledPlugin {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let stamp = PackageStamp(modified: attributes[.modificationDate] as? Date,
                                 size: (attributes[.size] as? NSNumber)?.uint64Value,
                                 inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        if let cached = packageCacheLock.withLock({ packageCache[url] }), cached.stamp == stamp,
           cached.plugin.isBuiltin == isBuiltin, fm.fileExists(atPath: cached.plugin.directory.path) {
            return cached.plugin
        }
        let digest = try FileOps.sha256(of: url)
        let contents = CellPaths.caches.appendingPathComponent("PluginContents/\(digest)", isDirectory: true)
        if !fm.fileExists(atPath: contents.path) {
            let scratch = try CellPaths.makeScratchDirectory(prefix: "cell-package")
            defer { try? fm.removeItem(at: scratch) }
            try PluginPackage.unpack(url, into: scratch)
            let folder = try PluginPackage.manifestFolder(in: scratch)
            _ = try loadManifest(in: folder)
            try fm.createDirectory(at: contents.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try fm.moveItem(at: folder, to: contents) }
            catch { if !fm.fileExists(atPath: contents.path) { throw error } }
        }
        let plugin = InstalledPlugin(manifest: try loadManifest(in: contents), directory: contents, isBuiltin: isBuiltin, packageURL: url)
        if url.pathExtension.lowercased() == "cell" {
            packageCacheLock.withLock { packageCache[url] = (stamp, plugin) }
        }
        return plugin
    }

    private static func migrateFolder(_ source: URL) throws -> InstalledPlugin {
        let fm = FileManager.default
        let parent = source.deletingLastPathComponent()
        let staged = parent.appendingPathComponent(".migration-\(UUID().uuidString).zip")
        let backup = parent.appendingPathComponent(".legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staged) }
        try PluginPackage.pack(source, to: staged)
        var plugin = try readPackage(staged)
        try fm.moveItem(at: source, to: backup)
        do { try fm.moveItem(at: staged, to: source) }
        catch { try? fm.moveItem(at: backup, to: source); throw error }
        try? fm.removeItem(at: backup)
        plugin.packageURL = source
        return plugin
    }

    public static func validatePackage(at url: URL) throws -> PluginManifest {
        try FileOps.isDirectory(url) ? loadManifest(in: url) : readPackage(url).manifest
    }

    public static func loadManifest(in directory: URL) throws -> PluginManifest {
        let url = directory.appendingPathComponent("plugin.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginError.invalid("plugin.json is missing") }
        let manifest: PluginManifest
        do {
            manifest = try JSONStore.load(PluginManifest.self, from: url)
        } catch let DecodingError.keyNotFound(key, _) {
            throw PluginError.invalid("missing field \"\(key.stringValue)\"")
        } catch let DecodingError.typeMismatch(_, context) {
            throw PluginError.invalid("wrong type at \(context.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch {
            throw PluginError.invalid(error.localizedDescription)
        }
        try validate(manifest, directory: directory)
        return manifest
    }

    /// Rejects manifests that could escape their sandbox or that Cell cannot understand.
    public static func validate(_ manifest: PluginManifest, directory: URL) throws {
        guard manifest.schemaVersion <= PluginManifest.currentSchemaVersion else {
            throw PluginError.invalid("needs a newer version of Cell (schema \(manifest.schemaVersion))")
        }
        guard manifest.id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$"#, options: .regularExpression) != nil else {
            throw PluginError.invalid("id must use letters, digits, dots, dashes or underscores")
        }
        guard !manifest.name.trimmingCharacters(in: .whitespaces).isEmpty else { throw PluginError.invalid("name is empty") }
        guard manifest.version.range(of: #"^[0-9]+(?:\.[0-9]+)*(?:-[A-Za-z0-9.-]+)?(?:\+[A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else {
            throw PluginError.invalid("use a numeric version such as 1.2.0 or 1.2.0-beta.1")
        }
        if let url = manifest.updateURL, url.scheme?.lowercased() != "https" || url.host == nil || url.user != nil || url.password != nil {
            throw PluginError.invalid("updateURL must be an HTTPS address without account credentials")
        }
        let rules = (manifest.match.any ?? []) + (manifest.match.all ?? [])
        guard !rules.isEmpty else { throw PluginError.invalid("match must contain at least one rule in \"any\" or \"all\"") }

        let backends = Set(GraphicsBackend.allCases.map(\.rawValue))
        let argumentBackends = manifest.fixes?.arguments?.whenBackend.map { Array($0.keys) } ?? []
        let environmentBackends = manifest.fixes?.environment?.whenBackend.map { Array($0.keys) } ?? []
        for name in (manifest.fixes?.graphics?.prefer ?? []) + (manifest.fixes?.graphics?.avoid ?? []) + argumentBackends + environmentBackends {
            guard backends.contains(name) else { throw PluginError.invalid("unknown graphics backend \"\(name)\"") }
        }
        for family in manifest.fixes?.engine?.prefer ?? [] where !["newest", "crossover", "upstream", "bundled-dxmt"].contains(family) {
            throw PluginError.invalid("unknown engine preference \"\(family)\" (use newest, crossover, upstream or bundled-dxmt)")
        }
        for entry in manifest.fixes?.registry ?? [] {
            if entry.scope != "app" { guard RegistryHive.split(entry.key) != nil else { throw PluginError.invalid("registry key \"\(entry.key)\" needs a hive (HKCU/HKLM)") } }
            guard ["string", "expand", "multi", "dword", "qword", "binary", "delete", "deleteKey"].contains(entry.type) else {
                throw PluginError.invalid("unknown registry type \"\(entry.type)\"")
            }
        }
        if let scope = manifest.scope {
            if let containers = scope.containers, !["all", "chosen"].contains(containers.lowercased()) {
                throw PluginError.invalid("scope.containers must be \"all\" or \"chosen\"")
            }
            for platform in scope.platforms ?? [] where PlatformKind(rawValue: platform.lowercased()) == nil {
                throw PluginError.invalid("unknown platform \"\(platform)\" in scope (use windows or linux)")
            }
        }
        var optionIDs: Set<String> = []
        for option in manifest.options ?? [] {
            guard option.id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil, optionIDs.insert(option.id).inserted else {
                throw PluginError.invalid("option ids must be unique letters, digits, - or _ (\"\(option.id)\")")
            }
            guard PluginOption.types.contains(option.type) else {
                throw PluginError.invalid("option \"\(option.id)\" has unknown type \"\(option.type)\" (toggle, choice, number, text)")
            }
            if option.type == "choice", option.choices?.isEmpty ?? true { throw PluginError.invalid("choice option \"\(option.id)\" needs choices") }
        }
        for condition in (manifest.optionFixes ?? [:]).keys {
            let id = String(condition.split(separator: "=").first ?? "").trimmingCharacters(in: .whitespaces)
            guard optionIDs.contains(id) else { throw PluginError.invalid("optionFixes uses unknown option \"\(id)\"") }
        }
        for (port, device) in manifest.fixes?.devices?.serialPorts ?? [:] {
            guard port.range(of: #"^(?i)COM\d{1,3}$"#, options: .regularExpression) != nil else { throw PluginError.invalid("serial port \"\(port)\" must look like COM3") }
            guard device.hasPrefix("/dev/") else { throw PluginError.invalid("serial device \"\(device)\" must be a /dev path") }
        }
        for rule in manifest.diagnostics ?? [] {
            guard (try? NSRegularExpression(pattern: rule.pattern)) != nil else { throw PluginError.invalid("bad pattern in diagnostic \"\(rule.id)\"") }
        }
        // Files that the plugin ships must stay inside the plugin folder.
        let fixes = [manifest.fixes].compactMap { $0 } + Array((manifest.optionFixes ?? [:]).values)
        for fix in fixes {
            var seen = Set<String>()
            for (key, target) in fix.wine?.keyMappings ?? [:] {
                let name = key.lowercased()
                guard PluginKeyMappings.codes[name] != nil, PluginKeyMappings.codes[target.lowercased()] != nil,
                      seen.insert(name).inserted else { throw PluginError.invalid("unknown or duplicate key mapping \"\(key) → \(target)\"") }
            }
        }
        var relativePaths = fixes.flatMap { ($0.files ?? []).map(\.from) }
        if let pre = manifest.scripts?.preLaunch { relativePaths.append(pre) }
        if let post = manifest.scripts?.postExit { relativePaths.append(post) }
        if let icon = manifest.icon { relativePaths.append(icon) }
        var actionIDs = Set<String>()
        for action in manifest.actions ?? [] {
            guard action.id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
                  actionIDs.insert(action.id).inserted, !action.title.isEmpty else {
                throw PluginError.invalid("actions need a unique ID and label")
            }
            guard action.runner == "shell" || (action.runner == "wine" && ["exe", "msi"].contains((action.file as NSString).pathExtension.lowercased())) else {
                throw PluginError.invalid("an action runs a shell script or a Windows .exe/.msi")
            }
            relativePaths.append(action.file)
        }
        for path in relativePaths {
            let url = directory.appendingPathComponent(path)
            guard !path.hasPrefix("/"), FileOps.isContained(url, in: directory) else {
                throw PluginError.invalid("\"\(path)\" points outside the plugin")
            }
            guard FileManager.default.fileExists(atPath: url.path) else { throw PluginError.invalid("\"\(path)\" is missing") }
        }
        for copy in fixes.flatMap({ $0.files ?? [] }) {
            guard copy.to.hasPrefix("{") else { throw PluginError.invalid("file destination \"\(copy.to)\" must start with a location like {gameDir}") }
        }
        for edit in fixes.flatMap({ $0.ini ?? [] }) {
            guard edit.file.hasPrefix("{") else { throw PluginError.invalid("ini file \"\(edit.file)\" must start with a location like {localAppData}") }
        }
    }

    // MARK: Import / create

    /// Installs a package or imports a legacy authoring folder as a single file.
    @discardableResult
    public func importPlugin(from source: URL, onlyIn container: Container? = nil, allowRollback: Bool = false,
                             expectedID: String? = nil) throws -> InstalledPlugin {
        try installationLock.withLock {
            try CellPaths.ensureDirectories()
            let fm = FileManager.default
            let staged = CellPaths.plugins.appendingPathComponent(".import-\(UUID().uuidString).zip")
            defer { try? fm.removeItem(at: staged) }
            if FileOps.isDirectory(source) { try PluginPackage.pack(source, to: staged) }
            else { try fm.copyItem(at: source, to: staged) }
            var installed = try Self.readPackage(staged)
            let manifest = installed.manifest
            if let expectedID, expectedID != manifest.id { throw PluginError.invalid("the update has a different plugin ID") }
            reload()
            let existing = plugins.first { $0.id.caseInsensitiveCompare(manifest.id) == .orderedSame }
            if let existing, existing.id != manifest.id { throw PluginError.invalid("package IDs must keep the same capitalization") }
            if let existing, !allowRollback,
               Self.compareVersions(manifest.version, existing.manifest.version) == .orderedAscending {
                throw PluginError.rollback(name: existing.manifest.name, installed: existing.manifest.version, incoming: manifest.version)
            }
            let destination = (existing?.isBuiltin == false ? existing?.packageURL : nil)
                ?? CellPaths.plugins.appendingPathComponent(manifest.id + ".cell")
            let sameBytes = existing?.isBuiltin == false && existing?.directory == installed.directory
            let previousState = state
            var newState = previousState
            if !sameBytes { newState.trustedScripts.remove(manifest.id) }
            if let container {
                if existing == nil { newState.setScope([container.id], plugin: installed) }
                else { newState.setActive(true, plugin: installed, in: container) }
            }
            try saveState(newState)
            do {
                if !sameBytes {
                    if fm.fileExists(atPath: destination.path) {
                        _ = try fm.replaceItemAt(destination, withItemAt: staged)
                    } else {
                        try fm.moveItem(at: staged, to: destination)
                    }
                }
            } catch {
                try? saveState(previousState)
                throw error
            }
            installed.packageURL = destination
            reload()
            return installed
        }
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ version: String) -> (String, [Substring]) {
            let build = version.split(separator: "+", maxSplits: 1)[0]
            let parts = build.split(separator: "-", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? parts[1].split(separator: ".") : [])
        }
        let (majorA, preA) = parts(a)
        let (majorB, preB) = parts(b)
        let lhs = LooseVersion(majorA), rhs = LooseVersion(majorB)
        if lhs < rhs { return .orderedAscending }
        if rhs < lhs { return .orderedDescending }
        if preA.isEmpty != preB.isEmpty { return preA.isEmpty ? .orderedDescending : .orderedAscending }
        for (first, second) in zip(preA, preB) {
            if first == second { continue }
            let numericA = first.allSatisfy(\.isNumber), numericB = second.allSatisfy(\.isNumber)
            if numericA != numericB { return numericA ? .orderedAscending : .orderedDescending }
            let order = String(first).compare(String(second), options: numericA ? .numeric : .literal)
            if order != .orderedSame { return order }
        }
        return preA.count < preB.count ? .orderedAscending : (preA.count == preB.count ? .orderedSame : .orderedDescending)
    }

    public func downloadUpdate(for plugin: InstalledPlugin) async throws -> URL {
        guard let address = plugin.manifest.updateURL else { throw PluginError.invalid("the developer has not set an update address") }
        let (file, response) = try await URLSession.shared.download(from: address)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else { throw PluginError.invalid("could not download the HTTPS update") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cell-update-\(UUID().uuidString).cell")
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    public static func exportFolder(_ folder: URL, to destination: URL) throws {
        _ = try loadManifest(in: folder)
        let fm = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".cell-export-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: staged) }
        try PluginPackage.pack(folder, to: staged)
        _ = try readPackage(staged)
        if fm.fileExists(atPath: destination.path) { _ = try fm.replaceItemAt(destination, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: destination) }
    }

    public func exportPlugin(_ plugin: InstalledPlugin, to destination: URL) throws {
        if plugin.packageURL?.standardizedFileURL == destination.standardizedFileURL { return }
        try Self.exportFolder(plugin.directory, to: destination)
    }

    public func saveEdit(_ plugin: InstalledPlugin, manifest: PluginManifest, adding assets: [URL],
                         removing removed: Set<String>, icon: URL?) throws -> InstalledPlugin {
        let fm = FileManager.default
        let scratch = try CellPaths.makeScratchDirectory(prefix: "cell-edit")
        defer { try? fm.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("package")
        try fm.copyItem(at: plugin.directory, to: folder)
        var manifest = manifest
        for item in removed where item != "plugin.json" && item == (item as NSString).lastPathComponent {
            let file = folder.appendingPathComponent(item)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
            if manifest.icon == item { manifest.icon = nil }
        }
        for asset in assets {
            let name = asset.lastPathComponent
            guard name.lowercased() != "plugin.json" else { throw PluginError.invalid("edit plugin.json in the manifest editor") }
            let destination = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: asset, to: destination)
        }
        if let icon {
            let name = "plugin-icon." + icon.pathExtension.lowercased()
            let destination = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: icon, to: destination)
            manifest.icon = name
        }
        try JSONStore.save(manifest, to: folder.appendingPathComponent("plugin.json"))
        return try importPlugin(from: folder, expectedID: plugin.id)
    }

    @discardableResult
    public func createTemplate(name: String, executable: String? = nil, steamAppID: String? = nil, identifier: String? = nil) throws -> InstalledPlugin {
        let slug = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = identifier?.isEmpty == false ? identifier! : "local.\(slug.isEmpty ? "plugin" : slug)"
        guard !plugins.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw PluginError.invalid("a package with this ID already exists")
        }
        var rule = MatchRule()
        rule.executable = executable ?? (steamAppID == nil ? "Game.exe" : nil)
        rule.steamAppID = steamAppID
        var manifest = PluginManifest(id: id, name: name, match: PluginMatch(all: [rule]))
        manifest.author = NSFullUserName()
        let folder = try CellPaths.makeScratchDirectory(prefix: "cell-template")
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONStore.save(manifest, to: folder.appendingPathComponent("plugin.json"))
        return try importPlugin(from: folder)
    }

    public func remove(_ plugin: InstalledPlugin) throws {
        guard !plugin.isBuiltin else { return }
        try FileManager.default.removeItem(at: plugin.packageURL ?? plugin.directory)
        reload()
    }

    public func restoreDefaults(for plugin: InstalledPlugin) throws {
        var reset = state
        reset.optionValues.removeValue(forKey: plugin.id)
        reset.onlyIn.removeValue(forKey: plugin.id)
        reset.disabled.remove(plugin.id)
        reset.trustedScripts.remove(plugin.id)
        for id in Array(reset.disabledIn.keys) { reset.disabledIn[id]?.remove(plugin.id) }
        try saveState(reset)
    }

    // MARK: State

    public func isEnabled(_ plugin: InstalledPlugin) -> Bool { !state.disabled.contains(plugin.id) }
    public func isTrusted(_ plugin: InstalledPlugin) -> Bool { state.trustedScripts.contains(plugin.id) }

    public func setEnabled(_ enabled: Bool, for plugin: InstalledPlugin) throws {
        var newState = state
        if enabled { newState.disabled.remove(plugin.id) } else { newState.disabled.insert(plugin.id) }
        try saveState(newState)
    }

    public func setTrusted(_ trusted: Bool, for plugin: InstalledPlugin) throws {
        var newState = state
        if trusted { newState.trustedScripts.insert(plugin.id) } else { newState.trustedScripts.remove(plugin.id) }
        try saveState(newState)
    }

    /// Turns a plugin on or off in one translation layer.
    public func setActive(_ active: Bool, for plugin: InstalledPlugin, in container: Container) throws {
        var newState = state
        newState.setActive(active, plugin: plugin, in: container)
        try saveState(newState)
    }

    /// What someone set a plugin option to.
    public func setOption(_ value: String, id: String, for plugin: InstalledPlugin) throws {
        var newState = state
        newState.optionValues[plugin.id, default: [:]][id] = value
        try saveState(newState)
    }

    /// Every translation layer (nil) or only some.
    public func setScope(_ containers: Set<UUID>?, for plugin: InstalledPlugin) throws {
        var newState = state
        newState.setScope(containers, plugin: plugin)
        try saveState(newState)
    }

    private func saveState(_ newState: PluginState) throws {
        try JSONStore.save(newState, to: CellPaths.pluginStateFile)
        lock.withLock { storedState = newState }
    }

    public var enabledPlugins: [InstalledPlugin] { plugins.filter(isEnabled) }
}
