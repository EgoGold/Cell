import Foundation

public enum RuntimeError: LocalizedError {
    case wineNotFound(String)
    case notInstalled(String)
    case checksumMismatch(String)
    case incompatible(String)

    public var errorDescription: String? {
        switch self {
        case .wineNotFound(let place): return "No Wine engine was found in \(place)."
        case .notInstalled(let what): return "\(what) is not installed."
        case .checksumMismatch(let file): return "The download of \(file) is damaged (checksum mismatch). Please try again."
        case .incompatible(let reason): return reason
        }
    }
}

/// Something on this Mac Cell can import (Porting Kit / Wineskin wrappers, engine archives).
public struct ImportSuggestion: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var title: String
    public var detail: String
    public var containsD3DMetal: Bool
    public var containsDXMT: Bool
}

/// Installs Wine engines and builds per-backend "flavors" of them.
///
/// A flavor is the base engine cloned with APFS copy-on-write (no extra disk space) with a
/// translation layer's builtin DLLs laid over `lib/`. Processes from different flavors share one
/// prefix and one wineserver, which is what makes the unified container possible.
public final class RuntimeManager: @unchecked Sendable {
    private var storedRuntimes: [WineRuntime] = []
    private let lock = NSLock()
    public var runtimes: [WineRuntime] { lock.withLock { storedRuntimes } }

    public init() { reload() }

