import Foundation

/// Builds the environment for Wine processes.
public enum WineEnvironment {
    /// Variables that must never leak from Cell's own environment into Wine.
    static let blockedPrefixes = ["DYLD_", "WINE", "LC_", "DXMT_", "D3DM_", "MTL_HUD"]

    /// Cell's environment without anything that could change how Wine behaves.
    static func cleanBase() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !blockedPrefixes.contains { key.hasPrefix($0) } && key != "LANG"
        }
    }

    /// Where the engine finds the libraries it bundles (MoltenVK, FreeType, GnuTLS, GStreamer, D3DMetal).
    static func libraryEnvironment(runtime: WineRuntime, flavorRoot: URL) -> [String: String] {
        var libraryPaths = [flavorRoot.appendingPathComponent("lib").path, flavorRoot.appendingPathComponent("lib/external").path]
        libraryPaths += runtime.extraLibraryPaths.map { runtime.directory.appendingPathComponent($0).path }
        libraryPaths += ["/usr/lib", "/usr/local/lib"]
        var frameworkPaths = runtime.extraFrameworkPaths.map { runtime.directory.appendingPathComponent($0).path }
        frameworkPaths += [flavorRoot.appendingPathComponent("lib/external").path, "/Library/Frameworks", "/System/Library/Frameworks"]
        var env: [String: String] = [:]
        // GStreamer (Wine plays videos through it: Media Foundation, DirectShow). Wine's bridge looks for its libraries
        // beside itself or in the search path, and the engine keeps them inside GStreamer.framework: without this every
        // in-game video failed ("Unsupported demuxer") — Poppy Playtime's title screen stayed white.
        if let gstreamer = gstreamerFolder(runtime: runtime) {
            libraryPaths.insert(gstreamer.appendingPathComponent("lib").path, at: libraryPaths.count - 2)
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = gstreamer.appendingPathComponent("lib/gstreamer-1.0").path
            env["GST_PLUGIN_SCANNER_1_0"] = gstreamer.appendingPathComponent("libexec/gstreamer-1.0/gst-plugin-scanner").path
            env["GST_REGISTRY_1_0"] = CellPaths.caches.appendingPathComponent("gstreamer-\(runtime.id).bin").path
        }
        env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        env["DYLD_FALLBACK_FRAMEWORK_PATH"] = frameworkPaths.joined(separator: ":")
        return env
    }

    /// `GStreamer.framework/Versions/1.0` bundled with an engine (Sikarugir: next to Wine; Gcenx: in Wine's lib).
    static func gstreamerFolder(runtime: WineRuntime) -> URL? {
        let candidates = [runtime.directory.appendingPathComponent("Frameworks/GStreamer.framework/Versions/1.0"),
                          runtime.wineRoot.appendingPathComponent("lib/GStreamer.framework/Versions/1.0")]
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("lib/gstreamer-1.0").path) }
    }

    public static func build(container: Container, runtime: WineRuntime, flavorRoot: URL, backend: GraphicsBackend?,
                             fixes: ResolvedFixes?, app: AppEntry?, dllOverrides: [String: String]) -> [String: String] {
        var env = cleanBase()
        let settings = container.settings
        env["WINEPREFIX"] = container.prefixURL.path
        // Imported bottles keep their Windows user (profile folder), e.g. "Wineskin" or "crossover".
        if let user = settings.windowsUserName, !user.isEmpty {
            env["USER"] = user
            env["LOGNAME"] = user
        }
        // Message box texts are always logged, so Cell can show what a game says even when its dialog is
        // hidden behind fullscreen or drawn without text (see WineMessageBoxes).
        env["WINEDEBUG"] = settings.debugLogging ? "err+all,warn+module,warn+seh,fixme-all,trace+msgbox" : "-all,trace+msgbox"

        // Sync primitives: one mode per prefix (wineserver and clients must agree).
        switch settings.syncMode {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }

        for (key, value) in libraryEnvironment(runtime: runtime, flavorRoot: flavorRoot) { env[key] = value }
        // Each Windows program shows its own name in the Dock instead of "wine" (see DockNames).
        for (key, value) in DockNames.environment(for: container) { env[key] = value }
        env["CELL_WINE_ENGINE_ID"] = runtime.id
        env["CELL_STEAM_COMPAT_ROUTES"] = ProgramSettings.compatibilityURL(for: container).path
        env["CELL_STEAM_COMPAT_HELPER"] = CellPaths.cliExecutable()?.path

        // Language. Wine takes the user locale (what programs show) from LC_MESSAGES and the system locale
        // (the ANSI code page typed text passes through) from LC_CTYPE. Keeping them apart lets programs stay
        // in English while typing Chinese in Steam works instead of turning into "???".
        let display = LanguageResolver.resolve(settings.language).language
        let text = LanguageResolver.textLanguage(for: settings.language).language
        if let locale = display.localeIdentifier {
            env["LANG"] = locale
            env["LC_MESSAGES"] = locale
        }
        if let locale = text.localeIdentifier ?? display.localeIdentifier {
            env["LC_CTYPE"] = locale
        }

        // Graphics.
        if settings.metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        for (key, value) in backendEnvironment(settings: settings, backend: backend) { env[key] = value }

        // DLL overrides passed in the environment apply to this process and its children.
        var overrides = ["winemenubuilder.exe": "d"]
        for (dll, mode) in settings.dllOverrides { overrides[dll] = mode }
        for (dll, mode) in dllOverrides { overrides[dll] = mode }
        env["WINEDLLOVERRIDES"] = overrides.keys.sorted().map { "\($0)=\(overrides[$0]!.isEmpty ? "d" : overrides[$0]!)" }.joined(separator: ";")

        // Web views (Microsoft Edge WebView2) draw in their own process without the GPU process (see WebView2).
        env["WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"] = WebView2.browserArguments
        // .NET 5+ programs (Stardew Valley…) take text rules from Windows' NLS, which Wine has, instead of an ICU
        // library: installers leave foreign icu.dll copies in system32, and .NET stopped at "Could not load ICU data".
        env["DOTNET_SYSTEM_GLOBALIZATION_USENLS"] = "1"

        // User and plugin variables come last so they can override anything above.
        for (key, value) in settings.environment { env[key] = value }
        if let backend, let fixes { for (key, value) in fixes.environment(for: backend) { env[key] = value } }
        for (key, value) in app?.settings.environment ?? [:] { env[key] = value }
        env["CELL_FOCUS_RECOVERY"] = "0"
        env["CELL_REPLAY_MAC_FOCUS"] = runtime.canReplayMacFocus ? "1" : "0"
        env.removeValue(forKey: "CELL_SIMS_DISPLAY_OPTIONS")
        if let app, let program = app.windowsPath.flatMap(ProgramSettings.programName) {
            env.merge(ProgramSettings.focusRecoveryVariables(for: app, fixes: fixes, program: program)) { _, new in new }
            env.merge(ProgramSettings.fullscreenVariables(for: app, in: container, fixes: fixes, program: program)) { _, new in new }
            for (key, value) in ProgramSettings.gameHotkeyVariables(for: app, program: program) { env[key] = value }
            env.merge(ProgramSettings.simsDisplayVariables(for: app, container: container, fixes: fixes, program: program)) { _, new in new }
            env.merge(PluginKeyMappings.environment(fixes?.keyMappings ?? [:], program: program)) { _, new in new }
        }
        if let appID = app?.steamAppID ?? app?.analysis?.steamAppID, app?.kind == .windowsExecutable {
            env["SteamAppId"] = appID
            env["SteamGameId"] = appID
        }
        return env
    }
}


