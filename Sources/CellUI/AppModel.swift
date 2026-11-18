import SwiftUI
import AppKit
import CellCore

public enum SidebarItem: Hashable {
    /// Every app and game (the start page).
    case home
    case running
    /// A Windows translation layer.
    case container(UUID)
    case virtualMachine(UUID)
    case engines
    case downloads
    case plugins
    case network
    case settings
    case setup
}

/// A background job shown in the activity list (downloads, installs, setup).
@MainActor
@Observable
final class Activity: Identifiable {
    let id = UUID()
    let title: String
    var detail = ""
    var progress: Double?
    var finished = false
    var failure: String?
    /// Set for work the person can stop (installers): ends the program.
    var stop: (() -> Void)?

    init(title: String) { self.title = title }
}

enum SetupStatus: Equatable {
    case pending
    case running(String, Double?)
    case done(String)
    case failed(String)
}

struct ErrorMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// UI state and actions. Views call into this; it calls into CellCore off the main thread.
@MainActor
@Observable
public final class AppModel {
    public static let shared = AppModel()

    let services: CellServices

    // Data
    var containers: [Container] = []
    var apps: [AppEntry] = []
    var runtimes: [WineRuntime] = []
    var components: [GraphicsComponent] = []
    var plugins: [InstalledPlugin] = []
    var pluginState = PluginState()
    var pluginErrors: [String] = []
    var settings = CellSettings()
    var importSuggestions: [ImportSuggestion] = []
    /// Engines found on this Mac that haven't been imported yet.
    var pendingImportSuggestions: [ImportSuggestion] {
        importSuggestions.filter { suggestion in !runtimes.contains { $0.originDescription == suggestion.url.path } }
    }

    // Virtual machines
    var virtualMachines: [VirtualMachine] = []
    var vmSessions: [UUID: VirtualMachineSession] = [:]
    var showNewVirtualMachine = false
    var virtualizationSupported: Bool { VirtualMachineConfigurator.isSupported }

