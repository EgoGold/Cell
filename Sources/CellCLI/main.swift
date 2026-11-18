import Foundation
import CellCore
import Virtualization
import ImageIO
import CoreFoundation

// cell — command line companion of Cell.app (also used by "Add to Applications" shortcuts).

/// Created on first use, so commands like `internal-make-icon` never touch Cell's data folders.
enum CLI { static let services = CellServices.shared }
var services: CellServices { CLI.services }
var arguments = Array(CommandLine.arguments.dropFirst())
// Text Input Sources and display queries must run on the main thread; cache them before any async work.
LanguageResolver.prime()
DisplayInfo.prime()

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func container(named reference: String?) -> Container? {
    guard let reference else { return services.library.defaultContainer }
    if let id = UUID(uuidString: reference), let match = services.library.container(id: id) { return match }
    return services.library.containers.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
}

/// Runs an async block from top-level code and waits for it.
func blocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task.detached {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

/// Runs a virtual machine without a window for `seconds`, then turns it off and shows its console output.
@MainActor
func runVirtualMachineHeadless(_ machine: VirtualMachine, seconds: Double) throws {
    let session = try VirtualMachineSession(machine: machine)
    final class Box: @unchecked Sendable { var finished = false; var failure: Error? }
    let box = Box()
    session.onStop = { error in box.failure = error; box.finished = true }
    Task { @MainActor in
        do { try await session.start(); printError("Started \(machine.name).") } catch { box.failure = error; box.finished = true }
    }
    let deadline = Date().addingTimeInterval(seconds)
    while !box.finished && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2)) }
    let state = session.virtualMachine.state
    let names: [VZVirtualMachine.State: String] = [.running: "running", .stopped: "stopped", .error: "error", .starting: "starting"]
    print("State after \(Int(seconds)) s: \(names[state] ?? "state \(state.rawValue)")")
    if let failure = box.failure { print("Stopped: \(failure.localizedDescription)") }
    if session.isRunning {
        Task { @MainActor in try? await session.forceStop() }
        let stopDeadline = Date().addingTimeInterval(10)
        while session.isRunning && Date() < stopDeadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2)) }
    }
    let console = (try? String(contentsOf: machine.consoleLogURL, encoding: .utf8)) ?? ""
    print("console.log: \(console.utf8.count) bytes")
    print(console.split(separator: "\n").suffix(15).joined(separator: "\n"))
}

func usage() {
    print("""
    cell — run Windows apps on your Mac

    USAGE
      cell launch --app <id> [--backend d3dmetal|dxmt|dxvk|wined3d]
      cell run <program.exe|.msi> [--container <name|id>] [-- args…]
      cell prepare [--container <name>]  Set up a container (Windows prefix + settings)
      cell add <program.exe> [--container <name>]
      cell plan --app <id> [--backend …]  Show exactly how an app would be started
      cell list                      Apps in the library
      cell containers                Containers
      cell engines                   Wine engines and graphics layers
      cell check-engines [--again]   Check which engine pairs can draw (headless, cached)
      cell vm list                   Virtual machines
      cell vm create --name <n> --guest linux|macos|windows|android [--installer <iso|ipsw>]
                        [--kernel <Image> --initrd <file> --cmdline "…"] [--cpus 4] [--memory 4096] [--disk 40]
      cell vm start <name|id> [--seconds 30]   Run without a window (console output in console.log)
      cell vm delete <name|id>       Move a virtual machine to the Trash
      cell analyze <program.exe>     What Cell detects and which engine it would pick
      cell import-engine <path>      Import a Wine engine (folder, wrapper .app, archive)
      cell import-d3dmetal <path>    Import D3DMetal (Game Porting Toolkit .dmg, folder or engine)
      cell import-dxmt <path>        Import DXMT (release archive, folder or engine)
      cell plugin list|validate <path>|import <path> [--allow-rollback]|export <id> <file.cell>
      cell plugin new <name> [--id com.example.game] [--exe Game.exe] [--steam-app-id 123]
      cell plugin pack <source-folder> <file.cell>
      cell bottles                   Porting Kit / CrossOver / Whisky bottles on this Mac
      cell import-bottle <name|path> Bring a bottle (with Steam and games) into Cell
      cell nat-test                  Check how your network handles peer-to-peer UDP
    """)
}