    public func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: CellPaths.runtimes, includingPropertiesForKeys: nil)) ?? []
        // Engines installed before the cleanup existed still hold Finder's "._" files (once per engine).
        for dir in dirs where !fm.fileExists(atPath: dir.appendingPathComponent(".cell-appledouble-removed").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("runtime.json").path) {
            FileOps.removeAppleDoubleFiles(in: dir)
            fm.createFile(atPath: dir.appendingPathComponent(".cell-appledouble-removed").path, contents: Data())
        }
        let loaded = dirs.compactMap { JSONStore.loadIfPresent(WineRuntime.self, from: $0.appendingPathComponent("runtime.json")) }
            .filter { fm.fileExists(atPath: $0.wineRoot.appendingPathComponent($0.loaderRelativePath).path) }
            .sorted { LooseVersion($0.version) > LooseVersion($1.version) }
        lock.withLock { storedRuntimes = loaded }
    }

    public func runtime(id: String?) -> WineRuntime? {
        guard let id else { return nil }
        return runtimes.first { $0.id == id }
    }

    /// Best engine for a new container: one that can run D3DMetal (CrossOver-based) wins, then the newest.
    public var recommendedRuntime: WineRuntime? {
        runtimes.max { lhs, rhs in
            func score(_ r: WineRuntime) -> Int {
                (r.supportsD3DMetal == true ? 4 : 0) + (r.supportsDXMT == true ? 2 : 0) + (r.hasMono ? 1 : 0)
            }
            if score(lhs) != score(rhs) { return score(lhs) < score(rhs) }
            return LooseVersion(lhs.version) < LooseVersion(rhs.version)
        }
    }

    // MARK: Install & import

    public func install(_ entry: CatalogEntry, progress: Downloader.Progress? = nil,
                        status: (@Sendable (String) -> Void)? = nil) async throws -> WineRuntime {
        try CellPaths.ensureDirectories()
        let archive = CellPaths.downloads.appendingPathComponent(entry.url.lastPathComponent)
        status?("Downloading \(entry.name) \(entry.version)…")
        _ = try await Downloader.download(entry.url, to: archive, title: "\(entry.name) \(entry.version)",
                                          sha256: entry.sha256, expectedSize: entry.sizeBytes, progress: progress)
        status?("Unpacking \(entry.name)…")
        var scratch: URL?
        defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
        var source = archive
        if entry.id == "sikarugir-wine-10.0-revision-8" {
            let directory = try CellPaths.makeScratchDirectory(prefix: "sikarugir")
            scratch = directory
            source = try await assembleSikarugir(engine: archive, in: directory, progress: progress, status: status)
        }
        var runtime = try importRuntime(from: source, preferredID: entry.id, displayName: "\(entry.name) \(entry.version)",
                                        origin: .catalog, originDescription: entry.url.absoluteString)
        if let d3dmetal = entry.supportsD3DMetal { runtime.supportsD3DMetal = d3dmetal }
        if let dxmt = entry.supportsDXMT { runtime.supportsDXMT = dxmt }
        try JSONStore.save(runtime, to: runtime.metadataURL)
        try? FileManager.default.removeItem(at: archive)
        reload()
        return runtime
    }

    private func assembleSikarugir(engine: URL, in directory: URL, progress: Downloader.Progress?,
                                   status: (@Sendable (String) -> Void)?) async throws -> URL {
        let fm = FileManager.default
        let template = CellPaths.downloads.appendingPathComponent(Catalog.sikarugirTemplateURL.lastPathComponent)
        status?("Downloading Sikarugir’s Wine libraries…")
        _ = try await Downloader.download(Catalog.sikarugirTemplateURL, to: template, title: "Sikarugir Wine libraries",
                                          sha256: Catalog.sikarugirTemplateSHA256, expectedSize: Catalog.sikarugirTemplateSize, progress: progress)
        let wrapper = directory.appendingPathComponent("Template-1.0.27.app")
        let package = directory.appendingPathComponent("Engine")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        status?("Unpacking the Wine engine and its libraries…")
        try FileOps.extractArchive(template, to: directory)
        try FileOps.extractArchive(engine, to: package)
        let contents = wrapper.appendingPathComponent("Contents")
        let sharedSupport = contents.appendingPathComponent("SharedSupport")
        try fm.createDirectory(at: sharedSupport, withIntermediateDirectories: true)
        guard let root = Self.findWineRoot(in: package), FileOps.isDirectory(contents.appendingPathComponent("Frameworks")) else {
            throw RuntimeError.incompatible("The Sikarugir engine or its Wine libraries are missing from the archive.")
        }
        try fm.moveItem(at: root, to: sharedSupport.appendingPathComponent("wine"))
        try? fm.removeItem(at: template)
        return wrapper
    }

    /// Imports a Wine engine from a folder, a Wineskin/Porting Kit wrapper `.app`, or an archive.
    @discardableResult
    public func importRuntime(from source: URL, preferredID: String? = nil, displayName: String? = nil,
                              origin: RuntimeOrigin = .imported, originDescription: String? = nil) throws -> WineRuntime {
        try CellPaths.ensureDirectories()
        let fm = FileManager.default
        var scratch: URL?
        defer { if let scratch { try? fm.removeItem(at: scratch) } }

        var searchRoot = source
        if !FileOps.isDirectory(source) {
            let dir = try CellPaths.makeScratchDirectory(prefix: "runtime")
            scratch = dir
            try FileOps.extractArchive(source, to: dir)
            searchRoot = dir
        }
        guard let wineRoot = Self.findWineRoot(in: searchRoot) else {
            throw RuntimeError.wineNotFound(source.lastPathComponent)
        }
        let info = Self.inspect(wineRoot: wineRoot)
        let id = preferredID ?? Self.makeID(from: info.versionString, source: source)
        var runtime = WineRuntime(id: id, name: displayName ?? Self.displayName(for: info.versionString, source: source),
                                  version: info.version, origin: origin,
                                  originDescription: originDescription ?? source.path)
        try? fm.removeItem(at: runtime.directory)
        try fm.createDirectory(at: runtime.directory, withIntermediateDirectories: true)

        // Clone (copy-on-write) or move the engine into place.
        if scratch != nil {
            try fm.moveItem(at: wineRoot, to: runtime.wineRoot)
        } else {
            try FileOps.cloneItem(at: wineRoot, to: runtime.wineRoot)
        }
        // Wrappers keep dylibs (MoltenVK, FreeType, GnuTLS, GStreamer…) in Contents/Frameworks.
        if let frameworks = Self.wrapperFrameworks(for: wineRoot) {
            let destination = runtime.directory.appendingPathComponent("Frameworks", isDirectory: true)
            if scratch != nil { try fm.moveItem(at: frameworks, to: destination) } else { try FileOps.cloneItem(at: frameworks, to: destination) }
            runtime.extraLibraryPaths = ["Frameworks"]
            runtime.extraFrameworkPaths = ["Frameworks"]
        }

        runtime.loaderRelativePath = info.loader
        runtime.baseBackend = info.baseBackend
        runtime.bundledComponents = info.bundled
        runtime.hasMono = info.hasMono
        runtime.hasGecko = info.hasGecko
        runtime.supportsD3DMetal = info.likelyCrossOver ? true : nil
        runtime.supportsDXMT = (info.likelyCrossOver || runtime.bundled(.dxmt) != nil) ? true : nil
        try JSONStore.save(runtime, to: runtime.metadataURL)
        reload()
        return runtime
    }

    public func remove(_ runtime: WineRuntime) throws {
        try FileManager.default.removeItem(at: runtime.directory)
        reload()
    }

    // MARK: Flavors

    /// Root of the Wine installation to use for `backend` (base engine or an overlay flavor).
    public func flavorRoot(for runtime: WineRuntime, backend: GraphicsBackend, components: ComponentManager, for32Bit: Bool = false) throws -> URL {
        guard backend.usesEngineOverlay, let kind = backend.componentKind else { return runtime.wineRoot }
        if runtime.baseBackend == backend { return runtime.wineRoot }
        guard let component = components.best(kind, for: runtime, for32Bit: for32Bit) else {
            if runtime.bundled(kind) != nil { return runtime.wineRoot }
            throw RuntimeError.notInstalled(backend.displayName)
        }
        return try ensureFlavor(runtime: runtime, component: component)
    }

    public func flavorKey(for runtime: WineRuntime, backend: GraphicsBackend, components: ComponentManager, for32Bit: Bool = false) -> String {
        guard backend.usesEngineOverlay, backend != runtime.baseBackend, let kind = backend.componentKind,
              let component = components.best(kind, for: runtime, for32Bit: for32Bit) else { return "base" }
        return component.id
    }

    private struct FlavorMarker: Codable, Equatable {
        var componentID: String
        var componentInstalledAt: Date
        var runtimeInstalledAt: Date
    }

    func ensureFlavor(runtime: WineRuntime, component: GraphicsComponent) throws -> URL {
        let fm = FileManager.default
        let directory = runtime.flavorsDirectory.appendingPathComponent(component.id, isDirectory: true)
        let markerURL = directory.appendingPathComponent(".chamber-flavor.json")
        let marker = FlavorMarker(componentID: component.id, componentInstalledAt: component.installedAt,
                                  runtimeInstalledAt: runtime.installedAt)
        if let existing = JSONStore.loadIfPresent(FlavorMarker.self, from: markerURL), existing == marker {
            return directory
        }
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: runtime.wineRoot, includingPropertiesForKeys: nil) {
            let target = directory.appendingPathComponent(item.lastPathComponent)
            if item.lastPathComponent == "share" {
                // Shared data keeps wine.inf's timestamp identical, so the prefix is never "updated" on switch.
                // A relative link keeps working if the whole data folder moves.
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: FileOps.relativePath(from: directory, to: item))
            } else {
                try FileOps.cloneItem(at: item, to: target)
            }
        }
        try FileOps.overlay(component.libDirectory, onto: directory.appendingPathComponent("lib", isDirectory: true))
        // A replaced DLL must not keep the previous translator's Unix half (e.g. D3DMetal's d3d11.so under DXMT).
        let componentWindows = component.libDirectory.appendingPathComponent("wine/x86_64-windows")
        let componentUnix = component.libDirectory.appendingPathComponent("wine/x86_64-unix")
        let flavorUnix = directory.appendingPathComponent("lib/wine/x86_64-unix")
        for dll in (try? fm.contentsOfDirectory(atPath: componentWindows.path)) ?? [] where dll.hasSuffix(".dll") {
            let soName = String(dll.dropLast(4)) + ".so"
            let stale = flavorUnix.appendingPathComponent(soName)
            if !fm.fileExists(atPath: componentUnix.appendingPathComponent(soName).path),
               fm.fileExists(atPath: stale.path) || FileOps.isSymlink(stale) {
                try? fm.removeItem(at: stale)
            }
        }
        try JSONStore.save(marker, to: markerURL)
        return directory
    }

    /// Removes cached flavors (they are rebuilt on demand).
    public func clearFlavors(for runtime: WineRuntime) {
        try? FileManager.default.removeItem(at: runtime.flavorsDirectory)
    }

    // MARK: Which backends can this engine run?

    public struct BackendSupport: Hashable, Sendable {
        public var backend: GraphicsBackend
        /// true = known to work with this engine, false = unknown (try, rank lower).
        public var confident: Bool
        public var supports32Bit: Bool
        /// Handles Direct3D 10/11/12. WineD3D loses this when the base engine's d3d11 was replaced.
        public var coversModernDirect3D: Bool = true

        public init(backend: GraphicsBackend, confident: Bool, supports32Bit: Bool, coversModernDirect3D: Bool = true) {
            self.backend = backend
            self.confident = confident
            self.supports32Bit = supports32Bit
            self.coversModernDirect3D = coversModernDirect3D
        }
    }

    public func supportedBackends(for runtime: WineRuntime, components: ComponentManager, for32Bit: Bool = false) -> [GraphicsBackend: BackendSupport] {
        var result: [GraphicsBackend: BackendSupport] = [:]
        // WineD3D always handles Direct3D 9 and older; Direct3D 10+ only if the base engine was not modified.
        result[.wined3d] = BackendSupport(backend: .wined3d, confident: true, supports32Bit: true,
                                          coversModernDirect3D: runtime.baseBackend == .wined3d)

        let hasD3DMetal = runtime.bundled(.d3dmetal) != nil || components.best(.d3dmetal, for: runtime) != nil
        if hasD3DMetal, runtime.supportsD3DMetal != false {
            result[.d3dmetal] = BackendSupport(backend: .d3dmetal,
                                               confident: runtime.supportsD3DMetal == true || runtime.bundled(.d3dmetal) != nil,
                                               supports32Bit: false)
        }
        let dxmtComponent = components.best(.dxmt, for: runtime, for32Bit: for32Bit)
        if runtime.bundled(.dxmt) != nil || dxmtComponent != nil, runtime.supportsDXMT != false {
            result[.dxmt] = BackendSupport(backend: .dxmt,
                                           confident: runtime.supportsDXMT == true || runtime.bundled(.dxmt) != nil,
                                           supports32Bit: dxmtComponent?.has32Bit ?? false)
        }
        if let dxvk = components.best(.dxvk, for: runtime) {
            result[.dxvk] = BackendSupport(backend: .dxvk, confident: true, supports32Bit: dxvk.has32Bit)
        }
        return result
    }

    // MARK: Inspection helpers

    public struct EngineInfo: Sendable {
        public var version: String
        public var versionString: String
        public var loader: String
        public var baseBackend: GraphicsBackend
        public var bundled: [BundledComponent]
        public var hasMono: Bool
        public var hasGecko: Bool
        public var likelyCrossOver: Bool
    }

    /// Finds the folder that contains `bin/wine` or `bin/wine64`.
    public static func findWineRoot(in directory: URL) -> URL? {
        func isRoot(_ url: URL) -> Bool {
            let fm = FileManager.default
            return (fm.isExecutableFile(atPath: url.appendingPathComponent("bin/wine").path)
                    || fm.isExecutableFile(atPath: url.appendingPathComponent("bin/wine64").path))
                && FileOps.isDirectory(url.appendingPathComponent("lib"))
        }
        if isRoot(directory) { return directory }
        let wrapperEngine = directory.appendingPathComponent("Contents/SharedSupport/wine")
        if isRoot(wrapperEngine) { return wrapperEngine }
        return FileOps.find(where: isRoot, in: directory, maxDepth: 6)
    }

    static func wrapperFrameworks(for wineRoot: URL) -> URL? {
        // <X>.app/Contents/SharedSupport/wine -> <X>.app/Contents/Frameworks
        let contents = wineRoot.deletingLastPathComponent().deletingLastPathComponent()
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        guard contents.lastPathComponent == "Contents", FileOps.isDirectory(frameworks) else { return nil }
        return frameworks
    }

    public static func inspect(wineRoot: URL) -> EngineInfo {
        let fm = FileManager.default
        let loader = fm.isExecutableFile(atPath: wineRoot.appendingPathComponent("bin/wine").path) ? "bin/wine" : "bin/wine64"
        let lib = wineRoot.appendingPathComponent("lib/wine")
        let unixLib = lib.appendingPathComponent("x86_64-unix")
        let windowsLib = lib.appendingPathComponent("x86_64-windows")

        var versionString = (try? String(contentsOf: wineRoot.appendingPathComponent("version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if versionString.isEmpty, let data = try? Data(contentsOf: unixLib.appendingPathComponent("ntdll.so"), options: .alwaysMapped) {
            let text = String(decoding: data.prefix(16 * 1024 * 1024).map { $0 < 0x20 || $0 > 0x7E ? 0x20 : $0 }, as: UTF8.self)
            if let range = text.range(of: #"wine-\d+\.\d+(\.\d+)?(-rc\d+)?"#, options: .regularExpression) {
                versionString = String(text[range])
            }
        }
        let version = versionString.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(versionString[$0]) } ?? "unknown"

        var bundled: [BundledComponent] = []
        var baseBackend: GraphicsBackend = .wined3d
        let d3d11 = windowsLib.appendingPathComponent("d3d11.dll")
        let d3dMetalFramework = wineRoot.appendingPathComponent("lib/external/D3DMetal.framework")
        if FileOps.isDirectory(d3dMetalFramework) {
            bundled.append(BundledComponent(kind: .d3dmetal, version: frameworkVersion(d3dMetalFramework)))
            if FileOps.fileContains(d3d11, token: "d3dmetal") { baseBackend = .d3dmetal }
        }
        if fm.fileExists(atPath: unixLib.appendingPathComponent("winemetal.so").path), FileOps.fileContains(d3d11, token: "dxmt") {
            let dxmtVersion = versionString.range(of: #"DXMT[- _]?v?(\d+\.\d+)"#, options: [.regularExpression, .caseInsensitive])
                .map { String(versionString[$0]).filter { $0.isNumber || $0 == "." } }
            bundled.append(BundledComponent(kind: .dxmt, version: dxmtVersion))
            baseBackend = .dxmt
        }

        let lowerVersion = versionString.lowercased()
        let likelyCrossOver = bundled.contains { $0.kind == .d3dmetal }
            || ["crossover", "sikarugir", "gptk", "game-porting", "cx"].contains { lowerVersion.contains($0) }
        let share = wineRoot.appendingPathComponent("share/wine")
        return EngineInfo(version: version, versionString: versionString.isEmpty ? "Wine \(version)" : versionString,
                          loader: loader, baseBackend: baseBackend, bundled: bundled,
                          hasMono: FileOps.isDirectory(share.appendingPathComponent("mono")),
                          hasGecko: FileOps.isDirectory(share.appendingPathComponent("gecko")),
                          likelyCrossOver: likelyCrossOver)
    }

    static func frameworkVersion(_ framework: URL) -> String? {
        for plist in ["Versions/A/Resources/Info.plist", "Resources/Info.plist"] {
            if let dict = NSDictionary(contentsOf: framework.appendingPathComponent(plist)),
               let version = (dict["CFBundleShortVersionString"] ?? dict["CFBundleVersion"]) as? String {
                return version
            }
        }
        return nil
    }

    static func makeID(from versionString: String, source: URL) -> String {
        let base = (versionString.isEmpty ? source.deletingPathExtension().lastPathComponent : versionString)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(base.prefix(48))-\(UUID().uuidString.prefix(6).lowercased())"
    }

    static func displayName(for versionString: String, source: URL) -> String {
        if source.pathExtension == "app" {
            return "\(source.deletingPathExtension().lastPathComponent) engine (\(versionString))"
        }
        return versionString.isEmpty ? source.lastPathComponent : versionString
    }

    /// Engines already on this Mac (Porting Kit / Wineskin / Sikarugir wrappers and engine archives).
    public static func importSuggestions() -> [ImportSuggestion] {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var suggestions: [ImportSuggestion] = []
        let appFolders = [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications"),
                          home.appendingPathComponent("Applications/Porting Kit"),
                          home.appendingPathComponent("Applications/Sikarugir"), home.appendingPathComponent("Applications/Wineskin")]
        for folder in appFolders {
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".app") {
                let app = folder.appendingPathComponent(name)
                let wine = app.appendingPathComponent("Contents/SharedSupport/wine")
                guard fm.fileExists(atPath: wine.appendingPathComponent("lib/wine").path) else { continue }
                let info = inspect(wineRoot: wine)
                let parts = [info.versionString] + info.bundled.map { "\($0.kind.displayName) \($0.version ?? "")".trimmingCharacters(in: .whitespaces) }
                suggestions.append(ImportSuggestion(url: app, title: name, detail: parts.joined(separator: " · "),
                                                    containsD3DMetal: info.bundled.contains { $0.kind == .d3dmetal },
                                                    containsDXMT: info.bundled.contains { $0.kind == .dxmt }))
            }
        }
        let engines = home.appendingPathComponent("Library/Application Support/Wineskin/Engines")
        for name in (try? fm.contentsOfDirectory(atPath: engines.path)) ?? [] where name.hasSuffix(".tar.7z") || name.hasSuffix(".tar.xz") {
            let lower = name.lowercased()
            suggestions.append(ImportSuggestion(url: engines.appendingPathComponent(name), title: name,
                                                detail: "Wineskin engine archive (needs the wrapper's libraries for full support)",
                                                containsD3DMetal: lower.contains("d3dmetal"), containsDXMT: lower.contains("dxmt")))
        }
        return suggestions
    }
}
