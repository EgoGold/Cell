import Foundation

/// `plugin.json` at the root of a .cell package. See Docs/PLUGINS.md.
public struct PluginManifest: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var author: String?
    public var summary: String?
    /// When to use it: the problem it solves, in one sentence ("Steam's window stays black or blank").
    public var useWhen: String?
    public var homepage: String?
    /// Relative path to the icon shipped in the package.
    public var icon: String?
    /// HTTPS URL of the latest .cell file for the same plugin ID.
    public var updateURL: URL?
    /// Higher priority plugins are applied later and win conflicts. Default 0.
    public var priority: Int?
    public var match: PluginMatch
    public var fixes: PluginFixes?
    public var diagnostics: [DiagnosticRule]?
    public var scripts: PluginScripts?
    /// User-invoked commands on the plugin's control panel.
    public var actions: [PluginAction]?
    /// Where the plugin applies when it is added: every translation layer (the default) or only the ones it is
    /// turned on in, and for which kinds of layers.
    public var scope: PluginScope?
    /// Settings the plugin offers people (shown on its page). Fixes use them as `{option.<id>}`.
    public var options: [PluginOption]?
    /// Extra fixes while an option has a value, keyed "id=value" (or just "id" for a toggle that is on).
    public var optionFixes: [String: PluginFixes]?

    public init(id: String, name: String, version: String = "1.0.0", match: PluginMatch = PluginMatch()) {
        schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.match = match
    }
}

public struct PluginMatch: Codable, Hashable, Sendable {
    /// At least one rule must match (ignored when empty).
    public var any: [MatchRule]?
    /// Every rule must match.
    public var all: [MatchRule]?
    /// No rule may match.
    public var none: [MatchRule]?
    public init(any: [MatchRule]? = nil, all: [MatchRule]? = nil, none: [MatchRule]? = nil) {
        self.any = any
        self.all = all
        self.none = none
    }
}

/// Every field that is set must match.
public struct MatchRule: Codable, Hashable, Sendable {
    public var steamAppID: String?
    /// Glob on the executable file name, e.g. "PEAK.exe" or "*-Win64-Shipping.exe".
    public var executable: String?
    public var pathContains: String?
    /// unity, unreal, godot, gameMaker, source, …
    public var engine: String?
    /// e.g. ">=2021", "<6000.3", "5.*"
    public var engineVersion: String?
    /// d3d9, d3d11, d3d12, opengl, vulkan, …
    public var graphicsAPI: String?
    public var productName: String?
    public var companyName: String?
    /// Path relative to the game folder that must exist.
    public var fileExists: String?
    /// x86, x64
    public var architecture: String?
    /// windowsExecutable, steamClient, steamGame
    public var appKind: String?

    public init() {}

    /// How specific the rule is; more specific plugins override generic ones.
    public var specificity: Int {
        var score = 0
        if steamAppID != nil || executable != nil { score = max(score, 3) }
        if productName != nil || fileExists != nil || pathContains != nil { score = max(score, 2) }
        if engine != nil || engineVersion != nil || graphicsAPI != nil || companyName != nil { score = max(score, 1) }
        return score
    }
}

public struct PluginFixes: Codable, Hashable, Sendable {
    public var engine: EngineFix?
    public var graphics: GraphicsFix?
    public var arguments: ArgumentsFix?
    public var environment: EnvironmentFix?
    /// e.g. {"xaudio2_7": "native,builtin", "gameoverlayrenderer64": ""}
    public var dllOverrides: [String: String]?
    public var registry: [PluginRegistryEntry]?
    public var wine: WineFix?
    public var steam: SteamFix?
    public var ini: [IniEdit]?
    public var files: [FileCopy]?
    public var network: NetworkFix?
    /// Mac devices the Windows program can use.
    public var devices: DeviceFix?
    public var notes: [String]?
    public init() {}
}

/// A setting a plugin offers ("Frame-rate cap", "Skip intro videos").
public struct PluginOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// toggle, choice, number or text.
    public var type: String
    /// Value until someone changes it ("true"/"false" for toggles).
    public var defaultValue: String?
    /// For choice.
    public var choices: [String]?
    public var help: String?

    enum CodingKeys: String, CodingKey { case id, title, type, defaultValue = "default", choices, help }

    public init(id: String, title: String, type: String, defaultValue: String? = nil, choices: [String]? = nil, help: String? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.defaultValue = defaultValue
        self.choices = choices
        self.help = help
    }

    static let types: Set<String> = ["toggle", "choice", "number", "text"]
}

