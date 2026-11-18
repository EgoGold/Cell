import Foundation

/// Per-program settings that apply however a program starts — from Cell, from Steam's window, or from a launcher.
///
/// Steam starts every game with its own Wine environment, so games started from its window all got Steam's graphics
/// engine: 32-bit games on D3DMetal (which only runs 64-bit programs) failed with "Failed to initialize graphics"
/// (Pony Island, Overcooked! 2, Beholder 2). Cell's helper library (Tools/dock-name) is in every Wine process; when a
/// program starts, it looks the program up in this table and sets its variables before Wine itself starts:
///
/// - `WINEDLLPATH_PREPEND`: the engine's own graphics libraries (DXMT, D3DMetal) are found before the ones the
///   running Wine engine came with — the game gets its own graphics engine inside Steam's Wine session.
/// - the graphics engine's settings (DXMT's frame limit, MetalFX) and the game's plugin and own variables.
///
/// File: `<container>/program-settings.tsv`, one line per program: `program.exe<TAB>NAME=value<TAB>…`.
public enum ProgramSettings {
    public static func fileURL(for container: Container) -> URL { container.directory.appendingPathComponent("program-settings.tsv") }

    static func compatibilityURL(for container: Container) -> URL { container.directory.appendingPathComponent("steam-compatibility.tsv") }

    /// The variable that tells the helper which program Cell started itself with all of this already set
    /// (its own launches use the matching engine directly, and fall back to others on a crash).
    public static let plannedProgramVariable = "CELL_PLANNED_PROGRAM"

    public struct Entry: Equatable, Sendable {
        public var program: String
        public var variables: [String: String]
    }

    static func text(for entries: [Entry]) -> String {
        entries.sorted { $0.program < $1.program }.map { entry in
            ([entry.program] + entry.variables.keys.sorted().map { "\($0)=\(entry.variables[$0]!)" })
                .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t") + "\n"
        }.joined()
    }

    /// Writes the table (only when it changed: programs read it as they start).
    public static func write(_ entries: [Entry], for container: Container) {
        let text = text(for: entries)
        let url = fileURL(for: container)
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return }
        try? FileManager.default.createDirectory(at: container.directory, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Lower-case file name of a program path ("C:\\Games\\Game.exe" → "game.exe"), if it is a program.
    static func programName(_ path: String) -> String? {
        let name = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)?.lowercased() ?? ""
        return name.hasSuffix(".exe") ? name : nil
    }

