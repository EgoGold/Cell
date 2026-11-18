import Foundation

/// What plugins match against.
public struct MatchContext: Sendable {
    public var executableName: String?
    public var analyzedExecutableName: String?
    public var executablePath: String?
    public var gameDirectory: URL?
    public var steamAppID: String?
    public var analysis: AppAnalysis?
    public var appKind: AppKind?

    public init(executableName: String? = nil, executablePath: String? = nil, gameDirectory: URL? = nil,
                steamAppID: String? = nil, analysis: AppAnalysis? = nil, appKind: AppKind? = nil) {
        self.executableName = executableName
        self.executablePath = executablePath
        self.gameDirectory = gameDirectory
        self.steamAppID = steamAppID
        self.analysis = analysis
        self.appKind = appKind
        self.analyzedExecutableName = analysis?.analyzedExecutable.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public init(app: AppEntry, container: Container) {
        let unix = app.windowsPath.flatMap { WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: $0) }
        let gameDirectory = app.analysis?.analyzedExecutable.map { AppAnalyzer.gameRootDirectory(for: URL(fileURLWithPath: $0)) }
            ?? unix?.deletingLastPathComponent()
        self.init(executableName: app.executableName, executablePath: unix?.path, gameDirectory: gameDirectory,
                  steamAppID: app.steamAppID ?? app.analysis?.steamAppID, analysis: app.analysis, appKind: app.kind)
    }
}

public struct PluginNote: Hashable, Sendable {
    public var plugin: String
    public var text: String
}

public struct PluginRegistryFix: Hashable, Sendable {
    public var pluginID: String
    public var entry: PluginRegistryEntry
}

public struct PluginFileFix: Hashable, Sendable {
    public var plugin: InstalledPlugin
    public var copy: FileCopy
}

public struct PluginIniFix: Hashable, Sendable {
    public var plugin: InstalledPlugin
    public var edit: IniEdit
}

public struct PluginDiagnostic: Hashable, Sendable {
    public var plugin: String
    public var rule: DiagnosticRule
}

public struct PluginScriptFix: Hashable, Sendable {
    public var plugin: InstalledPlugin
    public var scripts: PluginScripts
}

/// All matching plugins merged into one set of fixes (later / more specific plugins win).
public struct ResolvedFixes: Sendable {
    public var plugins: [InstalledPlugin] = []
    public var enginePreference: [String] = []
    public var minimumWineVersion: String?
    public var preferBackends: [GraphicsBackend] = []
    public var avoidBackends: [GraphicsBackend] = []
    public var arguments: [String] = []
    public var argumentsByBackend: [GraphicsBackend: [String]] = [:]
    public var environment: [String: String] = [:]
    public var environmentByBackend: [GraphicsBackend: [String: String]] = [:]
    public var dllOverrides: [String: String] = [:]
    public var registry: [PluginRegistryFix] = []
    public var windowsVersion: WindowsVersion?
    public var scrollMode: ScrollMode?
    public var captureDisplays: Bool?
    public var highResolution: Bool?
    public var nativeResolution: Bool?
    public var startFullscreen: Bool?
    public var preferBorderlessFullscreen: Bool?
    public var mouseWarp: MouseWarpMode?
    public var cursorCapture: CursorCaptureMethod?
    public var lockWindowWhenCaptured: Bool?
    public var recoverInputOnFocus: Bool?
    public var keyMappings: [String: String] = [:]
    public var steamOverlay: OverlayMode?
    public var preferGameExecutable: Bool?
    public var steamClientArguments: [String] = []
    public var steamLaunchArguments: [String] = []
    public var steamCompatibilityLaunchers: [String] = []
    public var iniEdits: [PluginIniFix] = []
    public var fileCopies: [PluginFileFix] = []
    public var ports: [PortMapping] = []
    /// Windows serial port (COM3) → Mac device path pattern.
    public var serialPorts: [String: String] = [:]
    public var notes: [PluginNote] = []
    public var diagnostics: [PluginDiagnostic] = []
    public var scripts: [PluginScriptFix] = []

    public init() {}

    public func arguments(for backend: GraphicsBackend) -> [String] {
        arguments + (argumentsByBackend[backend] ?? [])
    }

    public func environment(for backend: GraphicsBackend) -> [String: String] {
        environment.merging(environmentByBackend[backend] ?? [:]) { _, new in new }
    }
}

