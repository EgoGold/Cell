import Foundation

public enum AppKind: String, Codable, Sendable {
    case windowsExecutable, steamClient, steamGame
}

public enum AppSource: String, Codable, Sendable {
    case manual, startMenu, steam
}

/// An app or game in the Library.
public struct AppEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var containerID: UUID
    public var name: String
    public var kind: AppKind
    public var source: AppSource
    /// Windows path, e.g. `C:\Program Files\Game\Game.exe` (stable even if the container moves).
    public var windowsPath: String?
    public var workingDirectory: String?
    /// Arguments that belong to the app (from its .lnk), not user overrides.
    public var launchArguments: [String]
    public var steamAppID: String?
    /// File names inside `CellPaths.icons`.
    public var iconFile: String?
    public var artworkFile: String?
    public var settings: AppSettings
    public var analysis: AppAnalysis?
    public var learned: LearnedCompat
    public var shortcutPath: String?
    public var addedAt: Date
    public var lastPlayedAt: Date?
    public var totalPlayTime: TimeInterval
    public var isFavorite: Bool
    public var isHidden: Bool

    public init(id: UUID = UUID(), containerID: UUID, name: String, kind: AppKind, source: AppSource,
                windowsPath: String? = nil, workingDirectory: String? = nil, launchArguments: [String] = [],
                steamAppID: String? = nil) {
        self.id = id
        self.containerID = containerID
        self.name = name
        self.kind = kind
        self.source = source
        self.windowsPath = windowsPath
        self.workingDirectory = workingDirectory
        self.launchArguments = launchArguments
        self.steamAppID = steamAppID
        self.settings = AppSettings()
        self.learned = LearnedCompat()
        self.addedAt = Date()
        self.totalPlayTime = 0
        self.isFavorite = false
        self.isHidden = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        containerID = try c.decode(UUID.self, forKey: .containerID)
        name = c.value(.name, default: "App")
        kind = c.value(.kind, default: .windowsExecutable)
        source = c.value(.source, default: .manual)
        windowsPath = c.value(.windowsPath, default: nil)
        workingDirectory = c.value(.workingDirectory, default: nil)
        launchArguments = c.value(.launchArguments, default: [])
        steamAppID = c.value(.steamAppID, default: nil)
        iconFile = c.value(.iconFile, default: nil)
        artworkFile = c.value(.artworkFile, default: nil)
        settings = c.value(.settings, default: AppSettings())
        analysis = c.value(.analysis, default: nil)
        learned = c.value(.learned, default: LearnedCompat())
        shortcutPath = c.value(.shortcutPath, default: nil)
        addedAt = c.value(.addedAt, default: Date())
        lastPlayedAt = c.value(.lastPlayedAt, default: nil)
        totalPlayTime = c.value(.totalPlayTime, default: 0)
        isFavorite = c.value(.isFavorite, default: false)
        isHidden = c.value(.isHidden, default: false)
    }

    /// Executable file name, e.g. `Game.exe` (used for Wine AppDefaults keys).
    public var executableName: String? {
        guard let windowsPath else { return nil }
        return windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
    }

    /// Games get game-friendly defaults (notched scrolling, display capture).
    public var isGame: Bool {
        if let explicit = settings.isGame { return explicit }
        switch kind {
        case .steamGame: return true
        case .steamClient: return false
        case .windowsExecutable:
            guard let analysis else { return false }
            if analysis.engine.map({ $0 != .electron && $0 != .cef && $0 != .java && $0 != .unknown }) == true { return true }
            return analysis.graphicsAPIs.contains { $0 != .opengl } && !analysis.isInstaller
        }
    }

    public var iconURL: URL? { iconFile.map { CellPaths.icons.appendingPathComponent($0) } }
    public var artworkURL: URL? { artworkFile.map { CellPaths.icons.appendingPathComponent($0) } }
}

