import Foundation

/// A self-contained translation layer with its own Wine prefix.
public struct Container: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var platform: PlatformKind
    /// Wine engine used by this container (Windows only).
    public var runtimeID: String?
    public var settings: ContainerSettings
    public var createdAt: Date
    public var isDefault: Bool
    /// Engine that initialised the prefix; switching engines triggers a prefix update.
    public var initializedRuntimeID: String?
    /// Hash of the registry configuration last written into the prefix.
    public var appliedConfigHash: String?
    /// SF Symbol used in the sidebar.
    public var symbol: String
    /// Prefix this container was cloned from (Porting Kit, CrossOver, Whisky…), to avoid importing twice.
    public var importedFrom: String?

    public init(id: UUID = UUID(), name: String, platform: PlatformKind = .windows, runtimeID: String? = nil,
                settings: ContainerSettings = ContainerSettings(), isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.platform = platform
        self.runtimeID = runtimeID
        self.settings = settings
        self.createdAt = Date()
        self.isDefault = isDefault
        self.symbol = "shippingbox"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "Container")
        // Older Cell releases stored a separate APK library under this platform.
        if c.value(.platform, default: "") == "android" {
            throw DecodingError.dataCorruptedError(forKey: .platform, in: c, debugDescription: "This translation layer is no longer supported.")
        }
        platform = c.value(.platform, default: .windows)
        runtimeID = c.value(.runtimeID, default: nil)
        settings = c.value(.settings, default: ContainerSettings())
        createdAt = c.value(.createdAt, default: Date())
        isDefault = c.value(.isDefault, default: false)
        initializedRuntimeID = c.value(.initializedRuntimeID, default: nil)
        appliedConfigHash = c.value(.appliedConfigHash, default: nil)
        symbol = c.value(.symbol, default: "shippingbox")
        importedFrom = c.value(.importedFrom, default: nil)
    }

    public var directory: URL { CellPaths.containers.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// The Wine prefix for this container.
    public var prefixURL: URL { directory.appendingPathComponent("prefix", isDirectory: true) }
    public var driveC: URL { prefixURL.appendingPathComponent("drive_c", isDirectory: true) }
    public var metadataURL: URL { directory.appendingPathComponent("container.json") }
    public var appsURL: URL { directory.appendingPathComponent("apps.json") }
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var logsDirectory: URL { CellPaths.logs.appendingPathComponent(id.uuidString, isDirectory: true) }
    public var isInitialized: Bool {
        platform == .windows && FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("system.reg").path)
    }
}

/// Per-container settings with Mac-friendly defaults.
public struct ContainerSettings: Codable, Hashable, Sendable {
    // Compatibility
    public var windowsVersion: WindowsVersion = .win10

    // Display
    /// Wine "RetinaMode": render at full pixel resolution instead of half.
    public var highResolution: Bool = true
    public var dpiMode: DPIMode = .automatic
    public var customDPI: Int = 144
    /// Fullscreen games lock the whole display (Wine's "capture"). Off: Mission Control, Cmd-Tab, trackpad
    /// gestures and the Dock keep working while a game is fullscreen. (Replaces `captureDisplaysInFullscreen`,
    /// which used to be on by default and is ignored now.)
    public var fullscreenLocksDisplay: Bool = false
    /// Games that switch the screen resolution get a virtual display mode (Wine's EmulateModeset): the Mac's
    /// display never changes mode, so there's no flicker and no wrongly sized windows when switching away.
    /// Experimental, off: a game that asks for another screen resolution gets a pretend one and is stretched.
    /// It kept the Mac's own display mode, but the Mac driver then reports mouse positions wrongly, so buttons in
    /// games that run at a low resolution (Undertale, RPG Maker and GameMaker games) couldn't be clicked.
    /// (Named `emulateModeChanges` and on by default before: the new name leaves that saved value behind.)
    public var virtualDisplayModes: Bool = false
    /// Before a game starts, set Unreal and Unity games to the display's full resolution, borderless fullscreen
    /// and 100% 3D resolution. Quality settings stay as they are.
    public var nativeGameResolution: Bool = true
    public var startGamesFullscreen: Bool = true
    /// Experimental: the display this layer's games are set up for (its resolution and sharpness), by display ID.
    /// nil: the main display (the one with the menu bar, where Windows programs open).
    public var displayID: String? = nil

    // Input
    public var commandAsControl: Bool = true
    public var optionAsAlt: Bool = true
    public var scrollMode: ScrollMode = .automatic
    public var mouseWarp: MouseWarpMode = .automatic

    // Performance
    public var syncMode: SyncMode = .msync
    /// Keeps wineserver alive for a few minutes after the last app quits, for faster launches.
    public var keepEngineWarm: Bool = true
    /// Lets Rosetta report AVX/AVX2 to games that require it.
    public var advertiseAVX: Bool = true