/// Mac devices a Windows program reaches through Wine.
public struct DeviceFix: Codable, Hashable, Sendable {
    /// Windows serial ports and the Mac devices behind them, e.g. {"COM3": "/dev/cu.usbserial-*"} (first match):
    /// microcontroller tools, PLC software, old programmers and other engineering software talk to them as COM ports.
    public var serialPorts: [String: String]?
    public init(serialPorts: [String: String]? = nil) { self.serialPorts = serialPorts }
}

/// Which Wine engine suits the game.
public struct EngineFix: Codable, Hashable, Sendable {
    /// In order: "newest", "crossover", "upstream", or "bundled-dxmt" for an engine that ships DXMT.
    public var prefer: [String]?
    /// e.g. "11.0"
    public var minimumWineVersion: String?
}

public struct GraphicsFix: Codable, Hashable, Sendable {
    /// Backends in order of preference: d3dmetal, dxmt, dxvk, wined3d.
    public var prefer: [String]?
    public var avoid: [String]?
}

public struct ArgumentsFix: Codable, Hashable, Sendable {
    public var append: [String]?
    /// Extra arguments only for a backend, e.g. {"dxmt": ["-force-d3d11"]}.
    public var whenBackend: [String: [String]]?
}

public struct EnvironmentFix: Codable, Hashable, Sendable {
    public var set: [String: String]?
    public var whenBackend: [String: [String: String]]?
}

public struct PluginRegistryEntry: Codable, Hashable, Sendable {
    /// Full key, e.g. "HKCU\\Software\\Wine\\DirectInput". With scope "app" the key is relative to
    /// HKCU\Software\Wine\AppDefaults\<game.exe>\ (e.g. "Mac Driver").
    public var key: String
    /// nil = default value.
    public var name: String?
    /// string, expand, multi, dword, qword, binary, delete, deleteKey
    public var type: String
    public var value: String?
    public var values: [String]?
    /// "container" (default) or "app".
    public var scope: String?
}

public struct WineFix: Codable, Hashable, Sendable {
    public var windowsVersion: String?
    /// automatic, smooth, notched
    public var scrollMode: String?
    public var captureDisplays: Bool?
    public var highResolution: Bool?
    public var nativeResolution: Bool?
    public var startFullscreen: Bool?
    /// Opt out of Cell's borderless defaults when the game's own display settings work.
    public var preferBorderlessFullscreen: Bool?
    /// enable, disable, force
    public var mouseWarp: String?
    public var cursorCapture: String?
    public var lockWindowWhenCaptured: Bool?
    public var recoverInputOnFocus: Bool?
    /// Keys to remap for this program, such as "Left": "A". Names refer to physical keys.
    public var keyMappings: [String: String]?
}

public struct SteamFix: Codable, Hashable, Sendable {
    /// enabled / disabled
    public var overlay: String?
    public var clientArguments: [String]?
    /// Arguments passed only when Steam starts the game or its launcher.
    public var launchArguments: [String]?
    /// Prefer the installed game executable when Steam's launcher fails.
    public var preferGameExecutable: Bool?
    /// The publisher bootstrap executables that must use the same minimum Wine version as the game.
    public var compatibilityLaunchers: [String]?
}

public struct IniEdit: Codable, Hashable, Sendable {
    /// Path template, e.g. "{localAppData}/{unrealProject}/Saved/Config/Windows/GameUserSettings.ini".
    public var file: String
    public var section: String
    public var set: [String: String]
    /// Create the file if it does not exist (default false).
    public var create: Bool?
}

public struct FileCopy: Codable, Hashable, Sendable {
    /// Relative to the plugin folder.
    public var from: String
    /// Path template inside the prefix or game folder, e.g. "{gameDir}/dinput8.dll".
    public var to: String
    public var overwrite: Bool?
}

public struct NetworkFix: Codable, Hashable, Sendable {
    public var ports: [PortMapping]?
}

public struct DiagnosticRule: Codable, Hashable, Sendable {
    public var id: String
    /// "wine" for the launch log, or a path template such as "{unityPlayerLog}".
    public var log: String
    /// Regular expression.
    public var pattern: String
    /// info, warning, error
    public var severity: String?
    public var title: String
    public var advice: String?
}

public struct PluginScripts: Codable, Hashable, Sendable {
    /// Relative paths to shell scripts. Run only after the user trusts the plugin.
    public var preLaunch: String?
    public var postExit: String?
}

/// A plugin found on disk.
public struct PluginAction: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// `shell` invokes zsh, `wine` launches the package's .exe or .msi in the selected layer.
    public var runner: String
    public var file: String
    public var arguments: [String]?
}

