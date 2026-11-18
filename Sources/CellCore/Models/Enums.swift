import Foundation

public enum PlatformKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case windows, linux
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }
    public var isAvailable: Bool { self != .linux }
}

/// The Direct3D → Metal translation layer used for a launch.
public enum GraphicsBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case d3dmetal, dxmt, dxvk, wined3d

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .d3dmetal: return "D3DMetal"
        case .dxmt: return "DXMT"
        case .dxvk: return "DXVK"
        case .wined3d: return "WineD3D"
        }
    }

    public var summary: String {
        switch self {
        case .d3dmetal: return "Apple's Direct3D 11/12 to Metal translator (Game Porting Toolkit). Best for DirectX 12."
        case .dxmt: return "Open-source Direct3D 10/11 to Metal translator. Usually the fastest for DirectX 11."
        case .dxvk: return "Direct3D 9-11 to Vulkan, running on Metal through MoltenVK. A compatibility fallback."
        case .wined3d: return "Wine's built-in Direct3D (OpenGL). Best for old DirectX 9 and earlier games."
        }
    }

    /// Supplied as Wine builtin DLL overlays (a "flavor" of the Wine engine).
    public var usesEngineOverlay: Bool { self == .d3dmetal || self == .dxmt }

    public var componentKind: ComponentKind? {
        switch self {
        case .d3dmetal: return .d3dmetal
        case .dxmt: return .dxmt
        case .dxvk: return .dxvk
        case .wined3d: return nil
        }
    }
}

public enum GraphicsAPI: String, Codable, CaseIterable, Comparable, Sendable {
    case ddraw, d3d8, d3d9, d3d10, d3d11, d3d12, opengl, vulkan

    public var displayName: String {
        switch self {
        case .ddraw: return "DirectDraw"
        case .d3d8: return "Direct3D 8"
        case .d3d9: return "Direct3D 9"
        case .d3d10: return "Direct3D 10"
        case .d3d11: return "Direct3D 11"
        case .d3d12: return "Direct3D 12"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        }
    }

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: GraphicsAPI, rhs: GraphicsAPI) -> Bool { lhs.order < rhs.order }

    /// Maps an imported DLL name to an API.
    public static func from(dllName: String) -> GraphicsAPI? {
        switch dllName.lowercased() {
        case "d3d12.dll", "d3d12core.dll": return .d3d12
        case "d3d11.dll", "d3d11on12.dll": return .d3d11
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3dx10_43.dll": return .d3d10
        case "d3d9.dll", "d3dx9_43.dll", "d3dx9_42.dll", "d3dx9_41.dll", "d3dx9_40.dll", "d3dx9_39.dll", "d3dx9_38.dll", "d3dx9_36.dll": return .d3d9
        case "d3d8.dll", "d3dx8.dll": return .d3d8
        case "ddraw.dll": return .ddraw
        case "opengl32.dll": return .opengl
        case "vulkan-1.dll": return .vulkan
        default: return nil
        }
    }
}

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case unity, unreal, godot, gameMaker, source, source2, rpgMaker, renpy, xna, fna, monoGame, electron, cef, java, cryEngine, idTech, unknown

    public var displayName: String {
        switch self {
        case .unity: return "Unity"
        case .unreal: return "Unreal Engine"
        case .godot: return "Godot"
        case .gameMaker: return "GameMaker"
        case .source: return "Source"
        case .source2: return "Source 2"
        case .rpgMaker: return "RPG Maker"
        case .renpy: return "Ren'Py"
        case .xna: return "XNA"
        case .fna: return "FNA"
        case .monoGame: return "MonoGame"
        case .electron: return "Electron"
        case .cef: return "Chromium Embedded"
        case .java: return "Java"
        case .cryEngine: return "CryEngine"
        case .idTech: return "id Tech"
        case .unknown: return "Unknown"
        }
    }
}

