import Foundation

public enum ComponentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dmetal, dxmt, dxvk
    public var id: String { rawValue }
    public var backend: GraphicsBackend {
        switch self {
        case .d3dmetal: return .d3dmetal
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        }
    }
    public var displayName: String { backend.displayName }
}

public enum RuntimeOrigin: String, Codable, Sendable {
    case catalog, imported
}

/// A graphics translation layer that already ships inside a Wine engine.
public struct BundledComponent: Codable, Hashable, Sendable {
    public var kind: ComponentKind
    public var version: String?
    public init(kind: ComponentKind, version: String?) {
        self.kind = kind
        self.version = version
    }
}

/// A Wine engine (downloaded or imported).
public struct WineRuntime: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// A short name for headers: "Metal", "DXMT", "Wine Staging" (no version or build details).
    public var shortName: String { Self.shortName(for: name) }

    public static func shortName(for name: String) -> String {
        var short = String(name.split(separator: "(").first ?? Substring(name)).trimmingCharacters(in: .whitespaces)
        short = short.replacingOccurrences(of: #"(?i)\s+engine$"#, with: "", options: .regularExpression)
        short = short.replacingOccurrences(of: #"\s+v?\d+(\.\d+)*$"#, with: "", options: .regularExpression)
        return short.isEmpty ? name : short
    }
    public var version: String
    public var origin: RuntimeOrigin
    public var originDescription: String
    public var installedAt: Date
    /// What the engine's own `d3d11.dll` is (WineD3D, or a translator someone already installed).
    public var baseBackend: GraphicsBackend
    public var bundledComponents: [BundledComponent]
    /// Extra dylib / framework folders, relative to the runtime directory (Wineskin `Frameworks`).
    public var extraLibraryPaths: [String]
    public var extraFrameworkPaths: [String]
    /// nil = unknown (assume it might work, rank lower).
    public var supportsD3DMetal: Bool?
    public var supportsDXMT: Bool?
    public var hasMono: Bool
    public var hasGecko: Bool
    /// Relative path of the Wine loader inside `wine/`, e.g. `bin/wine` or `bin/wine64`.
    public var loaderRelativePath: String

    public init(id: String, name: String, version: String, origin: RuntimeOrigin, originDescription: String) {
        self.id = id
        self.name = name
        self.version = version
        self.origin = origin
        self.originDescription = originDescription
        self.installedAt = Date()
        self.baseBackend = .wined3d
        self.bundledComponents = []
        self.extraLibraryPaths = []
        self.extraFrameworkPaths = []
        self.hasMono = false
        self.hasGecko = false
        self.loaderRelativePath = "bin/wine"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: id)
        version = c.value(.version, default: "")
        origin = c.value(.origin, default: .imported)
        originDescription = c.value(.originDescription, default: "")
        installedAt = c.value(.installedAt, default: Date())
        baseBackend = c.value(.baseBackend, default: .wined3d)
        bundledComponents = c.value(.bundledComponents, default: [])
        extraLibraryPaths = c.value(.extraLibraryPaths, default: [])
        extraFrameworkPaths = c.value(.extraFrameworkPaths, default: [])
        supportsD3DMetal = c.value(.supportsD3DMetal, default: nil)
        supportsDXMT = c.value(.supportsDXMT, default: nil)
        hasMono = c.value(.hasMono, default: false)
        hasGecko = c.value(.hasGecko, default: false)
        loaderRelativePath = c.value(.loaderRelativePath, default: "bin/wine")
    }

    public var directory: URL { CellPaths.runtimes.appendingPathComponent(id, isDirectory: true) }
    public var wineRoot: URL { directory.appendingPathComponent("wine", isDirectory: true) }
    public var flavorsDirectory: URL { directory.appendingPathComponent("flavors", isDirectory: true) }
    public var metadataURL: URL { directory.appendingPathComponent("runtime.json") }

    public func bundled(_ kind: ComponentKind) -> BundledComponent? { bundledComponents.first { $0.kind == kind } }

    /// CrossOver-based engines (Sikarugir, GPTK builds) can run D3DMetal.
    public var isCrossOverBased: Bool { supportsD3DMetal == true || bundled(.d3dmetal) != nil }

    var sikarugir10Revision: Int? {
        guard LooseVersion(version) == LooseVersion("10.0") else { return nil }
        let identity = "\(id) \(name)".lowercased()
        guard identity.contains("sikarugir"),
              let range = identity.range(of: #"(?<=revision[ -])\d+"#, options: .regularExpression) else { return nil }
        return Int(identity[range])
    }

    func fixesSikarugirFocusCompared(to previous: WineRuntime) -> Bool {
        guard let old = previous.sikarugir10Revision, old < 7 else { return false }
        return (sikarugir10Revision ?? 0) >= 7
    }

    var canReplayMacFocus: Bool {
        LooseVersion(version) >= LooseVersion("10.6") || (sikarugir10Revision ?? 0) >= 7
    }

    public func matches(family: String) -> Bool {
        switch family {
        case "crossover": return isCrossOverBased
        case "upstream": return !isCrossOverBased
        case "bundled-dxmt": return baseBackend == .dxmt
        default: return true
        }
    }
}

/// A translation layer installed by Cell, stored in Wine `lib/` layout so it can be overlaid.
extension GraphicsComponent {
    /// DXMT's builtin DLLs talk to Wine's Unix side through an interface that changes between Wine
    /// generations, so each DXMT release works with one: CrossOver 25 paired DXMT with Wine 10,
    /// CrossOver 26 paired 0.72 with Wine 11. Measured here: DXMT 0.80 on a Wine 10 engine crashes PEAK
    /// right after it creates its Direct3D 11 device; on Wine 11 it runs.
    public var minimumWineVersion: String? {
        guard kind == .dxmt else { return nil }
        if version == "bundled" {
            // Copied out of an engine: it belongs to that engine's Wine generation (PK's DXMT came with Wine 11).
            guard let source = sourceWineVersion, LooseVersion(source) >= LooseVersion("11") else { return nil }
            return "11.0"
        }
        guard LooseVersion(version) >= LooseVersion("0.70") else { return nil }
        return "11.0"
    }

    /// `for32Bit`: for a 32-bit program. Those have no other Metal path on an engine that comes with D3DMetal (it runs
    /// 64-bit programs only), and the crash that set the Wine-generation rule was a 64-bit game's (PEAK); Beholder and
    /// Beholder 2 run with DXMT 0.80 on Wine 10.
    public func isCompatible(with runtime: WineRuntime, for32Bit: Bool = false) -> Bool {
        if kind == .dxmt && version == "bundled" {
            guard let sourceWineVersion, let sourceMajor = LooseVersion(sourceWineVersion).components.first,
                  let targetMajor = LooseVersion(runtime.version).components.first else { return false }
            return sourceMajor == targetMajor
        }
        guard let minimum = minimumWineVersion else { return true }
        if for32Bit && has32Bit { return true }
        return LooseVersion(runtime.version) >= LooseVersion(minimum)
    }
}

public struct GraphicsComponent: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ComponentKind
    public var version: String
    public var installedAt: Date
    public var origin: String
    public var has32Bit: Bool
    /// Durable provenance: installation paths may move or disappear.
    public var sourceWineVersion: String?
    public var sourceRuntimeID: String?

    public init(kind: ComponentKind, version: String, origin: String, has32Bit: Bool) {
        let safeVersion = version.replacingOccurrences(of: "/", with: "-")
        self.id = "\(kind.rawValue)-\(safeVersion)"
        self.kind = kind
        self.version = version
        self.installedAt = Date()
        self.origin = origin
        self.has32Bit = has32Bit
        let metadata = URL(fileURLWithPath: origin).deletingLastPathComponent().appendingPathComponent("runtime.json")
        self.sourceWineVersion = ComponentSourceVersions.version(of: metadata)
        self.sourceRuntimeID = nil
    }

    public var directory: URL { CellPaths.components.appendingPathComponent(id, isDirectory: true) }
    /// Files in Wine-lib layout: `lib/wine/x86_64-windows`, `lib/wine/x86_64-unix`, `lib/external`, …
    public var libDirectory: URL { directory.appendingPathComponent("lib", isDirectory: true) }
    /// DXVK only: native DLLs (`x64`, `x32`).
    public var nativeDirectory: URL { directory.appendingPathComponent("native", isDirectory: true) }
    public var metadataURL: URL { directory.appendingPathComponent("component.json") }
}

