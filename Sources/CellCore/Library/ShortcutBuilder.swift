import Foundation
import CoreServices

/// Creates real `.app` bundles in /Applications that launch an app directly, without opening Cell.
public enum ShortcutBuilder {
    public static let bundleIdentifierPrefix = "app.cell.shortcut."

    public static func destinationFolder(settings: CellSettings) -> URL {
        let fm = FileManager.default
        switch settings.shortcutDestination {
        case .applications:
            let folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if fm.isWritableFile(atPath: folder.path) { return folder }
            fallthrough
        case .userApplications:
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        case .custom:
            if let custom = settings.customShortcutFolder, !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)
        }
    }

    /// Builds (or rebuilds) the shortcut and returns its location.
    @discardableResult
    public static func createShortcut(for app: AppEntry, container: Container, settings: CellSettings,
                                      cliPath: URL? = CellPaths.cliExecutable()) throws -> URL {
        let fm = FileManager.default
        let folder = destinationFolder(settings: settings)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let existing = app.shortcutPath { removeShortcut(at: existing) }

        var bundle = folder.appendingPathComponent("\(FileOps.sanitizedFileName(app.name)).app", isDirectory: true)
        if fm.fileExists(atPath: bundle.path), !isCellShortcut(bundle) {
            bundle = folder.appendingPathComponent("\(FileOps.sanitizedFileName(app.name)) (Cell).app", isDirectory: true)
        }
        try? fm.removeItem(at: bundle)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Icon: exe icon or Steam artwork on a macOS-style body.
        let icon = app.iconURL.flatMap(IconTools.loadImage)
        let artwork = app.artworkURL.flatMap(IconTools.loadImage)
        if let composed = IconTools.composeAppIcon(icon: icon, artwork: artwork, title: app.name) {
            try? IconTools.writeICNS(composed, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        let info: [String: Any] = [
            "CFBundleName": app.name,
            "CFBundleDisplayName": app.name,
            "CFBundleIdentifier": bundleIdentifierPrefix + app.id.uuidString.lowercased(),
            "CFBundleExecutable": "launch",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleInfoDictionaryVersion": "6.0",
            "LSMinimumSystemVersion": "14.0",
            "LSApplicationCategoryType": app.isGame ? "public.app-category.games" : "public.app-category.utilities",
            // The launcher itself has no UI; the game shows up in the Dock with its own window.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "CellAppID": app.id.uuidString,
            "CellContainerID": container.id.uuidString,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))

        let script = launcherScript(appID: app.id, appName: app.name, cliPath: cliPath?.path)
        let executable = macOS.appendingPathComponent("launch")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
        LSRegisterURL(bundle as CFURL, true)
        return bundle
    }

    static func launcherScript(appID: UUID, appName: String, cliPath: String?) -> String {
        let quotedCLI = (cliPath ?? "/Applications/Cell.app/Contents/Helpers/cell").replacingOccurrences(of: "'", with: "'\\''")
        let safeName = appName.replacingOccurrences(of: "\n", with: " ")
        return """
        #!/bin/sh
        # Created by Cell — launches “\(safeName)”.
        # Delete this app to remove the shortcut; the game stays in Cell.
        CLI='\(quotedCLI)'
        if [ ! -x "$CLI" ]; then
          APP=$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'app.cell.Cell'" 2>/dev/null | /usr/bin/head -n 1)
          CLI="$APP/Contents/Helpers/cell"
        fi
        if [ ! -x "$CLI" ]; then
          /usr/bin/osascript -e 'display alert "Cell is needed to open this app." message "Install Cell, then try again."' >/dev/null 2>&1
          exit 1
        fi
        exec "$CLI" launch --app \(appID.uuidString) --from-shortcut "$@"

        """
    }

    public static func isCellShortcut(_ bundle: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let identifier = info["CFBundleIdentifier"] as? String else { return false }
        return identifier.hasPrefix(bundleIdentifierPrefix)
    }

    public static func removeShortcut(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard isCellShortcut(url) else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