public enum PEArchitecture: String, Codable, Sendable {
    case x86, x64, arm64, arm64ec, unknown
    public var displayName: String {
        switch self {
        case .x86: return "32-bit (x86)"
        case .x64: return "64-bit (x64)"
        case .arm64: return "ARM64"
        case .arm64ec: return "ARM64EC"
        case .unknown: return "Unknown"
        }
    }
}

public enum WindowsVersion: String, Codable, CaseIterable, Identifiable, Sendable {
    case win11, win10, win81, win8, win7, winxp
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .win11: return "Windows 11"
        case .win10: return "Windows 10"
        case .win81: return "Windows 8.1"
        case .win8: return "Windows 8"
        case .win7: return "Windows 7"
        case .winxp: return "Windows XP"
        }
    }
}

public enum DPIMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, standard, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Match Mac display"
        case .standard: return "Standard (96 DPI)"
        case .custom: return "Custom"
        }
    }
}

public enum ScrollMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, smooth, notched
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Automatic (English)"
        case .smooth: return "Smooth (trackpad precision)"
        case .notched: return "Notched (like a mouse wheel)"
        }
    }
}

public enum SyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case msync, esync, none
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .msync: return "MSync (fastest)"
        case .esync: return "ESync"
        case .none: return "Off"
        }
    }
}

public enum CursorCaptureMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case confinement, eventTap
    public var id: String { rawValue }
    public var displayName: String {
        self == .confinement ? "Window capture" : "Legacy capture (requires Accessibility)"
    }
}

public enum MouseWarpMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, enable, disable, force
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .enable: return "Enable"
        case .disable: return "Disable"
        case .force: return "Force (fixes some camera controls)"
        }
    }
}

public enum OverlayMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, enabled, disabled
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .enabled: return "On"
        case .disabled: return "Off"
        }
    }
}

public enum SteamRestartPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, never
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .automatic: return "Restart Steam with the right graphics engine"
        case .never: return "Keep Steam running as it is"
        }
    }
}

public enum ContainerLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, english, simplifiedChinese, traditionalChinese, japanese, korean
    case russian, german, french, spanish, portuguese, italian, polish, turkish

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .polish: return "Polski"
        case .turkish: return "Türkçe"
        }
    }

    /// Unix locale handed to Wine (it decides the Windows locale and ANSI code page).
    public var localeIdentifier: String? {
        switch self {
        case .automatic: return nil
        case .english: return "en_US.UTF-8"
        case .simplifiedChinese: return "zh_CN.UTF-8"
        case .traditionalChinese: return "zh_TW.UTF-8"
        case .japanese: return "ja_JP.UTF-8"
        case .korean: return "ko_KR.UTF-8"
        case .russian: return "ru_RU.UTF-8"
        case .german: return "de_DE.UTF-8"
        case .french: return "fr_FR.UTF-8"
        case .spanish: return "es_ES.UTF-8"
        case .portuguese: return "pt_BR.UTF-8"
        case .italian: return "it_IT.UTF-8"
        case .polish: return "pl_PL.UTF-8"
        case .turkish: return "tr_TR.UTF-8"
        }
    }

    public var cjkScript: CJKScript? {
        switch self {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .japanese: return .japanese
        case .korean: return .korean
        default: return nil
        }
    }
}

public enum CJKScript: String, Codable, CaseIterable, Sendable {
    case simplifiedChinese, traditionalChinese, japanese, korean
}

public enum NetworkProtocol: String, Codable, CaseIterable, Sendable {
    case udp, tcp
}

public struct PortMapping: Codable, Hashable, Sendable {
    public var proto: NetworkProtocol
    public var port: UInt16
    public init(proto: NetworkProtocol, port: UInt16) {
        self.proto = proto
        self.port = port
    }
    public var displayName: String { "\(proto.rawValue.uppercased()) \(port)" }
}

public enum ShortcutDestination: String, Codable, CaseIterable, Identifiable, Sendable {
    case applications, userApplications, custom
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .applications: return "Applications folder"
        case .userApplications: return "Applications in your home folder"
        case .custom: return "Custom folder"
        }
    }
}
