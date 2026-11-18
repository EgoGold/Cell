import Foundation

/// One place that owns Cell's managers. Shared by the app and the CLI.
public final class CellServices: @unchecked Sendable {
    public static let shared = CellServices()

    public let library: LibraryStore
    public let runtimes: RuntimeManager
    public let components: ComponentManager
    public let plugins: PluginManager
    public private(set) var settings: CellSettings
    public private(set) lazy var planner = LaunchPlanner(services: self)
    public private(set) lazy var launcher = Launcher(services: self)
    /// Virtual machines (whole systems: Linux, macOS, Windows on Arm, Android images you bring).
    public let virtualMachines = VirtualMachineLibrary()
    /// Which Wine engine + graphics engine pairs really draw (checked once each, in the background).
    public private(set) lazy var verifier = EngineVerifier(services: self)

    public init() {
        try? CellPaths.ensureDirectories()
        library = LibraryStore()
        runtimes = RuntimeManager()
        components = ComponentManager()
        plugins = PluginManager()
        settings = CellSettings.load()
    }

    public func reloadAll() {
        library.reload()
        runtimes.reload()
        components.reload()
        plugins.reload()
        settings = CellSettings.load()
        verifier.reload()
        virtualMachines.reload()
    }

    /// Crash records from before Cell 0.3 round 10 are forgotten once: most were made by causes fixed since — Wine's
    /// crash debugger hanging every crashed game, a foreign ICU library stopping .NET games, and every game started
    /// through Steam running on Steam's graphics engine (32-bit games on D3DMetal), Unreal's Visual C++ prompt counted
    /// as a crash. They kept games off the engine that suits them (MeiQi 2019 was put on WineD3D).
    public static let crashRecordsRevision = 10

    public func forgetStaleCrashes() {
        guard settings.crashRecordsRevision < Self.crashRecordsRevision else { return }
        for container in library.containers {
            for app in library.apps(in: container.id) where !app.learned.failedCombinations.isEmpty || !app.learned.failedBackends.isEmpty {
                _ = try? library.update(appID: app.id) { entry in
                    entry.learned.failedCombinations = []
                    entry.learned.failedBackends = []
                }
            }
        }
        try? updateSettings { $0.crashRecordsRevision = Self.crashRecordsRevision }
    }

    public func updateSettings(_ change: (inout CellSettings) -> Void) throws {
        var updated = settings
        change(&updated)
        try updated.save()
        settings = updated
    }

    // MARK: Containers

    /// Creates the default "Games & Apps" container on first run.
    @discardableResult
    public func ensureDefaultContainer() throws -> Container {
        if let existing = library.defaultContainer { return existing }
        return try library.createContainer(name: "Games & Apps", platform: .windows,
                                           runtimeID: runtimes.recommendedRuntime?.id, makeDefault: true)
    }

    /// Stops Wine and deletes the container.
    public func deleteContainer(_ container: Container) async throws {
        if container.platform == .windows, let runtime = planner.runtime(for: container), container.isInitialized {
            await WineCommands.killAll(container: container, runtime: runtime)
        }
        try library.deleteContainer(container)
    }

    // MARK: Library

    static let genericProductNames: Set<String> = ["bootstrappackagedgame", "unity player", "unityplayer", "unrealgame",
                                                   "ue4game", "epic games", "microsoft® windows® operating system", "launcher"]

