import Foundation
import CryptoKit

public enum LaunchError: LocalizedError {
    case noProgramInFolder(String)
    case noRuntime(String)
    case missingExecutable(String)
    case steamNotInstalled
    case unsupportedPlatform(String)
    case containerMissing
    /// The person stopped it.
    case stopped(String)
    /// A program that can't work in Wine (title, explanation).
    case unsupported(String, String)

    public var errorDescription: String? {
        switch self {
        case .noRuntime(let container): return "“\(container)” has no Wine engine yet. Install one in Engines, then choose it in the container's settings."
        case .missingExecutable(let path): return "The program could not be found: \(path)"
        case .noProgramInFolder(let folder): return "No Windows program (.exe) was found in “\(folder)”."
        case .steamNotInstalled: return "Steam is not installed in this container."
        case .unsupportedPlatform(let detail): return detail
        case .containerMissing: return "The app's container no longer exists."
        case .stopped(let name): return "\(name) was stopped."
        case .unsupported(_, let explanation): return explanation
        }
    }
}

/// Everything needed to start an app, computed without side effects (except creating engine flavors).
public struct LaunchPlan: @unchecked Sendable {
    public enum Kind: String, Sendable { case direct, steamGame, steamClient }

    public var app: AppEntry
    public var container: Container
    public var runtime: WineRuntime
    public var decision: BackendDecision
    public var flavorRoot: URL
    public var flavorKey: String
    public var loader: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var fixes: ResolvedFixes
    public var kind: Kind
    public var warnings: [String]
    public var ports: [PortMapping]
    /// Why this Wine engine was chosen, and which engines to try if every graphics engine crashes.
    public var engineReason: String
    public var engineFallbacks: [String]

    /// Human-readable command line for logs.
    public var commandLine: String {
        ([loader.path] + arguments).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }
}

public final class LaunchPlanner: @unchecked Sendable {
    unowned let services: CellServices

    init(services: CellServices) { self.services = services }

    // MARK: Pieces used by the UI

    public func fixes(for app: AppEntry, container: Container) -> ResolvedFixes {
        let plugins = services.plugins
        // Switched off everywhere, in this translation layer, or for this app.
        let disabled = plugins.state.inactive(plugins.plugins, in: container).union(app.settings.disabledPlugins)
        return FixResolver.resolve(plugins: plugins.plugins, context: MatchContext(app: app, container: container), disabled: disabled,
                                   options: plugins.state)
    }

    /// The container's own engine (also used by tools and installers).
    public func runtime(for container: Container) -> WineRuntime? {
        services.runtimes.runtime(id: container.runtimeID) ?? services.runtimes.recommendedRuntime
    }

    public struct EngineChoice: Sendable {
        public var runtime: WineRuntime
        public var reason: String
        public var fallbacks: [WineRuntime]
    }

    /// A typical game: what games started from Steam's own window usually need.
    static let typicalGame: AppAnalysis = {
        var analysis = AppAnalysis(architecture: .x64)
        analysis.graphicsAPIs = [.d3d11]
        return analysis
    }()

    /// What the app needs from a graphics engine (for Steam itself: what its games typically need).
    func need(for app: AppEntry) -> GraphicsNeed {
        app.kind == .steamClient ? .direct3D11 : GraphicsNeed(analysis: app.analysis)
    }

    /// Graphics engines `runtime` offers for an app with `need`, without those Cell's engine check found
    /// unable to draw. Checked ones count as known to work.
    public func support(for runtime: WineRuntime, need: GraphicsNeed, for32Bit: Bool = false) -> [GraphicsBackend: RuntimeManager.BackendSupport] {
        var support = services.runtimes.supportedBackends(for: runtime, components: services.components, for32Bit: for32Bit)
        for (backend, info) in support {
            switch services.verifier.verdict(runtime: runtime, backend: backend, need: need) {
            case .broken:
                support[backend] = nil
            case .works:
                var known = info
                known.confident = true
                support[backend] = known
            case .unchecked:
                break
            }
        }
        return support
    }

    /// One way to run an app: a Wine engine and the graphics engine Autopilot picks on it.
    struct EngineOption {
        var runtime: WineRuntime
        var backend: GraphicsBackend
        /// Cell's engine check showed this pair draws.
        var verified: Bool
        /// Position of the graphics engine in the app's order of preference — fastest first (0 = first choice).
        var preference: Int
        /// Windows dialogs show text with this engine (false only when the check proved they don't).
        var showsText: Bool
    }

    /// How the app would run on `runtime`; nil when only broken or already crashed graphics engines are left there.
    func option(for app: AppEntry, container: Container, runtime: WineRuntime, fixes: ResolvedFixes,
                ignoringCrashes: Bool = false) -> EngineOption? {
        guard let decision = decision(for: app, container: container, fixes: fixes, runtime: runtime) else { return nil }
        let need = need(for: app)
        let backend = decision.backend
        if !ignoringCrashes, app.kind != .steamClient, app.learned.failedBackends(on: runtime.id).contains(backend) { return nil }
        let verdict = services.verifier.verdict(runtime: runtime, backend: backend, need: need)
        if case .broken = verdict { return nil }
        // Wine's own renderer draws Direct3D 10–12 on few Macs: only count it when the check proved it.
        if backend == .wined3d, need == .direct3D11 || need == .direct3D12, verdict != .works { return nil }
        let analysis = app.kind == .steamClient ? Self.typicalGame : app.analysis
        let order = BackendSelector.policy(analysis: analysis, baseBackend: runtime.baseBackend).order
        return EngineOption(runtime: runtime, backend: backend, verified: verdict == .works,
                            preference: order.firstIndex(of: backend) ?? order.count,
                            showsText: services.verifier.drawsText(runtime: runtime) != false)
    }