    // Graphics
    /// nil = Autopilot.
    public var preferredBackend: GraphicsBackend? = nil
    public var metalHUD: Bool = false
    public var metalFXUpscaling: Bool = false
    /// DXMT spatial upscale factor (1.0–2.0) when MetalFX upscaling is on.
    public var metalFXScale: Double = 1.5
    /// 0 = unlimited.
    public var frameRateLimit: Int = 0
    public var rayTracing: Bool = false

    // Language & fonts
    public var language: ContainerLanguage = .automatic
    public var cjkFontFallbacks: Bool = true

    // Steam
    /// The "Install Steam" card on the layer's page was closed (Install Steam stays in Settings).
    public var hideSteamSuggestion: Bool = false
    public var steamStabilityMode: Bool = true
    public var steamExtraArguments: [String] = []
    public var steamRestartPolicy: SteamRestartPolicy = .automatic

    // Network
    public var mapPortsWhilePlaying: Bool = false
    public var hostRewrites = HostRewrites()

    // Advanced
    public var environment: [String: String] = [:]
    public var dllOverrides: [String: String] = [:]
    public var debugLogging: Bool = false
    /// Windows user (profile folder) for imported bottles, e.g. "Wineskin" or "crossover". nil = your Mac user name.
    public var windowsUserName: String? = nil

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContainerSettings()
        windowsVersion = c.value(.windowsVersion, default: d.windowsVersion)
        highResolution = c.value(.highResolution, default: d.highResolution)
        dpiMode = c.value(.dpiMode, default: d.dpiMode)
        customDPI = c.value(.customDPI, default: d.customDPI)
        fullscreenLocksDisplay = c.value(.fullscreenLocksDisplay, default: d.fullscreenLocksDisplay)
        virtualDisplayModes = c.value(.virtualDisplayModes, default: d.virtualDisplayModes)
        nativeGameResolution = c.value(.nativeGameResolution, default: d.nativeGameResolution)
        startGamesFullscreen = c.value(.startGamesFullscreen, default: d.startGamesFullscreen)
        displayID = c.value(.displayID, default: d.displayID)
        commandAsControl = c.value(.commandAsControl, default: d.commandAsControl)
        optionAsAlt = c.value(.optionAsAlt, default: d.optionAsAlt)
        scrollMode = c.value(.scrollMode, default: d.scrollMode)
        mouseWarp = c.value(.mouseWarp, default: d.mouseWarp)
        syncMode = c.value(.syncMode, default: d.syncMode)
        keepEngineWarm = c.value(.keepEngineWarm, default: d.keepEngineWarm)
        advertiseAVX = c.value(.advertiseAVX, default: d.advertiseAVX)
        preferredBackend = c.value(.preferredBackend, default: d.preferredBackend)
        metalHUD = c.value(.metalHUD, default: d.metalHUD)
        metalFXUpscaling = c.value(.metalFXUpscaling, default: d.metalFXUpscaling)
        metalFXScale = c.value(.metalFXScale, default: d.metalFXScale)
        frameRateLimit = c.value(.frameRateLimit, default: d.frameRateLimit)
        rayTracing = c.value(.rayTracing, default: d.rayTracing)
        language = c.value(.language, default: d.language)
        cjkFontFallbacks = c.value(.cjkFontFallbacks, default: d.cjkFontFallbacks)
        hideSteamSuggestion = c.value(.hideSteamSuggestion, default: d.hideSteamSuggestion)
        steamStabilityMode = c.value(.steamStabilityMode, default: d.steamStabilityMode)
        steamExtraArguments = c.value(.steamExtraArguments, default: d.steamExtraArguments)
        steamRestartPolicy = c.value(.steamRestartPolicy, default: d.steamRestartPolicy)
        mapPortsWhilePlaying = c.value(.mapPortsWhilePlaying, default: d.mapPortsWhilePlaying)
        hostRewrites = c.value(.hostRewrites, default: d.hostRewrites)
        environment = c.value(.environment, default: d.environment)
        dllOverrides = c.value(.dllOverrides, default: d.dllOverrides)
        debugLogging = c.value(.debugLogging, default: d.debugLogging)
        windowsUserName = c.value(.windowsUserName, default: d.windowsUserName)
    }
}

/// Runtime state that changes while apps run (kept out of container.json).
public struct ContainerState: Codable, Hashable, Sendable {
    /// PID of the Steam client Cell started, and the backend flavor it runs with.
    public var steamPID: Int32?
    public var steamBackend: GraphicsBackend?
    public var steamFlavorKey: String?
    /// Wine engine the container's wineserver currently runs (one engine at a time per container).
    public var activeRuntimeID: String?
    public var steamRuntimeID: String?
    /// Last time Cell checked for (and pre-downloaded) a Steam client update.
    public var lastSteamUpdateCheck: Date?
    /// Engine and graphics engine of the last Steam session (games started from its window ran on them).
    public var lastSteamRuntimeID: String?
    public var lastSteamBackend: GraphicsBackend?
    /// How far Cell has read Steam's game log.
    public var steamGameLogOffset: UInt64?
    public init() {}
}