    public static func preferredName(for executable: URL, analysis: AppAnalysis?) -> String {
        var base = executable.deletingPathExtension().lastPathComponent
        for suffix in ["-Win64-Shipping", "-WinGDK-Shipping", "_x64", "64"] where base.hasSuffix(suffix) && base.count > suffix.count + 1 {
            base = String(base.dropLast(suffix.count))
        }
        for candidate in [analysis?.unityProduct, analysis?.productName, analysis?.fileDescription].compactMap({ $0 }) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count <= 60, !genericProductNames.contains(trimmed.lowercased()),
               !trimmed.lowercased().hasSuffix(".exe") {
                return trimmed
            }
        }
        return base
    }

    /// Adds a Windows program (inside or outside the container) to the library.
    @discardableResult
    /// Adds an app that comes as a whole folder (a portable game, a copy of an installed program) instead of an
    /// installer: the folder is copied into the layer (`C:\\Games\\<name>`, an instant clone on the same disk), its main
    /// program is found and added. A folder already inside the layer is used where it is.
    public func addFolder(_ folder: URL, to container: Container, status: Launcher.StatusHandler? = nil) throws -> AppEntry {
        let fm = FileManager.default
        let name = folder.lastPathComponent
        var destination = folder
        if !folder.standardizedFileURL.path.hasPrefix(container.driveC.standardizedFileURL.path + "/") {
            let games = container.driveC.appendingPathComponent("Games", isDirectory: true)
            try fm.createDirectory(at: games, withIntermediateDirectories: true)
            destination = games.appendingPathComponent(name, isDirectory: true)
            var number = 2
            while fm.fileExists(atPath: destination.path) {
                destination = games.appendingPathComponent("\(name) \(number)", isDirectory: true)
                number += 1
            }
            status?("Copying “\(name)” into “\(container.name)”…")
            try FileOps.cloneItem(at: folder, to: destination)
        }
        guard let program = SteamIntegration.mainExecutable(in: destination, gameName: name) else {
            throw LaunchError.noProgramInFolder(name)
        }
        return try addExecutable(program, to: container, name: Self.preferredName(for: program, analysis: AppAnalyzer.analyze(executable: program)) == program.deletingPathExtension().lastPathComponent ? name : nil)
    }

    public func addExecutable(_ url: URL, to container: Container, name: String? = nil, source: AppSource = .manual,
                              arguments: [String] = [], workingDirectory: String? = nil) throws -> AppEntry {
        let mapper = WinePathMapper(prefix: container.prefixURL)
        let windowsPath = mapper.windowsPath(for: url)
        if let existing = library.apps(in: container.id).first(where: { $0.windowsPath?.caseInsensitiveCompare(windowsPath) == .orderedSame }) {
            return existing
        }
        let analysis = AppAnalyzer.analyze(executable: url)
        let isSteam = url.lastPathComponent.lowercased() == "steam.exe"
        var app = AppEntry(containerID: container.id, name: isSteam ? "Steam" : (name ?? Self.preferredName(for: url, analysis: analysis)),
                           kind: isSteam ? .steamClient : .windowsExecutable, source: source, windowsPath: windowsPath,
                           workingDirectory: workingDirectory, launchArguments: arguments)
        app.analysis = analysis
        app.steamAppID = isSteam ? nil : analysis.steamAppID
        let artwork = app.steamAppID.map { SteamIntegration.artwork(appID: $0, in: container) }
        let icons = IconTools.cacheIcons(for: app, executable: url, artwork: artwork)
        app.iconFile = icons.0
        app.artworkFile = icons.1
        try library.save(app)
        return app
    }

    /// Finds programs installed into the container (Start Menu shortcuts) and Steam games; adds new ones.
    @discardableResult
    public func discoverApps(in container: Container) throws -> [AppEntry] {
        guard container.platform == .windows, container.isInitialized else { return [] }
        var added: [AppEntry] = []
        let mapper = WinePathMapper(prefix: container.prefixURL)
        // Apps analysed by an older analyzer are read again (e.g. their Unreal version decides the graphics engine).
        for app in library.apps(in: container.id) where app.windowsPath != nil
            && AppAnalyzer.needsRefresh(app, in: container) {
            _ = try? refreshAnalysis(for: app)
        }
        // Games Steam has uninstalled leave the library too (only when Steam's library can be read).
        if SteamIntegration.isInstalled(in: container) {
            let installed = Set(SteamIntegration.installedGames(in: container).map(\.appID))
            // A library that reads as empty is more likely out of reach (a disk not connected) than emptied: keep Home.
            if !installed.isEmpty {
            for app in library.apps(in: container.id) where app.kind == .steamGame {
                guard let id = app.steamAppID, !installed.contains(id) else { continue }
                if let shortcut = app.shortcutPath { ShortcutBuilder.removeShortcut(at: shortcut) }
                try? library.remove(app)
            }
            }
        }
        let existing = library.apps(in: container.id)
        var knownPaths = Set(existing.compactMap { $0.windowsPath?.lowercased() })
        let knownSteamIDs = Set(existing.compactMap(\.steamAppID))

        // Steam client.
        if let steamPath = SteamIntegration.steamWindowsPath(in: container), !existing.contains(where: { $0.kind == .steamClient }),
           let unix = mapper.unixURL(forWindowsPath: steamPath) {
            added.append(try addExecutable(unix, to: container, name: "Steam", source: .startMenu))
            knownPaths.insert(steamPath.lowercased())
        }

        // Start Menu shortcuts.
        let skipWords = ["uninstall", "unins0", "remove", "readme", "read me", "manual", "help", "support", "website", "eula",
                         "license", "release notes", "changelog", "documentation", "report", "repair", "update", "config"]
        var lnkFiles: [URL] = []
        var roots = [container.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs"),
                     container.driveC.appendingPathComponent("users/Public/Desktop")]
        let users = container.driveC.appendingPathComponent("users")
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] {
            roots.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs"))
            // The layer's own Desktop (never the Mac's: a link to it is left alone here and replaced at the next start).
            let desktop = users.appendingPathComponent("\(user)/Desktop")
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: desktop.path)) == nil { roots.append(desktop) }
        }
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "lnk" {
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                lnkFiles.append(file)
            }
        }
        for file in lnkFiles {
            let title = file.deletingPathExtension().lastPathComponent
            guard !skipWords.contains(where: { title.lowercased().contains($0) }),
                  let link = LnkFile(url: file), let target = link.targetPath,
                  target.lowercased().hasSuffix(".exe"), !knownPaths.contains(target.lowercased()),
                  let unix = mapper.unixURL(forWindowsPath: target), FileManager.default.fileExists(atPath: unix.path) else { continue }
            let lowerTarget = unix.lastPathComponent.lowercased()
            if skipWords.contains(where: { lowerTarget.contains($0) }) { continue }
            let arguments = link.arguments.map(LnkFile.splitArguments) ?? []
            let app = try addExecutable(unix, to: container, name: title, source: .startMenu, arguments: arguments,
                                        workingDirectory: link.workingDirectory)
            knownPaths.insert(target.lowercased())
            added.append(app)
        }

        // Steam games.
        for game in SteamIntegration.installedGames(in: container) where !knownSteamIDs.contains(game.appID) && game.isFullyInstalled {
            var app = AppEntry(containerID: container.id, name: game.name, kind: .steamGame, source: .steam, steamAppID: game.appID)
            let executable = SteamIntegration.mainExecutable(in: game.installDirectory, gameName: game.name)
            if let executable {
                app.windowsPath = mapper.windowsPath(for: executable)
                var analysis = AppAnalyzer.analyze(executable: executable)
                analysis.steamAppID = game.appID
                app.analysis = analysis
            }
            let icons = IconTools.cacheIcons(for: app, executable: executable, artwork: SteamIntegration.artwork(appID: game.appID, in: container))
            app.iconFile = icons.0
            app.artworkFile = icons.1
            try library.save(app)
            added.append(app)
        }
        // Steam can stay open while games are installed. Publish the new executable's renderer
        // before returning it to Home; otherwise its first Steam-library launch inherits Steam's.
        launcher.updateDockNames(for: container)
        return added
    }

    /// Re-reads the executable (after a game update) and refreshes icons.
    @discardableResult
    public func refreshAnalysis(for app: AppEntry) throws -> AppEntry? {
        guard let container = library.container(id: app.containerID), let windowsPath = app.windowsPath,
              let unix = WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: windowsPath),
              FileManager.default.fileExists(atPath: unix.path) else { return app }
        var analysis = AppAnalyzer.analyze(executable: unix)
        if analysis.steamAppID == nil { analysis.steamAppID = app.steamAppID }
        let artwork = app.steamAppID.map { SteamIntegration.artwork(appID: $0, in: container) }
        let icons = IconTools.cacheIcons(for: app, executable: unix, artwork: artwork)
        return try library.update(appID: app.id) { entry in
            entry.analysis = analysis
            if let icon = icons.0 { entry.iconFile = icon }
            if let art = icons.1 { entry.artworkFile = art }
        }
    }

    /// Downloads the official Steam installer and installs Steam silently into the container.
    @discardableResult
    public func installSteam(in container: Container, installer local: URL? = nil, status: Launcher.StatusHandler? = nil,
                             progress: Downloader.Progress? = nil) async throws -> AppEntry? {
        var installer = local ?? CellPaths.downloads.appendingPathComponent("SteamSetup.exe")
        if local == nil {
            status?("Downloading Steam…")
            installer = try await Downloader.download(Catalog.steamInstallerURL, to: installer, title: "Steam installer", progress: progress)
        }
        status?("Installing Steam…")
        try await launcher.runExecutable(installer, in: container, arguments: ["/S"], status: status)
        if local == nil { try? FileManager.default.removeItem(at: installer) }
        let current = library.container(id: container.id) ?? container
        if let steam = SteamIntegration.steamDirectory(in: current) {
            // Steam's first start downloads ~500 MB over one slow connection; fetch it now, all servers at once.
            SteamClientUpdater.applyDownloadSettings(steamDirectory: steam)
            let others = library.containers.filter { $0.id != current.id }.compactMap { SteamIntegration.steamDirectory(in: $0) }
            SteamClientUpdater.shareUpdateHosts(to: steam, from: others)
            status?("Downloading Steam…")
            if (try? await SteamClientUpdater.prefetch(steamDirectory: steam, timeout: 10, status: status))?.version != nil {
                var state = library.state(for: current)
                state.lastSteamUpdateCheck = Date()
                library.saveState(state, for: current)
            }
        }
        _ = try discoverApps(in: current)
        return library.apps(in: container.id).first { $0.kind == .steamClient }
    }

    /// Whether Microsoft's .NET Framework 4 (instead of Wine Mono) is installed in the container.
    public static func hasDotNetFramework(_ container: Container) -> Bool { hasDotNetFramework(driveC: container.driveC) }

    static func hasDotNetFramework(driveC drive: URL) -> Bool {
        let clr = ["windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll", "windows/Microsoft.NET/Framework/v4.0.30319/clr.dll"]
        guard clr.contains(where: { FileManager.default.fileExists(atPath: drive.appendingPathComponent($0).path) }) else { return false }
        // Microsoft's mscoree.dll, not Wine's stub (Wine's builtin stubs say so in their header).
        let mscoree = drive.appendingPathComponent("windows/system32/mscoree.dll")
        guard let head = try? FileHandle(forReadingFrom: mscoree).read(upToCount: 256) else { return false }
        return head.range(of: Data("Wine builtin DLL".utf8)) == nil && head.range(of: Data("Wine placeholder DLL".utf8)) == nil
    }

    /// The .NET Framework's files are there but Microsoft's loader (mscoree.dll) isn't: no .NET program can start.
    /// Happens when a game's own installer (or an older Cell) installed .NET 4.5 or newer on its own.
    public static func dotNetNeedsRepair(_ container: Container) -> Bool {
        hasDotNetRuntimeFiles(driveC: container.driveC) && !hasDotNetFramework(driveC: container.driveC)
    }

    static func hasDotNetRuntimeFiles(driveC drive: URL) -> Bool {
        FileManager.default.fileExists(atPath: drive.appendingPathComponent("windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll").path)
    }

    /// Installs Microsoft's .NET Framework 4.8 in place of Wine Mono, for .NET programs that need what Wine Mono
    /// lacks (Plain Craft Launcher, many tools and launchers), or repairs a half-installed one.
    ///
    /// Microsoft's loader (mscoree.dll) only ships in the 4.0 package: later Windows versions include it, so the
    /// 4.8 installer doesn't carry it, and the 4.0 installer refuses to run once anything newer is registered.
    /// So the two loader files are taken straight out of the 4.0 package and put in place of Wine's stubs, and
    /// only 4.8 is installed (reporting Windows 7). About two minutes; a repair takes seconds.
    public func installDotNetFramework(in container: Container, status: Launcher.StatusHandler? = nil,
                                       progress: Downloader.Progress? = nil, control: RunControl? = nil) async throws {
        let fm = FileManager.default
        let file40 = CellPaths.downloads.appendingPathComponent("dotNetFx40_Full_x86_x64.exe")
        let file48 = CellPaths.downloads.appendingPathComponent("ndp48-x86-x64-allos-enu.exe")
        let needsRuntime = !Self.hasDotNetRuntimeFiles(driveC: container.driveC)
        status?("Downloading .NET Framework…")
        let share = needsRuntime ? 0.4 : 1.0
        _ = try await Downloader.download(Catalog.dotNet40URL, to: file40, title: ".NET Framework 4.0", sha256: Catalog.dotNet40SHA256,
                                          progress: { fraction, received, total in progress?(fraction * share, received, total) })
        if needsRuntime {
            _ = try await Downloader.download(Catalog.dotNet48URL, to: file48, title: ".NET Framework 4.8", sha256: Catalog.dotNet48SHA256,
                                              progress: { fraction, received, total in progress?(0.4 + fraction * 0.6, received, total) })
        }
        try await launcher.prepareContainer(library.container(id: container.id) ?? container, status: status)
        let current = library.container(id: container.id) ?? container
        guard let runtime = launcher.activeRuntime(for: current) else { throw LaunchError.noRuntime(current.name) }
        func windows(_ version: String) async throws {
            try await WineCommands.applyRegistry([.set(.currentUser, "Software\\Wine", "Version", .string(version))], container: current, runtime: runtime)
        }
        // Engines that install Wine Mono into the layer (instead of sharing it): remove it.
        let list = try await WineCommands.run(["uninstaller", "--list"], container: current, runtime: runtime, timeout: 120)
        for line in list.stdout.split(whereSeparator: \.isNewline) where line.lowercased().contains("wine mono") {
            guard let code = line.split(separator: "|").first, code.hasPrefix("{") else { continue }
            status?("Removing Wine Mono…")
            _ = try? await WineCommands.run(["uninstaller", "--remove", String(code)], container: current, runtime: runtime, timeout: 300)
        }
        if control?.isStopped == true { throw LaunchError.stopped(".NET Framework") }

        status?("Adding Microsoft's .NET loader…")
        let work = current.driveC.appendingPathComponent("cell-dotnet-loader")
        try? fm.removeItem(at: work)
        defer { try? fm.removeItem(at: work) }
        let package = WinePathMapper(prefix: current.prefixURL).windowsPath(for: file40)
        _ = try await WineCommands.run([package, "/q", "/x:C:\\cell-dotnet-loader"], container: current, runtime: runtime, timeout: 600)
        try fm.createDirectory(at: work.appendingPathComponent("out"), withIntermediateDirectories: true)
        for (member, folder) in [("_003_mscoree_dll_amd64", "windows/system32"), ("_003_mscoree_dll_x86", "windows/syswow64")] {
            _ = try await WineCommands.run(["cabarc", "x", "C:\\cell-dotnet-loader\\netfx_Core.mzz", member, "C:\\cell-dotnet-loader\\out\\"],
                                           container: current, runtime: runtime, timeout: 600)
            let extracted = work.appendingPathComponent("out/\(member)")
            let target = current.driveC.appendingPathComponent("\(folder)/mscoree.dll")
            guard fm.fileExists(atPath: extracted.path), FileOps.isDirectory(target.deletingLastPathComponent()) else { continue }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: extracted, to: target)
        }

        var edits: [RegistryEdit] = [.set(.currentUser, "Software\\Wine\\DllOverrides", "mscoree", .string("native"))]
        if needsRuntime {
            // Wine claims ".NET 4.7" in both registry views; installers read the 32-bit one.
            edits += [.deleteKey(.localMachine, "Software\\Microsoft\\NET Framework Setup\\NDP\\v4"),
                      .deleteKey(.localMachine, "Software\\Wow6432Node\\Microsoft\\NET Framework Setup\\NDP\\v4")]
        }
        try await WineCommands.applyRegistry(edits, container: current, runtime: runtime)
        if needsRuntime {
            do {
                try await windows("win7")
                status?("Installing .NET Framework 4.8 (about two minutes)…")
                try await launcher.runExecutable(file48, in: current, arguments: ["/sfxlang:1027", "/q", "/norestart"], extraDllOverrides: "fusion=b",
                                                 status: nil, control: control)
            } catch {
                try? await windows(current.settings.windowsVersion.rawValue)
                throw error
            }
        }
        try await WineCommands.applyRegistry([.set(.localMachine, "Software\\Microsoft\\.NETFramework", "OnlyUseLatestCLR", .dword(1))],
                                             container: current, runtime: runtime)
        // The container's own Windows version again, plus Microsoft's mscoree from now on (part of its settings).
        var updated = library.container(id: container.id) ?? current
        updated.appliedConfigHash = nil
        try library.save(updated)
        try await launcher.applySettingsIfNeeded(updated, runtime: runtime)
        guard Self.hasDotNetFramework(updated) else {
            throw LaunchError.unsupported(".NET Framework", "The .NET Framework installer finished, but its files aren't in place. Its logs are in the container's Temp folder (Open Logs shows Cell's own).")
        }
        try? fm.removeItem(at: file40)
        try? fm.removeItem(at: file48)
        // Crashes recorded while .NET was missing say nothing about engines any more.
        for app in library.apps(in: container.id) where app.analysis?.isDotNet == true && !app.learned.failedCombinations.isEmpty {
            _ = try? library.update(appID: app.id) { $0.learned = LearnedCompat() }
        }
    }

    /// Installs Microsoft Edge WebView2 (the build that works under Wine) with Microsoft's own installer, which
    /// fetches it from Microsoft. A newer build that something else installed is replaced. About three minutes.
    public func installWebView2(in container: Container, status: Launcher.StatusHandler? = nil,
                                progress: Downloader.Progress? = nil, control: RunControl? = nil) async throws {
        var current = library.container(id: container.id) ?? container
        if WebView2.isReady(in: current) { return }
        let file = CellPaths.downloads.appendingPathComponent("MicrosoftEdgeWebview2Setup.exe")
        status?("Downloading Microsoft Edge WebView2…")
        _ = try await Downloader.download(WebView2.bootstrapperURL, to: file, title: "Microsoft Edge WebView2 installer", progress: progress)
        // The Windows 7 settings must be in the registry before the installer asks Microsoft which build to send.
        try await launcher.prepareContainer(current, status: status)
        current = library.container(id: container.id) ?? current
        if WebView2.installedVersion(in: current) != nil, let runtime = launcher.activeRuntime(for: current) {
            // A build that can't draw: take it out, or the installer keeps it.
            status?("Removing the WebView2 build that can't draw…")
            await WineCommands.killAll(container: current, runtime: runtime)
            try? FileManager.default.removeItem(at: current.driveC.appendingPathComponent("Program Files (x86)/Microsoft/EdgeWebView"))
            let client = "Microsoft\\EdgeUpdate\\Clients\\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
            try await WineCommands.applyRegistry([.deleteKey(.localMachine, "Software\\Wow6432Node\\\(client)"),
                                                  .deleteKey(.localMachine, "Software\\\(client)"),
                                                  .deleteKey(.currentUser, "Software\\\(client)")], container: current, runtime: runtime)
        }
        status?("Installing Microsoft Edge WebView2 (about three minutes)…")
        try await launcher.runExecutable(file, in: current, arguments: ["/silent", "/install"], status: nil, control: control)
        guard WebView2.isReady(in: current) else {
            let found = WebView2.installedVersion(in: current).map { "version \($0) was installed instead of \(WebView2.workingMajorVersion)" } ?? "nothing was installed"
            throw LaunchError.unsupported("Microsoft Edge WebView2", "Microsoft's WebView2 installer finished, but \(found). Check the Mac's internet connection and try again.")
        }
        try? FileManager.default.removeItem(at: file)
    }

    /// Puts in place what an installer needs (see KnownInstallers.Prerequisite), fetched with Cell's own downloader.
    public func installPrerequisites(_ needed: Set<KnownInstallers.Prerequisite>, in container: Container,
                                     status: Launcher.StatusHandler? = nil, control: RunControl? = nil) async throws {
        try await repairDotNetIfNeeded(in: container, status: status)
        if needed.contains(.webView2) {
            try await installWebView2(in: container, status: status, control: control)
        }
        if needed.contains(.visualCpp) {
            let current = library.container(id: container.id) ?? container
            if !(WebView2.hasVisualCpp("x64", in: current) && WebView2.hasVisualCpp("x86", in: current)) {
                try await installVisualCppRuntimes(in: current, status: status)
            }
        }
    }

    /// Installs Epic's classic launcher from Epic's Windows Installer package (offered in a layer's Settings).
    public func installEpicGamesLauncher(in container: Container, status: Launcher.StatusHandler? = nil,
                                         progress: Downloader.Progress? = nil, control: RunControl? = nil) async throws {
        let file = CellPaths.downloads.appendingPathComponent("EpicGamesLauncherInstaller.msi")
        status?("Downloading the Epic Games Launcher…")
        _ = try await Downloader.download(KnownInstallers.epicLauncherMSI, to: file, title: "Epic Games Launcher", progress: progress)
        status?("Installing the Epic Games Launcher…")
        try await launcher.runExecutable(file, in: library.container(id: container.id) ?? container, arguments: ["/qb", "/norestart"],
                                         status: status, control: control)
        try? FileManager.default.removeItem(at: file)
        _ = try discoverApps(in: library.container(id: container.id) ?? container)
    }

    /// Installs the Microsoft Visual C++ runtimes most games need.
    /// A half-installed .NET Framework makes other installers fail (their steps load it): repair it first.
    public func repairDotNetIfNeeded(in container: Container, status: Launcher.StatusHandler? = nil) async throws {
        let current = library.container(id: container.id) ?? container
        guard Self.dotNetNeedsRepair(current) else { return }
        status?("Repairing .NET Framework…")
        try await installDotNetFramework(in: current, status: status)
    }

    /// Microsoft's Visual C++ runtime files the newest programs need, checked in both Windows folders.
    static let visualCppFiles = ["msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll", "vcruntime140.dll"]

    /// Whether the Visual C++ runtime has to be (re)installed: one of Microsoft's files is missing from a Windows folder
    /// (or isn't Microsoft's: Wine's own copies carry no version).
    public static func visualCppNeedsInstall(_ container: Container) -> Bool {
        guard container.platform == .windows, container.isInitialized else { return false }
        let windows = container.driveC.appendingPathComponent("windows")
        var checks: [(String, [String])] = [("system32", visualCppFiles + ["vcruntime140_1.dll"])]
        if FileOps.isDirectory(windows.appendingPathComponent("syswow64")) { checks.append(("syswow64", visualCppFiles)) }
        for (folder, files) in checks {
            for file in files {
                let url = windows.appendingPathComponent("\(folder)/\(file)")
                guard let pe = PEFile(url: url) else { return true }
                if pe.versionStrings()["FileVersion"] == nil { return true }
            }
        }
        return false
    }

    /// Installs Visual C++ when its files aren't Microsoft's (see visualCppNeedsInstall).
    public func repairVisualCppIfNeeded(in container: Container, status: Launcher.StatusHandler? = nil) async {
        guard Self.visualCppNeedsInstall(container) else { return }
        status?("Installing Microsoft Visual C++…")
        try? await installVisualCppRuntimes(in: container, status: status)
    }

    public func installVisualCppRuntimes(in container: Container, status: Launcher.StatusHandler? = nil) async throws {
        try await repairDotNetIfNeeded(in: container, status: status)
        for url in [Catalog.vcRedistX64URL, Catalog.vcRedistX86URL] {
            let file = CellPaths.downloads.appendingPathComponent(url.lastPathComponent)
            status?("Downloading \(url.lastPathComponent)…")
            _ = try await Downloader.download(url, to: file, title: "Microsoft Visual C++ (\(url.lastPathComponent))")
            try await launcher.runExecutable(file, in: library.container(id: container.id) ?? container,
                                             arguments: ["/install", "/quiet", "/norestart"], status: status)
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Creates the /Applications shortcut and remembers where it is.
    @discardableResult
    public func addToApplications(_ app: AppEntry) throws -> URL {
        guard let container = library.container(id: app.containerID) else { throw LaunchError.containerMissing }
        let url = try ShortcutBuilder.createShortcut(for: app, container: container, settings: settings)
        try library.update(appID: app.id) { $0.shortcutPath = url.path }
        return url
    }

    public func removeFromApplications(_ app: AppEntry) throws {
        if let path = app.shortcutPath { ShortcutBuilder.removeShortcut(at: path) }
        try library.update(appID: app.id) { $0.shortcutPath = nil }
    }
}