extension WineEnvironment {
    /// Variables a graphics engine reads (DXMT's frame limit and MetalFX, D3DMetal's MetalFX and ray tracing).
    static let vulkanGPUVariable = "CELL_VULKAN_GPU"

    static func backendEnvironment(settings: ContainerSettings, backend: GraphicsBackend?) -> [String: String] {
        var env: [String: String] = [:]
        if backend == .dxmt {
            var config: [String] = []
            if settings.frameRateLimit > 0 { config.append("d3d11.preferredMaxFrameRate=\(settings.frameRateLimit)") }
            if settings.metalFXUpscaling {
                env["DXMT_METALFX_SPATIAL_SWAPCHAIN"] = "1"
                config.append("d3d11.metalSpatialUpscaleFactor=\(String(format: "%.2f", min(max(settings.metalFXScale, 1.0), 2.0)))")
            }
            if !config.isEmpty { env["DXMT_CONFIG"] = config.joined(separator: ";") + ";" }
        }
        if backend == .d3dmetal {
            if settings.metalFXUpscaling { env["D3DM_ENABLE_METALFX"] = "1" }
            if settings.rayTracing { env["D3DM_SUPPORT_DXR"] = "1" }
        }
        // Vulkan games see the Mac's GPU as the AMD card D3DMetal shows DirectX games (Cell's helper, see
        // Tools/dock-name): Windows games don't know Apple GPUs. DXVK keeps Apple's IDs (it has its own vendor rules).
        env[vulkanGPUVariable] = backend == .dxvk ? "apple" : "windows"
        return env
    }
}

/// Runs Wine tools (wineboot, regedit, wineserver) for a container.
public enum WineCommands {
    public static func loader(runtime: WineRuntime, flavorRoot: URL? = nil) -> URL {
        (flavorRoot ?? runtime.wineRoot).appendingPathComponent(runtime.loaderRelativePath)
    }

    public static func wineserver(runtime: WineRuntime) -> URL {
        runtime.wineRoot.appendingPathComponent("bin/wineserver")
    }