/// Something Cell can download for the user.
public struct CatalogEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case wine, dxmt, dxvk }
    public var id: String
    public var kind: Kind
    public var name: String
    public var version: String
    public var url: URL
    public var sizeBytes: Int64?
    public var sha256: String?
    public var notes: String
    public var supportsD3DMetal: Bool?
    public var supportsDXMT: Bool?
    public var recommended: Bool
}

/// App-wide preferences.
public struct CellSettings: Codable, Hashable, Sendable {
    public var shortcutDestination: ShortcutDestination = .applications
    public var customShortcutFolder: String?
    public var autoFallback: Bool = true
    public var defaultContainerID: UUID?
    public var confirmBeforeSteamRestart: Bool = false
    public var showHiddenApps: Bool = false
    /// The order of the cards on Home, arranged by dragging (apps not listed follow alphabetically).
    public var homeOrder: [UUID] = []
    /// Connections per download (1–32).
    public var downloadConnections: Int = 16
    /// Downloads add connections (up to 32) while that makes them faster; off = exactly `downloadConnections`.
    public var automaticDownloadConnections: Bool = true
    /// A download that loses its connection carries on by itself.
    public var reconnectDownloads: Bool = true
    /// Also download from verified mirrors (GitHub download proxies, all of Valve's CDNs).
    public var useDownloadMirrors: Bool = true
    /// Set when the automatic first-run setup finished.
    public var setupCompleted: Bool = false
    /// Engine new containers use; nil = Cell decides.
    public var defaultRuntimeID: String?
    /// Which round of crash records is current (older records are forgotten once, see CellServices.forgetStaleCrashes).
    public var crashRecordsRevision: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CellSettings()
        shortcutDestination = c.value(.shortcutDestination, default: d.shortcutDestination)
        customShortcutFolder = c.value(.customShortcutFolder, default: d.customShortcutFolder)
        autoFallback = c.value(.autoFallback, default: d.autoFallback)
        defaultContainerID = c.value(.defaultContainerID, default: d.defaultContainerID)
        confirmBeforeSteamRestart = c.value(.confirmBeforeSteamRestart, default: d.confirmBeforeSteamRestart)
        showHiddenApps = c.value(.showHiddenApps, default: d.showHiddenApps)
        homeOrder = c.value(.homeOrder, default: d.homeOrder)
        downloadConnections = min(max(c.value(.downloadConnections, default: d.downloadConnections), 1), 32)
        automaticDownloadConnections = c.value(.automaticDownloadConnections, default: d.automaticDownloadConnections)
        reconnectDownloads = c.value(.reconnectDownloads, default: d.reconnectDownloads)
        useDownloadMirrors = c.value(.useDownloadMirrors, default: d.useDownloadMirrors)
        setupCompleted = c.value(.setupCompleted, default: d.setupCompleted)
        defaultRuntimeID = c.value(.defaultRuntimeID, default: d.defaultRuntimeID)
        crashRecordsRevision = c.value(.crashRecordsRevision, default: d.crashRecordsRevision)
    }

    public static func load() -> CellSettings {
        JSONStore.loadIfPresent(CellSettings.self, from: CellPaths.settingsFile) ?? CellSettings()
    }

    public func save() throws { try JSONStore.save(self, to: CellPaths.settingsFile) }
}

/// Wine versions of engines that components were copied from (read once per file).
enum ComponentSourceVersions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    static func version(of runtimeFile: URL) -> String? {
        if let cached = lock.withLock({ cache[runtimeFile.path] }) { return cached }
        var version: String?
        if let data = try? Data(contentsOf: runtimeFile),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            version = object["version"] as? String
        }
        lock.withLock { cache[runtimeFile.path] = version }
        return version
    }
}