public enum FixResolver {
    public static func resolve(plugins: [InstalledPlugin], context: MatchContext, disabled: Set<String> = [],
                               options: PluginState = PluginState()) -> ResolvedFixes {
        let matched = plugins
            .filter { !disabled.contains($0.id) && matches($0.manifest, context: context) }
            .sorted { lhs, rhs in
                let lp = lhs.manifest.priority ?? 0, rp = rhs.manifest.priority ?? 0
                if lp != rp { return lp < rp }
                let ls = specificity(lhs.manifest), rs = specificity(rhs.manifest)
                if ls != rs { return ls < rs }
                if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
                return lhs.id < rhs.id
            }
        var result = ResolvedFixes()
        result.plugins = matched
        for plugin in matched {
            let values = options.values(for: plugin)
            // Fixes that apply while an option has a value ("skipIntro=true", or "skipIntro" for a toggle that is on).
            for (condition, extra) in (plugin.manifest.optionFixes ?? [:]).sorted(by: { $0.key < $1.key }) {
                let parts = condition.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                let wanted = parts.count == 2 ? parts[1] : "true"
                if values[parts[0]]?.caseInsensitiveCompare(wanted) == .orderedSame { merge(fill(extra, with: values), from: plugin, into: &result) }
            }
            guard let fixes = plugin.manifest.fixes else {
                result.diagnostics += (plugin.manifest.diagnostics ?? []).map { PluginDiagnostic(plugin: plugin.manifest.name, rule: $0) }
                continue
            }
            merge(fill(fixes, with: values), from: plugin, into: &result)
            result.diagnostics += (plugin.manifest.diagnostics ?? []).map { PluginDiagnostic(plugin: plugin.manifest.name, rule: $0) }
            if let scripts = plugin.manifest.scripts { result.scripts.append(PluginScriptFix(plugin: plugin, scripts: scripts)) }
        }
        return result
    }

    /// Puts option values into a plugin's fixes wherever they say `{option.<id>}`.
    static func fill(_ fixes: PluginFixes, with values: [String: String]) -> PluginFixes {
        guard !values.isEmpty else { return fixes }
        func text(_ string: String) -> String {
            var result = string
            for (key, value) in values { result = result.replacingOccurrences(of: "{option.\(key)}", with: value) }
            return result
        }
        var filled = fixes
        filled.arguments?.append = fixes.arguments?.append?.map(text)
        filled.arguments?.whenBackend = fixes.arguments?.whenBackend?.mapValues { $0.map(text) }
        filled.environment?.set = fixes.environment?.set?.mapValues(text)
        filled.environment?.whenBackend = fixes.environment?.whenBackend?.mapValues { $0.mapValues(text) }
        filled.registry = fixes.registry?.map { entry in
            var entry = entry
            entry.value = entry.value.map(text)
            entry.values = entry.values?.map(text)
            return entry
        }
        filled.ini = fixes.ini?.map { edit in
            var edit = edit
            edit.set = edit.set.mapValues(text)
            return edit
        }
        filled.devices?.serialPorts = fixes.devices?.serialPorts?.mapValues(text)
        filled.notes = fixes.notes?.map(text)
        return filled
    }

    static func specificity(_ manifest: PluginManifest) -> Int {
        ((manifest.match.any ?? []) + (manifest.match.all ?? [])).map(\.specificity).max() ?? 0
    }