    // Navigation & presentation
    var selection: SidebarItem? = .home
    var libraryPath = NavigationPath()
    var searchText = ""
    var showNewContainer = false
    var pendingDeletion: Container?
    var pendingUninstall: AppEntry?
    /// Windows programs running in containers (found by scanning processes every two seconds).
    var runningProcesses: [WineProcess] = []
    var scannedRunning: [UUID: [pid_t]] = [:]
    /// Set when the window was closed while something was still running: quit once it all stops.
    var quitWhenIdle = false
    /// Opens a new main window (SwiftUI's action, kept from the first window so Cell can open one when none is left).
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Brings Cell's main window to the front: the existing one (also when minimised or hidden), or a new one.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        quitWhenIdle = false
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }
    private var monitorTask: Task<Void, Never>?
    var errorMessage: ErrorMessage?
    var toast: String?

    // Activity
    var activities: [Activity] = []
    var launchStatus: [UUID: String] = [:]
    var sessions: [UUID: RunningSession] = [:]
    var lastOutcome: [UUID: LaunchOutcome] = [:]

    // Setup
    var setupSteps: [SetupStep] = []
    var setupStatus: [SetupStep.Kind: SetupStatus] = [:]
    var setupSkipped: Set<SetupStep.Kind> = []
    var setupRunning = false
    var bottles: [ExistingBottle] = []

    // Downloads
    var downloads: [DownloadSnapshot] = []
    var activeDownloadCount: Int { downloads.filter(\.isActive).count }

    // Engine checks
    /// What the background engine check is doing (nil when idle).
    var engineCheckStatus: String?
    /// Bumped whenever check results change, so views showing them refresh.
    var engineCheckRevision = 0

    // Network
    var firewallStatus: FirewallHelper.Status = .unknown
    var networkReport: NetworkDiagnostics.Report?
    var networkTesting = false
    var networkFixing = false

    init(services: CellServices = .shared) {
        self.services = services
        refresh()
        DownloadManager.shared.connectionsPerDownload = settings.downloadConnections
        DownloadManager.shared.addsConnectionsAutomatically = settings.automaticDownloadConnections
        DownloadManager.shared.reconnectsAutomatically = settings.reconnectDownloads
        DownloadMirrors.enabled = settings.useDownloadMirrors
        DownloadManager.shared.setUpdateHandler { [weak self] snapshots in
            Task { @MainActor in self?.downloads = snapshots }
        }
    }

    // MARK: Loading

    func refresh() {
        // Main-thread-only system facts (input methods, display) are cached for background work.
        LanguageResolver.prime()
        DisplayInfo.prime()
        services.library.reload()
        services.runtimes.reload()
        services.components.reload()
        services.plugins.reload()
        decisionCache.removeAll()
        containers = services.library.containers
        EADesktopLinks.shared.watch(containers)
        apps = services.library.apps
        runtimes = services.runtimes.runtimes
        components = services.components.components
        plugins = services.plugins.plugins
        pluginState = services.plugins.state
        pluginErrors = services.plugins.loadErrors
        settings = services.settings
        services.virtualMachines.reload()
        virtualMachines = services.virtualMachines.machines
    }

    /// Container tab requested by `CELL_UI_PAGE` (consumed by ContainerView).
    var requestedContainerTab: String?

    /// Developer/design switch: `CELL_UI_PAGE=engines|plugins|network|recent|container[:settings|:registry]|app:<name>`
    /// opens that page on launch, so every screen can be previewed directly.
    private func applyRequestedPage() {
        // Developer switch: CELL_UI_ACTION=prepare sets up the default container like "Set Up Now".
        if ProcessInfo.processInfo.environment["CELL_UI_ACTION"] == "prepare", let container = defaultContainer {
            setUp(container)
        }
        guard let page = ProcessInfo.processInfo.environment["CELL_UI_PAGE"]?.lowercased() else { return }
        switch page {
        case "engines": selection = .engines
        case "downloads": selection = .downloads
        case "setup": selection = .setup
        case "plugins": selection = .plugins
        case "network": selection = .network
        case "home", "library", "overview", "recent": selection = .home
        case "usage", "running": selection = .running
        case "settings": selection = .settings
        default:
            if page.hasPrefix("vm") {
                selection = virtualMachines.first.map { .virtualMachine($0.id) }
            } else if page.hasPrefix("container") {
                selection = containers.first.map { .container($0.id) }
                requestedContainerTab = page.split(separator: ":").dropFirst().first.map(String.init)
            } else if page.hasPrefix("app:") {
                let name = page.dropFirst(4)
                if let app = apps.first(where: { $0.name.lowercased() == name }) {
                    selection = .home
                    libraryPath = NavigationPath([app.id])
                }
            }
        }
    }

    /// Developer/design switch: `CELL_UI_SNAPSHOT=/path/file.png` renders the main window to a PNG and quits.
    private func scheduleSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["CELL_UI_SNAPSHOT"] else { return }
        // CELL_UI_SNAPSHOT_DELAY (seconds) waits longer for pages that load something first.
        let delay = Double(ProcessInfo.processInfo.environment["CELL_UI_SNAPSHOT_DELAY"] ?? "") ?? 3.5
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.performRequestedDrag()
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
               let view = window.contentView?.superview ?? window.contentView,
               let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: representation)
                try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Developer/design switch: `CELL_UI_DRAG=x1,y1,x2,y2` (window points from the top left) drags the mouse from
    /// the first point to the second before the snapshot, with events sent to the window itself, so dragging
    /// can be checked without anything appearing on screen. Prints Home's saved order afterwards.
    private func performRequestedDrag() async {
        guard let text = ProcessInfo.processInfo.environment["CELL_UI_DRAG"] else { return }
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4,
              let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else { return }
        if let offset = Double(ProcessInfo.processInfo.environment["CELL_UI_SCROLL_Y"] ?? "") {
            func findScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.frame.width > 500 { return scroll }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            if let root = window.contentView, let scroll = findScroll(root) {
                var bounds = scroll.contentView.bounds
                bounds.origin.y = offset
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(bounds).origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        let height = window.contentView?.superview?.bounds.height ?? window.frame.height
        // The events go straight to the view under the pointer: the hidden window is never key, so the usual
        // route (the app's event queue) would treat them as clicks that only activate the window.
        var target: NSView?
        func send(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
            let location = NSPoint(x: x, y: height - y)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            if type == .leftMouseDown { target = (window.contentView?.superview ?? window.contentView)?.hitTest(location) }
            switch type {
            case .leftMouseDown: target?.mouseDown(with: event)
            case .leftMouseDragged: target?.mouseDragged(with: event)
            default: target?.mouseUp(with: event)
            }
        }
        let began = Date()
        send(.leftMouseDown, numbers[0], numbers[1])
        // Like a trackpad: a few points per event, about 120 events a second, then small movements over the target.
        let distance = hypot(numbers[2] - numbers[0], numbers[3] - numbers[1])
        let steps = max(12, Int(distance / 3))
        var lastMoveStep = -100
        var moves = homeDragMoves
        for step in 1...steps where distance > 0 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            let t = Double(step) / Double(steps)
            send(.leftMouseDragged, numbers[0] + (numbers[2] - numbers[0]) * t, numbers[1] + (numbers[3] - numbers[1]) * t)
            if homeDragMoves != moves { moves = homeDragMoves; lastMoveStep = step }
            // CELL_UI_DRAG_SNAPSHOTS=folder: pictures of the first moments of the drag (the card being picked up) and
            // of the moments right after the other cards made room (where the dragged card used to jump).
            if let folder = ProcessInfo.processInfo.environment["CELL_UI_DRAG_SNAPSHOTS"], step <= 6 || step - lastMoveStep < 6,
               let view = window.contentView?.superview ?? window.contentView,
               let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: representation)
                try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(folder)/drag-\(step).png"))
            }
        }
        for jiggle in 0..<40 {
            try? await Task.sleep(nanoseconds: 8_000_000)
            send(.leftMouseDragged, numbers[2] + Double(jiggle % 3 - 1), numbers[3] + Double((jiggle / 3) % 3 - 1))
        }
        // Exercise edge scrolling with a stationary pointer, without generating more drag events.
        if let hold = Double(ProcessInfo.processInfo.environment["CELL_UI_DRAG_HOLD"] ?? ""), hold > 0 {
            try? await Task.sleep(nanoseconds: UInt64(min(hold, 10) * 1_000_000_000))
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        send(.leftMouseUp, numbers[2], numbers[3])
        try? await Task.sleep(nanoseconds: 600_000_000)
        let names = visibleApps.map(\.name).joined(separator: " | ")
        FileHandle.standardError.write(Data("Home order after drag: \(names)\nOrder changes while dragging: \(homeDragMoves), drag took \(String(format: "%.2f", Date().timeIntervalSince(began))) s\nSaved: \(settings.homeOrder.count) ids, path depth \(libraryPath.count), key \(window.isKeyWindow), active \(NSApp.isActive)\n".utf8))
    }

    /// First run: create the default container, discover what's installed, look for engines on this Mac.
    func bootstrap() {
        do { try services.ensureDefaultContainer() } catch { show("Couldn't create the default container", error) }
        services.forgetStaleCrashes()
        refresh()
        reloadSetup()
        if !settings.setupCompleted && setupSteps.contains(where: \.needed) { selection = .setup }
        applyRequestedPage()
        scheduleSnapshotIfRequested()
        startProcessMonitor()
        quitWhenIdle = false
        // Displays come and go (external monitors): settings use the current ones.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            DisplayInfo.prime()
        }
        let services = self.services
        Task.detached(priority: .utility) {
            let suggestions = RuntimeManager.importSuggestions()
            let discovered = services.library.containers
                .filter { $0.platform == .windows && $0.isInitialized }
                .map { (try? services.discoverApps(in: $0))?.isEmpty == false }
                .contains(true)
            for container in services.library.containers {
                services.launcher.updateDockNames(for: container)
                services.launcher.prepareGames(in: container)
                await services.launcher.applySettingsWhileRunning(in: container)
            }
            let bottles = BottleImporter.discover()
            await MainActor.run {
                self.importSuggestions = suggestions
                self.bottles = bottles
                if discovered { self.refresh() }
                if self.settings.setupCompleted { self.checkEngines() }
            }
        }
    }

    /// Whether some installed engine pair is checked to draw Direct3D 11 (nil while unknown).
    var canRunDirect3D11Games: Bool? {
        _ = engineCheckRevision
        let verifier = services.verifier
        var unknown = false
        for runtime in runtimes {
            for backend in verifier.checkableBackends(for: runtime) {
                guard let check = verifier.check(runtime: runtime, backend: backend), check.isConclusive else { unknown = true; continue }
                if check.runsDirect3D11 { return true }
            }
        }
        return unknown || runtimes.isEmpty ? nil : false
    }

    /// Checks every Wine engine + graphics engine pair that hasn't been checked yet, in the background
    /// (about 15 seconds per engine plus a few per graphics engine; nothing appears on screen).
    func checkEngines(again: Bool = false) {
        guard engineCheckStatus == nil else { return }
        if again { services.verifier.reset() }
        guard services.verifier.hasUncheckedPairs else { engineCheckRevision += 1; return }
        engineCheckStatus = "Checking graphics engines…"
        let services = self.services
        Task { @MainActor in
            await Task.detached(priority: .utility) {
                await services.verifier.verifyAll(status: { message in
                    Task { @MainActor in self.engineCheckStatus = message }
                })
            }.value
            engineCheckStatus = nil
            engineCheckRevision += 1
        }
    }

    // MARK: Virtual machines

    func virtualMachine(_ id: UUID) -> VirtualMachine? { virtualMachines.first { $0.id == id } }

    func isRunning(_ machine: VirtualMachine) -> Bool { vmSessions[machine.id]?.isRunning ?? false }

    func createVirtualMachine(name: String, guest: GuestSystem, installer: URL?, cpuCount: Int, memoryMiB: Int, diskGiB: Int) {
        let services = self.services
        perform("Creating “\(name)”") { _ in
            let machine = try await self.background {
                try services.virtualMachines.create(name: name, guest: guest, installer: installer, cpuCount: cpuCount,
                                                    memoryMiB: memoryMiB, diskGiB: diskGiB)
            }
            self.refresh()
            self.selection = .virtualMachine(machine.id)
        }
    }

    func importVirtualMachine(_ url: URL) {
        let services = self.services
        perform("Importing \(url.lastPathComponent)") { _ in
            let machine = try await self.background { try services.virtualMachines.importBundle(url) }
            self.refresh()
            self.selection = .virtualMachine(machine.id)
        }
    }

    /// Starts a machine (installing macOS first when needed) and opens its window.
    func start(_ machine: VirtualMachine, openWindow: @escaping (UUID) -> Void) {
        guard !isRunning(machine) else { openWindow(machine.id); return }
        perform("Starting “\(machine.name)”") { activity in
            var current = self.virtualMachine(machine.id) ?? machine
            #if arch(arm64)
            if current.guest == .macOS && !current.isInstalled {
                activity.detail = "Reading the restore image…"
                _ = try await VirtualMachineConfigurator.prepareMacInstallation(current)
                let installer = try VirtualMachineSession(machine: current)
                activity.detail = "Installing macOS (this takes a while)…"
                try await installer.installMacOS { fraction in
                    Task { @MainActor in activity.progress = fraction }
                }
                try self.services.virtualMachines.finishInstallation(current)
                self.refresh()
                current = self.virtualMachine(machine.id) ?? current
            }
            #endif
            // Experimental: a machine tied to a display takes that display's resolution.
            if let id = current.displayID {
                let display = DisplayInfo.resolve(id)
                if display.id == id, current.displayWidth != display.pixelWidth || current.displayHeight != display.pixelHeight {
                    current.displayWidth = display.pixelWidth
                    current.displayHeight = display.pixelHeight
                    try? self.services.virtualMachines.save(current)
                }
            }
            let session = try VirtualMachineSession(machine: current)
            session.onStop = { error in
                self.vmSessions[current.id] = nil
                if let error { self.errorMessage = ErrorMessage(title: "“\(current.name)” stopped", message: error.localizedDescription) }
            }
            try await session.start()
            self.vmSessions[current.id] = session
            openWindow(current.id)
        }
    }

    func shutDown(_ machine: VirtualMachine) {
        guard let session = vmSessions[machine.id] else { return }
        do { try session.requestShutdown() } catch { show("Couldn't ask “\(machine.name)” to shut down", error) }
    }

    func forceStop(_ machine: VirtualMachine) {
        guard let session = vmSessions[machine.id] else { return }
        Task { @MainActor in
            try? await session.forceStop()
            self.vmSessions[machine.id] = nil
        }
    }

    func finishInstallation(_ machine: VirtualMachine) {
        do {
            try services.virtualMachines.finishInstallation(machine)
            refresh()
            flash("“\(machine.name)” now starts from its own disk.")
        } catch { show("Couldn't update “\(machine.name)”", error) }
    }

    func updateVirtualMachine(_ machine: VirtualMachine) {
        do { try services.virtualMachines.save(machine); refresh() } catch { show("Couldn't save “\(machine.name)”", error) }
    }

    func delete(_ machine: VirtualMachine) {
        if let session = vmSessions[machine.id] {
            Task { @MainActor in try? await session.forceStop() }
            vmSessions[machine.id] = nil
        }
        do {
            try services.virtualMachines.delete(machine)
            if selection == .virtualMachine(machine.id) { selection = .home }
            refresh()
            flash("Moved “\(machine.name)” to the Trash.")
        } catch { show("Couldn't delete “\(machine.name)”", error) }
    }

    // MARK: Helpers

    func show(_ title: String, _ error: Error) {
        errorMessage = ErrorMessage(title: title, message: error.localizedDescription)
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == message { toast = nil }
        }
    }

    @discardableResult
    func perform(_ title: String, _ work: @escaping @MainActor (Activity) async throws -> Void) -> Task<Void, Never> {
        let activity = Activity(title: title)
        // Trying something again replaces its earlier failure in the list.
        activities.removeAll { $0.title == title && $0.failure != nil }
        activities.append(activity)
        return Task { @MainActor in
            do {
                try await work(activity)
                activity.finished = true
            } catch {
                activity.finished = true
                activity.failure = error.localizedDescription
                show(title, error)
            }
            refresh()
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            activities.removeAll { $0.id == activity.id && $0.failure == nil }
            // A failure was already explained in a dialog: its line leaves after a minute.
            try? await Task.sleep(nanoseconds: 56_000_000_000)
            activities.removeAll { $0.id == activity.id }
        }
    }

    /// Runs blocking core work off the main thread.
    func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    func container(_ id: UUID?) -> Container? { containers.first { $0.id == id } }
    /// Translation layers shown in Cell.
    var visibleContainers: [Container] { containers.filter { $0.platform == .windows } }
    func app(_ id: UUID) -> AppEntry? { apps.first { $0.id == id } }
    func apps(in container: Container) -> [AppEntry] { apps.filter { $0.containerID == container.id } }
    func runtime(for container: Container) -> WineRuntime? { services.planner.runtime(for: container) }
    var defaultContainer: Container? { containers.first { $0.isDefault } ?? containers.first { $0.platform == .windows } }
    var hasEngine: Bool { !runtimes.isEmpty }
    func isRunning(_ app: AppEntry) -> Bool {
        isStopping(app) || (sessions[app.id]?.isRunning ?? false) || scannedRunning[app.id] != nil
    }

    func runningPrograms(in container: Container) -> [WineProcess] { runningProcesses.filter { $0.containerID == container.id } }

    /// Something Cell should stay open for (in the menu bar) after its window is closed.
    var hasBackgroundWork: Bool {
        !runningProcesses.isEmpty || sessions.values.contains { $0.isRunning } || downloads.contains { $0.isActive }
            || setupRunning || activities.contains { !$0.finished } || vmSessions.values.contains { $0.isRunning }
    }

    /// How many things run right now (apps in translation layers and virtual machines), for the sidebar.
    var runningCount: Int {
        let apps = Set(scannedRunning.keys).union(sessions.filter { $0.value.isRunning }.map(\.key)).count
        return apps + vmSessions.values.filter(\.isRunning).count
    }

    /// Scans for running Windows programs every two seconds; quits Cell when its window is closed and nothing runs.
    func startProcessMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { @MainActor [weak self] in
            // Leftovers of earlier sessions (hung crash debuggers and Wine helpers kept running for days).
            if let containers = self?.containers.filter({ $0.platform == .windows }) {
                await Task.detached(priority: .utility) { for container in containers { WineProcessScanner.endOrphans(of: container) } }.value
            }
            var nextInstallCheck = Date.distantPast
            var installedSteamGames: [UUID: Set<String>] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let containers = self.containers
                let apps = self.apps
                if Date() >= nextInstallCheck {
                    nextInstallCheck = Date().addingTimeInterval(20)
                    let installed = await Task.detached(priority: .utility) {
                        containers.filter { $0.platform == .windows && $0.isInitialized }.reduce(into: [UUID: Set<String>]()) {
                            $0[$1.id] = Set(SteamIntegration.installedGames(in: $1).filter(\.isFullyInstalled).map(\.appID))
                        }
                    }.value
                    let newlyInstalled = installed.contains { id, games in
                        let known = installedSteamGames[id] ?? Set(apps.lazy.filter { $0.containerID == id }.compactMap(\.steamAppID))
                        return !games.subtracting(known).isEmpty
                    }
                    installedSteamGames = installed
                    if newlyInstalled { self.rescanQuietly() }
                }
                let processes = await Task.detached(priority: .utility) { WineProcessScanner.scan(containers: containers) }.value
                let running = WineProcessScanner.runningApps(processes, apps: apps)
                if processes != self.runningProcesses { self.runningProcesses = processes }
                let pending = self.pendingStops.filter { _, targets in
                    targets.contains { pid, startedAt in WineProcessScanner.startTime(of: pid) == startedAt }
                }
                if pending != self.pendingStops { self.pendingStops = pending }
                let individual = self.pendingProgramStops.intersection(processes)
                if individual != self.pendingProgramStops { self.pendingProgramStops = individual }
                if running != self.scannedRunning {
                    let stopped = Set(self.scannedRunning.keys).subtracting(running.keys)
                    self.scannedRunning = running
                    // A Steam game was uninstalled or a program finished: refresh the library.
                    if !stopped.isEmpty {
                        let services = self.services
                        for id in stopped { await services.launcher.repairDisplayAfterExit(appID: id) }
                        self.rescanQuietly()
                    }
                }
                self.showMessageBoxes()
                if self.quitWhenIdle, !self.hasBackgroundWork, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    NSApp.terminate(nil)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// How far each launch log has been read for message boxes.
    private var messageLogOffsets: [URL: UInt64] = [:]

    /// Shows the text of Windows message boxes (errors) in Cell: a fullscreen game can hide its dialog,
    /// and some engines draw dialogs without text.
    private func showMessageBoxes() {
        for session in sessions.values {
            let url = session.logURL
            let offset = messageLogOffsets[url] ?? 0
            guard let (text, end) = WineMessageBoxes.newText(of: url, from: offset) else { continue }
            messageLogOffsets[url] = end
            let messages = WineMessageBoxes.messages(in: text)
            guard let message = messages.last else { continue }
            var speaker = session.plan.app.name
            if session.plan.kind != .direct {
                // Games started from Steam's window write into Steam's log.
                let games = apps.filter { $0.containerID == session.plan.container.id && $0.kind == .steamGame && scannedRunning[$0.id] != nil }
                if games.count == 1 { speaker = games[0].name } else if session.plan.kind == .steamClient { speaker = "A game started from Steam" }
            }
            // Kept, not shown: the game's own message box shows its text, and a second window from Cell only got in
            // the way. (The launch log has every message too.)
            lastGameMessage = (speaker, message)
        }
    }

    /// The last message box a game showed (its own window has it; Cell no longer opens one of its own).
    @ObservationIgnored var lastGameMessage: (from: String, text: String)?

    private func rescanQuietly() {
        let services = self.services
        let containers = self.containers.filter { $0.platform == .windows && $0.isInitialized }
        Task {
            let changed = await Task.detached(priority: .utility) {
                containers.map { (try? services.discoverApps(in: $0))?.isEmpty == false }.contains(true)
            }.value
            _ = changed
            refresh()
        }
    }

    var visibleApps: [AppEntry] {
        let showHidden = settings.showHiddenApps
        let filtered = apps.filter { showHidden || !$0.isHidden }
        let search = searchText.trimmingCharacters(in: .whitespaces)
        let matching = search.isEmpty ? filtered : filtered.filter { $0.name.localizedCaseInsensitiveContains(search) }
        // The order arranged on Home by dragging; apps that were never placed follow alphabetically.
        let position = Dictionary(settings.homeOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return matching.sorted { lhs, rhs in
            switch (position[lhs.id], position[rhs.id]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    var recentApps: [AppEntry] {
        apps.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    // MARK: Containers

    func createContainer(name: String, platform: PlatformKind, runtimeID: String?) {
        do {
            let container = try services.library.createContainer(name: name, platform: platform, runtimeID: runtimeID)
            refresh()
            selection = .container(container.id)
        } catch {
            show("Couldn't create the container", error)
        }
    }

    func save(_ container: Container) {
        do {
            try services.library.save(container)
            if let index = containers.firstIndex(where: { $0.id == container.id }) { containers[index] = container }
        } catch {
            show("Couldn't save settings", error)
        }
    }

    func makeDefault(_ container: Container) {
        do { try services.library.setDefault(container); refresh() } catch { show("Couldn't change the default container", error) }
    }

    func delete(_ container: Container) {
        let services = self.services
        perform("Deleting “\(container.name)”") { _ in
            try await services.deleteContainer(container)
            if self.selection == .container(container.id) { self.selection = .home }
        }
    }

    func setUp(_ container: Container) {
        let services = self.services
        perform("Setting up “\(container.name)”") { activity in
            try await services.launcher.prepareContainer(container) { message in
                Task { @MainActor in activity.detail = message }
            }
            _ = try await self.background { try services.discoverApps(in: services.library.container(id: container.id) ?? container) }
        }
    }

    func rescan(_ container: Container) {
        let services = self.services
        perform("Looking for apps in “\(container.name)”") { _ in
            let added = try await self.background {
                try services.discoverApps(in: container)
            }
            self.flash(added.isEmpty ? "No new apps found." : "Added \(added.map(\.name).joined(separator: ", ")).")
        }
    }

    func stopAll(_ container: Container) {
        guard let runtime = runtime(for: container) else { return }
        Task {
            await WineCommands.killAll(container: container, runtime: runtime)
            flash("Stopped everything in “\(container.name)”.")
        }
    }

    func openDriveC(_ container: Container) {
        NSWorkspace.shared.activateFileViewerSelecting([container.driveC])
    }

    func openLogs(_ container: Container) {
        try? FileManager.default.createDirectory(at: container.logsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(container.logsDirectory)
    }

    // MARK: Adding apps

    /// Handles dropped or chosen Windows installers and programs.
    func open(_ urls: [URL], into target: Container? = nil) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            // A whole app folder (a portable game, a copy of an installed program) instead of an installer.
            if FileOps.isDirectory(url), ext != "app", !PluginManager.pluginExtensions.contains(ext) {
                guard let container = (target?.platform == .windows ? target : nil) ?? defaultContainer else { continue }
                addFolder(url, to: container)
                continue
            }
            if PluginManager.pluginExtensions.contains(ext)
                        || (ext == "zip" && PluginManager.pluginExtensions.contains { url.lastPathComponent.contains($0) }) {
                importPlugin(url)
            } else if ["msix", "msixbundle", "appx", "appxbundle", "appinstaller"].contains(ext) {
                if case .unsupported(let title, let explanation) = KnownInstallers.verdict(for: url) {
                    errorMessage = ErrorMessage(title: title, message: explanation)
                }
            } else if ext == "exe" || ext == "msi" || ext == "bat" || ext == "lnk" {
                guard let container = (target?.platform == .windows ? target : nil) ?? defaultContainer else { continue }
                let name = url.lastPathComponent.lowercased()
                let insideCell = url.standardizedFileURL.path.hasPrefix(CellPaths.containers.standardizedFileURL.path)
                // A program inside another app's bottle (Porting Kit, CrossOver, Whisky) only works with that bottle:
                // bring the whole bottle over (instant clone) instead of running it out of context.
                if !insideCell, let bottle = BottleImporter.bottle(containing: url) {
                    if let existing = containers.first(where: { $0.importedFrom == bottle.prefix.path }) {
                        selection = .container(existing.id)
                        flash("“\(bottle.name)” is already in Cell as “\(existing.name)”.")
                    } else {
                        importBottle(bottle, thenOpen: url)
                    }
                    continue
                }
                if name == "steam.exe" && !insideCell {
                    installSteam(in: container)
                    continue
                }
                if name.hasPrefix("steamsetup") {
                    installSteam(in: container, installer: url)
                    continue
                }
                let isInstaller = ext == "msi" || AppAnalyzer.looksLikeInstaller(name: url.lastPathComponent, description: nil)
                if isInstaller { runInstaller(url, in: container) } else { addProgram(url, to: container) }
            }
        }
    }

    func addFolder(_ folder: URL, to container: Container) {
        let services = self.services
        perform("Adding \(folder.lastPathComponent)") { activity in
            let status: Launcher.StatusHandler = { message in Task { @MainActor in activity.detail = message } }
            let app = try await self.background { try services.addFolder(folder, to: container, status: status) }
            self.refresh()
            self.selection = .home
            self.libraryPath = NavigationPath([app.id])
        }
    }

    func addProgram(_ url: URL, to container: Container) {
        let services = self.services
        perform("Adding \(url.deletingPathExtension().lastPathComponent)") { _ in
            var resolved = url
            if url.pathExtension.lowercased() == "lnk", let link = LnkFile(url: url), let path = link.targetPath,
               let unix = WinePathMapper(prefix: container.prefixURL).unixURL(forWindowsPath: path) {
                resolved = unix
            }
            let target = resolved
            let app = try await self.background { try services.addExecutable(target, to: container) }
            self.refresh()
            self.selection = .home
            self.libraryPath = NavigationPath([app.id])
        }
    }

    func runInstaller(_ url: URL, in container: Container) {
        if case .unsupported(let title, let explanation) = KnownInstallers.verdict(for: url) {
            errorMessage = ErrorMessage(title: title, message: explanation)
            return
        }
        let services = self.services
        let control = RunControl()
        perform("Installing \(url.lastPathComponent)") { activity in
            if !self.hasEngine { throw LaunchError.noRuntime(container.name) }
            activity.stop = { control.stop() }
            let status: Launcher.StatusHandler = { message in Task { @MainActor in activity.detail = message } }
            // What the installer would otherwise download itself (and often fail at) is put in place first.
            let needed = try await self.background { KnownInstallers.prerequisites(for: url) }
            try await services.installPrerequisites(needed, in: container, status: status, control: control)
            _ = try await services.launcher.runExecutable(url, in: services.library.container(id: container.id) ?? container,
                                                          status: status, control: control)
            activity.stop = nil
            let added = try await self.background { try services.discoverApps(in: services.library.container(id: container.id) ?? container) }
            self.flash(added.isEmpty ? "Installer finished." : "Installed \(added.map(\.name).joined(separator: ", ")).")
        }
    }

    /// Epic's classic launcher, from Epic's own package (the layer's Settings).
    func installEpicGamesLauncher(in container: Container) {
        let services = self.services
        let control = RunControl()
        perform("Installing the Epic Games Launcher") { activity in
            activity.stop = { control.stop() }
            try await services.installEpicGamesLauncher(in: container, status: { message in
                Task { @MainActor in activity.detail = message }
            }, progress: { fraction, _, _ in
                Task { @MainActor in activity.progress = fraction }
            }, control: control)
            activity.stop = nil
        }
    }

    /// Microsoft's .NET Framework 4.8 in place of Wine Mono (several minutes).
    func installDotNet(in container: Container, thenStart app: AppEntry? = nil) {
        let services = self.services
        let control = RunControl()
        perform("Installing .NET Framework 4.8") { activity in
            activity.stop = { control.stop() }
            try await services.installDotNetFramework(in: container, status: { message in
                Task { @MainActor in activity.detail = message }
            }, progress: { fraction, _, _ in
                Task { @MainActor in activity.progress = fraction }
            }, control: control)
            activity.stop = nil
            if let app { self.launch(app) } else { self.flash(".NET Framework 4.8 is installed in “\(container.name)”.") }
        }
    }

    /// A .NET program crashed on Wine Mono: offer Microsoft's .NET Framework (and start it again).
    var dotNetSuggestion: AppEntry?

    func hideSteamSuggestion(_ container: Container) {
        var updated = container
        updated.settings.hideSteamSuggestion = true
        save(updated)
    }

    func installSteam(in container: Container, installer: URL? = nil) {
        let services = self.services
        perform("Installing Steam") { activity in
            _ = try await services.installSteam(in: container, installer: installer, status: { message in
                Task { @MainActor in activity.detail = message }
            }, progress: { fraction, _, _ in
                Task { @MainActor in activity.progress = fraction }
            })
            self.flash("Steam is installed. Sign in once, then your games show up here.")
        }
    }

    func installVisualCpp(in container: Container) {
        let services = self.services
        perform("Installing Visual C++ runtimes") { activity in
            try await services.installVisualCppRuntimes(in: container) { message in
                Task { @MainActor in activity.detail = message }
            }
        }
    }

    // MARK: Apps

    func save(_ app: AppEntry) {
        do {
            try services.library.save(app)
            decisionCache[app.id] = nil
            if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = app }
        } catch {
            show("Couldn't save", error)
        }
    }

    func remove(_ app: AppEntry) {
        do {
            try services.library.remove(app)
            libraryPath = NavigationPath()
            refresh()
        } catch {
            show("Couldn't remove the app", error)
        }
    }

    /// Remembers the order Home's cards were dragged into. Apps not shown right now (hidden ones) keep their
    /// places after the ones shown.
    func setHomeOrder(_ shown: [UUID]) {
        let rest = settings.homeOrder.filter { !shown.contains($0) }
        updateSettings { $0.homeOrder = shown + rest }
    }

    func rename(_ app: AppEntry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != app.name else { return }
        var updated = app
        updated.name = trimmed
        save(updated)
        services.launcher.updateDockNames(for: container(app.containerID) ?? Container(name: ""))
    }

    /// The app being renamed (Home's Rename… sheet).
    var renaming: AppEntry?

    /// Hides an app from Home (it stays in its translation layer, so a rescan doesn't bring it back).
    func removeFromHome(_ app: AppEntry) {
        var updated = app
        updated.isHidden = true
        save(updated)
        flash("Removed “\(app.name)” from Home. It's still in “\(container(app.containerID)?.name ?? "its translation layer")”.")
    }

    func showOnHome(_ app: AppEntry) {
        var updated = app
        updated.isHidden = false
        save(updated)
    }

    func goToContainer(of app: AppEntry) {
        libraryPath = NavigationPath()
        selection = .container(app.containerID)
    }

    func launch(_ app: AppEntry) {
        guard !isRunning(app) else { return }
        launchStatus[app.id] = "Starting…"
        let services = self.services
        let appID = app.id
        Task { @MainActor in
            do {
                let session = try await services.launcher.launch(appID: appID, status: { message in
                    Task { @MainActor in self.launchStatus[appID] = message }
                }, onExit: { outcome, session in
                    Task { @MainActor in self.handleExit(outcome, session: session) }
                })
                if session.plan.kind != .steamGame { sessions[appID] = session }
                launchStatus[appID] = session.plan.kind == .steamGame ? "Started through Steam" : nil
                if session.plan.kind == .steamGame {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 6_000_000_000)
                        if self.launchStatus[appID] == "Started through Steam" { self.launchStatus[appID] = nil }
                    }
                }
                refresh()
            } catch {
                launchStatus[appID] = nil
                show("Couldn't start \(app.name)", error)
            }
        }
    }

    private func handleExit(_ outcome: LaunchOutcome, session: RunningSession?) {
        lastOutcome[outcome.appID] = outcome
        if sessions[outcome.appID] === session { sessions[outcome.appID] = nil }
        if let session, services.launcher.willRetry(after: outcome, session: session), let next = outcome.retryBackend {
            launchStatus[outcome.appID] = "Trying \(next.displayName)…"
        } else {
            launchStatus[outcome.appID] = nil
            if outcome.findings.contains(where: { $0.id == LogAnalyzer.dotNetGap }), let app = app(outcome.appID),
               let container = container(app.containerID), !CellServices.hasDotNetFramework(container) {
                dotNetSuggestion = app
            } else if outcome.crashedEarly {
                let advice = outcome.findings.first.map { "\n\n\($0.title)" + ($0.advice.map { ": \($0)" } ?? "") } ?? ""
                errorMessage = ErrorMessage(title: "The app quit right after starting",
                                            message: "Cell tried every suitable graphics engine.\(advice)")
            }
        }
        refresh()
    }

    /// How often Home's order changed during drags (checked by the CELL_UI_DRAG test).
    @ObservationIgnored var homeDragMoves = 0

    /// The PIDs and start times of apps that have received a quit request.
    private var pendingStops: [UUID: [pid_t: Date]] = [:]
    private var pendingProgramStops: Set<WineProcess> = []

    func isStopping(_ process: WineProcess) -> Bool {
        pendingProgramStops.contains(process)
    }

    func stop(_ process: WineProcess) {
        guard let container = container(process.containerID),
              let startedAt = process.startedAt, startedAt == WineProcessScanner.startTime(of: process.pid) else { return }
        if process.executableName == "steam.exe" {
            quitSteam(in: container)
            return
        }
        if !pendingProgramStops.insert(process).inserted {
            kill(process.pid, SIGKILL)
        } else {
            for session in sessions.values where session.process.processIdentifier == process.pid {
                session.recordStopRequest()
            }
            if NSRunningApplication(processIdentifier: process.pid)?.terminate() != true {
                kill(process.pid, SIGTERM)
            }
        }
    }

    func isStopping(_ app: AppEntry) -> Bool {
        pendingStops[app.kind == .steamClient ? app.containerID : app.id] != nil
    }

    /// "Quit", "Quit Steam", or "Force Quit" while quitting doesn't finish.
    func quitTitle(for app: AppEntry) -> String {
        if isStopping(app) { return "Force Quit" }
        return app.kind == .steamClient ? "Quit Steam" : "Quit"
    }

    func stop(_ app: AppEntry) {
        guard let container = container(app.containerID) else { return }
        if app.kind == .steamClient {
            quitSteam(in: container)
            return
        }
        if forcePendingStop(app.id) { return }

        let session = sessions[app.id]
        let running = WineProcessScanner.scan(containers: [container])
        var pids = WineProcessScanner.runningApps(running, apps: [app])[app.id] ?? []
        if let session, session.isRunning { pids.append(session.process.processIdentifier) }
        let targets = rememberStop(app.id, pids: pids)
        guard !targets.isEmpty else { return }
        session?.recordStopRequest()
        for pid in targets {
            // Wine's macOS app forwards a standard quit request to Windows. Programs without a
            // registered macOS application can still be asked to exit with SIGTERM.
            if NSRunningApplication(processIdentifier: pid)?.terminate() != true { kill(pid, SIGTERM) }
        }
    }

    func steamQuitTitle(in container: Container) -> String {
        isStoppingSteam(in: container) ? "Force Quit Steam" : "Quit Steam"
    }

    func isStoppingSteam(in container: Container) -> Bool {
        pendingStops[container.id] != nil
    }

    func quitSteam(in container: Container) {
        if forcePendingStop(container.id) { return }
        let running = WineProcessScanner.scan(containers: [container])
        let pids = running.filter { ["steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe"].contains($0.executableName) }.map(\.pid)
        guard !rememberStop(container.id, pids: pids).isEmpty else { return }
        for session in sessions.values where session.plan.container.id == container.id && session.plan.kind == .steamClient {
            session.recordStopRequest()
        }
        let services = self.services
        perform("Quitting Steam") { _ in
            await services.launcher.requestSteamQuit(in: container)
        }
    }

    private func rememberStop(_ id: UUID, pids: [pid_t]) -> [pid_t] {
        var targets: [pid_t: Date] = [:]
        for pid in Set(pids) where pid > 0 {
            targets[pid] = WineProcessScanner.startTime(of: pid)
        }
        if !targets.isEmpty { pendingStops[id] = targets }
        return Array(targets.keys)
    }

    private func forcePendingStop(_ id: UUID) -> Bool {
        guard let targets = pendingStops[id] else { return false }
        for (pid, startedAt) in targets where WineProcessScanner.startTime(of: pid) == startedAt {
            kill(pid, SIGKILL)
        }
        return true
    }

    /// Ends every Windows program in a container.
    func stopAll(in container: Container) {
        let services = self.services
        perform("Stopping everything in “\(container.name)”") { _ in
            await services.launcher.stopAll(in: container)
        }
    }

    // MARK: Uninstall

    func uninstallPlan(for app: AppEntry) -> UninstallPlan { services.uninstallPlan(for: app) }

    func uninstall(_ app: AppEntry) {
        let services = self.services
        let isSteamGame = app.kind == .steamGame
        perform("Uninstalling \(app.name)") { activity in
            try await services.uninstall(app)
            self.libraryPath = NavigationPath()
            self.flash(isSteamGame ? "Uninstalled \(app.name). Its folder is in the Trash." : "Uninstalled \(app.name).")
        }
    }

    func addToApplications(_ app: AppEntry) {
        do {
            let url = try services.addToApplications(app)
            refresh()
            flash("Added “\(app.name)” to \(url.deletingLastPathComponent().lastPathComponent).")
        } catch {
            show("Couldn't add to Applications", error)
        }
    }

    func removeFromApplications(_ app: AppEntry) {
        do { try services.removeFromApplications(app); refresh() } catch { show("Couldn't remove the shortcut", error) }
    }

    func reanalyze(_ app: AppEntry) {
        let services = self.services
        perform("Checking \(app.name)") { _ in
            _ = try await self.background { try services.refreshAnalysis(for: app) }
            ImageCache.shared.invalidate(app.iconURL)
        }
    }

    func resetLearned(_ app: AppEntry) {
        var updated = app
        updated.learned = LearnedCompat()
        save(updated)
    }

    /// Remembered until the library is read again: every card asks for this each time Home redraws, and working
    /// it out anew for all of them on every mouse movement is what made dragging a card stutter.
    @ObservationIgnored private var decisionCache: [UUID: BackendDecision?] = [:]

    func decision(for app: AppEntry) -> BackendDecision? {
        if let cached = decisionCache[app.id] { return cached }
        guard let container = container(app.containerID) else { return nil }
        let decision = services.planner.decision(for: app, container: container)
        decisionCache[app.id] = decision
        return decision
    }

    func fixes(for app: AppEntry) -> ResolvedFixes {
        guard let container = container(app.containerID) else { return ResolvedFixes() }
        return services.planner.fixes(for: app, container: container)
    }

    // MARK: Steam

    func openSteamFriends(_ container: Container) {
        do { try services.launcher.openSteamURL("steam://open/friends", in: container) } catch { show("Couldn't open Steam", error) }
    }

    func steamContainers() -> [Container] { containers.filter { SteamIntegration.isInstalled(in: $0) } }

    // MARK: Engines

    func install(_ entry: CatalogEntry) {
        let services = self.services
        perform("Installing \(entry.name) \(entry.version)") { activity in
            let status: @Sendable (String) -> Void = { message in Task { @MainActor in activity.detail = message } }
            let progress: Downloader.Progress = { fraction, _, _ in Task { @MainActor in activity.progress = fraction } }
            if entry.kind == .wine {
                _ = try await services.runtimes.install(entry, progress: progress, status: status)
                services.adoptRuntimeForContainersWithoutEngine()
            } else {
                _ = try await services.components.install(entry, progress: progress, status: status)
            }
            self.checkEngines()
        }
    }

    func importRuntime(_ url: URL) {
        let services = self.services
        perform("Importing engine from \(url.lastPathComponent)") { _ in
            _ = try await self.background { try services.importRuntimeWithComponents(from: url) }
            self.reloadSetup()
            self.checkEngines()
        }
    }

    func importD3DMetal(_ url: URL) {
        let services = self.services
        perform("Importing D3DMetal") { _ in
            _ = try await self.background { try services.components.importD3DMetal(from: url) }
            self.checkEngines()
        }
    }

    func importDXMT(_ url: URL) {
        let services = self.services
        perform("Importing DXMT") { _ in
            _ = try await self.background { try services.components.importDXMT(from: url) }
            self.checkEngines()
        }
    }

    func importDXVK(_ url: URL) {
        let services = self.services
        perform("Importing DXVK") { _ in _ = try await self.background { try services.components.importDXVK(from: url) } }
    }

    func remove(_ runtime: WineRuntime) {
        if containers.contains(where: { $0.runtimeID == runtime.id }) {
            errorMessage = ErrorMessage(title: "Engine in use", message: "Switch the containers that use “\(runtime.name)” to another engine first.")
            return
        }
        do { try services.runtimes.remove(runtime); refresh() } catch { show("Couldn't remove the engine", error) }
    }

    func remove(_ component: GraphicsComponent) {
        do {
            try services.components.remove(component)
            for runtime in runtimes { services.runtimes.clearFlavors(for: runtime) }
            refresh()
        } catch {
            show("Couldn't remove \(component.kind.displayName)", error)
        }
    }

    // MARK: Plugins

    /// Adds a plugin: for every translation layer (as its plugin.json says), or only for `container`.
    func importPlugin(_ url: URL, onlyIn container: Container? = nil) {
        perform("Importing plugin") { _ in
            guard let plugin = try await self.installPlugin(url, onlyIn: container) else { return }
            if container == nil { self.selection = .plugins }
            self.flash("Installed \(plugin.manifest.name) \(plugin.manifest.version).")
        }
    }

    private func installPlugin(_ url: URL, onlyIn container: Container? = nil, expectedID: String? = nil) async throws -> InstalledPlugin? {
        let manager = services.plugins
        do {
            return try await Task.detached(priority: .utility) {
                try manager.importPlugin(from: url, onlyIn: container, expectedID: expectedID)
            }.value
        } catch let error as PluginError {
            guard case .rollback(let name, let installed, let incoming) = error else { throw error }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Install an older plugin version?"
            alert.informativeText = "This replaces \(name) \(installed) with version \(incoming)."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Install Older Version").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
            return try await Task.detached(priority: .utility) {
                try manager.importPlugin(from: url, onlyIn: container, allowRollback: true, expectedID: expectedID)
            }.value
        }
    }

    func checkPluginUpdates(only plugin: InstalledPlugin? = nil) {
        let candidates = (plugin.map { [$0] } ?? plugins).filter { $0.manifest.updateURL != nil }
        guard !candidates.isEmpty else { refresh(); flash("Plugins reloaded."); return }
        perform("Checking plugin updates") { _ in
            var installed = 0
            var failures: [String] = []
            for candidate in candidates {
                do {
                    let file = try await self.services.plugins.downloadUpdate(for: candidate)
                    defer { try? FileManager.default.removeItem(at: file) }
                    if try await self.installPlugin(file, expectedID: candidate.id) != nil { installed += 1 }
                } catch { failures.append("\(candidate.manifest.name) · \(error.localizedDescription)") }
            }
            if !failures.isEmpty { throw PluginError.invalid(failures.joined(separator: "\n")) }
            self.flash(installed > 0 ? "Checked and installed \(installed) plugin package(s)." : "No plugin packages installed.")
        }
    }

    func exportPlugin(_ plugin: InstalledPlugin) {
        let panel = NSSavePanel()
        panel.title = "Export Plugin"
        panel.nameFieldStringValue = "\(plugin.id).cell"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "cell" { url.appendPathExtension("cell") }
        let destination = url
        let manager = services.plugins
        perform("Exporting \(plugin.manifest.name)") { _ in
            try await Task.detached(priority: .utility) { try manager.exportPlugin(plugin, to: destination) }.value
            self.flash("Exported \(destination.lastPathComponent).")
        }
    }

    func restorePluginDefaults(_ plugin: InstalledPlugin) {
        let alert = NSAlert()
        alert.messageText = "Restore default configuration?"
        alert.informativeText = "Reset \(plugin.manifest.name)’s options, layer selection, enabled state, and script permission."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Continue")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Restore \(plugin.manifest.name)’s defaults now?"
        confirmation.addButton(withTitle: "Cancel")
        confirmation.addButton(withTitle: "Restore Defaults").hasDestructiveAction = true
        guard confirmation.runModal() == .alertSecondButtonReturn else { return }
        do { try services.plugins.restoreDefaults(for: plugin); refresh() }
        catch { show("Couldn’t restore plugin defaults", error) }
    }

    func runPluginAction(_ action: PluginAction, plugin: InstalledPlugin, in container: Container) {
        perform(action.title) { _ in
            let result = try await self.services.launcher.runPluginAction(action, for: plugin, in: container)
            let output = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded else { throw PluginError.invalid(output.isEmpty ? "program exited with status \(result.status)" : String(output.suffix(3000))) }
            let alert = NSAlert()
            alert.messageText = action.title
            alert.informativeText = output.isEmpty ? "Completed." : String(output.suffix(3000))
            alert.addButton(withTitle: "Done")
            alert.runModal()
        }
    }

    func isPluginActive(_ plugin: InstalledPlugin, in container: Container) -> Bool { pluginState.isActive(plugin, in: container) }

    func setPluginOption(_ plugin: InstalledPlugin, id: String, to value: String) {
        do { try services.plugins.setOption(value, id: id, for: plugin); pluginState = services.plugins.state }
        catch { show("Couldn't change the plugin", error) }
    }

    /// Adds plugins dropped on a plugin page (for every layer, or for `container` only).
    @discardableResult
    func importDroppedPlugins(_ urls: [URL], onlyIn container: Container? = nil) -> Bool {
        let plugins = urls.filter { url in
            PluginManager.pluginExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "zip"
        }
        for url in plugins { importPlugin(url, onlyIn: container) }
        return !plugins.isEmpty
    }

    func setPlugin(_ plugin: InstalledPlugin, active: Bool, in container: Container) {
        do { try services.plugins.setActive(active, for: plugin, in: container); pluginState = services.plugins.state }
        catch { show("Couldn't change the plugin", error) }
    }

    /// Every translation layer (nil) or only some.
    func setPluginScope(_ plugin: InstalledPlugin, containers: Set<UUID>?) {
        do { try services.plugins.setScope(containers, for: plugin); pluginState = services.plugins.state }
        catch { show("Couldn't change the plugin", error) }
    }

    /// Apps a plugin's rules match (in one layer, or everywhere).
    func apps(matching plugin: InstalledPlugin, in container: Container? = nil) -> [AppEntry] {
        apps.filter { app in
            guard let owner = self.container(app.containerID), container == nil || owner.id == container?.id else { return false }
            return FixResolver.matches(plugin.manifest, context: MatchContext(app: app, container: owner))
        }
    }

    @discardableResult
    func createPlugin(named name: String, executable: String?, steamAppID: String?, identifier: String? = nil) -> InstalledPlugin? {
        do {
            let plugin = try services.plugins.createTemplate(name: name, executable: executable?.isEmpty == true ? nil : executable,
                                                             steamAppID: steamAppID?.isEmpty == true ? nil : steamAppID, identifier: identifier)
            refresh()
            return plugin
        } catch {
            show("Couldn't create the plugin", error)
            return nil
        }
    }

    func setEnabled(_ enabled: Bool, plugin: InstalledPlugin) {
        do { try services.plugins.setEnabled(enabled, for: plugin); pluginState = services.plugins.state } catch { show("Couldn't change the plugin", error) }
    }

    func setTrusted(_ trusted: Bool, plugin: InstalledPlugin) {
        do { try services.plugins.setTrusted(trusted, for: plugin); pluginState = services.plugins.state } catch { show("Couldn't change the plugin", error) }
    }

    func remove(_ plugin: InstalledPlugin) {
        do { try services.plugins.remove(plugin); refresh() } catch { show("Couldn't remove the plugin", error) }
    }

    func revealPluginsFolder() {
        try? FileManager.default.createDirectory(at: CellPaths.plugins, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CellPaths.plugins)
    }

    // MARK: Network

    private var allWineBinaries: [URL] { runtimes.flatMap { FirewallHelper.wineBinaries(for: $0) } }

    func refreshFirewall() {
        let binaries = allWineBinaries
        Task {
            let status = try? await background { FirewallHelper.status(binaries: binaries) }
            firewallStatus = status ?? .unknown
        }
    }

    /// Adds every Wine engine (and graphics flavor) not yet allowed. macOS asks for the password once.
    func allowIncomingConnections() {
        perform("Allowing incoming connections for Wine") { _ in
            try await self.allowWineThroughFirewall()
        }
    }

    private func allowWineThroughFirewall() async throws {
        let binaries = allWineBinaries
        let missing = try await background { FirewallHelper.status(binaries: binaries).notAllowed }
        if !missing.isEmpty {
            try await background { try FirewallHelper.allowIncomingConnections(for: missing) }
        }
        let status = try await background { FirewallHelper.status(binaries: binaries) }
        firewallStatus = status
        if status.wineAllowed { flash("Wine can now accept incoming connections.") }
    }

    func runNetworkTest() {
        guard !networkTesting else { return }
        networkTesting = true
        Task {
            networkReport = await NetworkDiagnostics.run()
            networkTesting = false
        }
    }

    /// Opens the VPN / proxy app that is dropping games' UDP.
    func openVPNApp() {
        guard let bundle = networkReport?.vpn?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var portMappingEverywhere: Bool {
        let windows = containers.filter { $0.platform == .windows }
        return !windows.isEmpty && windows.allSatisfy(\.settings.mapPortsWhilePlaying)
    }

    /// Asks the router (NAT-PMP / PCP / UPnP) to forward games' ports while they run, in every container.
    func enablePortMapping() {
        for var container in containers where container.platform == .windows && !container.settings.mapPortsWhilePlaying {
            container.settings.mapPortsWhilePlaying = true
            try? services.library.save(container)
        }
        refresh()
    }

    /// Everything Cell can fix by itself: the firewall, router port mapping, then a fresh test.
    /// What only the user can change (a VPN app's settings) is opened for them.
    func fixNetwork() {
        guard !networkFixing else { return }
        networkFixing = true
        perform("Fixing the network for games") { activity in
            defer { self.networkFixing = false }
            if self.firewallStatus.state == .on || self.firewallStatus.state == .unknown {
                activity.detail = "Allowing Wine through the firewall…"
                try? await self.allowWineThroughFirewall()
            }
            activity.detail = "Testing UDP and NAT…"
            self.networkTesting = true
            var report = await NetworkDiagnostics.run()
            if case .good(.strict) = report.verdict, !self.portMappingEverywhere {
                self.enablePortMapping()
            }
            if case .vpnBlocksUDP(.strict) = report.verdict, !self.portMappingEverywhere {
                self.enablePortMapping()
            }
            report = await NetworkDiagnostics.run()
            self.networkReport = report
            self.networkTesting = false
            if case .vpnBlocksUDP = report.verdict { self.openVPNApp() }
        }
    }

    // MARK: Setup

    func reloadSetup() {
        setupSteps = SetupAssistant.steps(services: services)
        bottles = BottleImporter.discover()
    }

    var setupNeeded: Bool { setupSteps.contains(where: \.needed) }

    /// Runs every needed step in order. No choices: steps the user unticked are skipped.
    func runSetup() {
        guard !setupRunning else { return }
        reloadSetup()
        setupRunning = true
        setupStatus = [:]
        let services = self.services
        Task { @MainActor in
            for step in setupSteps where step.needed && !setupSkipped.contains(step.kind) {
                let kind = step.kind
                setupStatus[kind] = .running("Starting…", nil)
                do {
                    let message = try await SetupAssistant.run(kind, services: services, status: { text in
                        Task { @MainActor in
                            if case .running(_, let fraction) = self.setupStatus[kind] { self.setupStatus[kind] = .running(text, fraction) }
                        }
                    }, progress: { fraction, _, _ in
                        Task { @MainActor in
                            if case .running(let text, _) = self.setupStatus[kind] { self.setupStatus[kind] = .running(text, fraction) }
                        }
                    })
                    setupStatus[kind] = .done(message)
                } catch {
                    setupStatus[kind] = .failed(error.localizedDescription)
                }
                refresh()
            }
            setupRunning = false
            updateSettings { $0.setupCompleted = true }
            checkEngines()
            let statuses = setupStatus
            reloadSetup()
            setupStatus = statuses
            flash("Cell is set up.")
        }
    }

    func importBottle(_ bottle: ExistingBottle, thenOpen file: URL? = nil) {
        let services = self.services
        perform("Importing “\(bottle.name)”") { activity in
            let container = try await self.background {
                try services.importBottle(bottle) { message in Task { @MainActor in activity.detail = message } }
            }
            self.refresh()
            self.reloadSetup()
            // Open the program the user picked, now living in the imported container.
            if let file, let relative = Self.relativePath(of: file, in: bottle.prefix) {
                let target = container.prefixURL.appendingPathComponent(relative)
                let windowsPath = WinePathMapper(prefix: container.prefixURL).windowsPath(for: target).lowercased()
                if let app = self.apps.first(where: { $0.containerID == container.id && $0.windowsPath?.lowercased() == windowsPath })
                    ?? self.apps.first(where: { $0.containerID == container.id && $0.kind == .steamClient && windowsPath.hasSuffix("steam.exe") }) {
                    self.selection = .home
                    self.libraryPath = NavigationPath([app.id])
                    return
                }
            }
            self.selection = .container(container.id)
            let count = self.apps(in: container).count
            self.flash("Imported “\(container.name)” with \(count) app\(count == 1 ? "" : "s").")
        }
    }

    static func relativePath(of file: URL, in root: URL) -> String? {
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return nil }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    func engineChoice(for app: AppEntry) -> LaunchPlanner.EngineChoice? {
        guard let container = container(app.containerID) else { return nil }
        return services.planner.engineChoice(for: app, container: container)
    }

    func makeDefaultEngine(_ runtime: WineRuntime) {
        updateSettings { $0.defaultRuntimeID = runtime.id }
        for var container in containers where container.platform == .windows && container.isDefault {
            container.runtimeID = runtime.id
            save(container)
        }
        refresh()
    }

    // MARK: Settings

    func updateSettings(_ change: (inout CellSettings) -> Void) {
        do {
            try services.updateSettings(change)
            settings = services.settings
            DownloadManager.shared.connectionsPerDownload = settings.downloadConnections
        DownloadManager.shared.addsConnectionsAutomatically = settings.automaticDownloadConnections
        DownloadManager.shared.reconnectsAutomatically = settings.reconnectDownloads
            DownloadMirrors.enabled = settings.useDownloadMirrors
        } catch {
            show("Couldn't save preferences", error)
        }
    }
}