/// User overrides for one app. `nil` means "use the container default / Autopilot".
public struct AppSettings: Codable, Hashable, Sendable {
    public var backendOverride: GraphicsBackend? = nil
    /// Wine engine for this app; nil = automatic.
    public var runtimeOverride: String? = nil
    public var extraArguments: [String] = []
    public var environment: [String: String] = [:]
    public var scrollMode: ScrollMode? = nil
    public var highResolution: Bool? = nil
    public var captureDisplays: Bool? = nil
    /// nil = the container's "native resolution for games" setting.
    public var nativeResolution: Bool? = nil
    public var startFullscreen: Bool? = nil
    public var mouseWarp: MouseWarpMode? = nil
    public var cursorCapture: CursorCaptureMethod? = nil
    public var lockWindowWhenCaptured: Bool? = nil
    public var recoverInputOnFocus: Bool? = nil
    public var windowsVersion: WindowsVersion? = nil
    public var steamOverlay: OverlayMode = .automatic
    public var disabledPlugins: [String] = []
    public var autoFallback: Bool = true
    public var portMappings: [PortMapping] = []
    public var isGame: Bool? = nil
    /// Experimental: a display of its own (resolution and, for Unity games, the monitor it starts on). nil: the layer's.
    public var displayID: String? = nil

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        backendOverride = c.value(.backendOverride, default: d.backendOverride)
        runtimeOverride = c.value(.runtimeOverride, default: d.runtimeOverride)
        extraArguments = c.value(.extraArguments, default: d.extraArguments)
        environment = c.value(.environment, default: d.environment)
        scrollMode = c.value(.scrollMode, default: d.scrollMode)
        highResolution = c.value(.highResolution, default: d.highResolution)
        captureDisplays = c.value(.captureDisplays, default: d.captureDisplays)
        nativeResolution = c.value(.nativeResolution, default: d.nativeResolution)
        startFullscreen = c.value(.startFullscreen, default: d.startFullscreen)
        mouseWarp = c.value(.mouseWarp, default: d.mouseWarp)
        cursorCapture = c.value(.cursorCapture, default: d.cursorCapture)
        lockWindowWhenCaptured = c.value(.lockWindowWhenCaptured, default: d.lockWindowWhenCaptured)
        recoverInputOnFocus = c.value(.recoverInputOnFocus, default: d.recoverInputOnFocus)
        windowsVersion = c.value(.windowsVersion, default: d.windowsVersion)
        steamOverlay = c.value(.steamOverlay, default: d.steamOverlay)
        disabledPlugins = c.value(.disabledPlugins, default: d.disabledPlugins)
        autoFallback = c.value(.autoFallback, default: d.autoFallback)
        portMappings = c.value(.portMappings, default: d.portMappings)
        isGame = c.value(.isGame, default: d.isGame)
        displayID = c.value(.displayID, default: d.displayID)
    }
}

