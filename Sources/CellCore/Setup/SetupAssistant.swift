import Foundation

/// One thing the automatic setup does.
public struct SetupStep: Identifiable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case reuseEngines, downloadWine, downloadDXMT, findD3DMetal, importBottles, prepareContainer, installSteam, installRuntimes
    }

    public var id: Kind { kind }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// false = already in place.
    public var needed: Bool
}

/// First-run setup: gets every engine and runtime a game needs, with no decisions for the user.
public enum SetupAssistant {
    public static func steps(services: CellServices) -> [SetupStep] {
        let runtimes = services.runtimes.runtimes
        let components = services.components
        let engines = RuntimeManager.importSuggestions()
            .filter { suggestion in suggestion.url.pathExtension == "app" && !runtimes.contains { $0.originDescription == suggestion.url.path } }
        let bottles = BottleImporter.discover().filter { !services.isImported($0) }
        let wine = Catalog.wineEngines.first(where: \.recommended)
        let dxmt = Catalog.graphicsComponents.first { $0.kind == .dxmt }
        let hasUpstream = runtimes.contains { !$0.isCrossOverBased }
        let hasDXMT = components.best(.dxmt) != nil || runtimes.contains { $0.bundled(.dxmt) != nil }
        let hasD3DMetal = components.best(.d3dmetal) != nil || runtimes.contains { $0.bundled(.d3dmetal) != nil }
        let defaultContainer = services.library.defaultContainer
        let steamInstalled = services.library.containers.contains { SteamIntegration.isInstalled(in: $0) }
            || bottles.contains(where: \.hasSteam)

        return [
            SetupStep(kind: .reuseEngines, title: "Reuse engines already on this Mac",
                      detail: engines.isEmpty ? "Nothing to reuse." : engines.map(\.title).joined(separator: ", ") + " — cloned, no extra disk space",
                      needed: !engines.isEmpty),
            SetupStep(kind: .downloadWine, title: "Download \(wine.map { "\($0.name) \($0.version)" } ?? "Wine")",
                      detail: "The newest Wine (\((wine?.sizeBytes ?? 0).byteDescriptionCore)). Used for games that need recent fixes and as a backup engine.",
                      needed: !hasUpstream && wine != nil),
            SetupStep(kind: .downloadDXMT, title: "Download DXMT \(dxmt?.version ?? "")",
                      detail: "Fast DirectX 10/11 → Metal (\((dxmt?.sizeBytes ?? 0).byteDescriptionCore)).",
                      needed: !hasDXMT && dxmt != nil),
            SetupStep(kind: .findD3DMetal, title: "Find D3DMetal",
                      detail: "Apple's DirectX 12 → Metal translator, taken from the Game Porting Toolkit or an engine on this Mac.",
                      needed: !hasD3DMetal),
            SetupStep(kind: .importBottles, title: "Bring over your games",
                      detail: bottles.isEmpty ? "No Porting Kit, CrossOver or Whisky bottles found."
                        : bottles.map { "\($0.name) (\($0.summary))" }.joined(separator: "; "),
                      needed: !bottles.isEmpty),
            SetupStep(kind: .prepareContainer, title: "Set up Windows",
                      detail: "Creates the “Games & Apps” container with Retina resolution, Mac keyboard and your language.",
                      needed: !(defaultContainer?.isInitialized ?? false)),
            SetupStep(kind: .installSteam, title: "Install Steam", detail: "Official installer from Valve, installed silently.",
                      needed: !steamInstalled),
            SetupStep(kind: .installRuntimes, title: "Install Visual C++ runtimes",
                      detail: "Microsoft runtimes most games need (from Microsoft).",
                      needed: !(defaultContainer.map(hasVisualCpp) ?? false)),
        ]
    }