    private static func merge(_ fixes: PluginFixes, from plugin: InstalledPlugin, into result: inout ResolvedFixes) {
        if let engine = fixes.engine {
            let prefer = engine.prefer ?? []
            result.enginePreference = prefer + result.enginePreference.filter { !prefer.contains($0) }
            if let minimum = engine.minimumWineVersion { result.minimumWineVersion = minimum }
        }
        if let graphics = fixes.graphics {
            let prefer = (graphics.prefer ?? []).compactMap(GraphicsBackend.init(rawValue:))
            result.preferBackends = prefer + result.preferBackends.filter { !prefer.contains($0) }
            for avoid in (graphics.avoid ?? []).compactMap(GraphicsBackend.init(rawValue:)) where !result.avoidBackends.contains(avoid) {
                result.avoidBackends.append(avoid)
            }
        }
        if let arguments = fixes.arguments {
            appendGroup(arguments.append ?? [], to: &result.arguments)
            for (key, list) in arguments.whenBackend ?? [:] {
                guard let backend = GraphicsBackend(rawValue: key) else { continue }
                appendGroup(list, to: &result.argumentsByBackend[backend, default: []])
            }
        }
        if let environment = fixes.environment {
            result.environment.merge(environment.set ?? [:]) { _, new in new }
            for (key, values) in environment.whenBackend ?? [:] {
                guard let backend = GraphicsBackend(rawValue: key) else { continue }
                result.environmentByBackend[backend, default: [:]].merge(values) { _, new in new }
            }
        }
        result.dllOverrides.merge(fixes.dllOverrides ?? [:]) { _, new in new }
        result.registry += (fixes.registry ?? []).map { PluginRegistryFix(pluginID: plugin.id, entry: $0) }
        if let wine = fixes.wine {
            for (key, target) in wine.keyMappings ?? [:] {
                result.keyMappings[key.lowercased()] = target.lowercased()
            }
            if let version = wine.windowsVersion.flatMap(WindowsVersion.init(rawValue:)) { result.windowsVersion = version }
            if let scroll = wine.scrollMode.flatMap(ScrollMode.init(rawValue:)) { result.scrollMode = scroll }
            if let capture = wine.captureDisplays { result.captureDisplays = capture }
            if let high = wine.highResolution { result.highResolution = high }
            if let native = wine.nativeResolution { result.nativeResolution = native }
            if let fullscreen = wine.startFullscreen { result.startFullscreen = fullscreen }
            if let borderless = wine.preferBorderlessFullscreen { result.preferBorderlessFullscreen = borderless }
            if let warp = wine.mouseWarp.flatMap(MouseWarpMode.init(rawValue:)) { result.mouseWarp = warp }
            if let capture = wine.cursorCapture.flatMap(CursorCaptureMethod.init(rawValue:)) { result.cursorCapture = capture }
            if let lock = wine.lockWindowWhenCaptured { result.lockWindowWhenCaptured = lock }
            if let recover = wine.recoverInputOnFocus { result.recoverInputOnFocus = recover }
        }
        if let steam = fixes.steam {
            if let overlay = steam.overlay.flatMap(OverlayMode.init(rawValue:)) { result.steamOverlay = overlay }
            if let preferGame = steam.preferGameExecutable { result.preferGameExecutable = preferGame }
            result.steamClientArguments += (steam.clientArguments ?? []).filter { !result.steamClientArguments.contains($0) }
            if let arguments = steam.launchArguments {
                appendGroup(arguments, to: &result.steamLaunchArguments)
            }
            result.steamCompatibilityLaunchers += steam.compatibilityLaunchers ?? []
        }
        result.iniEdits += (fixes.ini ?? []).map { PluginIniFix(plugin: plugin, edit: $0) }
        result.fileCopies += (fixes.files ?? []).map { PluginFileFix(plugin: plugin, copy: $0) }
        for port in fixes.network?.ports ?? [] where !result.ports.contains(port) { result.ports.append(port) }
        for (port, device) in fixes.devices?.serialPorts ?? [:] { result.serialPorts[port.uppercased()] = device }
        result.notes += (fixes.notes ?? []).map { PluginNote(plugin: plugin.manifest.name, text: $0) }
    }

    /// Appends an argument group (e.g. ["-window-mode", "borderless"]) unless it is already present in order.
    public static func appendGroup(_ group: [String], to list: inout [String]) {
        guard !group.isEmpty else { return }
        if group.count <= list.count {
            for start in 0...(list.count - group.count) where Array(list[start..<(start + group.count)]) == group { return }
        }
        list += group
    }

    // MARK: Matching

    public static func matches(_ manifest: PluginManifest, context: MatchContext) -> Bool {
        let any = manifest.match.any ?? []
        let all = manifest.match.all ?? []
        let none = manifest.match.none ?? []
        if any.isEmpty && all.isEmpty { return false }
        if !any.isEmpty && !any.contains(where: { matches($0, context: context) }) { return false }
        if !all.allSatisfy({ matches($0, context: context) }) { return false }
        if none.contains(where: { matches($0, context: context) }) { return false }
        return true
    }

    public static func matches(_ rule: MatchRule, context: MatchContext) -> Bool {
        let analysis = context.analysis
        if let appID = rule.steamAppID, appID != context.steamAppID { return false }
        if let pattern = rule.executable {
            let names = [context.executableName, context.analyzedExecutableName].compactMap { $0 }
            if !names.contains(where: { globMatch(pattern, $0) }) { return false }
        }
        if let fragment = rule.pathContains {
            guard let path = context.executablePath ?? analysis?.analyzedExecutable,
                  path.range(of: fragment, options: .caseInsensitive) != nil else { return false }
        }
        if let engine = rule.engine {
            guard let detected = analysis?.engine, detected.rawValue.caseInsensitiveCompare(engine) == .orderedSame else { return false }
        }
        if let expression = rule.engineVersion {
            guard let version = analysis?.engineVersion, LooseVersion(version).satisfies(expression) else { return false }
        }
        if let apiName = rule.graphicsAPI {
            guard let api = GraphicsAPI(rawValue: apiName.lowercased()), let analysis else { return false }
            let present = analysis.graphicsAPIs.contains(api) || (api == .d3d12 && analysis.hasD3D12AgilitySDK)
            if !present { return false }
        }
        if let pattern = rule.productName {
            guard let product = analysis?.productName ?? analysis?.unityProduct, globMatch(pattern, product) else { return false }
        }
        if let pattern = rule.companyName {
            guard let company = analysis?.companyName ?? analysis?.unityCompany, globMatch(pattern, company) else { return false }
        }
        if let relative = rule.fileExists {
            guard let directory = context.gameDirectory,
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) else { return false }
        }
        if let architecture = rule.architecture, analysis?.architecture.rawValue != architecture.lowercased() { return false }
        if let kind = rule.appKind, context.appKind?.rawValue != kind { return false }
        return true
    }
}
