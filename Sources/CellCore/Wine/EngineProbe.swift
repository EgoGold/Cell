import Foundation

/// What Cell's engine check found for one Wine engine + graphics engine pair.
public struct EngineCheck: Codable, Hashable, Sendable {
    public var fingerprint: String
    public var runtimeID: String
    public var backend: GraphicsBackend
    public var checkedAt: Date
    /// The GPU the graphics engine reports: "Apple M5" for DXMT; "NVIDIA GeForce 6800" is Wine's stand-in,
    /// which means Wine's own renderer answered instead.
    public var adapter: String?
    public var vendorID: UInt32?
    /// A Direct3D 11 device could be created.
    public var direct3D11: Bool
    /// A swap chain could be created and a frame shown — what every game needs to draw at all.
    public var drawsFrames: Bool
    public var direct3D12: Bool
    /// Windows dialogs can show text (nil: checked by an older version). Porting Kit's Wine 11.0 test build has
    /// no font renderer: every message box and launcher window shrinks to an empty title bar.
    public var drawsText: Bool?
    /// The step the check died in when it didn't finish ("swapchain": the process ended creating the swap chain).
    public var stoppedAt: String?
    public var exitCode: Int32?
    public var output: String

    /// Direct3D 10/11 games can run with this pair.
    public var runsDirect3D11: Bool { direct3D11 && drawsFrames }

    /// A missing/partial report cannot establish that a renderer is unusable.
    public var isConclusive: Bool {
        runsDirect3D11 || output.split(whereSeparator: \.isNewline).contains { $0 == "done" }
    }

    /// One line for the Engines page and logs.
    public var summary: String {
        if !isConclusive { return "Check incomplete — rendering capability unknown" }
        if runsDirect3D11 {
            return "Draws Direct3D 11\(direct3D12 ? " and 12" : "")" + (adapter.map { " on \($0)" } ?? "")
                + (drawsText == false ? " · Windows dialogs show no text" : "")
        }
        if direct3D11, let stoppedAt, ["window", "swapchain", "present"].contains(stoppedAt) {
            return "Crashes when a game opens its window"
        }
        if direct3D11 { return "Can't show frames" }
        if direct3D12 { return "Only Direct3D 12 works" }
        if output.isEmpty { return "Didn't start" }
        return "Can't create a Direct3D 11 device"
    }
}

/// Runs `Tools/engine-probe` (embedded as `EngineProbe.base64`) with a Wine engine and graphics engine in a
/// throw-away prefix. Nothing appears on screen: the prefix is created with Wine's Mac driver turned off,
/// and the check only uses a hidden window.
public enum EngineProbe {
    static let image: Data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()

    /// Graphics engines the check can test (DXVK first needs its DLLs copied into the prefix).
    public static let checkableBackends: [GraphicsBackend] = [.dxmt, .d3dmetal, .wined3d]

    /// The order in which a check reports its steps.
    static let steps = ["probe", "factory", "adapter", "d3d11", "window", "swapchain", "present", "d3d12", "text", "done"]

    static func succeeded(_ text: Substring?) -> Bool {
        guard let text, let value = UInt32(text.dropFirst(text.hasPrefix("0x") ? 2 : 0), radix: 16) else { return false }
        return value & 0x8000_0000 == 0
    }

