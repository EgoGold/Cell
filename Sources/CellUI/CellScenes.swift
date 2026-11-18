import SwiftUI
import AppKit
import CellCore

/// Receives files opened from Finder (double-clicked .exe/.msi, dropped on the Dock icon).
public final class CellAppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.open(urls) }
    }

    /// Design snapshots (`CELL_UI_SNAPSHOT`) render without showing anything: no Dock icon, no activation,
    /// and the window stays transparent (see SnapshotWindowHider).
    public func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["CELL_UI_SNAPSHOT"] != nil { NSApp.setActivationPolicy(.accessory) }
    }

    /// Closing the window quits Cell, unless a game, Steam or a download is still running: then Cell
    /// stays in the menu bar (to quit them or open Steam Friends) and quits by itself once they stop.
    /// Clicking the Dock icon (or opening Cell again) always shows the window, also after it was closed while
    /// a game or download kept Cell running — it used to stay in the Dock with no window.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated { AppModel.shared.showMainWindow() }
        return false
    }

    /// Cell always starts with its window, whatever macOS restored from the last session.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["CELL_UI_SNAPSHOT"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { AppModel.shared.showMainWindow() }
            }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if model.hasBackgroundWork {
                model.quitWhenIdle = true
                return false
            }
            return true
        }
    }
}

/// All of Cell's scenes, used by the @main app.
public struct CellScenes: Scene {
    @State private var model = AppModel.shared

    public init() {}

    /// The designed menu bar icon (Resources/StatusIcon.png), drawn as a template so it matches the menu bar.
    static let statusIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png")
                ?? CellPaths.bundledResource("Resources/StatusIcon.png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 14, height: 14)
        image.isTemplate = true
        return image
    }()

    public var body: some Scene {
        WindowGroup("Cell", id: "main") {
            RootView(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        // The main window opens at every launch, even when macOS restored a session without windows (Cell then sat
        // in the Dock with nothing to click).
        .defaultLaunchBehavior(.presented)
        .commands {
            // Cell's own settings are called Preferences (the menu bar icon has the same item).
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text("Preferences…") }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Translation Layer…") { model.showNewContainer = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Add Program or Installer…") {
                    model.open(Panels.chooseFiles(title: "Choose a Windows program or installer",
                                                  extensions: ["exe", "msi", "lnk"], multiple: true))
                }
                .keyboardShortcut("o")
                Button("Add App Folder…") {
                    model.open(Panels.chooseFiles(title: "Choose the folder of a Windows app or game", allowFolders: true, allowFiles: false, multiple: true))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Library") {
                Button("Look for New Apps") { for container in model.containers { model.rescan(container) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Engines") { model.selection = .engines }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Plugins") { model.selection = .plugins }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Network") { model.selection = .network }.keyboardShortcut("3", modifiers: [.command, .option])
            }
        }

        Settings {
            PreferencesView(model: model)
        }

        // A running virtual machine's display.
        WindowGroup("Virtual Machine", id: "vm", for: UUID.self) { $machineID in
            VirtualMachineWindow(model: model, machineID: machineID)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            if let icon = Self.statusIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "chevron.left.circle.fill")
            }
        }
    }
}

struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        let running = model.apps.filter { model.isRunning($0) }
        let machines = model.virtualMachines.filter { model.isRunning($0) }
        if running.isEmpty && machines.isEmpty {
            Text("Nothing running")
        } else {
            ForEach(running) { app in
                Button("\(model.isStopping(app) ? "Force Quit" : "Quit") \(app.name)") { model.stop(app) }
            }
            ForEach(machines) { machine in
                Button("Shut Down \(machine.name)") { model.shutDown(machine) }
            }
        }
        Divider()
        if let recent = model.recentApps.first {
            Button("Play \(recent.name)") { model.launch(recent) }
        }
        Divider()
        Button("Open Cell") { model.showMainWindow() }
        SettingsLink { Text("Preferences…") }.keyboardShortcut(",")
        Button("Quit Cell") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Cell's settings as a page in the main window (the same settings as Cell ▸ Settings…).
struct SettingsPage: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Settings").font(.largeTitle.weight(.bold))
                GeneralSettingsForm(model: model)
                    .frame(maxWidth: 700)
                Text("Each translation layer has its own settings (display, input, language, Steam) on its page.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Settings")
    }
}

struct PreferencesView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsForm(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }

            VStack(spacing: 10) {
                Image(systemName: "shippingbox.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor)
                Text("Cell").font(.title.weight(.bold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3") preview").foregroundStyle(.secondary)
                Text("Built on Wine, DXMT, D3DMetal (Apple Game Porting Toolkit), DXVK, MoltenVK and Apple's Virtualization framework.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(30)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 380)
    }
}

struct GeneralSettingsForm: View {
    let model: AppModel

    var body: some View {
            Form {
                Picker("Add to Applications puts apps in", selection: Binding(
                    get: { model.settings.shortcutDestination },
                    set: { value in model.updateSettings { $0.shortcutDestination = value } })) {
                    ForEach(ShortcutDestination.allCases) { destination in Text(destination.displayName).tag(destination) }
                }
                if model.settings.shortcutDestination == .custom {
                    HStack {
                        Text(model.settings.customShortcutFolder ?? "Not chosen").foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let url = Panels.chooseFiles(title: "Folder for app shortcuts", allowFolders: true, allowFiles: false).first {
                                model.updateSettings { $0.customShortcutFolder = url.path }
                            }
                        }
                    }
                }
                Toggle("Try another graphics engine when a game crashes on start", isOn: Binding(
                    get: { model.settings.autoFallback },
                    set: { value in model.updateSettings { $0.autoFallback = value } }))
                Toggle("Show hidden apps in the Library", isOn: Binding(
                    get: { model.settings.showHiddenApps },
                    set: { value in model.updateSettings { $0.showHiddenApps = value } }))
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(CellPaths.root) }
                }
            }
            .formStyle(.grouped)
    }
}

