import Foundation

public struct LaunchOutcome: Sendable {
    public var appID: UUID
    public var backend: GraphicsBackend
    public var exitCode: Int32
    public var duration: TimeInterval
    public var crashedEarly: Bool
    public var logURL: URL?
    public var findings: [DiagnosticFinding]
    /// Set when Cell automatically relaunched with another engine.
    public var retryBackend: GraphicsBackend?
    /// The process only handed the request to an already running Steam.
    public var wasHandoff: Bool
    /// A Steam game started without Steam quit at once while the Steam Cell started for it was still coming up:
    /// it gets started again once Steam is ready.
    public var waitsForSteam: Bool = false
}

/// A running app started by Cell.
public final class RunningSession: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let plan: LaunchPlan
    public let process: Process
    public let logURL: URL
    public let startedAt = Date()
    public let attempt: Int
    public let isHandoff: Bool
    let portMapper: PortMapper?
    /// Cell started Steam in the background for this game (it wasn't running).
    var startedSteam = false

    init(plan: LaunchPlan, process: Process, logURL: URL, attempt: Int, isHandoff: Bool, portMapper: PortMapper?) {
        self.plan = plan
        self.process = process
        self.logURL = logURL
        self.attempt = attempt
        self.isHandoff = isHandoff
        self.portMapper = portMapper
    }

    public var appID: UUID { plan.app.id }
    public var isRunning: Bool { process.isRunning }

    /// You quit it (from Cell): its end is not a crash and nothing starts it again.
    public private(set) var stopRequested = false

    public func recordStopRequest() {
        stopRequested = true
    }

    public func terminate() {
        recordStopRequest()
        guard process.isRunning else { return }
        process.terminate()
    }
}