    /// Whether the app is a game (they draw their own text) rather than an installer, launcher or tool, whose
    /// windows are made of Windows dialogs and controls.
    func drawsItsOwnText(_ app: AppEntry) -> Bool {
        app.kind == .steamGame || app.kind == .steamClient || app.isGame
    }

    /// Best first. Games: pairs the engine check confirmed, then the fastest graphics engine for the game, then
    /// engines whose dialogs show text. Installers and tools: dialogs that show text come first. Ties go to the
    /// engine the container's Windows folder is already on (switching stops everything and updates it), engines
    /// that ship that graphics engine themselves, the container's own engine, then newer versions.
    func rank(_ options: [EngineOption], container: Container, app: AppEntry) -> [EngineOption] {
        let game = drawsItsOwnText(app)
        return options.sorted { a, b in
            if !game, a.showsText != b.showsText { return a.showsText }
            if a.verified != b.verified { return a.verified }
            if a.preference != b.preference { return a.preference < b.preference }
            if a.showsText != b.showsText { return a.showsText }
            let aCurrent = a.runtime.id == container.initializedRuntimeID, bCurrent = b.runtime.id == container.initializedRuntimeID
            if aCurrent != bCurrent { return aCurrent }
            let aBundled = a.runtime.baseBackend == a.backend, bBundled = b.runtime.baseBackend == b.backend
            if aBundled != bBundled { return aBundled }
            let aHome = a.runtime.id == container.runtimeID, bHome = b.runtime.id == container.runtimeID
            if aHome != bHome { return aHome }
            return LooseVersion(a.runtime.version) > LooseVersion(b.runtime.version)
        }
    }

    /// The Wine engine the container's running programs use, if any are running.
    func runningRuntime(in container: Container) -> WineRuntime? {
        guard WineCommands.isServerRunning(container: container) else { return nil }
        return services.runtimes.runtime(id: services.library.state(for: container).activeRuntimeID)
    }

    /// Whether a graphics engine can run an app's kind of Direct3D at all.
    static func handles(_ backend: GraphicsBackend, need: GraphicsNeed) -> Bool {
        switch need {
        case .direct3D12: return backend == .d3dmetal
        case .direct3D11: return backend != .wined3d
        case .legacy, .none: return true
        }
    }

    /// Engine Autopilot. Switching Wine engines stops everything running in the container (Steam, games) and
    /// updates its Windows folder — half a minute or more each time, which is what made starting things slow. So the
    /// engine already in use stays — the running one, then the one the Windows folder is on, then the container's own
    /// — whenever it can run the app properly (dialogs with text for apps made of Windows dialogs, a graphics engine
    /// that handles the app's Direct3D, what a plugin requires). Only otherwise does Autopilot move to the best other
    /// engine. Graphics engines (DXMT, D3DMetal…) still switch freely per app: they share the running engine.
    public func engineChoice(for app: AppEntry, container: Container, fixes: ResolvedFixes? = nil,
                             forced: String? = nil) -> EngineChoice? {
        let all = services.runtimes.runtimes
        guard let base = runtime(for: container) ?? all.first else { return nil }
        func find(_ id: String?) -> WineRuntime? { id.flatMap { id in all.first { $0.id == id } } }
        let resolvedFixes = fixes ?? self.fixes(for: app, container: container)
        let available = all.compactMap { option(for: app, container: container, runtime: $0, fixes: resolvedFixes) }
        let options = Self.satisfyingRuntimePreference(available, fixes: resolvedFixes)
        let ranked = rank(options, container: container, app: app)
        let need = need(for: app)
        // Programs really running here (a wineserver kept warm doesn't count).
        let processes = WineProcessScanner.scan(containers: [container])
        let busy = !processes.isEmpty
        let running = busy ? runningRuntime(in: container) : nil
        /// `runtime` when the app can run on it properly, so there's no reason to switch away from it.
        ///
        /// A crash recorded for the app on this engine is only a reason to leave for a game, and only while
        /// nothing else runs in the container. A launcher or tool that crashed (a missing .NET, a bad download)
        /// crashed for another reason, and following it to another engine moved Steam and every game there too.
        func canStay(_ runtime: WineRuntime?) -> WineRuntime? {
            guard let runtime, let option = self.option(for: app, container: container, runtime: runtime, fixes: resolvedFixes,
                                                        ignoringCrashes: true) else { return nil }
            let crashedHere = app.kind != .steamClient && app.learned.failedBackends(on: runtime.id).contains(option.backend)
            if crashedHere, drawsItsOwnText(app), !busy { return nil }
            if !drawsItsOwnText(app), !option.showsText, options.contains(where: \.showsText) { return nil }
            guard Self.handles(option.backend, need: need) else { return nil }
            if let minimum = resolvedFixes.minimumWineVersion, LooseVersion(runtime.version) < LooseVersion(minimum) { return nil }
            if !resolvedFixes.enginePreference.isEmpty,
               !resolvedFixes.enginePreference.contains(where: { $0 == "newest" || runtime.matches(family: $0) }) { return nil }
            return runtime
        }
        /// `runtime` when it is as good as the best choice (as fast, as sure, and dialogs as readable).
        func asGood(_ runtime: WineRuntime?) -> WineRuntime? {
            guard let runtime, let best = ranked.first, let option = options.first(where: { $0.runtime.id == runtime.id }) else { return nil }
            guard option.verified == best.verified, option.preference == best.preference else { return nil }
            if best.showsText && !option.showsText { return nil }
            return runtime
        }

        var chosen = base
        var reason = "the container's engine"
        if let forcedRuntime = find(forced) {
            chosen = forcedRuntime
            reason = forcedRuntime.id == base.id ? "the container's engine" : "trying another engine after a crash"
        } else if let user = find(app.settings.runtimeOverride) {
            chosen = user
            reason = "you chose it"
        } else if app.isGame, let previous = canStay(running ?? find(container.runtimeID) ?? find(container.initializedRuntimeID)),
                  let oldBackend = option(for: app, container: container, runtime: previous, fixes: resolvedFixes)?.backend,
                  let corrected = ranked.first(where: {
                      $0.verified && $0.backend == oldBackend && $0.runtime.fixesSikarugirFocusCompared(to: previous)
                  }), !processes.contains(where: Launcher.blocksCompatibilityEngineSwitch) {
            chosen = corrected.runtime
            reason = "it fixes input after switching apps"
        } else if let active = canStay(running) {
            chosen = active
            reason = "it's already running in this container (switching would stop everything running there)"
        } else if let home = canStay(find(container.runtimeID)) {
            chosen = home
            reason = "it's the container's engine"
        } else if let current = canStay(find(container.initializedRuntimeID)) {
            chosen = current
            reason = "the container is set up for it (switching engines takes half a minute)"
        } else if let learned = asGood(find(app.learned.workingRuntimeID)) {
            chosen = learned
            reason = "it worked last time"
        } else if app.kind == .steamClient, let games = steamClientEngine(container: container, all: all) {
            chosen = games.runtime
            reason = games.reason
        } else if let preferred = asGood(Self.preferredRuntime(fixes: resolvedFixes, among: options.map(\.runtime), current: base)) {
            chosen = preferred
            let plugin = resolvedFixes.plugins.last { $0.manifest.fixes?.engine != nil }?.manifest.name ?? "a plugin"
            reason = "recommended by \(plugin)"
        } else if let best = ranked.first {
            chosen = best.runtime
            reason = best.verified ? "\(best.backend.displayName) is the fastest choice that is checked to work" : "the best match for this app"
        }
        let fallbacks = app.kind == .steamClient ? [] : ranked.map(\.runtime).filter { $0.id != chosen.id }
        return EngineChoice(runtime: chosen, reason: reason, fallbacks: fallbacks)
    }