    /// Reads the probe's output.
    static func parse(_ output: String, runtimeID: String, backend: GraphicsBackend, fingerprint: String,
                      exitCode: Int32?) -> EngineCheck {
        var fields: [String: [Substring]] = [:]
        var last = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard let step = words.first.map(String.init) else { continue }
            fields[step] = Array(words.dropFirst())
            last = step
        }
        var check = EngineCheck(fingerprint: fingerprint, runtimeID: runtimeID, backend: backend, checkedAt: Date(),
                                adapter: nil, vendorID: nil, direct3D11: false, drawsFrames: false, direct3D12: false,
                                drawsText: nil, stoppedAt: nil, exitCode: exitCode, output: output)
        if let adapter = fields["adapter"], adapter.count >= 3 {
            check.vendorID = UInt32(adapter[0].dropFirst(2), radix: 16)
            check.adapter = String(adapter[2]).trimmingCharacters(in: .whitespaces)
        }
        check.direct3D11 = succeeded(fields["d3d11"]?.first)
        check.drawsFrames = succeeded(fields["swapchain"]?.first) && succeeded(fields["present"]?.first)
        check.direct3D12 = succeeded(fields["d3d12"]?.first)
        if let text = fields["text"], text.count >= 2 {
            let width = UInt32(text[0].dropFirst(2), radix: 16) ?? 0
            let height = UInt32(text[1].dropFirst(2), radix: 16) ?? 0
            check.drawsText = width > 0 && height > 0
        }
        if fields["done"] == nil, steps.contains(last) {
            // The step after the last one reported is where it died.
            var index = (steps.firstIndex(of: last) ?? 0) + 1
            if last == "d3d11" && !check.direct3D11 { index = steps.firstIndex(of: "d3d12")! }
            if index < steps.count, steps[index] == "adapter" && fields["factory"] != nil { index += 1 }
            check.stoppedAt = steps[min(index, steps.count - 1)]
        }
        return check
    }

    static func environment(runtime: WineRuntime, flavorRoot: URL, prefix: URL) -> [String: String] {
        var env = WineEnvironment.cleanBase()
        for (key, value) in WineEnvironment.libraryEnvironment(runtime: runtime, flavorRoot: flavorRoot) { env[key] = value }
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = "-all,err+all,warn+seh,trace+loaddll"
        env["WINEBOOT_HIDE_DIALOG"] = "1"
        env["WINEDLLOVERRIDES"] = "mscoree=d;mshtml=d;winemenubuilder.exe=d"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    /// Checks each `(backend, flavor root, fingerprint)` on `runtime`. Takes about 15 seconds to set up the
    /// prefix plus a few seconds per graphics engine; the prefix is deleted afterwards.
    static func run(runtime: WineRuntime, targets: [(backend: GraphicsBackend, flavorRoot: URL, fingerprint: String)],
                    status: (@Sendable (String) -> Void)? = nil) async -> [EngineCheck] {
        guard !targets.isEmpty, !image.isEmpty else { return [] }
        let fm = FileManager.default
        let work = CellPaths.caches.appendingPathComponent("EngineChecks/\(runtime.id)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let prefix = work.appendingPathComponent("prefix", isDirectory: true)
        let wineserver = WineCommands.wineserver(runtime: runtime)
        // Keep reports outside the disposable prefix, including stderr and setup failures.
        defer { try? fm.removeItem(at: prefix) }
        do {
            try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
            // Headless: without the Mac driver, wineboot can't show its "updating" window or a Dock icon.
            var setup = environment(runtime: runtime, flavorRoot: runtime.wineRoot, prefix: prefix)
            setup["WINEDLLOVERRIDES"] = (setup["WINEDLLOVERRIDES"] ?? "") + ";winemac.drv=d"
            status?("Preparing a check of \(runtime.name)…")
            _ = try await ProcessRunner.runAsync(WineCommands.loader(runtime: runtime), arguments: ["wineboot", "--init"],
                                                 environment: setup, currentDirectory: work, timeout: 300,
                                                 outputDirectory: work.appendingPathComponent("setup"))
            _ = try? await ProcessRunner.runAsync(wineserver, arguments: ["-w"], environment: setup, timeout: 60)
            _ = try? await ProcessRunner.runAsync(wineserver, arguments: ["-k"], environment: setup, timeout: 20)
            let registry = work.appendingPathComponent("probe.reg")
            let edits = ["Software\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug",
                         "Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion\\AeDebug"].map {
                RegistryEdit.set(.localMachine, $0, "Debugger", .string(""))
            }
            try RegFile.data(for: edits).write(to: registry)
            _ = try await ProcessRunner.runAsync(WineCommands.loader(runtime: runtime),
                                                 arguments: ["regedit", "/S", registry.path], environment: setup, timeout: 30)
            _ = try? await ProcessRunner.runAsync(wineserver, arguments: ["-k"], environment: setup, timeout: 20)
            try image.write(to: prefix.appendingPathComponent("drive_c/cell-probe.exe"))
        } catch {
            let output = "setup failed: \(error.localizedDescription)"
            try? output.write(to: work.appendingPathComponent("setup-error.txt"), atomically: true, encoding: .utf8)
            return targets.map { EngineCheck(fingerprint: $0.fingerprint, runtimeID: runtime.id, backend: $0.backend, checkedAt: Date(),
                                             adapter: nil, vendorID: nil, direct3D11: false, drawsFrames: false, direct3D12: false,
                                             drawsText: nil, stoppedAt: "setup", exitCode: nil, output: output) }
        }
        var results: [EngineCheck] = []
        for target in targets {
            status?("Checking \(target.backend.displayName) on \(runtime.name)…")
            // DXMT's helper DLL is expected in system32, like in containers.
            let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
            try? fm.removeItem(at: system32.appendingPathComponent("winemetal.dll"))
            let winemetal = target.flavorRoot.appendingPathComponent("lib/wine/x86_64-windows/winemetal.dll")
            if target.backend == .dxmt, fm.fileExists(atPath: winemetal.path) {
                try? FileOps.cloneItem(at: winemetal, to: system32.appendingPathComponent("winemetal.dll"))
            }
            let outputFile = prefix.appendingPathComponent("drive_c/cell-probe.txt")
            try? fm.removeItem(at: outputFile)
            var env = environment(runtime: runtime, flavorRoot: target.flavorRoot, prefix: prefix)
            env["CELL_PROBE_OUT"] = "C:\\cell-probe.txt"
            var exitCode: Int32?
            do {
                let result = try await ProcessRunner.runAsync(WineCommands.loader(runtime: runtime, flavorRoot: target.flavorRoot),
                                                              arguments: ["C:\\cell-probe.exe"], environment: env,
                                                              currentDirectory: work, timeout: 40,
                                                              outputDirectory: work.appendingPathComponent(target.backend.rawValue))
                exitCode = result.status
                try? (result.stdout + "\n" + result.stderr).write(to: work.appendingPathComponent("\(target.backend.rawValue)-process.log"), atomically: true, encoding: .utf8)
            } catch {
                try? error.localizedDescription.write(to: work.appendingPathComponent("\(target.backend.rawValue)-error.txt"), atomically: true, encoding: .utf8)
            }
            _ = try? await ProcessRunner.runAsync(wineserver, arguments: ["-k"], environment: env, timeout: 20)
            let output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
            try? output.write(to: work.appendingPathComponent("\(target.backend.rawValue)-probe.txt"), atomically: true, encoding: .utf8)
            results.append(parse(output, runtimeID: runtime.id, backend: target.backend, fingerprint: target.fingerprint,
                                 exitCode: exitCode))
        }
        return results
    }
}

/// What the app needs from a graphics engine.
public enum GraphicsNeed: Sendable {
    /// Direct3D 10/11 (also assumed for programs that weren't analysed: most are games).
    case direct3D11
    case direct3D12
    /// Direct3D 9 and older.
    case legacy
    /// No Direct3D at all (installers, tools, Vulkan or OpenGL programs): graphics checks don't matter.
    case none

    public init(analysis: AppAnalysis?) {
        guard let analysis else { self = .direct3D11; return }
        let apis = analysis.graphicsAPIs
        let legacy = !apis.isDisjoint(with: [.d3d9, .d3d8, .ddraw])
        let has11 = apis.contains(.d3d11) || apis.contains(.d3d10) || (analysis.engine == .unity && !legacy)
        let has12 = apis.contains(.d3d12) || analysis.hasD3D12AgilitySDK
        if has11 { self = .direct3D11 }
        else if has12 { self = .direct3D12 }
        else if apis.contains(.d3d9) || apis.contains(.d3d8) || apis.contains(.ddraw) { self = .legacy }
        else { self = .none }
    }
}

/// Remembers which engine pairs really work, checks new ones once, and keeps Cell from using a pair that
/// can't draw (the cause of games crashing right at start).
public final class EngineVerifier: @unchecked Sendable {
    unowned let services: CellServices
    private let lock = NSLock()
    private var checks: [String: EngineCheck] = [:]
    private var running: [String: Task<Void, Never>] = [:]

    public enum Verdict: Equatable, Sendable {
        case works
        case broken(String)
        case unchecked
    }

    static var storeURL: URL { CellPaths.root.appendingPathComponent("engine-checks.json") }

    init(services: CellServices) {
        self.services = services
        let saved = JSONStore.loadIfPresent([EngineCheck].self, from: Self.storeURL) ?? []
        checks = Dictionary(saved.map { ($0.fingerprint, $0) }, uniquingKeysWith: { $1 })
    }

    public func reload() {
        let saved = JSONStore.loadIfPresent([EngineCheck].self, from: Self.storeURL) ?? []
        lock.withLock { checks = Dictionary(saved.map { ($0.fingerprint, $0) }, uniquingKeysWith: { $1 }) }
    }

    /// Changes whenever the engine, the graphics engine files or the check itself change.
    public func fingerprint(runtime: WineRuntime, backend: GraphicsBackend) -> String {
        let components = services.components
        let key = services.runtimes.flavorKey(for: runtime, backend: backend, components: components)
        var parts = ["provenance-v2", String(EngineProbe.sha256.prefix(12)), runtime.id, String(Int(runtime.installedAt.timeIntervalSince1970)),
                     backend.rawValue, key]
        if key != "base", let kind = backend.componentKind, let component = components.best(kind, for: runtime) {
            parts.append(String(Int(component.installedAt.timeIntervalSince1970)))
            parts.append(component.sourceRuntimeID ?? "unknown-runtime")
            parts.append(component.sourceWineVersion ?? "unknown-version")
        }
        return parts.joined(separator: "|")
    }

    public func check(runtime: WineRuntime, backend: GraphicsBackend) -> EngineCheck? {
        let key = fingerprint(runtime: runtime, backend: backend)
        return lock.withLock { checks[key] }
    }

    public func verdict(runtime: WineRuntime, backend: GraphicsBackend, need: GraphicsNeed) -> Verdict {
        guard EngineProbe.checkableBackends.contains(backend), backend != .wined3d || runtime.baseBackend == .wined3d else { return .unchecked }
        guard need != .none, let check = check(runtime: runtime, backend: backend),
              check.isConclusive else { return .unchecked }
        switch need {
        case .none:
            return .unchecked
        case .legacy:
            // The check covers Direct3D 10–12 only; Direct3D 9 games are judged by how they run.
            return backend == .wined3d || check.runsDirect3D11 ? .works : .broken(check.summary)
        case .direct3D11:
            return check.runsDirect3D11 ? .works : .broken(check.summary)
        case .direct3D12:
            if backend == .dxmt { return .broken("DXMT has no Direct3D 12") }
            return check.direct3D12 && (check.drawsFrames || backend == .wined3d) ? .works : .broken(check.summary)
        }
    }

    /// Whether Windows dialogs show text with this engine (fonts don't depend on the graphics engine);
    /// nil while unknown.
    public func drawsText(runtime: WineRuntime) -> Bool? {
        let known = checkableBackends(for: runtime).compactMap { check(runtime: runtime, backend: $0)?.drawsText }
        if known.contains(true) { return true }
        return known.isEmpty ? nil : false
    }

    /// Graphics engines on `runtime` that haven't been checked yet.
    public func uncheckedBackends(for runtime: WineRuntime) -> [GraphicsBackend] {
        checkableBackends(for: runtime).filter { check(runtime: runtime, backend: $0) == nil }
    }

    /// Graphics engines of `runtime` the check can test. WineD3D only where it is the engine's own renderer:
    /// on engines built around DXMT or D3DMetal those answer instead, and the result would mislead.
    public func checkableBackends(for runtime: WineRuntime) -> [GraphicsBackend] {
        let supported = services.runtimes.supportedBackends(for: runtime, components: services.components)
        return EngineProbe.checkableBackends.filter { backend in
            supported[backend] != nil && (backend != .wined3d || runtime.baseBackend == .wined3d)
        }
    }

    public var hasUncheckedPairs: Bool {
        services.runtimes.runtimes.contains { !uncheckedBackends(for: $0).isEmpty }
    }

    /// Checks every graphics engine of `runtime` that hasn't been checked (one check per engine at a time).
    public func verify(runtime: WineRuntime, status: (@Sendable (String) -> Void)? = nil) async {
        let task: Task<Void, Never> = lock.withLock {
            if let existing = running[runtime.id] { return existing }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performChecks(runtime: runtime, status: status)
            }
            running[runtime.id] = task
            return task
        }
        await task.value
        lock.withLock { running[runtime.id] = nil }
    }

    /// Checks every installed engine (in the background after setup and after installing engines).
    public func verifyAll(status: (@Sendable (String) -> Void)? = nil) async {
        for runtime in services.runtimes.runtimes where !uncheckedBackends(for: runtime).isEmpty {
            await verify(runtime: runtime, status: status)
        }
    }

    private func performChecks(runtime: WineRuntime, status: (@Sendable (String) -> Void)?) async {
        var targets: [(backend: GraphicsBackend, flavorRoot: URL, fingerprint: String)] = []
        for backend in uncheckedBackends(for: runtime) {
            guard let root = try? services.runtimes.flavorRoot(for: runtime, backend: backend, components: services.components) else { continue }
            targets.append((backend, root, fingerprint(runtime: runtime, backend: backend)))
        }
        let results = await EngineProbe.run(runtime: runtime, targets: targets, status: status)
        guard !results.isEmpty else { return }
        lock.withLock {
            for result in results {
                // A check that couldn't even set up says nothing about the graphics engine: try again next time.
                if result.stoppedAt == "setup" { continue }
                checks[result.fingerprint] = result
            }
            let all = checks.values.sorted { ($0.runtimeID, $0.backend.rawValue) < ($1.runtimeID, $1.backend.rawValue) }
            try? JSONStore.save(all, to: Self.storeURL)
        }
    }

    /// Forgets results so every engine is checked again.
    public func reset() {
        lock.withLock {
            checks.removeAll()
            try? FileManager.default.removeItem(at: Self.storeURL)
        }
    }
}
