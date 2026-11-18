import Foundation

/// Installers that can't work in Wine, and ones Cell runs differently so they work.
public enum KnownInstallers {
    public enum Verdict: Equatable, Sendable {
        /// Run it as it is.
        case normal
        /// It can't work in Wine: say why instead of running it (and waiting forever).
        case unsupported(title: String, explanation: String)
    }

    /// What an installer needs in the layer before it runs. Installers that fetch these themselves often give up:
    /// the new Epic Games Launcher setup allows two minutes per file over a single connection, which Microsoft's
    /// servers don't always manage. Cell fetches them with its own downloader first, so the installer finds
    /// everything in place and only has to install.
    public enum Prerequisite: Hashable, Sendable { case webView2, visualCpp }

    /// Epic's classic launcher as a Windows Installer package (what Lutris, Heroic and CrossOver use). The layer's
    /// Settings offer it; an Epic installer you bring yourself (also the new launcher's) runs as it is.
    public static let epicLauncherMSI = URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!

    public static func isEpicGamesLauncherSetup(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("epicgameslaunchersetup") || (name.hasPrefix("epicinstaller") && url.pathExtension.lowercased() == "exe")
    }

    /// Reads the installer (can take a second for a large one: call it off the main thread).
    public static func prerequisites(for url: URL) -> Set<Prerequisite> {
        guard url.pathExtension.lowercased() == "exe" else { return [] }
        var result: Set<Prerequisite> = []
        if isEpicGamesLauncherSetup(url) { result = [.webView2, .visualCpp] }
        if !result.contains(.webView2), WebView2.isUsed(by: url) { result.insert(.webView2) }
        return result
    }

    static let microsoftStore = "It installs from the Microsoft Store (MSIX packages and Gaming Services), which Windows has and Wine doesn't, so it can't run in Cell. Games bought on Steam, Epic or GOG run instead; Xbox and PC Game Pass games can't."

    public static func verdict(for url: URL) -> Verdict {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        if ["msix", "msixbundle", "appx", "appxbundle", "appinstaller"].contains(ext) {
            return .unsupported(title: "Microsoft Store apps can't run in Cell", explanation: "“\(url.lastPathComponent)” is a Microsoft Store package. " + microsoftStore)
        }
        if name.hasPrefix("xboxinstaller") || name.contains("gamingservices") || name.hasPrefix("xboxapp") {
            return .unsupported(title: "The Xbox app can't run in Cell", explanation: "The Xbox app installer " + microsoftStore.prefix(1).lowercased() + microsoftStore.dropFirst())
        }
        // .NET installers that deploy MSIX packages through Windows' package manager.
        if ext == "exe", FileOps.fileContains(url, token: "Windows.Management.Deployment", includeUTF16: true),
           FileOps.fileContains(url, token: "PackageManager", includeUTF16: true), FileOps.fileContains(url, token: "AddPackageAsync", includeUTF16: true) {
            return .unsupported(title: "This installer needs the Microsoft Store", explanation: "“\(url.lastPathComponent)” " + microsoftStore.prefix(1).lowercased() + microsoftStore.dropFirst())
        }
        return .normal
    }
}
