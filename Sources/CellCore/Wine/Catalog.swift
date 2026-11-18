import Foundation

/// Downloadable engines. Users can always import their own instead.
public enum Catalog {
    public static let entries: [CatalogEntry] = [
        CatalogEntry(
            id: "sikarugir-wine-10.0-revision-8", kind: .wine, name: "Sikarugir Wine", version: "10.0 (revision 8)",
            url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineSikarugir10.0_8.tar.xz")!,
            sizeBytes: 166_321_980, sha256: "2a6bcf2a3bf13cddf825599b6bc1e3659cbf71e1282c6d77141a92f6ac8d4c68",
            notes: "Includes Wine's macOS focus fixes. D3DMetal is a separate graphics component.",
            supportsD3DMetal: true, supportsDXMT: nil, recommended: false),
        CatalogEntry(
            id: "gcenx-wine-staging-11.21", kind: .wine, name: "Wine Staging", version: "11.21",
            url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-staging-11.21-osx64.tar.xz")!,
            sizeBytes: 228_148_688, sha256: "d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452",
            notes: "Gcenx build of Wine Staging for macOS (Rosetta 2). Includes wine-mono, wine-gecko and GStreamer.",
            supportsD3DMetal: nil, supportsDXMT: true, recommended: true),
        CatalogEntry(
            id: "gcenx-wine-devel-11.21", kind: .wine, name: "Wine Devel", version: "11.21",
            url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.21/wine-devel-11.21-osx64.tar.xz")!,
            sizeBytes: 225_612_636, sha256: "9909b486657e10ab66c7279371ae1f990345b596b3b1b3a0cf21f28af24fa0ce",
            notes: "Gcenx build of upstream Wine development release for macOS.",
            supportsD3DMetal: nil, supportsDXMT: true, recommended: false),
        CatalogEntry(
            id: "dxmt-0.80", kind: .dxmt, name: "DXMT", version: "0.80",
            url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!,
            sizeBytes: 18_681_669, sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
            notes: "Direct3D 10/11 to Metal (MIT). Installed as Wine builtin DLLs into an engine flavor.",
            supportsD3DMetal: nil, supportsDXMT: nil, recommended: true),
    ]

    public static var wineEngines: [CatalogEntry] { entries.filter { $0.kind == .wine } }
    public static var graphicsComponents: [CatalogEntry] { entries.filter { $0.kind != .wine } }

    static let sikarugirTemplateURL = URL(string: "https://github.com/Sikarugir-App/Template/releases/download/v1.0/Template-1.0.27.tar.xz")!
    static let sikarugirTemplateSHA256 = "dd0778f7b553d63df9b0f4e2cda3f3c6c005aabb75588c84d604afe80cdedbb9"
    static let sikarugirTemplateSize: Int64 = 96_161_660

    public static let steamInstallerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    public static let vcRedistX64URL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!
    /// Microsoft .NET Framework 4.8 offline installer (the file winetricks uses).
    public static let dotNet48URL = URL(string: "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe")!
    public static let dotNet48SHA256 = "95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
    /// .NET Framework 4.0, installed first: its installer is the one that puts Microsoft's mscoree.dll in place.
    public static let dotNet40URL = URL(string: "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe")!
    public static let dotNet40SHA256 = "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"
    public static let vcRedistX86URL = URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!
    public static let gptkDownloadPage = URL(string: "https://developer.apple.com/games/game-porting-toolkit/")!
}