/// Prepares containers, starts processes, watches them, learns which engine works and falls back on crashes.
public final class Launcher: @unchecked Sendable {
    unowned let services: CellServices
    public static let earlyCrashWindow: TimeInterval = 20
    public static let knownGoodAfter: TimeInterval = 60
    public static let maximumAttempts = 4
    private static let steamProcesses: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "steamservice.exe", "gameoverlayui.exe", "gameoverlayui64.exe"
    ]

    init(services: CellServices) { self.services = services }

    public typealias StatusHandler = @Sendable (String) -> Void
    public typealias ExitHandler = @Sendable (LaunchOutcome, RunningSession?) -> Void

    /// Plans, prepares and starts an app. `onExit` fires when it quits (and again for automatic retries).
    @discardableResult
    public func launch(appID: UUID, forcedBackend: GraphicsBackend? = nil, forcedRuntime: String? = nil, attempt: Int = 1,
                       throughSteam: Bool = true, requiredWineVersion: String? = nil,
                       status: StatusHandler? = nil, onExit: ExitHandler? = nil) async throws -> RunningSession {
        guard var app = services.library.app(id: appID) else { throw LaunchError.missingExecutable("app") }
        guard let container = services.library.container(id: app.containerID) else { throw LaunchError.containerMissing }
        if AppAnalyzer.needsRefresh(app, in: container), let refreshed = try services.refreshAnalysis(for: app) { app = refreshed }
        if container.runtimeID == nil, let recommended = services.runtimes.recommendedRuntime {
            var updated = container
            updated.runtimeID = recommended.id
            try services.library.save(updated)
        }
        let current = services.library.container(id: app.containerID) ?? container
        if app.kind == .steamClient || app.kind == .steamGame { learnFromSteamGameLog(container: current) }
        updateDockNames(for: current)
        learnFromGameLog(app, container: current)
        // .NET was installed without Microsoft's loader: no .NET program starts, and installers that use .NET for
        // their steps fail (Visual C++ and Unreal's prerequisites). Fix it before anything else runs.
        if CellServices.dotNetNeedsRepair(current) {
            status?("Repairing .NET Framework…")
            try? await services.installDotNetFramework(in: current, status: status)
        }
        // Games built with Visual C++ need Microsoft's runtime files, not Wine's stand-ins (see visualCppNeedsInstall).
        await services.repairVisualCppIfNeeded(in: current, status: status)
        status?("Choosing graphics engine…")
        var plan = try services.planner.plan(app: services.library.app(id: appID) ?? app, container: current, forcedBackend: forcedBackend,
                                             forcedRuntime: forcedRuntime, throughSteam: throughSteam)
        // An engine pair is checked once before its first use (a few seconds, nothing appears on screen), so a
        // pair that can't draw is never used — that is what made games crash right at start.
        for _ in 0..<3 {
            guard !isHandoffToRunningSteam(plan), services.verifier.checkableBackends(for: plan.runtime).contains(plan.decision.backend),
                  services.verifier.check(runtime: plan.runtime, backend: plan.decision.backend) == nil else { break }
            status?("Checking \(plan.decision.backend.displayName) on \(plan.runtime.shortName) (only the first time)…")
            await services.verifier.verify(runtime: plan.runtime, status: nil)
            let refreshed = services.library.container(id: app.containerID) ?? current
            plan = try services.planner.plan(app: services.library.app(id: appID) ?? app, container: refreshed,
                                             forcedBackend: forcedBackend, forcedRuntime: forcedRuntime, throughSteam: throughSteam)
        }
        if let minimum = requiredWineVersion,
           plan.fixes.minimumWineVersion.map({ LooseVersion($0) >= LooseVersion(minimum) }) != true
            || LooseVersion(plan.runtime.version) < LooseVersion(minimum) {
            throw LaunchError.unsupported(plan.app.name, "This Steam launch needs its Cell compatibility profile and Wine \(minimum) or newer. Open the game in the current Cell build to check its engine.")
        }
        try await prepare(plan, status: status)
        let session = try await start(plan, attempt: attempt, status: status)
        watch(session, status: status, onExit: onExit)
        // A Steam game started on its own: Steam comes up quietly behind it when the game talks to Steam (achievements,
        // friends, cloud saves, online play).
        if plan.kind == .direct, plan.app.kind == .steamGame, !steamRuns(in: plan.container),
           let directory = plan.workingDirectory as URL?, SteamIntegration.usesSteamworks(directory) {
            session.startedSteam = true
            Task { await self.startSteamQuietly(in: plan.container) }
        }
        return session
    }

    func steamRuns(in container: Container) -> Bool {
        WineProcessScanner.scan(containers: [container]).contains { $0.executableName == "steam.exe" }
    }

    /// Starts Steam without its window (as it does when Windows starts) for a game that runs without it.
    func startSteamQuietly(in container: Container) async {
        guard let steam = services.library.apps(in: container.id).first(where: { $0.kind == .steamClient }),
              let current = services.library.container(id: container.id) else { return }
        do {
            var plan = try services.planner.plan(app: steam, container: current)
            // Only beside the game, on the Wine engine it runs on (two engines can't share a layer).
            guard plan.runtime.id == services.library.state(for: current).activeRuntimeID else { return }
            if plan.arguments.count > 0, !plan.arguments.contains("-silent") { plan.arguments.insert("-silent", at: 1) }
            let session = try await start(plan, status: nil)
            watch(session, status: nil, onExit: nil)
        } catch {}
    }

    /// Waits until the Steam just started can answer games: its web helper has been up for a few seconds.
    func waitForSteam(in container: Container, timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)
        var helperSince: Date?
        while Date() < deadline {
            let running = WineProcessScanner.scan(containers: [container])
            guard running.contains(where: { $0.executableName == "steam.exe" }) else { return }
            if running.contains(where: { $0.executableName.hasPrefix("steamwebhelper") }) {
                if let since = helperSince, Date().timeIntervalSince(since) > 8 { return }
                if helperSince == nil { helperSince = Date() }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Quits the Steam Cell started for a game once the game is over and nothing else runs.
    func quitSteamIfOnlyItRuns(in container: Container) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let others = WineProcessScanner.scan(containers: [container]).filter { !Self.steamProcesses.contains($0.executableName) }
        if others.isEmpty { await quitSteam(in: container) }
    }

    // MARK: Prepare

    /// Creates or updates the Windows prefix for the container's engine. Returns the saved container.
    @discardableResult
    public func initializeIfNeeded(_ original: Container, runtime: WineRuntime, status: StatusHandler? = nil) async throws -> Container {
        var container = original
        if !container.isInitialized {
            status?("Setting up Windows in “\(container.name)” (first launch takes a minute)…")
            try await WineCommands.initializePrefix(container: container, runtime: runtime)
            container.initializedRuntimeID = runtime.id
            container.appliedConfigHash = nil
            try services.library.save(container)
        } else if container.initializedRuntimeID != runtime.id {
            status?("Updating “\(container.name)” for \(runtime.shortName)…")
            try await WineCommands.updatePrefix(container: container, runtime: runtime)
            container.initializedRuntimeID = runtime.id
            container.appliedConfigHash = nil
            try services.library.save(container)
        }
        return container
    }

    /// Writes the container's settings into its registry when they changed since the last time.
    @discardableResult
    public func applySettingsIfNeeded(_ original: Container, runtime: WineRuntime, status: StatusHandler? = nil) async throws -> Container {
        var container = services.library.container(id: original.id) ?? original
        let edits = services.planner.registryConfiguration(for: container)
        let hash = LaunchPlanner.configurationHash(edits)
        // Games write their own display values back (The Rewinder kept "Resolution" = 3, past the end of its list of
        // screen sizes, and stopped at its first page): those fixes go in whenever one is needed, even when Cell's
        // own settings haven't changed since they were last written.
        let gameValues = services.planner.unityResolutionEdits(for: container)
        if container.appliedConfigHash != hash {
            status?("Applying settings…")
            try await WineCommands.applyRegistry(edits, container: container, runtime: runtime)
            container.appliedConfigHash = hash
            try services.library.save(container)
        }
        if !gameValues.isEmpty {
            try await WineCommands.applyRegistry(gameValues, container: container, runtime: runtime)
        }
        return container
    }

    /// Writes changed settings into a container whose Windows programs are already running (usually Steam, left
    /// open from before), through the engine they run on, so games started from Steam's window get them too.
    /// Nothing happens when nothing runs: the next launch applies them.
    public func applySettingsWhileRunning(in container: Container) async {
        guard container.platform == .windows, container.isInitialized, WineCommands.isServerRunning(container: container) else { return }
        let state = services.library.state(for: container)
        guard let runtime = services.runtimes.runtime(id: state.activeRuntimeID ?? state.steamRuntimeID),
              container.initializedRuntimeID == runtime.id else { return }
        _ = try? await applySettingsIfNeeded(container, runtime: runtime)
    }

    /// Games may save an invalid fullscreen size again as they close. Repair that game's
    /// preferences after its process exits, before the next launch from an already-open Steam.
    public func repairDisplayAfterExit(appID: UUID) async {
        guard let app = services.library.app(id: appID), app.analysis?.engine == .unity,
              let container = services.library.container(id: app.containerID),
              let runtime = services.runtimes.runtime(id: services.library.state(for: container).activeRuntimeID
                  ?? services.library.state(for: container).steamRuntimeID),
              WineCommands.isServerRunning(container: container) else { return }
        let running = WineProcessScanner.scan(containers: [container])
        guard !running.contains(where: { WineProcessScanner.belongs($0, to: app) }) else { return }
        learnFromGameLog(app, container: container)
        let edits = services.planner.unityResolutionEdits(for: container, only: appID)
        if !edits.isEmpty { try? await WineCommands.applyRegistry(edits, container: container, runtime: runtime) }
    }

    /// Sets up a container without launching anything ("Set up now", `cell prepare`).
    public func prepareContainer(_ container: Container, status: StatusHandler? = nil) async throws {
        guard container.platform == .windows else { return }
        var target = container
        guard let runtime = services.planner.runtime(for: target) else { throw LaunchError.noRuntime(target.name) }
        if target.runtimeID == nil {
            target.runtimeID = runtime.id
            try services.library.save(target)
        }
        await switchEngineIfNeeded(target, to: runtime, status: status)
        target = try await initializeIfNeeded(target, runtime: runtime, status: status)
        try await applySettingsIfNeeded(target, runtime: runtime, status: status)
    }

    /// One Wine engine runs per container at a time: stop the other engine's processes before switching.
    public func switchEngineIfNeeded(_ container: Container, to runtime: WineRuntime, status: StatusHandler? = nil) async {
        var state = services.library.state(for: container)
        if let active = state.activeRuntimeID, active != runtime.id, WineCommands.isServerRunning(container: container),
           let activeRuntime = services.runtimes.runtime(id: active) {
            status?("Switching “\(container.name)” to \(runtime.shortName)…")
            await WineCommands.killAll(container: container, runtime: activeRuntime)
            for _ in 0..<20 where WineCommands.isServerRunning(container: container) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            state.steamPID = nil
            state.steamFlavorKey = nil
            state.steamBackend = nil
            state.steamRuntimeID = nil
        }
        state.activeRuntimeID = runtime.id
        services.library.saveState(state, for: container)
    }

    static func blocksCompatibilityEngineSwitch(_ process: WineProcess) -> Bool {
        if steamProcesses.contains(process.executableName) { return false }
        // The Service Control Manager starts this daemon even after the EA app or a game has quit.
        // It restarts with the next Wine session. EA's client, installers and games still block the switch.
        return process.executable.caseInsensitiveCompare(
            "C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EABackgroundService.exe"
        ) != .orderedSame
    }

    /// A game that needs a newer Wine engine can restart idle Steam and background services.
    private func prepareCompatibilityEngine(_ plan: LaunchPlan, status: StatusHandler?) async throws {
        let container = plan.container
        guard plan.app.isGame, let active = services.library.state(for: container).activeRuntimeID,
              active != plan.runtime.id,
              WineCommands.isServerRunning(container: container) else { return }
        let updatingFocus = services.runtimes.runtime(id: active).map { plan.runtime.fixesSikarugirFocusCompared(to: $0) } ?? false
        guard plan.fixes.minimumWineVersion != nil || updatingFocus else { return }
        func running() -> [WineProcess] { WineProcessScanner.scan(containers: [container]) }
        let processes = running()
        if let other = processes.first(where: Self.blocksCompatibilityEngineSwitch) {
            throw LaunchError.unsupported(plan.app.name, "Quit \(other.executableName) before launching this game. Its compatibility profile needs \(plan.runtime.shortName).")
        }
        if processes.contains(where: { $0.executableName == "steam.exe" }) {
            status?("Closing Steam to change Wine engines…")
            _ = await requestSteamQuit(in: container)
        }
        func waitingForExit() -> Bool {
            running().contains { Self.steamProcesses.contains($0.executableName) || Self.blocksCompatibilityEngineSwitch($0) }
        }
        for _ in 0..<20 {
            if !waitingForExit() { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard !waitingForExit() else {
            throw LaunchError.unsupported(plan.app.name, "Quit Steam and any other running Windows apps before switching to \(plan.runtime.shortName).")
        }
    }

    public func prepare(_ plan: LaunchPlan, status: StatusHandler? = nil) async throws {
        let runtime = plan.runtime
        let fm = FileManager.default
        try await prepareCompatibilityEngine(plan, status: status)
        await switchEngineIfNeeded(plan.container, to: runtime, status: status)
        var container = try await initializeIfNeeded(plan.container, runtime: runtime, status: status)
        try container.settings.hostRewrites.write(for: container)
        ProgramSettings.write(services.planner.programSettings(for: container, overrides: [plan.app.id: plan.decision.backend]), for: container)

        // Backend files that live in the prefix.
        let system32 = container.driveC.appendingPathComponent("windows/system32")
        let syswow64 = container.driveC.appendingPathComponent("windows/syswow64")
        if plan.decision.backend == .dxmt {
            let libraries = services.planner.graphicsLibraries(for: .dxmt, app: plan.app, runtime: runtime)
                ?? plan.flavorRoot.appendingPathComponent("lib/wine")
            let source = libraries.appendingPathComponent("x86_64-windows/winemetal.dll")
            let target = system32.appendingPathComponent("winemetal.dll")
            if fm.fileExists(atPath: source.path), !sameSize(source, target) { try FileOps.cloneItem(at: source, to: target) }
            let source32 = libraries.appendingPathComponent("i386-windows/winemetal.dll")
            if fm.fileExists(atPath: source32.path), FileOps.isDirectory(syswow64) {
                let target32 = syswow64.appendingPathComponent("winemetal.dll")
                if !sameSize(source32, target32) { try FileOps.cloneItem(at: source32, to: target32) }
            }
        }
        if plan.decision.backend == .dxvk, let dxvk = services.components.best(.dxvk) {
            let marker = system32.appendingPathComponent(".chamber-dxvk")
            if (try? String(contentsOf: marker, encoding: .utf8)) != dxvk.id {
                status?("Installing DXVK into the container…")
                try FileOps.overlay(dxvk.nativeDirectory.appendingPathComponent("x64"), onto: system32)
                let x32 = dxvk.nativeDirectory.appendingPathComponent("x32")
                if FileOps.isDirectory(x32), FileOps.isDirectory(syswow64) { try FileOps.overlay(x32, onto: syswow64) }
                try dxvk.id.write(to: marker, atomically: true, encoding: .utf8)
            }
        }

        // Registry: Mac driver, DPI, fonts, per-app AppDefaults, plugin values. Applied only when changed.
        container = try await applySettingsIfNeeded(container, runtime: runtime, status: status)
        if plan.app.isGame || plan.kind != .direct {
            fixGameDisplays(in: container)
            setUnrealGraphicsAPI(for: plan)
        }

        // Plugin files and INI edits.
        for fix in plan.fixes.fileCopies {
            let context = PathTemplateContext(container: container, app: plan.app, pluginDirectory: fix.plugin.directory)
            let source = fix.plugin.directory.appendingPathComponent(fix.copy.from)
            guard FileOps.isContained(source, in: fix.plugin.directory), let target = context.resolveWritablePath(fix.copy.to) else { continue }
            if fm.fileExists(atPath: target.path) && fix.copy.overwrite != true { continue }
            try FileOps.cloneItem(at: source, to: target)
        }
        for fix in plan.fixes.iniEdits {
            let context = PathTemplateContext(container: container, app: plan.app, pluginDirectory: fix.plugin.directory)
            guard let target = context.resolveWritablePath(fix.edit.file) else { continue }
            var values: [String: String] = [:]
            for (key, value) in fix.edit.set { values[key] = context.expand(value) ?? value }
            _ = try? IniEditor.apply(values, section: fix.edit.section, to: target, create: fix.edit.create ?? false)
        }

        // Plugin devices: a Windows serial port (COM3) reaches a Mac device (dosdevices/com3 → /dev/cu.usbserial-…).
        for (port, pattern) in plan.fixes.serialPorts {
            let folder = (pattern as NSString).deletingLastPathComponent
            let name = (pattern as NSString).lastPathComponent
            guard folder == "/dev", let device = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).sorted()
                    .first(where: { globMatch(name, $0) }) else { continue }
            let link = container.prefixURL.appendingPathComponent("dosdevices/\(port.lowercased())")
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: "\(folder)/\(device)")
        }

        try runScripts(\.preLaunch, plan: plan, status: status)

        if container.settings.keepEngineWarm {
            // Half an hour: starting the next game or Steam again skips Wine's start-up.
            WineCommands.warmUp(container: container, runtime: runtime, seconds: 1800)
        }
    }

    private func sameSize(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber else { return false }
        return sa == sb
    }

    private func runScripts(_ keyPath: KeyPath<PluginScripts, String?>, plan: LaunchPlan, status: StatusHandler?) throws {
        for fix in plan.fixes.scripts {
            guard let relative = fix.scripts[keyPath: keyPath], services.plugins.isTrusted(fix.plugin) else { continue }
            let script = fix.plugin.directory.appendingPathComponent(relative)
            guard FileOps.isContained(script, in: fix.plugin.directory) else { continue }
            status?("Running \(fix.plugin.manifest.name)…")
            var environment = plan.environment
            environment["CELL_PREFIX"] = plan.container.prefixURL.path
            environment["CELL_APP_NAME"] = plan.app.name
            environment["CELL_BACKEND"] = plan.decision.backend.rawValue
            environment["CELL_PLUGIN_DIR"] = fix.plugin.directory.path
            environment["CELL_WINE_LOADER"] = plan.loader.path
            let state = services.plugins.state
            for option in fix.plugin.manifest.options ?? [] {
                let value = state.optionValues[fix.plugin.id]?[option.id] ?? option.defaultValue ?? ""
                environment["CELL_PLUGIN_OPTION_" + option.id.replacingOccurrences(of: "-", with: "_")] = value
            }
            if let gameDirectory = PathTemplateContext(container: plan.container, app: plan.app).gameDirectory {
                environment["CELL_GAME_DIR"] = gameDirectory.path
            }
            _ = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: [script.path], environment: environment,
                                       currentDirectory: fix.plugin.directory, timeout: 120)
        }
    }

    // MARK: Start

    public func start(_ plan: LaunchPlan, attempt: Int = 1, status: StatusHandler? = nil) async throws -> RunningSession {
        EADesktopLinks.shared.watchBeforeLaunch(plan.container)
        let fm = FileManager.default
        try fm.createDirectory(at: plan.container.logsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = plan.container.logsDirectory.appendingPathComponent("\(FileOps.sanitizedFileName(plan.app.name))-\(stamp).log")
        var header = """
        Cell launch log
        App: \(plan.app.name)
        Engine: \(plan.runtime.name) · flavor \(plan.flavorKey)
        Graphics: \(plan.decision.backend.displayName) — \(plan.decision.reason)
        Fallbacks: \(plan.decision.fallbacks.map(\.displayName).joined(separator: ", "))
        Plugins: \(plan.fixes.plugins.map(\.manifest.name).joined(separator: ", "))
        Command: \(plan.commandLine)
        Working directory: \(plan.workingDirectory.path)
        WINEDLLOVERRIDES=\(plan.environment["WINEDLLOVERRIDES"] ?? "")
        LANG=\(plan.environment["LANG"] ?? "")

        """
        for warning in plan.warnings { header += "Warning: \(warning)\n" }
        fm.createFile(atPath: logURL.path, contents: Data((header + "\n").utf8))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        var isHandoff = false
        var steamDirectory: URL?
        if plan.kind == .steamGame || plan.kind == .steamClient {
            isHandoff = try await prepareSteam(for: plan, status: status)
            if !isHandoff, let steam = SteamIntegration.steamDirectory(in: plan.container) {
                steamDirectory = steam
                await prepareSteamClient(steam, container: plan.container, status: status)
            }
        }

        let process = Process()
        process.executableURL = plan.loader
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        status?(plan.kind == .steamGame ? "Starting through Steam…" : "Starting \(plan.app.name)…")
        WineCommands.prepareSession(container: plan.container)
        try process.run()
        try? handle.close()
        WebViewBridge.start(for: plan)

        if !isHandoff, plan.kind != .direct {
            var state = services.library.state(for: plan.container)
            state.steamPID = process.processIdentifier
            state.steamFlavorKey = plan.flavorKey
            state.steamBackend = plan.decision.backend
            state.steamRuntimeID = plan.runtime.id
            state.lastSteamRuntimeID = plan.runtime.id
            state.lastSteamBackend = plan.decision.backend
            services.library.saveState(state, for: plan.container)
        }

        if let steamDirectory, plan.container.settings.steamStabilityMode {
            guardWebHelper(steamDirectory: steamDirectory)
        }

        var portMapper: PortMapper?
        if !plan.ports.isEmpty && (plan.container.settings.mapPortsWhilePlaying || !plan.app.settings.portMappings.isEmpty) {
            portMapper = PortMapper()
            portMapper?.map(plan.ports)
        }
        return RunningSession(plan: plan, process: process, logURL: logURL, attempt: attempt, isHandoff: isHandoff, portMapper: portMapper)
    }

    /// Before Steam starts: faster downloads, the web UI fix, and Steam's own update downloaded at full speed.
    private func prepareSteamClient(_ steam: URL, container: Container, status: StatusHandler?) async {
        SteamClientUpdater.applyDownloadSettings(steamDirectory: steam)
        let others = services.library.containers.filter { $0.id != container.id }.compactMap { SteamIntegration.steamDirectory(in: $0) }
        SteamClientUpdater.shareUpdateHosts(to: steam, from: others)
        var state = services.library.state(for: container)
        if state.lastSteamUpdateCheck.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            status?("Checking for a Steam update…")
            if let report = try? await SteamClientUpdater.prefetch(steamDirectory: steam, timeout: 4, status: status), report.version != nil {
                state = services.library.state(for: container)
                state.lastSteamUpdateCheck = Date()
                services.library.saveState(state, for: container)
            }
        }
        if container.settings.steamStabilityMode {
            SteamWebHelperWrapper.install(steamDirectory: steam)
        } else {
            SteamWebHelperWrapper.uninstall(steamDirectory: steam)
        }
    }

    /// When Steam applies a client update at startup it puts Valve's steamwebhelper.exe back before it
    /// starts it (and restarts itself, so the process Cell started may exit). Watch the first two
    /// minutes and put the launcher back in place right away.
    private func guardWebHelper(steamDirectory: URL) {
        Task.detached(priority: .utility) {
            var seen: [String: (Int64?, Date?)] = [:]
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !SteamWebHelperWrapper.isInstalled(steamDirectory: steamDirectory) else { seen.removeAll(); continue }
                // Only touch Valve's file once Steam has finished writing it (same size and date twice in a row).
                var stable = true
                for folder in SteamWebHelperWrapper.helperDirectories(steamDirectory: steamDirectory) {
                    let helper = folder.appendingPathComponent(SteamWebHelperWrapper.helperName)
                    let attributes = try? FileManager.default.attributesOfItem(atPath: helper.path)
                    let now = ((attributes?[.size] as? NSNumber)?.int64Value, attributes?[.modificationDate] as? Date)
                    if let before = seen[folder.path], before.0 == now.0, before.1 == now.1 { continue }
                    seen[folder.path] = now
                    stable = false
                }
                if stable { SteamWebHelperWrapper.install(steamDirectory: steamDirectory) }
            }
        }
    }

    /// Whether starting `plan` only hands a request to the Steam already running with the same engine flavor.
    func isHandoffToRunningSteam(_ plan: LaunchPlan) -> Bool {
        guard plan.kind != .direct else { return false }
        let state = services.library.state(for: plan.container)
        guard let pid = state.steamPID, ProcessRunner.isAlive(pid) else { return false }
        return plan.kind == .steamClient || state.steamFlavorKey == plan.flavorKey
    }

    /// Keeps the Dock name list (and the library that reads it) current before Wine starts something (DockNames).
    public func updateDockNames(for container: Container) {
        guard container.platform == .windows else { return }
        DockNames.installLibrary()
        DockNames.writeList(for: container, apps: services.library.apps(in: container.id))
        // What each game needs however it starts (Steam's window included): see ProgramSettings.
        ProgramSettings.write(services.planner.programSettings(for: container), for: container)
        services.planner.writeSteamCompatibilityRoutes(for: container)
    }

    /// Sets Unreal games to the display's full resolution and borderless fullscreen before anything that can
    /// start them runs (Cell, or Steam's own window). Unity games get theirs through the registry settings.
    func fixGameDisplays(in container: Container) {
        // Also before a game's first start (its settings folder is made for it).
        let unrealProjects = services.library.apps(in: container.id).filter { $0.analysis?.engine == .unreal }
            .compactMap { GameDisplayFixer.unrealProject(of: $0) }
        GameDisplayFixer.silenceDriverWarning(container: container, projects: unrealProjects)
        guard container.settings.nativeGameResolution else { return }
        let high = container.settings.highResolution
        let apps = services.library.apps(in: container.id)
        let skipped = Set(apps.filter { $0.settings.nativeResolution == false }.compactMap { GameDisplayFixer.unrealProject(of: $0)?.lowercased() })
        // Experimental: games set to a display of their own get its size, the rest the layer's display.
        var own: [String: GameDisplayFixer.Size] = [:]
        for app in apps where app.settings.displayID != nil && app.settings.nativeResolution != false {
            if let project = GameDisplayFixer.unrealProject(of: app)?.lowercased(),
               let size = GameDisplayFixer.targetSize(highResolution: high, display: .resolve(app.settings.displayID)) {
                own[project] = size
            }
        }
        if let size = GameDisplayFixer.targetSize(highResolution: high, display: .resolve(container.settings.displayID)) {
            GameDisplayFixer.applyUnreal(container: container, size: size, skipping: skipped.union(own.keys))
        }
        for (project, size) in own { GameDisplayFixer.applyUnreal(container: container, size: size, only: project) }
    }

    /// Puts the container's games in shape for the graphics engine Steam runs (or last ran) with: full resolution
    /// and, for Unreal games, Direct3D 11 unless that engine is D3DMetal. Cell calls this when it opens, so
    /// games started from an already running Steam's window are covered too.
    public func prepareGames(in container: Container) {
        guard container.platform == .windows, container.isInitialized else { return }
        fixGameDisplays(in: container)
        for app in services.library.apps(in: container.id) where app.analysis?.unityProduct != nil { learnFromGameLog(app, container: container) }
        setUnrealGraphicsAPI(in: container)
    }

    /// What a game's own log tells: a Unity game that wanted an exclusive-fullscreen mode the Mac's screen doesn't
    /// list (The Rewinder wants 16:9) failed to set it, kept a window twice the screen's size and showed only a
    /// corner of itself. Such a game gets Wine's virtual display modes from now on (only it: they put the mouse off
    /// in other games).
    static let missingDisplayMode = "Unable to apply requested ExclusiveFullScreen resolution"

    func learnFromGameLog(_ app: AppEntry, container: Container) {
        guard !app.learned.needsDisplayModes, app.analysis?.unityProduct != nil,
              let path = PathTemplateContext(container: container, app: app).expand("{unityPlayerLog}"),
              let text = LogAnalyzer.tail(of: URL(fileURLWithPath: path), bytes: 200_000), text.contains(Self.missingDisplayMode) else { return }
        _ = try? services.library.update(appID: app.id) { $0.learned.needsDisplayModes = true }
    }

    /// Unreal games get Direct3D 11 whenever they'll run on a graphics engine without good Direct3D 12 (DXMT,
    /// DXVK, WineD3D) — also when started from Steam's window. D3DMetal can use a per-game API recommendation
    /// or the person's explicit renderer argument instead of always restoring the game's Direct3D 12 default.
    func setUnrealGraphicsAPI(for plan: LaunchPlan) {
        setUnrealGraphicsAPI(in: plan.container, override: (plan.app.id, plan.decision.backend))
    }

    private func setUnrealGraphicsAPI(in container: Container, override: (UUID, GraphicsBackend)? = nil) {
        let entries = services.planner.programSettings(for: container)
        for app in services.library.apps(in: container.id) where app.analysis?.engine == .unreal {
            guard let project = GameDisplayFixer.unrealProject(of: app) else { continue }
            let programs = ProgramSettings.programs(of: app)
            let backend = override?.0 == app.id ? override?.1 : entries.first { programs.contains($0.program) }
                .flatMap { $0.variables["CELL_GRAPHICS"].flatMap(GraphicsBackend.init(rawValue:)) }
            guard let backend else { continue }
            let fixes = services.planner.fixes(for: app, container: container)
            let preference = app.settings.environment["CELL_UNREAL_RHI"]
                ?? fixes.environment(for: backend)["CELL_UNREAL_RHI"]
            let force11 = GameDisplayFixer.prefersUnrealDirect3D11(backend: backend,
                arguments: app.launchArguments + app.settings.extraArguments, preference: preference)
            GameDisplayFixer.setUnrealDirect3D11(force11, container: container,
                                                 projects: [project], only: project)
        }
    }

    /// Makes sure the Steam client runs with the game's engine flavor. Returns true when the launch is a
    /// hand-off to an already running Steam (the started process exits right away).
    private func prepareSteam(for plan: LaunchPlan, status: StatusHandler?) async throws -> Bool {
        let state = services.library.state(for: plan.container)
        guard let pid = state.steamPID, ProcessRunner.isAlive(pid) else { return false }
        if plan.kind == .steamClient || state.steamFlavorKey == plan.flavorKey
            || plan.container.settings.steamRestartPolicy == .never {
            return true
        }
        status?("Restarting Steam with \(plan.decision.backend.displayName)…")
        let shutdown = Process()
        shutdown.executableURL = plan.loader
        if let steam = SteamIntegration.steamWindowsPath(in: plan.container) { shutdown.arguments = [steam, "-shutdown"] }
        shutdown.environment = plan.environment
        shutdown.standardOutput = FileHandle.nullDevice
        shutdown.standardError = FileHandle.nullDevice
        try? shutdown.run()
        for _ in 0..<60 where ProcessRunner.isAlive(pid) { try await Task.sleep(nanoseconds: 500_000_000) }
        if ProcessRunner.isAlive(pid) {
            kill(pid, SIGTERM)
            for _ in 0..<10 where ProcessRunner.isAlive(pid) { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        return false
    }

    // MARK: Watch, learn, fall back

    /// The next graphics engine / Wine engine to try after a crash on start, if any.
    public func nextAttempt(after outcome: LaunchOutcome, session: RunningSession) -> (backend: GraphicsBackend?, runtimeID: String)? {
        guard outcome.crashedEarly, session.plan.app.settings.autoFallback, services.settings.autoFallback,
              session.attempt < Self.maximumAttempts else { return nil }
        let plan = session.plan
        let learned = services.library.app(id: plan.app.id)?.learned ?? plan.app.learned
        let failedHere = Set(learned.failedBackends(on: plan.runtime.id))
        if let backend = plan.decision.fallbacks.first(where: { !failedHere.contains($0) }) {
            return (backend, plan.runtime.id)
        }
        // Every graphics engine crashed with this Wine engine: try the next Wine engine — only for games (other
        // programs don't crash because of graphics) and only while nothing else runs here, because switching
        // engines stops everything in the container.
        guard services.planner.drawsItsOwnText(plan.app), WineProcessScanner.scan(containers: [plan.container]).isEmpty else { return nil }
        if let engine = plan.engineFallbacks.first(where: { learned.failedBackends(on: $0).isEmpty }) {
            return (nil, engine)
        }
        return nil
    }

    /// Whether programs from the app's folder still run after its process quit (it was a launcher).
    static func programStillRuns(for plan: LaunchPlan) -> Bool {
        guard let path = plan.app.windowsPath?.lowercased(), let slash = path.lastIndex(of: "\\") else { return false }
        let folder = String(path[..<slash])
        Thread.sleep(forTimeInterval: 1.5)
        return WineProcessScanner.scan(containers: [plan.container]).contains { process in
            let processPath = process.executable.lowercased()
            return processPath.hasPrefix(folder + "\\")
        }
    }

    /// Whether Cell will relaunch automatically after this outcome.
    public func willRetry(after outcome: LaunchOutcome, session: RunningSession) -> Bool {
        nextAttempt(after: outcome, session: session) != nil
    }

    private func watch(_ session: RunningSession, status: StatusHandler?, onExit: ExitHandler?) {
        session.process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let outcome = self.finish(session, exitCode: process.terminationStatus)
            onExit?(outcome, session)
            let plan = session.plan
            if outcome.waitsForSteam {
                status?("Waiting for Steam…")
                Task {
                    await self.waitForSteam(in: plan.container)
                    status?("Starting \(plan.app.name)…")
                    _ = try? await self.launch(appID: session.appID, attempt: session.attempt + 1, status: status, onExit: onExit)
                }
                return
            }
            if session.startedSteam, !outcome.crashedEarly, !session.stopRequested {
                Task { await self.quitSteamIfOnlyItRuns(in: plan.container) }
            }
            if outcome.crashedEarly, plan.app.kind == .steamGame, plan.kind == .direct,
               plan.fixes.preferGameExecutable != true,
               self.nextAttempt(after: outcome, session: session) == nil {
                // Every engine failed when started on its own: let Steam start it the way it knows (last resort).
                status?("Starting \(plan.app.name) through Steam…")
                Task { _ = try? await self.launch(appID: session.appID, attempt: Self.maximumAttempts, throughSteam: true, status: status, onExit: onExit) }
                return
            }
            if let next = self.nextAttempt(after: outcome, session: session) {
                let engineName = self.services.runtimes.runtime(id: next.runtimeID)?.name ?? "another engine"
                status?(next.backend.map { "\(session.plan.decision.backend.displayName) failed — trying \($0.displayName)…" }
                        ?? "Trying \(engineName)…")
                Task {
                    do {
                        _ = try await self.launch(appID: session.appID, forcedBackend: next.backend, forcedRuntime: next.runtimeID,
                                                  attempt: session.attempt + 1, status: status, onExit: onExit)
                    } catch {
                        status?("Could not relaunch: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Records the result of a session and returns what happened.
    @discardableResult
    public func finish(_ session: RunningSession, exitCode: Int32) -> LaunchOutcome {
        if GameHotkey.consumeUserStop(pid: session.process.processIdentifier, since: session.startedAt) {
            session.terminate() // records a requested stop; the process has already ended
        }
        let plan = session.plan
        let duration = Date().timeIntervalSince(session.startedAt)
        let context = PathTemplateContext(container: plan.container, app: services.library.app(id: plan.app.id) ?? plan.app)
        let findings = LogAnalyzer.analyze(launchLog: session.logURL, context: context, extraRules: plan.fixes.diagnostics.map(\.rule))
        // A Steam game that quit at once while the Steam Cell started for it was coming up most likely needed Steam:
        // it starts again when Steam is ready, and its graphics engine isn't blamed.
        let waitsForSteam = session.startedSteam && session.attempt == 1 && duration < Self.earlyCrashWindow && !session.stopRequested
        var crashedEarly = !session.stopRequested && !session.isHandoff && plan.kind == .direct && duration < Self.earlyCrashWindow && exitCode != 0 && !waitsForSteam
        // Not a graphics crash: a launcher that started the real program and quit (its windows still run), or a
        // .NET program missing something in Wine Mono. Another engine wouldn't help, and switching costs a restart.
        if crashedEarly, Self.programStillRuns(for: plan) || findings.contains(where: { $0.id == LogAnalyzer.dotNetGap }) {
            crashedEarly = false
        }
        session.portMapper?.unmapAll()

        let countsAsPlay = !session.isHandoff && plan.kind == .direct
        _ = try? services.library.update(appID: plan.app.id) { app in
            app.lastPlayedAt = session.startedAt
            if countsAsPlay { app.totalPlayTime += duration }
            app.learned.lastBackend = plan.decision.backend
            app.learned.lastExitCode = exitCode
            app.learned.lastSessionLength = duration
            app.learned.updatedAt = Date()
            let combination = "\(plan.runtime.id)|\(plan.decision.backend.rawValue)"
            if crashedEarly {
                if !app.learned.failedBackends.contains(plan.decision.backend) { app.learned.failedBackends.append(plan.decision.backend) }
                if !app.learned.failedCombinations.contains(combination) { app.learned.failedCombinations.append(combination) }
                if app.learned.workingBackend == plan.decision.backend && app.learned.workingRuntimeID == plan.runtime.id {
                    app.learned.workingBackend = nil
                    app.learned.workingRuntimeID = nil
                }

            } // Process lifetime does not establish rendered frames or usable input.
        }
        if !session.isHandoff, plan.kind != .direct {
            var state = services.library.state(for: plan.container)
            if state.steamPID == session.process.processIdentifier {
                state.steamPID = nil
                state.steamFlavorKey = nil
                state.steamBackend = nil
                state.steamRuntimeID = nil
                services.library.saveState(state, for: plan.container)
            }
        }
        try? runScripts(\.postExit, plan: plan, status: nil)

        let next = crashedEarly ? plan.decision.fallbacks.first : nil
        if let app = services.library.app(id: plan.app.id) { learnFromGameLog(app, container: plan.container) }
        return LaunchOutcome(appID: plan.app.id, backend: plan.decision.backend, exitCode: exitCode, duration: duration,
                             crashedEarly: crashedEarly, logURL: session.logURL, findings: findings, retryBackend: next,
                             wasHandoff: session.isHandoff, waitsForSteam: waitsForSteam)
    }

    /// Runs an arbitrary Windows program (installers, tools) in a container. Its output goes to a log in the
    /// container's logs, and `control` can stop it (an installer that hangs no longer blocks Cell for hours).
    @discardableResult
    public func runExecutable(_ url: URL, in container: Container, arguments: [String] = [], extraDllOverrides: String? = nil,
                              status: StatusHandler? = nil, control: RunControl? = nil) async throws -> ProcessResult {
        guard let runtime = services.planner.runtime(for: container) else { throw LaunchError.noRuntime(container.name) }
        var temporary = AppEntry(containerID: container.id, name: url.deletingPathExtension().lastPathComponent,
                                 kind: .windowsExecutable, source: .manual)
        temporary.windowsPath = WinePathMapper(prefix: container.prefixURL).windowsPath(for: url)
        temporary.analysis = AppAnalyzer.analyze(executable: url)
        var target = container
        if target.runtimeID == nil { target.runtimeID = runtime.id; try services.library.save(target) }
        let plan = try services.planner.plan(app: temporary, container: target)
        try await prepare(plan, status: status)
        EADesktopLinks.shared.watchBeforeLaunch(container)
        status?("Running \(url.lastPathComponent)…")
        var args = plan.arguments
        if url.pathExtension.lowercased() == "msi" {
            args = ["msiexec", "/i", temporary.windowsPath!] + arguments
        } else {
            args += arguments
        }
        let fm = FileManager.default
        try fm.createDirectory(at: container.logsDirectory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = container.logsDirectory.appendingPathComponent("Installer \(FileOps.sanitizedFileName(temporary.name))-\(stamp).log")
        let header = "Cell installer log\nProgram: \(url.path)\nEngine: \(plan.runtime.name)\nGraphics: \(plan.decision.backend.displayName)\n\n"
        fm.createFile(atPath: logURL.path, contents: Data(header.utf8))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        defer { try? handle.close() }
        WineCommands.prepareSession(container: container)
        updateDockNames(for: container)

        let process = Process()
        process.executableURL = plan.loader
        process.arguments = args
        var environment = plan.environment
        if let extraDllOverrides { environment["WINEDLLOVERRIDES"] = [environment["WINEDLLOVERRIDES"], extraDllOverrides].compactMap { $0 }.joined(separator: ";") }
        process.environment = environment
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do {
                try process.run()
                control?.attach(process)
                WebViewBridge.start(for: plan)
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        if control?.isStopped == true { throw LaunchError.stopped(url.lastPathComponent) }
        return ProcessResult(status: status, stdout: "", stderr: "")
    }

    public func runPluginAction(_ action: PluginAction, for plugin: InstalledPlugin, in container: Container) async throws -> ProcessResult {
        guard services.plugins.plugins.contains(plugin), plugin.hasScripts, services.plugins.isTrusted(plugin),
              services.plugins.state.isActive(plugin, in: container), plugin.manifest.actions?.contains(action) == true else {
            throw PluginError.invalid("enable this plugin and allow its scripts and programs first")
        }
        let file = plugin.directory.appendingPathComponent(action.file)
        guard FileOps.isContained(file, in: plugin.directory) else { throw PluginError.invalid("action points outside the package") }
        let state = services.plugins.state
        var environment = WineEnvironment.cleanBase()
        environment["WINEPREFIX"] = container.prefixURL.path
        environment["CELL_PREFIX"] = container.prefixURL.path
        environment["CELL_PLUGIN_DIR"] = plugin.directory.path
        for option in plugin.manifest.options ?? [] {
            environment["CELL_PLUGIN_OPTION_" + option.id.replacingOccurrences(of: "-", with: "_")] =
                state.optionValues[plugin.id]?[option.id] ?? option.defaultValue ?? ""
        }
        let arguments = action.arguments ?? []
        if action.runner == "wine" {
            return try await runExecutable(file, in: container, arguments: arguments)
        }
        let actionEnvironment = environment
        return try await Task.detached(priority: .utility) {
            try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), arguments: [file.path] + arguments,
                                  environment: actionEnvironment, currentDirectory: plugin.directory, timeout: 120)
        }.value
    }

    /// Opens a steam:// URL in the container's Steam (e.g. the friends list when the overlay can't open).
    /// Games started from Steam's own window aren't started by Cell, so a crash there is learned from
    /// Steam's game log (`logs/gameprocess_log.txt`): a game that quit with an error within 20 seconds is
    /// marked as failing with the engine and graphics engine Steam ran on, and the next Steam start avoids them.
    func learnFromSteamGameLog(container: Container) {
        guard let steam = SteamIntegration.steamDirectory(in: container) else { return }
        let log = steam.appendingPathComponent("logs/gameprocess_log.txt")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return }
        defer { try? handle.close() }
        var state = services.library.state(for: container)
        let size = (try? handle.seekToEnd()) ?? 0
        var offset = state.steamGameLogOffset ?? 0
        if offset > size { offset = 0 }   // Steam started a new log
        try? handle.seek(toOffset: offset)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        state.steamGameLogOffset = size
        defer { services.library.saveState(state, for: container) }
        guard let runtimeID = state.lastSteamRuntimeID, let runtime = services.runtimes.runtime(id: runtimeID) else { return }
        for crash in Self.earlySteamGameCrashes(in: text) {
            guard let app = services.library.apps(in: container.id).first(where: { $0.steamAppID == crash }) else { continue }
            // The game ran with its own graphics engine (ProgramSettings), not Steam's.
            guard let backend = services.planner.decision(for: app, container: container, runtime: runtime)?.backend else { continue }
            _ = try? services.library.update(appID: app.id) { app in
                let combination = "\(runtimeID)|\(backend.rawValue)"
                if !app.learned.failedCombinations.contains(combination) { app.learned.failedCombinations.append(combination) }
                if !app.learned.failedBackends.contains(backend) { app.learned.failedBackends.append(backend) }
                if app.learned.workingRuntimeID == runtimeID && app.learned.workingBackend == backend {
                    app.learned.workingRuntimeID = nil
                    app.learned.workingBackend = nil
                }
                app.learned.updatedAt = Date()
            }
        }
    }

    /// App IDs whose game process quit with an error code within 20 seconds of starting.
    static func earlySteamGameCrashes(in log: String) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var started: [String: (appID: String, at: Date)] = [:]
        var crashes: [String] = []
        for line in log.split(whereSeparator: \.isNewline) {
            guard line.count > 21, line.hasPrefix("["), let date = formatter.date(from: String(line.dropFirst().prefix(19))) else { continue }
            let words = line.split(separator: " ").map(String.init)
            guard let appIndex = words.firstIndex(of: "AppID"), appIndex + 1 < words.count,
                  let pidIndex = words.firstIndex(of: "PID"), pidIndex + 1 < words.count else { continue }
            let appID = words[appIndex + 1]
            let pid = words[pidIndex + 1].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            if line.contains("adding PID"), line.lowercased().contains(".exe"), !line.contains("UnityCrashHandler") {
                started[pid] = (appID, date)
            } else if line.contains("no longer tracking PID"), let entry = started.removeValue(forKey: pid),
                      let code = words.last.flatMap(Int.init), code != 0, date.timeIntervalSince(entry.at) < 20 {
                if !crashes.contains(entry.appID) { crashes.append(entry.appID) }
            }
        }
        return crashes
    }

    /// The engine whose wineserver currently runs the container (or the one it would use).
    func activeRuntime(for container: Container) -> WineRuntime? {
        let state = services.library.state(for: container)
        return services.runtimes.runtime(id: state.activeRuntimeID ?? "") ?? services.planner.runtime(for: container)
    }

    /// Requests a shutdown through Steam's own Exit path.
    @discardableResult
    public func requestSteamQuit(in container: Container) async -> Bool {
        // Without a running Wine session there is no Steam to quit (and "-shutdown" would start one).
        guard WineCommands.isServerRunning(container: container),
              let steam = SteamIntegration.steamWindowsPath(in: container), let runtime = activeRuntime(for: container) else { return false }
        _ = try? await WineCommands.run([steam, "-shutdown"], container: container, runtime: runtime, timeout: 30)
        return true
    }

    /// Stops a Steam instance that Cell started in the background for a game.
    public func quitSteam(in container: Container) async {
        guard await requestSteamQuit(in: container) else { return }
        for _ in 0..<40 {
            let running = WineProcessScanner.scan(containers: [container])
            if !running.contains(where: { ["steam.exe", "steamwebhelper.exe"].contains($0.executableName) }) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await stopAll(in: container)
    }

    /// Ends every Windows program in the container (by force when they don't quit within a few seconds).
    public func stopAll(in container: Container) async {
        if let runtime = activeRuntime(for: container) {
            await WineCommands.killAll(container: container, runtime: runtime)
        } else {
            WineProcessScanner.forceEnd(container)
        }
        forgetSteam(in: container)
    }

    /// Forgets the Steam Cell started in the container (after it was ended from outside Steam).
    public func forgetSteam(in container: Container) {
        var state = services.library.state(for: container)
        guard state.steamPID != nil else { return }
        if let pid = state.steamPID, ProcessRunner.isAlive(pid) { return }
        state.steamPID = nil
        state.steamFlavorKey = nil
        state.steamBackend = nil
        state.steamRuntimeID = nil
        services.library.saveState(state, for: container)
    }

    public func openSteamURL(_ steamURL: String, in container: Container) throws {
        let state = services.library.state(for: container)
        guard let runtime = services.runtimes.runtime(id: state.steamRuntimeID ?? state.activeRuntimeID) ?? services.planner.runtime(for: container),
              let steam = SteamIntegration.steamWindowsPath(in: container) else { throw LaunchError.steamNotInstalled }
        var flavor = runtime.wineRoot
        if let backend = state.steamBackend {
            flavor = (try? services.runtimes.flavorRoot(for: runtime, backend: backend, components: services.components)) ?? runtime.wineRoot
        }
        let process = Process()
        process.executableURL = WineCommands.loader(runtime: runtime, flavorRoot: flavor)
        process.arguments = [steam, steamURL]
        process.environment = WineEnvironment.build(container: container, runtime: runtime, flavorRoot: flavor,
                                                    backend: state.steamBackend, fixes: nil, app: nil, dllOverrides: [:])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        WineCommands.prepareSession(container: container)
        try process.run()
    }
}

/// Lets the person stop a program Cell runs for them (installers, tools).
public final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopRequested = false

    public init() {}

    public var isStopped: Bool { lock.withLock { stopRequested } }

    func attach(_ process: Process) {
        let stop = lock.withLock { () -> Bool in
            self.process = process
            return stopRequested
        }
        if stop { process.terminate() }
    }

    /// Ends the program (Windows sees it quit).
    public func stop() {
        let running = lock.withLock { () -> Process? in
            stopRequested = true
            return process
        }
        if let running, running.isRunning { running.terminate() }
    }
}
