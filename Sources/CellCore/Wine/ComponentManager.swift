import Foundation

public enum ComponentError: LocalizedError {
    case layoutNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .layoutNotFound(let detail): return detail
        }
    }
}

/// Installs graphics translation layers (DXMT, D3DMetal, DXVK) in a Wine-lib layout.
public final class ComponentManager: @unchecked Sendable {
    private var storedComponents: [GraphicsComponent] = []
    private let lock = NSLock()
    public var components: [GraphicsComponent] { lock.withLock { storedComponents } }

    public init() { reload() }

    public func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: CellPaths.components, includingPropertiesForKeys: nil)) ?? []
        let loaded = dirs.compactMap { JSONStore.loadIfPresent(GraphicsComponent.self, from: $0.appendingPathComponent("component.json")) }
            .map { component -> GraphicsComponent in
                var component = component
                if component.kind == .dxmt, component.version == "bundled", component.sourceWineVersion == nil {
                    let metadata = URL(fileURLWithPath: component.origin).deletingLastPathComponent().appendingPathComponent("runtime.json")
                    component.sourceWineVersion = ComponentSourceVersions.version(of: metadata)
                    // Recover a moved donor only from matching binaries, never its old folder name.
                    let runtimeDirs = (try? FileManager.default.contentsOfDirectory(at: CellPaths.runtimes, includingPropertiesForKeys: nil)) ?? []
                    let matches = runtimeDirs.compactMap { dir -> WineRuntime? in
                        guard let runtime = JSONStore.loadIfPresent(WineRuntime.self, from: dir.appendingPathComponent("runtime.json")) else { return nil }
                        let names = ["x86_64-windows/d3d11.dll", "x86_64-unix/winemetal.so"]
                        guard names.allSatisfy({ name in
                            guard let local = try? Data(contentsOf: component.libDirectory.appendingPathComponent("wine/" + name), options: .mappedIfSafe), !local.isEmpty,
                                  let donor = try? Data(contentsOf: runtime.wineRoot.appendingPathComponent("lib/wine/" + name), options: .mappedIfSafe) else { return false }
                            return local == donor
                        }) else { return nil }
                        return runtime
                    }
                    if matches.count == 1, let donor = matches.first {
                        component.sourceWineVersion = donor.version
                        component.sourceRuntimeID = donor.id
                    }
                    if component.sourceWineVersion != nil { try? JSONStore.save(component, to: component.metadataURL) }
                }
                return component
            }
            .sorted { $0.kind.rawValue == $1.kind.rawValue ? LooseVersion($0.version) > LooseVersion($1.version) : $0.kind.rawValue < $1.kind.rawValue }
        lock.withLock { storedComponents = loaded }
    }

    /// Newest installed component of a kind.
    public func best(_ kind: ComponentKind) -> GraphicsComponent? {
        components.filter { $0.kind == kind }.max { LooseVersion($0.version) < LooseVersion($1.version) }
    }

    /// The newest component of `kind` that works with `runtime`'s Wine version.
    public func best(_ kind: ComponentKind, for runtime: WineRuntime, for32Bit: Bool = false) -> GraphicsComponent? {
        if let found = components.filter({ $0.kind == kind && $0.isCompatible(with: runtime) && (!for32Bit || $0.has32Bit) })
            .max(by: { LooseVersion($0.version) < LooseVersion($1.version) }) { return found }
        guard for32Bit else { return nil }
        return components.filter { $0.kind == kind && $0.has32Bit && $0.isCompatible(with: runtime, for32Bit: true) }
            .max { LooseVersion($0.version) < LooseVersion($1.version) }
    }

    public func remove(_ component: GraphicsComponent) throws {
        try FileManager.default.removeItem(at: component.directory)
        reload()
    }

    // MARK: Catalog

    public func install(_ entry: CatalogEntry, progress: Downloader.Progress? = nil,
                        status: (@Sendable (String) -> Void)? = nil) async throws -> GraphicsComponent {
        try CellPaths.ensureDirectories()
        let archive = CellPaths.downloads.appendingPathComponent(entry.url.lastPathComponent)
        status?("Downloading \(entry.name) \(entry.version)…")
        _ = try await Downloader.download(entry.url, to: archive, title: "\(entry.name) \(entry.version)",
                                          sha256: entry.sha256, expectedSize: entry.sizeBytes, progress: progress)
        status?("Installing \(entry.name)…")
        defer { try? FileManager.default.removeItem(at: archive) }
        switch entry.kind {
        case .dxmt: return try importDXMT(from: archive, version: entry.version, origin: entry.url.absoluteString)
        case .dxvk: return try importDXVK(from: archive, version: entry.version, origin: entry.url.absoluteString)
        case .wine: throw ComponentError.layoutNotFound("Wine engines are installed by the runtime manager.")
        }
    }

    // MARK: DXMT

    /// Accepts the DXMT release archive, an extracted folder, or a Wine engine that already contains DXMT.
    @discardableResult
    public func importDXMT(from source: URL, version: String? = nil, origin: String? = nil) throws -> GraphicsComponent {
        let (root, cleanup) = try materialize(source)
        defer { cleanup() }

        // Case 1: a whole Wine engine with DXMT inside (e.g. a Porting Kit DXMT wrapper).
        if let wineRoot = RuntimeManager.findWineRoot(in: root),
           FileManager.default.fileExists(atPath: wineRoot.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so").path) {
            let info = RuntimeManager.inspect(wineRoot: wineRoot)
            let detected = info.bundled.first { $0.kind == .dxmt }?.version
            var component = GraphicsComponent(kind: .dxmt, version: version ?? detected ?? "bundled", origin: origin ?? source.path,
                                              has32Bit: false)
            component.sourceWineVersion = info.version
            let lib = wineRoot.appendingPathComponent("lib/wine")
            try prepare(component)
            let names = ["d3d11", "dxgi", "d3d10core", "winemetal", "nvapi64", "nvngx"]
            for arch in ["x86_64-windows", "i386-windows"] {
                for name in names {
                    let file = lib.appendingPathComponent("\(arch)/\(name).dll")
                    guard FileManager.default.fileExists(atPath: file.path) else { continue }
                    if name != "winemetal" && name != "nvngx" && name != "nvapi64" && !FileOps.fileContains(file, token: "dxmt") { continue }
                    try FileOps.cloneItem(at: file, to: component.libDirectory.appendingPathComponent("wine/\(arch)/\(name).dll"))
                }
            }
            try FileOps.cloneItem(at: lib.appendingPathComponent("x86_64-unix/winemetal.so"),
                                  to: component.libDirectory.appendingPathComponent("wine/x86_64-unix/winemetal.so"))
            return try finish(component)
        }

        // Case 2: the release archive layout (x86_64-windows / x86_64-unix / i386-windows folders).
        guard let windows = FileOps.find(where: { $0.lastPathComponent == "x86_64-windows" }, in: root, maxDepth: 5),
              let unix = FileOps.find(where: { $0.lastPathComponent == "x86_64-unix" }, in: root, maxDepth: 5) else {
            throw ComponentError.layoutNotFound("This doesn't look like a DXMT release (x86_64-windows and x86_64-unix folders are missing).")
        }
        let i386 = FileOps.find(where: { $0.lastPathComponent == "i386-windows" }, in: root, maxDepth: 5)
        let guessed = version ?? source.lastPathComponent.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression)
            .map { String(source.lastPathComponent[$0]) } ?? "custom"
        let component = GraphicsComponent(kind: .dxmt, version: guessed, origin: origin ?? source.path, has32Bit: i386 != nil)
        try prepare(component)
        try FileOps.overlay(windows, onto: component.libDirectory.appendingPathComponent("wine/x86_64-windows"))
        try FileOps.overlay(unix, onto: component.libDirectory.appendingPathComponent("wine/x86_64-unix"))
        if let i386 { try FileOps.overlay(i386, onto: component.libDirectory.appendingPathComponent("wine/i386-windows")) }
        return try finish(component)
    }

    // MARK: D3DMetal

    /// Accepts Apple's Game Porting Toolkit disk image, its mounted folder, or a Wine engine/wrapper that contains D3DMetal.
    @discardableResult
    public func importD3DMetal(from source: URL) throws -> GraphicsComponent {
        var mountPoint: URL?
        var searchRoot = source
        if source.pathExtension.lowercased() == "dmg" {
            mountPoint = try FileOps.attachDiskImage(source)
            searchRoot = mountPoint!
        }
        defer { if let mountPoint { FileOps.detachDiskImage(mountPoint) } }

        let isLibRoot: (URL) -> Bool = { url in
            url.lastPathComponent == "lib" && FileOps.isDirectory(url.appendingPathComponent("external/D3DMetal.framework"))
        }
        let libRoot: URL
        if isLibRoot(searchRoot) {
            libRoot = searchRoot
        } else if let wineRoot = RuntimeManager.findWineRoot(in: searchRoot), isLibRoot(wineRoot.appendingPathComponent("lib")) {
            libRoot = wineRoot.appendingPathComponent("lib")
        } else if let found = FileOps.find(where: isLibRoot, in: searchRoot, maxDepth: 6) {
            libRoot = found
        } else {
            throw ComponentError.layoutNotFound("D3DMetal.framework was not found. Choose Apple's Game Porting Toolkit disk image, its redist folder, or a Wine engine that already contains D3DMetal.")
        }

        let framework = libRoot.appendingPathComponent("external/D3DMetal.framework")
        let version = RuntimeManager.frameworkVersion(framework) ?? "imported"
        let component = GraphicsComponent(kind: .d3dmetal, version: version, origin: source.path, has32Bit: false)
        try prepare(component)
        let fm = FileManager.default

        // external/: D3DMetal.framework + libd3dshared.dylib
        try FileOps.overlay(libRoot.appendingPathComponent("external"), onto: component.libDirectory.appendingPathComponent("external"))

        // wine/x86_64-unix/*.so that belong to D3DMetal (symlinks into ../../external, or GPTK's own redist files).
        let unixDir = libRoot.appendingPathComponent("wine/x86_64-unix")
        let windowsDir = libRoot.appendingPathComponent("wine/x86_64-windows")
        let isFullEngine = fm.fileExists(atPath: unixDir.appendingPathComponent("ntdll.so").path)
        var ownedNames: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: unixDir.path)) ?? [] where name.hasSuffix(".so") {
            let file = unixDir.appendingPathComponent(name)
            if isFullEngine {
                guard let link = try? fm.destinationOfSymbolicLink(atPath: file.path), link.contains("external") else { continue }
            }
            let target = component.libDirectory.appendingPathComponent("wine/x86_64-unix/\(name)")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let link = try? fm.destinationOfSymbolicLink(atPath: file.path) {
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else {
                try FileOps.cloneItem(at: file, to: target)
            }
            ownedNames.append(String(name.dropLast(3)))
        }
        // Matching PE DLLs (d3d11, d3d12, dxgi, atidxx64, …).
        let extraPE = ["d3d12core"]
        for name in Set(ownedNames + (isFullEngine ? [] : extraPE)) {
            let dll = windowsDir.appendingPathComponent("\(name).dll")
            guard fm.fileExists(atPath: dll.path) else { continue }
            try FileOps.cloneItem(at: dll, to: component.libDirectory.appendingPathComponent("wine/x86_64-windows/\(name).dll"))
        }
        if !isFullEngine {
            for name in (try? fm.contentsOfDirectory(atPath: windowsDir.path)) ?? [] where name.hasSuffix(".dll") {
                let target = component.libDirectory.appendingPathComponent("wine/x86_64-windows/\(name)")
                if !fm.fileExists(atPath: target.path) { try FileOps.cloneItem(at: windowsDir.appendingPathComponent(name), to: target) }
            }
        }
        guard !ownedNames.isEmpty else {
            try? fm.removeItem(at: component.directory)
            throw ComponentError.layoutNotFound("Found D3DMetal.framework but not the Wine DLLs that use it.")
        }
        return try finish(component)
    }

    // MARK: DXVK

    /// Accepts a DXVK (or DXVK-macOS) release archive or folder with x64/x32 DLLs.
    @discardableResult
    public func importDXVK(from source: URL, version: String? = nil, origin: String? = nil) throws -> GraphicsComponent {
        let (root, cleanup) = try materialize(source)
        defer { cleanup() }
        guard let x64 = FileOps.find(where: { $0.lastPathComponent == "x64" && FileOps.isDirectory($0) }, in: root, maxDepth: 4) else {
            throw ComponentError.layoutNotFound("No x64 folder with DXVK DLLs was found.")
        }
        let x32 = FileOps.find(where: { $0.lastPathComponent == "x32" && FileOps.isDirectory($0) }, in: root, maxDepth: 4)
        let guessed = version ?? source.lastPathComponent.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression)
            .map { String(source.lastPathComponent[$0]) } ?? "custom"
        let component = GraphicsComponent(kind: .dxvk, version: guessed, origin: origin ?? source.path, has32Bit: x32 != nil)
        try prepare(component)
        try FileOps.overlay(x64, onto: component.nativeDirectory.appendingPathComponent("x64"))
        if let x32 { try FileOps.overlay(x32, onto: component.nativeDirectory.appendingPathComponent("x32")) }
        return try finish(component)
    }

    // MARK: Suggestions

    /// D3DMetal copies already on this Mac (wrappers, Wineskin engines, mounted GPTK images).
    public func d3dMetalSources() -> [ImportSuggestion] {
        var result = RuntimeManager.importSuggestions().filter { $0.containsD3DMetal && $0.url.pathExtension == "app" }
        let volumes = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        for volume in volumes where volume.lowercased().contains("game porting") || volume.lowercased().contains("evaluation environment") {
            let url = URL(fileURLWithPath: "/Volumes").appendingPathComponent(volume)
            result.append(ImportSuggestion(url: url, title: volume, detail: "Mounted Game Porting Toolkit", containsD3DMetal: true, containsDXMT: false))
        }
        return result
    }

    // MARK: Helpers

    private func materialize(_ source: URL) throws -> (URL, () -> Void) {
        if FileOps.isDirectory(source) { return (source, {}) }
        let scratch = try CellPaths.makeScratchDirectory(prefix: "component")
        try FileOps.extractArchive(source, to: scratch)
        return (scratch, { try? FileManager.default.removeItem(at: scratch) })
    }

    private func prepare(_ component: GraphicsComponent) throws {
        try CellPaths.ensureDirectories()
        try? FileManager.default.removeItem(at: component.directory)
        try FileManager.default.createDirectory(at: component.directory, withIntermediateDirectories: true)
    }

    private func finish(_ component: GraphicsComponent) throws -> GraphicsComponent {
        try JSONStore.save(component, to: component.metadataURL)
        reload()
        return component
    }
}