public struct InstalledPlugin: Identifiable, Hashable, Sendable {
    public var manifest: PluginManifest
    public var directory: URL
    public var isBuiltin: Bool
    public var packageURL: URL? = nil
    public var id: String { manifest.id }
    public var iconURL: URL? { manifest.icon.map { directory.appendingPathComponent($0) } }
    public var hasScripts: Bool {
        manifest.scripts?.preLaunch != nil || manifest.scripts?.postExit != nil || !(manifest.actions ?? []).isEmpty
    }
    /// The plugin asks to be turned on per translation layer instead of everywhere.
    public var isChosenPerLayer: Bool { manifest.scope?.containers?.lowercased() == "chosen" }

    public func applies(to platform: PlatformKind) -> Bool {
        guard let platforms = manifest.scope?.platforms, !platforms.isEmpty else { return true }
        return platforms.contains { $0.caseInsensitiveCompare(platform.rawValue) == .orderedSame }
    }
}

/// `"scope"` in plugin.json.
public struct PluginScope: Codable, Hashable, Sendable {
    /// "all": every translation layer (default). "chosen": only layers the plugin is turned on in.
    public var containers: String?
    /// Kinds of translation layers it can apply to, e.g. ["windows"]. Empty or missing: any.
    public var platforms: [String]?
    public init(containers: String? = nil, platforms: [String]? = nil) {
        self.containers = containers
        self.platforms = platforms
    }
}

/// Which plugins are switched off (everywhere or in one translation layer), where they apply, and which may run scripts.
public struct PluginState: Codable, Hashable, Sendable {
    /// Switched off everywhere.
    public var disabled: Set<String> = []
    public var trustedScripts: Set<String> = []
    /// Switched off in one translation layer (container ID → plugin IDs).
    public var disabledIn: [String: Set<String>] = [:]
    /// Applies only in these translation layers (plugin ID → container IDs). No entry: every layer.
    public var onlyIn: [String: Set<String>] = [:]
    /// What people set the plugins' options to (plugin ID → option ID → value).
    public var optionValues: [String: [String: String]] = [:]
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        disabled = c.value(.disabled, default: [])
        trustedScripts = c.value(.trustedScripts, default: [])
        disabledIn = c.value(.disabledIn, default: [:])
        onlyIn = c.value(.onlyIn, default: [:])
        optionValues = c.value(.optionValues, default: [:])
    }

    /// The plugin's option values: what was chosen, else the defaults.
    public func values(for plugin: InstalledPlugin) -> [String: String] {
        var values: [String: String] = [:]
        for option in plugin.manifest.options ?? [] { values[option.id] = option.defaultValue ?? (option.type == "toggle" ? "false" : "") }
        for (key, value) in optionValues[plugin.id] ?? [:] { values[key] = value }
        return values
    }

    /// Whether the plugin's fixes apply to apps in `container`.
    public func isActive(_ plugin: InstalledPlugin, in container: Container) -> Bool {
        guard !disabled.contains(plugin.id), plugin.applies(to: container.platform) else { return false }
        let key = container.id.uuidString
        if disabledIn[key]?.contains(plugin.id) == true { return false }
        if let only = onlyIn[plugin.id] { return only.contains(key) }
        return !plugin.isChosenPerLayer
    }

    /// Turns a plugin on or off in one translation layer.
    public mutating func setActive(_ active: Bool, plugin: InstalledPlugin, in container: Container) {
        let key = container.id.uuidString
        if active {
            disabledIn[key]?.remove(plugin.id)
            if disabled.contains(plugin.id) {
                // Off everywhere until now: on in this layer only.
                disabled.remove(plugin.id)
                onlyIn[plugin.id] = [key]
            } else if onlyIn[plugin.id] != nil || plugin.isChosenPerLayer {
                onlyIn[plugin.id, default: []].insert(key)
            }
        } else if onlyIn[plugin.id] != nil {
            onlyIn[plugin.id]?.remove(key)
        } else {
            disabledIn[key, default: []].insert(plugin.id)
        }
    }

    /// Every translation layer (nil) or only the given ones.
    public mutating func setScope(_ containers: Set<UUID>?, plugin: InstalledPlugin) {
        for key in disabledIn.keys { disabledIn[key]?.remove(plugin.id) }
        if let containers {
            onlyIn[plugin.id] = Set(containers.map(\.uuidString))
        } else {
            onlyIn[plugin.id] = nil
            disabled.remove(plugin.id)
        }
    }

    /// The layers a plugin is limited to (nil: all of them).
    public func scope(of plugin: InstalledPlugin) -> Set<UUID>? {
        if let only = onlyIn[plugin.id] { return Set(only.compactMap(UUID.init(uuidString:))) }
        return plugin.isChosenPerLayer ? [] : nil
    }

    /// Plugins that don't apply in `container` (merged with the app's own switched-off plugins).
    public func inactive(_ plugins: [InstalledPlugin], in container: Container) -> Set<String> {
        Set(plugins.filter { !isActive($0, in: container) }.map(\.id))
    }
}
