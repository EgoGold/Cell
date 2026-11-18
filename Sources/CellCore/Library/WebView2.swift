import Foundation

/// Microsoft Edge WebView2: the web view inside many newer Windows programs (everything built with Tauri, the
/// new Epic Games Launcher, parts of Office, many launchers and tools).
///
/// What it takes to work under Wine on a Mac:
/// - **The last build made for Windows 7 (109).** Newer builds only present through DirectComposition, which Wine
///   doesn't have. Microsoft's own installer hands out 109 when it and its updater see Windows 7, so those two
///   programs are told they run on Windows 7 (a per-program setting; the layer stays on Windows 10).
/// - **`msedgewebview2.exe` sees Windows 7 too**, so it draws with plain window painting.
/// - **It draws its own window.** WebView2 puts the page in a window that belongs to its own process, inside the
///   app's window. The Mac driver can't show a window of one process inside another's, so Cell's bridge
///   (WebViewBridge) lifts that window out and keeps it exactly over the place it belongs.
public enum WebView2 {
    /// Programs that must see Windows 7: the runtime, its updater and its installer.
    static let programs = ["msedgewebview2.exe", "MicrosoftEdgeUpdate.exe", "MicrosoftEdgeWebview2Setup.exe"]

    /// Microsoft's small installer (it fetches the build that fits the Windows version it sees).
    public static let bootstrapperURL = URL(string: "https://go.microsoft.com/fwlink/p/?LinkId=2124703")!

    /// The build that works under Wine.
    public static let workingMajorVersion = 109

    /// Chromium switches for every WebView2 in Cell: draw in the browser process itself, without the GPU process
    /// (a separate process can't draw into another one's window on a Mac).
    public static let browserArguments = "--in-process-gpu --disable-gpu"

    static func applicationFolder(in container: Container) -> URL {
        container.driveC.appendingPathComponent("Program Files (x86)/Microsoft/EdgeWebView/Application")
    }

    /// The WebView2 runtime version installed in the layer ("109.0.1518.140"), if any.
    public static func installedVersion(in container: Container) -> String? {
        let folder = applicationFolder(in: container)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { name in
            name.first?.isNumber == true
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(name)/msedgewebview2.exe").path)
        }
        return versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Whether the layer has the build that works (109).
    public static func isReady(in container: Container) -> Bool {
        guard let version = installedVersion(in: container) else { return false }
        return Int(version.split(separator: ".").first ?? "") == workingMajorVersion
    }

    /// Whether a program (or its installer) uses WebView2: it carries Microsoft's loader or names the runtime.
    public static func isUsed(by executable: URL) -> Bool {
        let folder = executable.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("WebView2Loader.dll").path) { return true }
        // Read at most the first 400 MB; the markers sit in the program's own code, not in what it carries.
        return ["EmbeddedBrowserWebView", "MicrosoftEdgeWebview2Setup", "WebView2Loader"].contains {
            FileOps.fileContains(executable, token: $0, limit: 400 * 1024 * 1024, includeUTF16: true)
        }
    }

    /// The per-program Windows version settings (part of every layer's registry settings).
    static var registryEdits: [RegistryEdit] {
        programs.map { .set(.currentUser, "Software\\Wine\\AppDefaults\\\($0)", "Version", .string("win7")) }
    }

    /// Whether the Visual C++ runtime of one architecture is installed (what installers look at).
    static func hasVisualCpp(_ architecture: String, in container: Container) -> Bool {
        guard let hive = try? WineRegistryHive.load(container.prefixURL.appendingPathComponent("system.reg"), rootName: "HKEY_LOCAL_MACHINE") else { return false }
        let keys = ["Software\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\\(architecture)",
                    "Software\\Wow6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\\(architecture)"]
        return keys.contains { hive.value($0, "Installed")?.contains("(1)") == true }
    }
}