    /// Rank usable engines that meet the profile first, including the retry list. If none are installed,
    /// preserve the usual choices so an optional compatibility profile cannot prevent the app from starting.
    static func satisfyingRuntimePreference(_ options: [EngineOption], fixes: ResolvedFixes) -> [EngineOption] {
        guard let minimum = fixes.minimumWineVersion else { return options }
        let eligible = options.filter { LooseVersion($0.runtime.version) >= LooseVersion(minimum) }
        guard !eligible.isEmpty else { return options }
        for family in fixes.enginePreference where family != "newest" {
            let preferred = eligible.filter { $0.runtime.matches(family: family) }
            if !preferred.isEmpty { return preferred }
        }
        return eligible
    }

    /// Games started from Steam's own window run on Steam's engine and graphics engine, so Steam runs where
    /// most of its games run best (a game that worked somewhere votes for that engine). Ties keep Steam where
    /// it ran last, so it doesn't move back and forth.
    func steamClientEngine(container: Container, all: [WineRuntime]) -> (runtime: WineRuntime, reason: String)? {
        let games = services.library.apps(in: container.id).filter { $0.kind == .steamGame }
        guard !games.isEmpty else { return nil }
        var votes: [String: Int] = [:]
        for game in games {
            guard let pick = bestOption(for: game, container: container, all: all) else { continue }
            votes[pick.runtime.id, default: 0] += 1
        }
        let state = services.library.state(for: container)
        let ranked = votes.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            for preferred in [state.lastSteamRuntimeID, container.initializedRuntimeID, container.runtimeID] {
                if let preferred, lhs.key == preferred || rhs.key == preferred { return lhs.key == preferred }
            }
            return LooseVersion(all.first { $0.id == lhs.key }?.version ?? "") > LooseVersion(all.first { $0.id == rhs.key }?.version ?? "")
        }
        guard let winner = ranked.first, let runtime = all.first(where: { $0.id == winner.key }) else { return nil }
        return (runtime, games.count == 1 ? "\(games[0].name) runs best on it (games you start from Steam's window use Steam's engine)"
                                          : "most of the Steam games here run best on it (games you start from Steam's window use Steam's engine)")
    }

    /// Where a game would run if nothing were running yet.
    func bestOption(for app: AppEntry, container: Container, all: [WineRuntime]) -> EngineOption? {
        let fixes = self.fixes(for: app, container: container)
        let options = all.compactMap { option(for: app, container: container, runtime: $0, fixes: fixes) }
        if let user = app.settings.runtimeOverride, let pick = options.first(where: { $0.runtime.id == user }) { return pick }
        if let working = app.learned.workingRuntimeID, let pick = options.first(where: { $0.runtime.id == working }) { return pick }
        return rank(options, container: container, app: app).first
    }

    /// The graphics engine most of the container's Steam games use on `runtime` (what Steam should run with).
    func steamGamesBackend(on runtime: WineRuntime, container: Container) -> GraphicsBackend? {
        let state = services.library.state(for: container)
        var votes: [GraphicsBackend: Int] = [:]
        for game in services.library.apps(in: container.id) where game.kind == .steamGame {
            let fixes = self.fixes(for: game, container: container)
            guard let option = option(for: game, container: container, runtime: runtime, fixes: fixes) else { continue }
            votes[option.backend, default: 0] += 1
        }
        return votes.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            if lhs.key == state.lastSteamBackend || rhs.key == state.lastSteamBackend { return rhs.key == state.lastSteamBackend }
            return lhs.key.rawValue > rhs.key.rawValue
        }?.key
    }

    static func preferredRuntime(fixes: ResolvedFixes, among all: [WineRuntime], current: WineRuntime) -> WineRuntime? {
        var candidates = all
        if let minimum = fixes.minimumWineVersion {
            candidates = candidates.filter { LooseVersion($0.version) >= LooseVersion(minimum) }
        }
        let newestFirst: (WineRuntime, WineRuntime) -> Bool = { LooseVersion($0.version) > LooseVersion($1.version) }
        for family in fixes.enginePreference {
            let matching = candidates.filter { $0.matches(family: family) }.sorted(by: newestFirst)
            if family != "newest", matching.contains(where: { $0.id == current.id }) { return current }
            if let best = matching.first { return best }
        }
        if fixes.minimumWineVersion != nil, !candidates.contains(where: { $0.id == current.id }) {
            return candidates.sorted(by: newestFirst).first
        }
        return nil
    }

    /// The graphics engine of the Steam that is running in the container, when `app` can use it too (one of the
    /// game's candidates, it handles the game's Direct3D, no crash with it, not found broken by the engine check).
    /// Restarting Steam for a slightly faster graphics engine took a minute and closed Steam's window, so a
    /// running Steam is kept whenever its graphics engine can run the game at all.
    func runningSteamBackend(for app: AppEntry, container: Container, runtime: WineRuntime, decision: BackendDecision) -> GraphicsBackend? {
        let state = services.library.state(for: container)
        guard let pid = state.steamPID, ProcessRunner.isAlive(pid), state.steamRuntimeID == runtime.id,
              let steamBackend = state.steamBackend, steamBackend != decision.backend,
              decision.fallbacks.contains(steamBackend), Self.handles(steamBackend, need: need(for: app)),
              !app.learned.failedBackends(on: runtime.id).contains(steamBackend) else { return nil }
        if case .broken = services.verifier.verdict(runtime: runtime, backend: steamBackend, need: need(for: app)) { return nil }
        return steamBackend
    }

    /// The Autopilot decision for an app (no side effects).
    public func decision(for app: AppEntry, container: Container, fixes: ResolvedFixes? = nil,
                         forced: GraphicsBackend? = nil, runtime chosenRuntime: WineRuntime? = nil) -> BackendDecision? {
        let resolvedFixes = fixes ?? self.fixes(for: app, container: container)
        guard let runtime = chosenRuntime ?? engineChoice(for: app, container: container, fixes: resolvedFixes)?.runtime else { return nil }
        let is32Bit = app.analysis?.architecture == .x86
        var support = self.support(for: runtime, need: need(for: app), for32Bit: is32Bit)
        // D3DMetal only runs 64-bit programs: 32-bit games (Beholder, Beholder 2) crash at once in its Direct3D 11.
        if is32Bit { support[.d3dmetal] = nil }
        // What was learned applies to this engine only.
        var learned = app.learned
        learned.failedBackends = app.learned.failedBackends(on: runtime.id)
        if let working = app.learned.workingRuntimeID, working != runtime.id { learned.workingBackend = nil }
        if app.kind == .steamClient {
            // Games started from Steam's own window inherit Steam's graphics engine: use what its games use.
            var decision = BackendSelector.decide(analysis: Self.typicalGame, support: support, fixes: ResolvedFixes(),
                                                  userOverride: app.settings.backendOverride,
                                                  containerPreference: container.settings.preferredBackend,
                                                  baseBackend: runtime.baseBackend, forced: forced)
            if forced == nil, app.settings.backendOverride == nil, container.settings.preferredBackend == nil,
               let gamesBackend = steamGamesBackend(on: runtime, container: container), support[gamesBackend] != nil,
               gamesBackend != decision.backend {
                decision.fallbacks.removeAll { $0 == gamesBackend }
                decision.fallbacks.insert(decision.backend, at: 0)
                decision.backend = gamesBackend
            }
            // Each game Steam starts gets its own graphics engine through ProgramSettings, from the libraries the
            // Wine engine came with: Steam itself runs on exactly those.
            if forced == nil, app.settings.backendOverride == nil, support[runtime.baseBackend] != nil, decision.backend != runtime.baseBackend {
                decision.fallbacks.removeAll { $0 == runtime.baseBackend }
                decision.fallbacks.insert(decision.backend, at: 0)
                decision.backend = runtime.baseBackend
            }
            decision.reason = "\(decision.backend.displayName) for Steam itself. Every game, also one started from Steam's window, gets its own best graphics engine."
            decision.extraArguments = []
            return decision
        }
        return BackendSelector.decide(analysis: app.analysis, support: support, fixes: resolvedFixes, learned: learned,
                                      userOverride: app.settings.backendOverride,
                                      containerPreference: container.settings.preferredBackend,
                                      baseBackend: runtime.baseBackend, forced: forced)
    }

    // MARK: Plan

    public func plan(app: AppEntry, container: Container, forcedBackend: GraphicsBackend? = nil,
                     forcedRuntime: String? = nil, throughSteam: Bool = true) throws -> LaunchPlan {
        guard container.platform == .windows else {
            throw LaunchError.unsupportedPlatform("Only Windows apps can launch in a translation layer.")
        }
        let fixes = self.fixes(for: app, container: container)
        guard let choice = engineChoice(for: app, container: container, fixes: fixes, forced: forcedRuntime) else {
            throw LaunchError.noRuntime(container.name)
        }
        let runtime = choice.runtime
        guard var decision = decision(for: app, container: container, fixes: fixes, forced: forcedBackend, runtime: runtime) else {
            throw LaunchError.noRuntime(container.name)
        }
        let mapper = WinePathMapper(prefix: container.prefixURL)
        // Steam games start through Steam (achievements, cloud saves, online play; games that need Steam run). The game
        // still gets its own graphics engine: ProgramSettings hands it over when Steam starts it. A game with
        // a broken launcher can prefer its own executable when one is available.
        let steamInstalled = SteamIntegration.steamWindowsPath(in: container) != nil
        let usesSteamLauncher = throughSteam && steamInstalled && fixes.preferGameExecutable != true
        let directGame = usesSteamLauncher ? nil : directExecutable(of: app, mapper: mapper)
        let components = services.components
        let is32Bit = app.analysis?.architecture == .x86
        // Through Steam: Steam's own Wine (the engine's base graphics), so a running Steam is never restarted for a game.
        let flavorBackend = (app.kind == .steamGame && directGame == nil) ? runtime.baseBackend : decision.backend
        let flavorRoot = try services.runtimes.flavorRoot(for: runtime, backend: flavorBackend, components: components, for32Bit: is32Bit)
        let flavorKey = services.runtimes.flavorKey(for: runtime, backend: flavorBackend, components: components, for32Bit: is32Bit)

        var gameArguments = fixes.arguments(for: decision.backend)
        if fixes.preferBorderlessFullscreen == true {
            FixResolver.appendGroup(["-window-mode", "borderless"], to: &gameArguments)
        }
        FixResolver.appendGroup(decision.extraArguments, to: &gameArguments)
        gameArguments += app.settings.extraArguments
        // Plugins may use templates such as {screenWidth} in arguments.
        let templates = PathTemplateContext(container: container, app: app)
        gameArguments = gameArguments.map { $0.contains("{") ? (templates.expand($0) ?? $0) : $0 }
        if ProgramSettings.startsFullscreen(app, in: container, fixes: fixes), app.analysis?.engine == .unity,
           !(app.launchArguments + gameArguments).contains(where: { $0.lowercased().hasPrefix("-screen-fullscreen") }) {
            gameArguments += ["-screen-fullscreen", "1"]
        }

        var warnings: [String] = []
        if let analysis = app.analysis, !analysis.antiCheat.isEmpty {
            warnings.append("\(analysis.antiCheat.joined(separator: " and ")) may block this game under Wine.")
        }

        var dllOverrides: [String: String] = [:]
        var arguments: [String]
        var workingDirectory = container.driveC
        let kind: LaunchPlan.Kind
        switch app.kind {
        case .steamGame where directGame != nil:
            // Started like any program, with its own best engine; the game finds Steam by itself when it runs.
            let (windowsPath, unix) = directGame!
            arguments = [windowsPath] + app.launchArguments + gameArguments
            workingDirectory = unix.deletingLastPathComponent()
            dllOverrides = fixes.dllOverrides
            if decision.backend == .dxvk { for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] { dllOverrides[dll] = "n,b" } }
            kind = .direct
        case .windowsExecutable:
            guard let windowsPath = app.windowsPath, let unix = mapper.unixURL(forWindowsPath: windowsPath) else {
                throw LaunchError.missingExecutable(app.windowsPath ?? app.name)
            }
            guard FileManager.default.fileExists(atPath: unix.path) else { throw LaunchError.missingExecutable(unix.path) }
            arguments = [windowsPath] + app.launchArguments + gameArguments
            workingDirectory = app.workingDirectory.flatMap { mapper.unixURL(forWindowsPath: $0) }
                .flatMap { FileOps.isDirectory($0) ? $0 : nil } ?? unix.deletingLastPathComponent()
            dllOverrides = fixes.dllOverrides
            if decision.backend == .dxvk { for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] { dllOverrides[dll] = "n,b" } }
            let overlay = app.settings.steamOverlay != .automatic ? app.settings.steamOverlay : (fixes.steamOverlay ?? .automatic)
            if overlay == .disabled { dllOverrides["gameoverlayrenderer"] = ""; dllOverrides["gameoverlayrenderer64"] = "" }
            kind = .direct
        case .steamClient:
            guard let steam = SteamIntegration.steamWindowsPath(in: container) else { throw LaunchError.steamNotInstalled }
            arguments = [steam] + SteamIntegration.clientArguments(settings: container.settings, fixes: fixes, silent: false)
                + app.settings.extraArguments
            kind = .steamClient
        case .steamGame:
            guard let steam = SteamIntegration.steamWindowsPath(in: container) else { throw LaunchError.steamNotInstalled }
            guard let appID = app.steamAppID else { throw LaunchError.missingExecutable(app.name) }
            arguments = [steam] + SteamIntegration.clientArguments(settings: container.settings, fixes: fixes, silent: true)
                + ["-applaunch", appID] + fixes.steamLaunchArguments + app.launchArguments + gameArguments
            kind = .steamGame
        }

        var environment = WineEnvironment.build(container: container, runtime: runtime, flavorRoot: flavorRoot,
                                                backend: decision.backend, fixes: fixes, app: app, dllOverrides: dllOverrides)
        // Cell starts this program with its engine and variables already chosen (the helper leaves them alone).
        if kind == .direct, let program = arguments.first.flatMap(ProgramSettings.programName) {
            environment[ProgramSettings.plannedProgramVariable] = program
        }
        if directGame != nil, let appID = app.steamAppID {
            // What Steam tells a game it starts: the game doesn't hand itself back to Steam to be started again.
            environment["SteamAppId"] = appID
            environment["SteamGameId"] = appID
        }
        var ports = fixes.ports
        for port in app.settings.portMappings where !ports.contains(port) { ports.append(port) }
        return LaunchPlan(app: app, container: container, runtime: runtime, decision: decision, flavorRoot: flavorRoot,
                          flavorKey: flavorKey, loader: WineCommands.loader(runtime: runtime, flavorRoot: flavorRoot),
                          arguments: arguments, environment: environment, workingDirectory: workingDirectory,
                          fixes: fixes, kind: kind, warnings: warnings, ports: ports,
                          engineReason: "\(runtime.name) — \(choice.reason)", engineFallbacks: choice.fallbacks.map(\.id))
    }

    /// The game's own program when a Steam game can be started without Steam's window: its program is known and
    /// there, and starting it directly worked before (or wasn't tried).
    func directExecutable(of app: AppEntry, mapper: WinePathMapper) -> (String, URL)? {
        guard app.kind == .steamGame, !app.learned.startsOnlyThroughSteam, let windowsPath = app.windowsPath,
              let unix = mapper.unixURL(forWindowsPath: windowsPath), FileManager.default.fileExists(atPath: unix.path) else { return nil }
        return (windowsPath, unix)
    }

    /// The Visual C++ 2015–2022 runtime libraries (what winetricks' vcrun2022 sets to native).
    static let visualCppLibraries = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                                     "msvcp140_codecvt_ids", "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1"]

    /// Microsoft's msvcp140 and vcruntime140 are in system32 (versioned: Wine's own copies have no version).
    static func hasMicrosoftsVisualCpp(_ container: Container) -> Bool {
        let system32 = container.driveC.appendingPathComponent("windows/system32")
        return ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"].allSatisfy { file in
            PEFile(url: system32.appendingPathComponent(file))?.versionStrings()["CompanyName"]?.contains("Microsoft") == true
        }
    }

    // MARK: Registry configuration (container-wide, includes per-app AppDefaults)

    public func registryConfiguration(for container: Container) -> [RegistryEdit] {
        let s = container.settings
        var edits: [RegistryEdit] = []
        func yn(_ value: Bool) -> RegistryValue { .string(value ? "y" : "n") }

        edits.append(.set(.currentUser, "Software\\Wine", "Version", .string(s.windowsVersion.rawValue)))

        let mac = "Software\\Wine\\Mac Driver"
        edits += [
            .set(.currentUser, mac, "RetinaMode", yn(s.highResolution)),
            // A captured display blocks Mission Control, Cmd-Tab and trackpad gestures while a game is fullscreen.
            .set(.currentUser, mac, "CaptureDisplaysForFullscreen", yn(s.fullscreenLocksDisplay)),
            .set(.currentUser, mac, "LeftCommandIsCtrl", yn(s.commandAsControl)),
            .set(.currentUser, mac, "RightCommandIsCtrl", yn(s.commandAsControl)),
            .set(.currentUser, mac, "LeftOptionIsAlt", yn(s.optionAsAlt)),
            .set(.currentUser, mac, "RightOptionIsAlt", yn(s.optionAsAlt)),
            .set(.currentUser, mac, "UsePreciseScrolling", yn(s.scrollMode != .notched)),
            // Windows a game marks "always on top" stay behind other Mac apps once you switch away.
            .set(.currentUser, mac, "WindowsFloatWhenInactive", .string("none")),
            .set(.currentUser, mac, "AllowVerticalSync", .string("y")),
        ]

        let dpi = Self.dpi(for: s)
        edits.append(.set(.currentUser, "Control Panel\\Desktop", "LogPixels", .dword(UInt32(dpi))))
        edits.append(.set(.localMachine, "System\\CurrentControlSet\\Hardware Profiles\\Current\\Software\\Fonts", "LogPixels", .dword(UInt32(dpi))))

        // Resolution changes become virtual (win32u reads this from the "X11 Driver" key for every driver): the
        // Mac's display keeps its mode, so Wine never captures it and windows keep their size when you switch away.
        edits.append(.set(.currentUser, "Software\\Wine\\X11 Driver", "EmulateModeset", yn(s.virtualDisplayModes)))
        // Steam must not start itself with every Wine session (see AutostartBlocker).
        edits.append(.set(.currentUser, "Software\\Microsoft\\Windows\\CurrentVersion\\Run", "Steam", .delete))

        edits.append(.set(.currentUser, "Software\\Wine\\DirectInput", "MouseWarpOverride",
                          s.mouseWarp == .automatic ? .delete : .string(s.mouseWarp.rawValue)))
        // Crashes are reported by Cell; Wine's crash dialog only gets in the way.
        edits.append(.set(.currentUser, "Software\\Wine\\WineDbg", "ShowCrashDialog", .dword(0)))
        // No crash debugger. Wine starts `winedbg --auto` for every crash, and on a Mac it never attaches: the crashed
        // program waited for it forever (a game that "never quits", Steam that couldn't be stopped) and the debuggers
        // piled up by the hundreds. With an empty debugger a crashed program simply ends. Both registry views: 32-bit
        // programs read their own.
        for key in ["Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
                    "Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"] {
            edits.append(.set(.localMachine, key, "Debugger", .string("")))
        }
        // Microsoft's Visual C++ runtime is installed: programs load it instead of Wine's own copies. Wine's copies carry
        // no version, and Unreal's starter reads it: MeiQi 2019 asked to install Visual C++ at every start.
        let visualCpp = Self.visualCppLibraries
        let microsoftsVisualCpp = Self.hasMicrosoftsVisualCpp(container)
        for name in visualCpp {
            edits.append(.set(.currentUser, "Software\\Wine\\DllOverrides", name, microsoftsVisualCpp ? .string("native,builtin") : .delete))
        }
        // Microsoft's .NET Framework replaced Wine Mono: use its mscoree.
        if CellServices.hasDotNetFramework(container) {
            edits.append(.set(.currentUser, "Software\\Wine\\DllOverrides", "mscoree", .string("native")))
        }
        // Microsoft Edge WebView2 and its installer see Windows 7: they get and use the build that draws under Wine.
        edits += WebView2.registryEdits
        // Never create Linux-style menu entries in the Mac home folder.
        edits.append(.set(.currentUser, "Software\\Wine\\DllOverrides", "winemenubuilder.exe", .string("")))

        if FileManager.default.fileExists(atPath: container.driveC.appendingPathComponent("windows/system32/.chamber-dxvk").path) {
            // DXVK's native DLLs live in system32; everyone else keeps the engine's builtin ones.
            for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] {
                edits.append(.set(.currentUser, "Software\\Wine\\DllOverrides", dll, .string("builtin")))
            }
        }

        if s.cjkFontFallbacks {
            let language = LanguageResolver.textLanguage(for: s.language).language
            edits += FontConfigurator.registryEdits(primary: language.cjkScript)
            edits += FontConfigurator.scriptFallbackEdits(primary: language.cjkScript)
        }

        for app in services.library.apps(in: container.id) {
            edits += appDefaults(for: app, container: container)
        }
        return edits
    }

    /// Windows' text size (LogPixels) for the container: 192 on a Retina Mac, so Steam and dialogs aren't tiny.
    static func dpi(for s: ContainerSettings, display: DisplayInfo? = nil) -> Int {
        guard s.highResolution else { return 96 }
        switch s.dpiMode {
        case .automatic: return (display ?? DisplayInfo.resolve(s.displayID)).automaticDPI
        case .standard: return 96
        case .custom: return min(max(s.customDPI, 96), 480)
        }
    }

    public static let appCompatLayers = "Software\\Microsoft\\Windows NT\\CurrentVersion\\AppCompatFlags\\Layers"
    static let dpiAwareLayer = "~ HIGHDPIAWARE"

    /// Whether a game is marked DPI-aware (`AppCompatFlags\Layers\<exe> = "~ HIGHDPIAWARE"`).
    ///
    /// Above 96 DPI Wine treats programs whose manifest doesn't say they're DPI-aware like Windows does: they see
    /// a screen of 1470×956 instead of 2940×1912 and what they draw is stretched to fill it, so the whole game —
    /// 3D view and interface — is blurry whatever its resolution setting says. Most Unreal games are like that
    /// (Unity games declare it). The flag makes Wine show them the real pixels, while Steam and Windows dialogs
    /// keep the larger text size. Wine looks the flag up by the executable's file name, under HKCU only.
    ///
    /// Automatic for games with a modern engine or Direct3D 10–12/Vulkan, which draw fullscreen at the display's
    /// size; older games (often small fixed windows) stay scaled up. "Full display resolution" on an app forces it.
    func drawsAtFullPixels(_ app: AppEntry, container: Container, pluginPreference: Bool? = nil) -> Bool {
        guard Self.dpi(for: container.settings) > 96, let analysis = app.analysis, analysis.declaresDPIAwareness == false else { return false }
        if let explicit = app.settings.nativeResolution { return explicit }
        if let pluginPreference { return pluginPreference }
        // Chromium-based apps (Electron, CEF) scale themselves when they're allowed to: sharp, and the right size.
        if analysis.engine == .electron || analysis.engine == .cef { return true }
        guard app.isGame else { return false }
        guard container.settings.nativeGameResolution else { return false }
        let modernEngines: Set<EngineKind> = [.unreal, .unity, .godot, .source2, .cryEngine, .idTech]
        if let engine = analysis.engine, modernEngines.contains(engine) { return true }
        return !analysis.graphicsAPIs.isDisjoint(with: [.d3d10, .d3d11, .d3d12, .vulkan])
    }

    /// Unity games that saved a lower resolution or exclusive fullscreen get the display's full resolution in
    /// borderless fullscreen (only when something needs to change, so settings are re-applied only then).
    func unityResolutionEdits(for container: Container, only appID: UUID? = nil) -> [RegistryEdit] {
        let apps = services.library.apps(in: container.id).filter { app in
            (appID == nil || app.id == appID) && app.analysis?.engine == .unity
                && (app.settings.nativeResolution ?? container.settings.nativeGameResolution)
        }
        guard !apps.isEmpty else { return [] }
        let hive = try? WineRegistryHive.load(container.prefixURL.appendingPathComponent("user.reg"), rootName: "HKEY_CURRENT_USER")
        var edits: [RegistryEdit] = []
        var seen = Set<String>()
        for app in apps {
            guard let executable = AppAnalyzer.executable(for: app, in: container),
                  let named = GameDisplayFixer.unityIdentity(executable: executable) else { continue }
            let identity = GameDisplayFixer.unityKey(company: named.company, product: named.product, in: hive)
            guard seen.insert("\(identity.company)\\\(identity.product)").inserted else { continue }
            // The game's own display, else the layer's (experimental; the main display unless one was chosen).
            let chosen = app.settings.displayID ?? container.settings.displayID
            let display = DisplayInfo.resolve(chosen)
            guard let size = GameDisplayFixer.targetSize(highResolution: container.settings.highResolution, display: display) else { continue }
            let fixes = fixes(for: app, container: container)
            let recoverDisplay = fixes.environment["CELL_UNITY_DISPLAY_RECOVERY"] == "1"
            edits += GameDisplayFixer.unityEdits(company: identity.company, product: identity.product, saved: hive, size: size,
                                                 choiceBroken: app.learned.needsDisplayModes || recoverDisplay,
                                                 preferBorderlessFullscreen: fixes.preferBorderlessFullscreen != false)
            if chosen != nil {
                edits.append(GameDisplayFixer.unityMonitorEdit(company: identity.company, product: identity.product, index: display.index))
            }
        }
        return edits
    }

    /// Per-executable settings (`HKCU\Software\Wine\AppDefaults\<exe>`): they also apply when Steam starts the game.
    func appDefaults(for app: AppEntry, container: Container) -> [RegistryEdit] {
        var names = Set<String>()
        if let name = app.executableName, app.kind == .windowsExecutable { names.insert(name) }
        if let analyzed = app.analysis?.analyzedExecutable { names.insert(URL(fileURLWithPath: analyzed).lastPathComponent) }
        names.remove("steam.exe")
        guard !names.isEmpty else { return [] }
        let fixes = self.fixes(for: app, container: container)
        let decision = self.decision(for: app, container: container, fixes: fixes)
        let fullPixels = drawsAtFullPixels(app, container: container, pluginPreference: fixes.nativeResolution)
        var edits: [RegistryEdit] = []
        // Chromium helpers inside the app (QQ Music's page browser, launchers' web views) scale themselves too.
        let helpersSharp = Self.dpi(for: container.settings) > 96 && app.settings.nativeResolution != false
        for helper in app.analysis?.chromiumHelpers ?? [] where !names.contains(helper) {
            edits.append(.set(.currentUser, Self.appCompatLayers, helper, helpersSharp ? .string(Self.dpiAwareLayer) : .delete))
        }
        for name in names.sorted() {
            // Read when the program starts, whoever starts it (Cell or Steam's window).
            edits.append(.set(.currentUser, Self.appCompatLayers, name, fullPixels ? .string(Self.dpiAwareLayer) : .delete))
            let base = "Software\\Wine\\AppDefaults\\\(name)"
            edits.append(.deleteKey(.currentUser, base + "\\Mac Driver"))
            edits.append(.deleteKey(.currentUser, base + "\\DirectInput"))
            edits.append(.deleteKey(.currentUser, base + "\\DllOverrides"))
            // Some games index a filtered list of display modes at startup. Resetting preferences cannot
            // repair an empty list; enable virtual modes only for games whose log established this need.
            edits.append(.deleteKey(.currentUser, base + "\\X11 Driver"))
            if app.learned.needsDisplayModes || fixes.environment["CELL_UNITY_DISPLAY_RECOVERY"] == "1" {
                edits.append(.set(.currentUser, base + "\\X11 Driver", "EmulateModeset", .string("y")))
            }

            let scroll = app.settings.scrollMode ?? fixes.scrollMode ?? container.settings.scrollMode
            let notched = scroll == .notched || (scroll == .automatic && app.isGame)
            edits.append(.set(.currentUser, base + "\\Mac Driver", "UsePreciseScrolling", .string(notched ? "n" : "y")))
            // Only you decide whether a game may lock the display (plugins can't: it blocks Mission Control).
            if let capture = app.settings.captureDisplays {
                edits.append(.set(.currentUser, base + "\\Mac Driver", "CaptureDisplaysForFullscreen", .string(capture ? "y" : "n")))
            }
            if let high = app.settings.highResolution ?? fixes.highResolution {
                edits.append(.set(.currentUser, base + "\\Mac Driver", "RetinaMode", .string(high ? "y" : "n")))
            }
            if let warp = app.settings.mouseWarp ?? fixes.mouseWarp, warp != .automatic {
                edits.append(.set(.currentUser, base + "\\DirectInput", "MouseWarpOverride", .string(warp.rawValue)))
            }
            if let capture = app.settings.cursorCapture ?? fixes.cursorCapture {
                edits.append(.set(.currentUser, base + "\\Mac Driver", "UseConfinementCursorClipping",
                                  .string(capture == .confinement ? "y" : "n")))
            }
            if let lock = app.settings.lockWindowWhenCaptured ?? fixes.lockWindowWhenCaptured {
                edits.append(.set(.currentUser, base + "\\Mac Driver", "CursorClippingLocksWindows", .string(lock ? "y" : "n")))
            }
            let version = app.settings.windowsVersion ?? fixes.windowsVersion
            edits.append(.set(.currentUser, base, "Version", version.map { .string($0.rawValue) } ?? .delete))

            var overrides = fixes.dllOverrides
            let overlay = app.settings.steamOverlay != .automatic ? app.settings.steamOverlay : (fixes.steamOverlay ?? .automatic)
            if overlay == .disabled { overrides["gameoverlayrenderer"] = ""; overrides["gameoverlayrenderer64"] = "" }
            if decision?.backend == .dxvk { for dll in ["d3d9", "d3d10core", "d3d11", "dxgi"] { overrides[dll] = "native,builtin" } }
            for (dll, mode) in overrides.sorted(by: { $0.key < $1.key }) {
                edits.append(.set(.currentUser, base + "\\DllOverrides", dll, .string(mode)))
            }
            for fix in fixes.registry {
                if let edit = Self.registryEdit(from: fix.entry, appKey: base) { edits.append(edit) }
            }
        }
        return edits
    }

    static func registryEdit(from entry: PluginRegistryEntry, appKey: String?) -> RegistryEdit? {
        let hive: RegistryHive
        let key: String
        if entry.scope == "app" {
            guard let appKey else { return nil }
            hive = .currentUser
            key = entry.key.isEmpty ? appKey : appKey + "\\" + entry.key
        } else {
            guard let split = RegistryHive.split(entry.key) else { return nil }
            hive = split.0
            key = split.1
        }
        func number(_ text: String?) -> UInt64? {
            guard let text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
            if text.lowercased().hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
            return UInt64(text)
        }
        switch entry.type {
        case "string": return .set(hive, key, entry.name, .string(entry.value ?? ""))
        case "expand": return .set(hive, key, entry.name, .expandString(entry.value ?? ""))
        case "multi": return .set(hive, key, entry.name, .multiString(entry.values ?? []))
        case "dword": return number(entry.value).map { .set(hive, key, entry.name, .dword(UInt32(truncatingIfNeeded: $0))) }
        case "qword": return number(entry.value).map { .set(hive, key, entry.name, .qword($0)) }
        case "binary":
            let digits = (entry.value ?? "").filter { $0.isHexDigit }
            var bytes: [UInt8] = []
            var index = digits.startIndex
            while index < digits.endIndex, let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) {
                if let byte = UInt8(digits[index..<next], radix: 16) { bytes.append(byte) }
                index = next
            }
            return .set(hive, key, entry.name, .binary(bytes))
        case "delete": return .set(hive, key, entry.name, .delete)
        case "deleteKey": return .deleteKey(hive, key)
        default: return nil
        }
    }

    public static func configurationHash(_ edits: [RegistryEdit]) -> String {
        let digest = SHA256.hash(data: Data(RegFile.text(for: edits).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
