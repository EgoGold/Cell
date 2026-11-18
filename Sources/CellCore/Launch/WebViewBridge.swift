import Foundation

/// Runs Cell's web view bridge (Tools/webview-bridge) beside the Windows programs of a layer, so pages shown by
/// Microsoft Edge WebView2 appear in their app's window (see WebView2 for why they otherwise don't).
public enum WebViewBridge {
    static let fileName = "cell-webview-bridge.exe"
    static var image: Data { Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data() }

    /// Where the bridge lives in a layer.
    static func location(in container: Container) -> URL {
        container.driveC.appendingPathComponent("windows/\(fileName)")
    }

    /// Puts the current bridge in the layer. Returns false if it can't.
    @discardableResult
    static func install(in container: Container) -> Bool {
        let data = image
        guard !data.isEmpty else { return false }
        let url = location(in: container)
        if let existing = try? Data(contentsOf: url), existing == data { return true }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// Starts the bridge with a program's Wine environment. It keeps to itself (one per layer) and quits when the
    /// layer's last program has. Besides WebView2 pages it fits games' windows that are as big as the screen to it
    /// (no title bar hanging under the menu bar; see Tools/webview-bridge).
    public static func start(for plan: LaunchPlan) {
        guard install(in: plan.container) else { return }
        let process = Process()
        process.executableURL = plan.loader
        process.arguments = ["C:\\windows\\\(fileName)"]
        process.environment = plan.environment
        process.currentDirectoryURL = plan.container.driveC
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }
}