    /// Lower-case file names of an app's programs (the one started and the one really analysed).
    static func programs(of app: AppEntry) -> [String] {
        var names: [String] = []
        for path in [app.windowsPath, app.analysis?.analyzedExecutable].compactMap({ $0 }) {
            if let name = programName(path), name != "steam.exe", !names.contains(name) { names.append(name) }
        }
        // The EA launcher can select the DX9 executable instead of the one in Steam's manifest.
        if app.steamAppID == "1222670", names.contains(where: simsPrograms.contains) {
            for name in simsPrograms.sorted() where !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static let simsPrograms: Set<String> = ["ts4_x64.exe", "ts4_dx9_x64.exe"]

    static func simsDisplayVariables(for app: AppEntry, container: Container, fixes: ResolvedFixes?, program: String) -> [String: String] {
        guard app.steamAppID == "1222670", simsPrograms.contains(program),
              app.settings.nativeResolution ?? fixes?.nativeResolution ?? container.settings.nativeGameResolution,
              app.settings.highResolution ?? fixes?.highResolution ?? container.settings.highResolution,
              let profile = WinePathMapper(prefix: container.prefixURL).userProfile else { return [:] }
        let options = profile.appendingPathComponent("Documents/Electronic Arts/The Sims 4/Options.ini")
        return ["CELL_SIMS_DISPLAY_OPTIONS": options.path]
    }

    static func gameHotkeyVariables(for app: AppEntry, program: String) -> [String: String] {
        ["CELL_GAME_FORCE_QUIT": app.isGame ? "1" : "0", "CELL_GAME_FORCE_QUIT_PROGRAM": program]
    }

    static func focusRecoveryVariables(for app: AppEntry, fixes: ResolvedFixes?, program: String) -> [String: String] {
        let recover = app.isGame && (app.settings.recoverInputOnFocus ?? fixes?.recoverInputOnFocus ?? true)
        return ["CELL_FOCUS_RECOVERY": recover ? "1" : "0", "CELL_FOCUS_RECOVERY_PROGRAM": program]
    }

    static func startsFullscreen(_ app: AppEntry, in container: Container, fixes: ResolvedFixes?) -> Bool {
        let arguments = (app.launchArguments + app.settings.extraArguments).map { $0.lowercased() }
        let windowed = arguments.contains { ["-windowed", "-window", "-sw", "-screen-fullscreen=0", "-window-mode=windowed"].contains($0) }
            || zip(arguments, arguments.dropFirst()).contains { flag, value in
                (flag == "-screen-fullscreen" && value == "0") || (flag == "-window-mode" && value == "windowed")
            }
        return app.isGame && !windowed && (app.settings.startFullscreen ?? fixes?.startFullscreen ?? container.settings.startGamesFullscreen)
    }

    static func fullscreenVariables(for app: AppEntry, in container: Container, fixes: ResolvedFixes?, program: String) -> [String: String] {
        ["CELL_START_FULLSCREEN": startsFullscreen(app, in: container, fixes: fixes) ? "1" : "0",
         "CELL_START_FULLSCREEN_PROGRAM": program]
    }
}

extension LaunchPlanner {
    /// The table for a container: what each of its games needs when it runs in the Wine engine Steam uses.
    public func programSettings(for container: Container, overrides: [UUID: GraphicsBackend] = [:]) -> [ProgramSettings.Entry] {
        let state = services.library.state(for: container)
        let all = services.runtimes.runtimes
        let runtime = [state.steamRuntimeID, state.activeRuntimeID, container.runtimeID].compactMap({ id in all.first { $0.id == id } }).first
                ?? runtime(for: container)
        var entries: [ProgramSettings.Entry] = []
        for app in services.library.apps(in: container.id) where app.kind == .steamGame || app.kind == .windowsExecutable {
            let programs = ProgramSettings.programs(of: app)
            guard !programs.isEmpty else { continue }
            let fixes = self.fixes(for: app, container: container)
            var variables: [String: String] = [:]
            if app.analysis != nil, let runtime,
               let decision = decision(for: app, container: container, fixes: fixes, forced: overrides[app.id], runtime: runtime) {
                variables = WineEnvironment.backendEnvironment(settings: container.settings, backend: decision.backend)
                // Steam may have inherited a game's overlay. An empty value explicitly removes it in the helper.
                variables["WINEDLLPATH_PREPEND"] = graphicsLibraries(for: decision.backend, app: app, runtime: runtime)?.path ?? ""
                for (key, value) in fixes.environment(for: decision.backend) { variables[key] = value }
                for (key, value) in app.settings.environment { variables[key] = value }
                variables["CELL_GRAPHICS"] = decision.backend.rawValue
            }
            for program in programs {
                var scoped = variables.merging(ProgramSettings.gameHotkeyVariables(for: app, program: program)) { _, new in new }
                scoped.merge(ProgramSettings.focusRecoveryVariables(for: app, fixes: fixes, program: program)) { _, new in new }
                scoped.merge(ProgramSettings.fullscreenVariables(for: app, in: container, fixes: fixes, program: program)) { _, new in new }
                scoped.merge(ProgramSettings.simsDisplayVariables(for: app, container: container, fixes: fixes, program: program)) { _, new in new }
                scoped.merge(PluginKeyMappings.environment(fixes.keyMappings, program: program)) { _, new in new }
                entries.append(ProgramSettings.Entry(program: program, variables: scoped))
            }
        }
        return entries
    }

    /// Steam spawns the publisher launcher itself. Route a launch back to Cell when Steam's Wine is too old.
    func writeSteamCompatibilityRoutes(for container: Container) {
        guard let helper = CellPaths.cliExecutable() else { return }
        let runtimes = services.runtimes.runtimes
        let mapper = WinePathMapper(prefix: container.prefixURL)
        var rows: [String] = []
        for app in services.library.apps(in: container.id) where app.kind == .steamGame {
            guard let appID = app.steamAppID, !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            let fixes = fixes(for: app, container: container)
            guard let minimum = fixes.minimumWineVersion, app.settings.runtimeOverride == nil else { continue }
            let version = LooseVersion(minimum)
            guard runtimes.contains(where: {
                LooseVersion($0.version) >= version && option(for: app, container: container, runtime: $0, fixes: fixes)?.verified == true
            }) else { continue }
            let programs = Set(ProgramSettings.programs(of: app) + fixes.steamCompatibilityLaunchers.compactMap(ProgramSettings.programName))
            let folder = app.windowsPath.flatMap { mapper.unixURL(forWindowsPath: $0) }?
                .deletingLastPathComponent().resolvingSymlinksInPath().path ?? ""
            for runtime in runtimes where LooseVersion(runtime.version) < version {
                for program in programs {
                    let fields = [runtime.id, appID, program, app.id.uuidString, folder, minimum]
                    if !fields.contains(where: { $0.contains("\t") || $0.contains("\n") }) { rows.append(fields.joined(separator: "\t")) }
                }
            }
        }
        let path = ProgramSettings.compatibilityURL(for: container)
        let text = "#\(helper.path)\n" + rows.sorted().map { $0 + "\n" }.joined()
        if (try? String(contentsOf: path, encoding: .utf8)) != text { try? text.write(to: path, atomically: true, encoding: .utf8) }
    }

    /// The folder (Wine's `lib/wine` layout) with the graphics engine's own libraries, when it isn't the one the
    /// Wine engine itself comes with.
    func graphicsLibraries(for backend: GraphicsBackend, app: AppEntry, runtime: WineRuntime) -> URL? {
        guard backend.usesEngineOverlay, backend != runtime.baseBackend, let kind = backend.componentKind,
              let component = services.components.best(kind, for: runtime, for32Bit: app.analysis?.architecture == .x86) else { return nil }
        let folder = component.libDirectory.appendingPathComponent("wine", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }
}