    static func toolEnvironment(container: Container, runtime: WineRuntime, extra: [String: String] = [:]) -> [String: String] {
        var env = WineEnvironment.build(container: container, runtime: runtime, flavorRoot: runtime.wineRoot,
                                        backend: nil, fixes: nil, app: nil, dllOverrides: [:])
        if !runtime.hasMono { env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"] ?? "") + ";mscoree=d" }
        if !runtime.hasGecko { env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"] ?? "") + ";mshtml=d" }
        for (key, value) in extra { env[key] = value }
        return env
    }

    @discardableResult
    public static func run(_ arguments: [String], container: Container, runtime: WineRuntime,
                           extraEnvironment: [String: String] = [:], timeout: TimeInterval = 600) async throws -> ProcessResult {
        prepareSession(container: container)
        return try await ProcessRunner.runAsync(loader(runtime: runtime), arguments: arguments,
                                         environment: toolEnvironment(container: container, runtime: runtime, extra: extraEnvironment),
                                         currentDirectory: container.prefixURL, timeout: timeout)
    }

    /// Creates the prefix (first run takes a while: Wine builds the Windows folder and registry).
    public static func initializePrefix(container: Container, runtime: WineRuntime) async throws {
        try FileManager.default.createDirectory(at: container.prefixURL, withIntermediateDirectories: true)
        let result = try await run(["wineboot", "--init"], container: container, runtime: runtime, timeout: 900)
        _ = try? await waitForServer(container: container, runtime: runtime, timeout: 120)
        guard FileManager.default.fileExists(atPath: container.prefixURL.appendingPathComponent("system.reg").path) else {
            throw ProcessRunnerError.failed("wineboot", result)
        }
    }

    /// Brings an existing prefix up to date after switching engines.
    public static func updatePrefix(container: Container, runtime: WineRuntime) async throws {
        try await run(["wineboot", "--update"], container: container, runtime: runtime, timeout: 900)
        _ = try? await waitForServer(container: container, runtime: runtime, timeout: 120)
    }

    /// Imports registry edits through `regedit /S` (Wine's GUI regedit is never shown).
    public static func applyRegistry(_ edits: [RegistryEdit], container: Container, runtime: WineRuntime) async throws {
        guard !edits.isEmpty else { return }
        let file = container.directory.appendingPathComponent("cell-settings-\(UUID().uuidString).reg")
        defer { try? FileManager.default.removeItem(at: file) }
        try RegFile.data(for: edits).write(to: file, options: .atomic)
        let windowsPath = WinePathMapper(prefix: container.prefixURL).windowsPath(for: file)
        let result = try await run(["regedit", "/S", windowsPath], container: container, runtime: runtime, timeout: 180)
        if !result.succeeded { throw ProcessRunnerError.failed("regedit", result) }
    }

    /// Ends every Windows process in the container: Wine's own way first, then by force whatever is left after a few
    /// seconds (a program hung on exit, a wineserver that doesn't answer, leftovers of an older session).
    public static func killAll(container: Container, runtime: WineRuntime) async {
        if isServerRunning(container: container) {
            _ = try? await ProcessRunner.runAsync(wineserver(runtime: runtime), arguments: ["-k"],
                                                  environment: toolEnvironment(container: container, runtime: runtime), timeout: 10)
        }
        for _ in 0..<10 {
            if WineProcessScanner.sessionProcesses(of: container).isEmpty { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        WineProcessScanner.forceEnd(container)
    }

    /// The folder of the container's wineserver (`/tmp/.wine-<uid>/server-<device>-<inode>`), named after the prefix.
    static func serverDirectory(for container: Container) -> String? {
        var info = stat()
        guard stat(container.prefixURL.path, &info) == 0 else { return nil }
        let dev = String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16)
        let ino = String(UInt64(info.st_ino), radix: 16)
        return "/tmp/.wine-\(getuid())/server-\(dev)-\(ino)"
    }

    /// Waits until the container's wineserver has exited (flushes the registry to disk).
    public static func waitForServer(container: Container, runtime: WineRuntime, timeout: TimeInterval) async throws -> ProcessResult {
        try await ProcessRunner.runAsync(wineserver(runtime: runtime), arguments: ["-w"],
                                         environment: toolEnvironment(container: container, runtime: runtime), timeout: timeout)
    }

    /// Starts a persistent wineserver so following launches skip Wine's start-up cost.
    public static func warmUp(container: Container, runtime: WineRuntime, seconds: Int = 300) {
        guard !isServerRunning(container: container) else { return }
        // The session starts here: what has to happen before it does (start-up entries) happens now.
        prepareSession(container: container)
        _ = try? ProcessRunner.run(wineserver(runtime: runtime), arguments: ["-p\(seconds)"],
                                   environment: toolEnvironment(container: container, runtime: runtime), timeout: 10)
    }

    /// Whether the container's wineserver runs. Its socket alone doesn't tell: a wineserver ended by force leaves it
    /// behind, and Cell then took every later launch for one into a running session (it skipped preparing them: old
    /// font links stayed and Steam showed no window). A running wineserver holds a lock on the folder's "lock" file
    /// for as long as it runs (Wine's own test), so that decides.
    public static func isServerRunning(container: Container) -> Bool {
        guard let directory = serverDirectory(for: container),
              FileManager.default.fileExists(atPath: directory + "/socket") else { return false }
        return serverHoldsLock(directory + "/lock")
    }

    /// Whether some process holds the write lock wineserver takes on byte 0 of its lock file. When the file can't be
    /// checked, the socket's word counts (running).
    static func serverHoldsLock(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 1
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return true }
        return lock.l_type != Int16(F_UNLCK)
    }
}