/// What Cell learned from previous launches.
public struct LearnedCompat: Codable, Hashable, Sendable {
    public var workingBackend: GraphicsBackend?
    public var workingRuntimeID: String?
    /// Backends that crashed on start, on any engine (kept for display).
    public var failedBackends: [GraphicsBackend] = []
    /// "runtimeID|backend" pairs that crashed on start.
    public var failedCombinations: [String] = []
    public var lastBackend: GraphicsBackend?
    public var lastExitCode: Int32?
    public var lastSessionLength: TimeInterval?
    public var updatedAt: Date?
    /// The game failed to apply its own resolution choice (Unity's "Unable to apply requested ExclusiveFullScreen
    /// resolution": The Rewinder wants a 16:9 mode a Mac screen doesn't have): Cell resets that choice to borderless
    /// fullscreen at full resolution (GameDisplayFixer.unityEdits).
    public var needsDisplayModes: Bool = false
    /// A Steam game that doesn't start on its own: Cell starts it through Steam.
    public var startsOnlyThroughSteam: Bool = false
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workingBackend = c.value(.workingBackend, default: nil)
        workingRuntimeID = c.value(.workingRuntimeID, default: nil)
        failedBackends = c.value(.failedBackends, default: [])
        failedCombinations = c.value(.failedCombinations, default: [])
        lastBackend = c.value(.lastBackend, default: nil)
        lastExitCode = c.value(.lastExitCode, default: nil)
        lastSessionLength = c.value(.lastSessionLength, default: nil)
        updatedAt = c.value(.updatedAt, default: nil)
        needsDisplayModes = c.value(.needsDisplayModes, default: false)
        startsOnlyThroughSteam = c.value(.startsOnlyThroughSteam, default: false)
    }

    /// Backends that crashed with this engine.
    public func failedBackends(on runtimeID: String) -> [GraphicsBackend] {
        failedCombinations.compactMap { combination in
            let parts = combination.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[0] == runtimeID ? GraphicsBackend(rawValue: parts[1]) : nil
        }
    }

    /// Engines on which every tried backend crashed.
    public func failedRuntimes(candidates: [String: Int]) -> Set<String> {
        Set(candidates.filter { failedBackends(on: $0.key).count >= $0.value }.map(\.key))
    }
}

/// Facts read from the executable and its folder.
public struct AppAnalysis: Codable, Hashable, Sendable {
    public var analyzedAt: Date
    public var executableSize: Int64?
    public var architecture: PEArchitecture
    public var isGUI: Bool
    public var graphicsAPIs: Set<GraphicsAPI>
    public var engine: EngineKind?
    public var engineVersion: String?
    /// Ships the D3D12 Agility SDK (a `D3D12` folder next to the exe).
    public var hasD3D12AgilitySDK: Bool
    public var productName: String?
    public var companyName: String?
    public var fileDescription: String?
    public var fileVersion: String?
    public var antiCheat: [String]
    public var isDotNet: Bool
    public var isInstaller: Bool
    public var steamAppID: String?
    public var unityCompany: String?
    public var unityProduct: String?
    public var unrealProject: String?
    /// The executable that was really analysed (e.g. the Unreal `-Shipping.exe` behind a stub).
    public var analyzedExecutable: String?
    public var notes: [String]
    /// Which version of the analyzer produced this (nil: before revisions); older analyses are redone.
    public var revision: Int?
    /// The executable's manifest declares it DPI-aware (nil: not read yet). Unaware games are drawn at half the
    /// Retina resolution and stretched unless Cell marks them DPI-aware (see `LaunchPlanner.drawsAtFullPixels`).
    public var declaresDPIAwareness: Bool?
    /// Chromium-based helper programs in the app's folder (file names), e.g. QQ Music's qmbrowser.exe that draws its
    /// pages. They scale themselves when allowed, so Cell marks them DPI-aware (otherwise their pages look blurry).
    public var chromiumHelpers: [String]?

    public init(architecture: PEArchitecture = .unknown) {
        analyzedAt = Date()
        self.architecture = architecture
        isGUI = true
        graphicsAPIs = []
        hasD3D12AgilitySDK = false
        antiCheat = []
        isDotNet = false
        isInstaller = false
        notes = []
    }

    public var primaryAPI: GraphicsAPI? {
        let d3d: [GraphicsAPI] = [.d3d12, .d3d11, .d3d10, .d3d9, .d3d8, .ddraw]
        if hasD3D12AgilitySDK || graphicsAPIs.contains(.d3d12) {
            return graphicsAPIs.contains(.d3d11) ? .d3d11 : .d3d12
        }
        return d3d.first { graphicsAPIs.contains($0) } ?? (graphicsAPIs.contains(.vulkan) ? .vulkan : (graphicsAPIs.contains(.opengl) ? .opengl : nil))
    }

    public var engineDescription: String? {
        guard let engine, engine != .unknown else { return nil }
        if let engineVersion, !engineVersion.isEmpty { return "\(engine.displayName) \(engineVersion)" }
        return engine.displayName
    }
}