/// Prints every running download's speed per server every two seconds (diagnostic commands).
func printDownloadProgress(since started: Date) {
    final class Clock: @unchecked Sendable { var last = Date.distantPast }
    let clock = Clock()
    DownloadManager.shared.setUpdateHandler { snapshots in
        guard Date().timeIntervalSince(clock.last) >= 2 else { return }
        clock.last = Date()
        for job in snapshots where job.state == .downloading || job.state == .connecting {
            let servers = job.sources.map { "\($0.label) \($0.connections)x \(Int64($0.bytesPerSecond).formatted(.byteCount(style: .file)))/s [\($0.health.rawValue)]" }
            print(String(format: "%5.1fs %@ %3.0f%% %@/s %d/%d conns | %@", Date().timeIntervalSince(started), job.title,
                         (job.fraction ?? 0) * 100, Int64(job.bytesPerSecond).formatted(.byteCount(style: .file)),
                         job.activeConnections, job.connectionLimit, servers.joined(separator: ", ")))
        }
    }
}

guard let command = arguments.first else { usage(); exit(0) }
arguments.removeFirst()

do {
    switch command {
    case "launch":
        let backend = option("--backend").flatMap(GraphicsBackend.init(rawValue:))
        let fromSteamCompatibility = flag("--from-steam-compatibility")
        let requiredWineVersion = fromSteamCompatibility ? option("--require-wine") : nil
        _ = flag("--from-shortcut")
        guard let idString = option("--app"), let id = UUID(uuidString: idString), let app = services.library.app(id: id) else {
            printError("Unknown app. Use `cell list` to see app ids.")
            exit(2)
        }
        let done = DispatchSemaphore(value: 0)
        final class ExitBox: @unchecked Sendable { var code: Int32 = 0; var message: String? }
        let exitBox = ExitBox()
        Task.detached {
            do {
                if fromSteamCompatibility {
                    try await Task.sleep(for: .milliseconds(300))
                    services.plugins.reload()
                }
                let session = try await services.launcher.launch(appID: app.id, forcedBackend: backend,
                                                                 requiredWineVersion: requiredWineVersion, status: { printError($0) },
                                                                 onExit: { outcome, session in
                    for finding in outcome.findings where finding.severity != .info {
                        printError("[\(finding.severity.rawValue)] \(finding.title)" + (finding.advice.map { " — \($0)" } ?? ""))
                    }
                    if let session, services.launcher.willRetry(after: outcome, session: session) { return }
                    exitBox.code = outcome.exitCode
                    done.signal()
                })
                // Steam keeps running after the game; don't hold the shortcut open for it.
                if session.plan.kind != .direct { done.signal() }
            } catch {
                printError(error.localizedDescription)
                exitBox.message = error.localizedDescription
                exitBox.code = 1
                done.signal()
            }
        }
        done.wait()
        if fromSteamCompatibility, let message = exitBox.message {
            CFUserNotificationDisplayAlert(0, kCFUserNotificationNoteAlertLevel, nil, nil, nil,
                                           "Cell could not start \(app.name)" as CFString, message as CFString,
                                           "OK" as CFString, nil, nil, nil)
        }
        exit(exitBox.code)

    case "run":
        let target = option("--container")
        var programArguments: [String] = []
        if let separator = arguments.firstIndex(of: "--") {
            programArguments = Array(arguments[(separator + 1)...])
            arguments.removeSubrange(separator...)
        }
        guard let path = arguments.first else { printError("Which program?"); exit(2) }
        guard let destination = container(named: target) ?? (try? services.ensureDefaultContainer()) else {
            printError("Container not found."); exit(2)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let result = try blocking {
            try await services.launcher.runExecutable(url, in: destination, arguments: programArguments, status: { printError($0) })
        }
        let added = try services.discoverApps(in: services.library.container(id: destination.id) ?? destination)
        for app in added { print("Added to library: \(app.name)") }
        exit(result.status)

    case "prepare":
        let target = option("--container")
        let destination = try container(named: target) ?? services.ensureDefaultContainer()
        _ = try services.discoverApps(in: destination)
        try blocking { try await services.launcher.prepareContainer(destination, status: { printError($0) }) }
        let refreshed = services.library.container(id: destination.id) ?? destination
        let added = try services.discoverApps(in: refreshed)
        print("“\(refreshed.name)” is ready (\(refreshed.prefixURL.path)).")
        for app in added { print("Added to library: \(app.name)") }

    case "add":
        let target = option("--container")
        guard let path = arguments.first else { printError("Which program?"); exit(2) }
        let destination = try container(named: target) ?? services.ensureDefaultContainer()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let app = FileOps.isDirectory(url) ? try services.addFolder(url, to: destination, status: { printError($0) })
                                           : try services.addExecutable(url, to: destination)
        print("\(app.id.uuidString)  \(app.name)")

    case "plan":
        guard let idString = option("--app"), let id = UUID(uuidString: idString), let app = services.library.app(id: id),
              let owner = services.library.container(id: app.containerID) else {
            printError("Unknown app."); exit(2)
        }
        let backend = option("--backend").flatMap(GraphicsBackend.init(rawValue:))
        let plan = try services.planner.plan(app: app, container: owner, forcedBackend: backend)
        print("Engine:      \(plan.runtime.name)")
        print("Flavor:      \(plan.flavorKey) → \(plan.flavorRoot.path)")
        print("Graphics:    \(plan.decision.reason)")
        print("Fallbacks:   \(plan.decision.fallbacks.map(\.displayName).joined(separator: " → "))")
        print("Kind:        \(plan.kind.rawValue)")
        print("Command:     \(plan.commandLine)")
        print("Directory:   \(plan.workingDirectory.path)")
        for key in ["SteamAppId", "GST_PLUGIN_SYSTEM_PATH_1_0", "WINEDLLOVERRIDES", "WINEMSYNC", "LANG", "DXMT_CONFIG", "ROSETTA_ADVERTISE_AVX", "DYLD_FALLBACK_LIBRARY_PATH"] {
            if let value = plan.environment[key] { print("\(key)=\(value)") }
        }
        for note in plan.fixes.notes { print("Note (\(note.plugin)): \(note.text)") }
        for warning in plan.warnings { print("Warning: \(warning)") }

    case "bottles":
        for bottle in BottleImporter.discover() {
            let state = services.isImported(bottle) ? "imported" : "available"
            print("[\(state)] \(bottle.name) — \(bottle.summary)\n          \(bottle.prefix.path)")
        }

    case "import-bottle":
        guard let reference = arguments.first else { printError("Which bottle? (name or path from `cell bottles`)"); exit(2) }
        let all = BottleImporter.discover()
        let path = (reference as NSString).expandingTildeInPath
        guard let bottle = all.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame || $0.prefix.path == path
                                           || $0.appBundle?.path == path })
                ?? BottleImporter.bottle(containing: URL(fileURLWithPath: path).appendingPathComponent("system.reg")) else {
            printError("No bottle found for \(reference)."); exit(2)
        }
        let started = Date()
        let imported = try services.importBottle(bottle) { printError($0) }
        print("Imported “\(imported.name)” in \(String(format: "%.1f", Date().timeIntervalSince(started))) s:")
        for app in services.library.apps(in: imported.id) { print("  \(app.id.uuidString)  \(app.name) (\(app.kind.rawValue))") }

    case "list":
        for app in services.library.apps.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            let containerName = services.library.container(id: app.containerID)?.name ?? "?"
            let engine = app.learned.workingBackend.map { " · works with \($0.displayName)" } ?? ""
            print("\(app.id.uuidString)  \(app.name)  [\(containerName)]\(engine)")
        }

    case "containers":
        for item in services.library.containers {
            let runtime = services.runtimes.runtime(id: item.runtimeID)?.name ?? "no engine"
            print("\(item.id.uuidString)  \(item.name)\(item.isDefault ? " (default)" : "")  \(item.platform.displayName) · \(runtime)")
        }

    case "engines":
        print("Wine engines:")
        for runtime in services.runtimes.runtimes {
            let bundled = runtime.bundledComponents.map { "\($0.kind.displayName) \($0.version ?? "")" }.joined(separator: ", ")
            print("  \(runtime.id)  \(runtime.name)  base: \(runtime.baseBackend.displayName)\(bundled.isEmpty ? "" : " · includes \(bundled)")")
        }
        print("Graphics layers:")
        for component in services.components.components {
            print("  \(component.id)  \(component.kind.displayName) \(component.version)")
        }

    case "vm":
        let library = services.virtualMachines
        func findMachine(_ reference: String?) -> VirtualMachine? {
            guard let reference else { return nil }
            if let id = UUID(uuidString: reference), let match = library.machine(id: id) { return match }
            return library.machines.first { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        }
        switch arguments.first {
        case "list":
            if library.machines.isEmpty { print("No virtual machines.") }
            for machine in library.machines {
                print("\(machine.id.uuidString)  \(machine.name)  \(machine.guest.displayName)  \(machine.cpuCount) CPUs  \(machine.memoryMiB) MiB  \(machine.diskGiB) GiB  — \(machine.nextStartSummary)")
            }
        case "create":
            guard let name = option("--name"), let guestName = option("--guest"),
                  let guest = GuestSystem.allCases.first(where: { $0.rawValue.lowercased() == guestName.lowercased() }) else {
                printError("Usage: cell vm create --name <name> --guest linux|macos|windows|android [--installer <path>]"); exit(2)
            }
            let installer = option("--installer").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            var machine = try library.create(name: name, guest: guest, installer: installer,
                                             cpuCount: option("--cpus").flatMap(Int.init), memoryMiB: option("--memory").flatMap(Int.init),
                                             diskGiB: option("--disk").flatMap(Int.init))
            if let kernel = option("--kernel") {
                try FileOps.cloneItem(at: URL(fileURLWithPath: kernel), to: machine.bundle.appendingPathComponent("Kernel"))
                machine.kernel = "Kernel"
                if let initrd = option("--initrd") {
                    try FileOps.cloneItem(at: URL(fileURLWithPath: initrd), to: machine.bundle.appendingPathComponent("Initrd"))
                    machine.initialRamdisk = "Initrd"
                }
                machine.kernelCommandLine = option("--cmdline")
                try library.save(machine)
            }
            print("Created \(machine.name) (\(machine.id.uuidString)) at \(machine.bundle.path)")
        case "start":
            guard let machine = findMachine(arguments.dropFirst().first) else { printError("Which virtual machine? (`cell vm list`)"); exit(2) }
            let seconds = option("--seconds").flatMap(Double.init) ?? 30
            try MainActor.assumeIsolated { try runVirtualMachineHeadless(machine, seconds: seconds) }
        case "delete":
            guard let machine = findMachine(arguments.dropFirst().first) else { printError("Which virtual machine?"); exit(2) }
            try library.delete(machine)
            print("Moved \(machine.name) to the Trash.")
        default:
            usage()
        }

    case "check-engines":
        if flag("--again") { services.verifier.reset() }
        try blocking { await services.verifier.verifyAll(status: { printError($0) }) }
        for runtime in services.runtimes.runtimes {
            print("\(runtime.name)  [\(runtime.id)]")
            for backend in services.verifier.checkableBackends(for: runtime) {
                guard let check = services.verifier.check(runtime: runtime, backend: backend) else {
                    print("  ?  \(backend.displayName): not checked"); continue
                }
                print("  \(check.runsDirect3D11 ? "✓" : "✗")  \(backend.displayName): \(check.summary)"
                      + (check.stoppedAt.map { " (stopped at \($0), exit \(check.exitCode.map(String.init) ?? "?"))" } ?? ""))
            }
        }

    case "analyze":
        guard let path = arguments.first else { printError("Which program?"); exit(2) }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let analysis = AppAnalyzer.analyze(executable: url)
        print("Program:       \(url.lastPathComponent)")
        if let analyzed = analysis.analyzedExecutable, analyzed != url.path { print("Analyzed:      \(analyzed)") }
        print("Name:          \(CellServices.preferredName(for: url, analysis: analysis))")
        print("Architecture:  \(analysis.architecture.displayName)\(analysis.isDotNet ? " · .NET" : "")")
        print("Graphics:      \(analysis.graphicsAPIs.sorted().map(\.displayName).joined(separator: ", "))\(analysis.hasD3D12AgilitySDK ? " (+ D3D12 Agility SDK)" : "")")
        print("Engine:        \(analysis.engineDescription ?? "not detected")")
        print("DPI-aware:     \(analysis.declaresDPIAwareness == true ? "yes (manifest)" : "no — Cell marks games like this DPI-aware so they get the real Retina pixels")")
        if let helpers = analysis.chromiumHelpers, !helpers.isEmpty {
            print("Chromium:      \(helpers.joined(separator: ", ")) — marked DPI-aware so their pages are sharp")
        }
        if let product = analysis.productName { print("Product:       \(product) \(analysis.fileVersion ?? "")") }
        if let appID = analysis.steamAppID { print("Steam app ID:  \(appID)") }
        if !analysis.antiCheat.isEmpty { print("Anti-cheat:    \(analysis.antiCheat.joined(separator: ", "))") }
        if analysis.isInstaller { print("Looks like an installer.") }
        for note in analysis.notes { print("Note:          \(note)") }
        var probe = AppEntry(containerID: UUID(), name: url.lastPathComponent, kind: .windowsExecutable, source: .manual)
        probe.analysis = analysis
        probe.steamAppID = analysis.steamAppID
        let fixes = FixResolver.resolve(plugins: services.plugins.enabledPlugins,
                                        context: MatchContext(executableName: url.lastPathComponent, executablePath: url.path,
                                                              gameDirectory: AppAnalyzer.gameRootDirectory(for: URL(fileURLWithPath: analysis.analyzedExecutable ?? url.path)),
                                                              steamAppID: analysis.steamAppID, analysis: analysis, appKind: .windowsExecutable))
        if !fixes.plugins.isEmpty { print("Plugins:       \(fixes.plugins.map(\.manifest.name).joined(separator: ", "))") }
        if let runtime = services.runtimes.recommendedRuntime {
            let support = services.runtimes.supportedBackends(for: runtime, components: services.components)
            let decision = BackendSelector.decide(analysis: analysis, support: support, fixes: fixes, baseBackend: runtime.baseBackend)
            print("Autopilot:     \(decision.reason)")
            if !decision.fallbacks.isEmpty { print("Fallbacks:     \(decision.fallbacks.map(\.displayName).joined(separator: " → "))") }
            var extra = fixes.arguments(for: decision.backend)
            FixResolver.appendGroup(decision.extraArguments, to: &extra)
            if !extra.isEmpty { print("Arguments:     \(extra.joined(separator: " "))") }
        } else {
            let all = Dictionary(uniqueKeysWithValues: GraphicsBackend.allCases.map {
                ($0, RuntimeManager.BackendSupport(backend: $0, confident: true, supports32Bit: $0 != .d3dmetal))
            })
            let decision = BackendSelector.decide(analysis: analysis, support: all, fixes: fixes)
            print("Autopilot:     \(decision.reason) (no engine installed yet)")
        }

    case "import-engine":
        guard let path = arguments.first else { printError("Path?"); exit(2) }
        let runtime = try services.runtimes.importRuntime(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        print("Imported \(runtime.name) (\(runtime.id)) · base graphics: \(runtime.baseBackend.displayName)")

    case "import-d3dmetal":
        guard let path = arguments.first else { printError("Path?"); exit(2) }
        let component = try services.components.importD3DMetal(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        print("Imported D3DMetal \(component.version)")

    case "import-dxmt":
        guard let path = arguments.first else { printError("Path?"); exit(2) }
        let component = try services.components.importDXMT(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        print("Imported DXMT \(component.version)")

    case "plugin":
        let sub = arguments.first ?? "list"
        if !arguments.isEmpty { arguments.removeFirst() }
        switch sub {
        case "list":
            for plugin in services.plugins.plugins {
                let state = services.plugins.isEnabled(plugin) ? "on " : "off"
                print("[\(state)] \(plugin.manifest.name) \(plugin.manifest.version)  \(plugin.id)\(plugin.isBuiltin ? "  (built-in)" : "")")
            }
            for problem in services.plugins.loadErrors { printError("Problem: \(problem)") }
        case "validate":
            guard let path = arguments.first else { printError("Path?"); exit(2) }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let manifest = try PluginManager.validatePackage(at: url)
            print("✓ \(manifest.name) \(manifest.version) (\(manifest.id)) is valid.")
        case "new":
            let exe = option("--exe")
            let steam = option("--steam-app-id")
            let id = option("--id")
            guard let name = arguments.first else { printError("Name?"); exit(2) }
            let plugin = try services.plugins.createTemplate(name: name, executable: exe, steamAppID: steam, identifier: id)
            print("Created \((plugin.packageURL ?? plugin.directory).path)")
        case "import":
            let rollback = flag("--allow-rollback")
            guard let path = arguments.first else { printError("Path?"); exit(2) }
            let result = try services.plugins.importPlugin(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), allowRollback: rollback)
            print("Installed \(result.id) \(result.manifest.version)")
        case "export":
            guard arguments.count == 2, let plugin = services.plugins.plugins.first(where: { $0.id == arguments[0] }) else {
                printError("Use cell plugin export <installed-plugin-id> <file.cell>.")
                exit(2)
            }
            try services.plugins.exportPlugin(plugin, to: URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath))
        case "pack":
            guard arguments.count == 2 else { printError("Use cell plugin pack <source-folder> <file.cell>."); exit(2) }
            try PluginManager.exportFolder(URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath),
                                           to: URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath))
        default:
            usage()
        }

    case "nat-test":
        let report = try blocking { await NetworkDiagnostics.run() }
        if let vpn = report.vpn { print("VPN / proxy: \(vpn.name) (\(vpn.interface)), physical interface: \(report.physicalInterface ?? "?")") }
        func describe(_ label: String, _ path: NetworkDiagnostics.PathResult) {
            print("\(label): UDP \(path.udpWorks ? "works" : "blocked"), STUN \(path.stunWorks ? "answered" : "no answer"), NAT \(path.nat?.rawValue ?? "unknown")")
            for reply in path.replies { print("  \(reply.server) sees you as \(reply.mapped)") }
        }
        describe("Games' route", report.games)
        if let direct = report.direct { describe("Direct (bypassing the VPN)", direct) }
        switch report.verdict {
        case .good(let nat): print("Verdict: OK\(nat.map { " — NAT \($0.rawValue): \($0.explanation)" } ?? "")")
        case .vpnBlocksUDP(let nat): print("Verdict: \(report.vpn?.name ?? "The VPN") drops UDP. Your network itself is fine\(nat.map { " (NAT \($0.rawValue))" } ?? "").")
        case .vpnFiltersSTUN: print("Verdict: UDP gets through \(report.vpn?.name ?? "the VPN"), but STUN is filtered.")
        case .udpBlocked: print("Verdict: UDP is blocked on this network.")
        }

    case "internal-download":
        // Diagnostics: cell internal-download <url> [destination] — shows speed per server.
        guard let address = arguments.first, let url = URL(string: address) else { exit(2) }
        let destination = arguments.count > 1 ? URL(fileURLWithPath: arguments[1])
            : CellPaths.downloads.appendingPathComponent(url.lastPathComponent)
        let started = Date()
        printDownloadProgress(since: started)
        let file = try blocking { try await Downloader.download(url, to: destination, title: url.lastPathComponent) }
        let seconds = Date().timeIntervalSince(started)
        let size = FileOps.fileSize(file) ?? 0
        print(String(format: "Done: %@ in %.1f s (%@/s), checksum %@", size.formatted(.byteCount(style: .file)), seconds,
                     Int64(Double(size) / seconds).formatted(.byteCount(style: .file)), "verified when known"))

    case "internal-steam-update":
        // Diagnostics: cell internal-steam-update <Steam folder> [--check]
        guard let path = arguments.first else { exit(2) }
        let steam = URL(fileURLWithPath: path)
        if flag("--check") {
            let state = try blocking { await SteamClientUpdater.check(steamDirectory: steam) }
            let bytes = state.missing.reduce(Int64(0)) { $0 + $1.size }
            print("Manifests: \(SteamClientUpdater.manifestNames(steamDirectory: steam).joined(separator: ", ")), newest version \(state.version ?? "?")")
            print("\(state.present) packages present, \(state.missing.count) missing (\(bytes.formatted(.byteCount(style: .file))))")
            for package in state.missing.prefix(40) { print("  missing \(package.fileName) (\(package.size) bytes)") }
        } else {
            printDownloadProgress(since: Date())
            let report = try blocking { try await SteamClientUpdater.prefetch(steamDirectory: steam) { print($0) } }
            print("Version \(report.version ?? "?"): downloaded \(report.downloaded.count) packages (\(report.bytes.formatted(.byteCount(style: .file)))), \(report.alreadyPresent) already there")
        }

    case "internal-apply-settings":
        // Diagnostics: re-reads the library and writes Cell's registry settings with the engine the container is
        // set up for (regedit only, nothing appears on screen). Prints the DPI flags it wrote.
        guard let target = container(named: option("--container")) else { printError("No such container."); exit(2) }
        _ = try services.discoverApps(in: target)
        let current = services.library.container(id: target.id) ?? target
        guard let runtime = services.runtimes.runtime(id: current.initializedRuntimeID) else { printError("Not set up yet."); exit(1) }
        for edit in services.planner.registryConfiguration(for: current) where edit.key == LaunchPlanner.appCompatLayers {
            print("\(edit.name ?? "@") → \(edit.value == .delete ? "removed" : "\(edit.value)")")
        }
        // What Cell does when it opens and before a session: games' display settings, fonts, own user folders,
        // per-program settings.
        services.launcher.prepareGames(in: current)
        WineCommands.prepareSession(container: current)
        services.launcher.updateDockNames(for: current)
        try blocking { try await services.launcher.applySettingsIfNeeded(services.library.container(id: target.id) ?? current, runtime: runtime) }
        print("Settings written with \(runtime.name).")

    case "internal-repair-vcpp":
        // Diagnostics: (re)installs Microsoft's Visual C++ runtime when its files are Wine's stand-ins.
        guard let target = container(named: option("--container")) else { printError("No such container."); exit(2) }
        print("needed before: \(CellServices.visualCppNeedsInstall(target))")
        let started = Date()
        try blocking { await services.repairVisualCppIfNeeded(in: target, status: { printError($0) }) }
        print(String(format: "needed after: %@ (%.0f s)", "\(CellServices.visualCppNeedsInstall(target))", Date().timeIntervalSince(started)))

    case "internal-install-dotnet":
        // Diagnostics: installs Microsoft's .NET Framework 4.8 the way the app does (or repairs it).
        guard let target = container(named: option("--container")) else { printError("No such container."); exit(2) }
        let started = Date()
        try blocking { try await services.installDotNetFramework(in: target, status: { printError($0) }) }
        print(String(format: ".NET Framework is in place (%.0f s).", Date().timeIntervalSince(started)))

    case "internal-program-settings":
        // Writes (and prints) what each game gets however it starts, Steam's window included (ProgramSettings).
        guard let target = option("--container"), let owner = container(named: target) else { printError("Unknown container."); exit(2) }
        services.launcher.updateDockNames(for: owner)
        print((try? String(contentsOf: ProgramSettings.fileURL(for: owner), encoding: .utf8)) ?? "")

    case "internal-orphans":
        // Lists a container's Wine processes and the leftovers of older sessions; --end ends the leftovers.
        guard let target = option("--container"), let owner = container(named: target) else { printError("Unknown container."); exit(2) }
        let processes = WineProcessScanner.sessionProcesses(of: owner)
        let orphans = Set(WineProcessScanner.orphans(in: processes))
        let formatter = ISO8601DateFormatter()
        for process in processes.sorted(by: { $0.startedAt < $1.startedAt }) {
            print("\(process.pid)\t\(formatter.string(from: process.startedAt))\t\(process.isServer ? "server" : (orphans.contains(process.pid) ? "LEFTOVER" : "running"))")
        }
        print("\(processes.count) processes, \(orphans.count) leftovers, server socket: \(WineCommands.isServerRunning(container: owner))")
        if flag("--end") { print("ended \(WineProcessScanner.endOrphans(of: owner))") }

    case "internal-make-icon":
        // Only use the placeholder when no designed image was requested.
        guard let path = arguments.first else { exit(2) }
        let image: CGImage
        if let sourcePath = arguments.dropFirst().first {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
                  let designed = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                printError("Could not read the app icon: \(sourcePath)")
                exit(2)
            }
            image = designed
        } else {
            guard let placeholder = IconTools.cellAppIcon() else { exit(2) }
            image = placeholder
        }
        try IconTools.writeICNS(image, to: URL(fileURLWithPath: path))

    case "help", "--help", "-h":
        usage()

    default:
        printError("Unknown command: \(command)")
        usage()
        exit(2)
    }
} catch {
    printError(error.localizedDescription)
    exit(1)
}