    /// Runs one step and returns a short result.
    public static func run(_ kind: SetupStep.Kind, services: CellServices, status: @escaping @Sendable (String) -> Void,
                           progress: Downloader.Progress? = nil) async throws -> String {
        switch kind {
        case .reuseEngines:
            let runtimes = services.runtimes.runtimes
            let engines = RuntimeManager.importSuggestions()
                .filter { suggestion in suggestion.url.pathExtension == "app" && !runtimes.contains { $0.originDescription == suggestion.url.path } }
            var names: [String] = []
            for engine in engines {
                status("Cloning \(engine.title)…")
                if let runtime = try? services.importRuntimeWithComponents(from: engine.url) { names.append(runtime.name) }
            }
            return names.isEmpty ? "Nothing imported." : "Imported \(names.count) engine\(names.count == 1 ? "" : "s")."

        case .downloadWine:
            guard let entry = Catalog.wineEngines.first(where: \.recommended) else { return "No engine in the catalog." }
            let runtime = try await services.runtimes.install(entry, progress: progress, status: status)
            services.adoptRuntimeForContainersWithoutEngine()
            return "Installed \(runtime.name)."

        case .downloadDXMT:
            guard let entry = Catalog.graphicsComponents.first(where: { $0.kind == .dxmt }) else { return "Not in the catalog." }
            let component = try await services.components.install(entry, progress: progress, status: status)
            for runtime in services.runtimes.runtimes { services.runtimes.clearFlavors(for: runtime) }
            return "Installed DXMT \(component.version)."

        case .findD3DMetal:
            status("Looking for D3DMetal…")
            for source in d3dMetalCandidates(services: services) {
                status("Importing D3DMetal from \(source.lastPathComponent)…")
                if let component = try? services.components.importD3DMetal(from: source) {
                    return "Imported D3DMetal \(component.version) from \(source.lastPathComponent)."
                }
            }
            return "Not found. DirectX 12 games need it: download Apple's Game Porting Toolkit (free Apple ID) and Cell picks it up from Downloads."

        case .importBottles:
            let bottles = BottleImporter.discover().filter { !services.isImported($0) }
            var imported: [String] = []
            for bottle in bottles {
                status("Importing \(bottle.name)…")
                if let container = try? services.importBottle(bottle, status: status) { imported.append(container.name) }
            }
            return imported.isEmpty ? "Nothing imported." : "Imported \(imported.joined(separator: ", "))."

        case .prepareContainer:
            let container = try services.ensureDefaultContainer()
            services.adoptRuntimeForContainersWithoutEngine()
            let current = services.library.container(id: container.id) ?? container
            try await services.launcher.prepareContainer(current, status: status)
            _ = try? services.discoverApps(in: services.library.container(id: container.id) ?? current)
            return "“\(current.name)” is ready."

        case .installSteam:
            let container = try services.ensureDefaultContainer()
            _ = try await services.installSteam(in: services.library.container(id: container.id) ?? container, status: status, progress: progress)
            return "Steam is installed. Sign in once and your games appear in the Library."

        case .installRuntimes:
            let container = try services.ensureDefaultContainer()
            try await services.installVisualCppRuntimes(in: services.library.container(id: container.id) ?? container, status: status)
            return "Installed."
        }
    }

    /// Game Porting Toolkit images in Downloads, mounted toolkits, and engines that contain D3DMetal.
    static func d3dMetalCandidates(services: CellServices) -> [URL] {
        var candidates = services.components.d3dMetalSources().map(\.url)
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [] {
            let lower = name.lowercased()
            guard lower.hasSuffix(".dmg") else { continue }
            if lower.contains("game porting") || lower.contains("game_porting") || lower.contains("evaluation environment")
                || lower.contains("gptk") {
                candidates.append(downloads.appendingPathComponent(name))
            }
        }
        for runtime in services.runtimes.runtimes where runtime.bundled(.d3dmetal) != nil {
            candidates.append(runtime.wineRoot)
        }
        return candidates
    }

    /// True when real (non-Wine) Visual C++ 2015+ runtimes are installed.
    static func hasVisualCpp(_ container: Container) -> Bool {
        let file = container.driveC.appendingPathComponent("windows/system32/vcruntime140_1.dll")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 128)) ?? Data()
        // Wine's own placeholders carry a signature right after the DOS header.
        return header.count == 128 && header.range(of: Data("Wine ".utf8)) == nil
    }
}

extension Int64 {
    var byteDescriptionCore: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
