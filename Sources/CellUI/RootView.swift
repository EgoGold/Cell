import SwiftUI
import CellCore

public struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isDropTargeted = false

    public init(model: AppModel) {
        self.model = model
    }

    /// Lets Cell open a main window later, when none is left (Dock icon, menu bar icon, opening Cell again).
    private func rememberWindowOpener() {
        guard model.openMainWindow == nil else { return }
        let open = openWindow
        model.openMainWindow = { open(id: "main") }
    }

    public var body: some View {
        let _ = rememberWindowOpener()
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: Theme.sidebarWidth, max: 320)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) { ToastView(model: model) }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .overlay(Text("Drop .exe, .msi or .cell").font(.title3.weight(.semibold))
                        .padding(14).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let target: Container? = {
                if case .container(let id) = model.selection { return model.container(id) }
                return nil
            }()
            model.open(urls, into: target)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(isPresented: $model.showNewContainer) { NewContainerSheet(model: model) }
        .sheet(isPresented: $model.showNewVirtualMachine) { NewVirtualMachineSheet(model: model) }
        .confirmationDialog("Delete “\(model.pendingDeletion?.name ?? "")”?",
                            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
                            presenting: model.pendingDeletion) { container in
            Button("Delete Container and Everything in It", role: .destructive) { model.delete(container) }
        } message: { _ in
            Text("All programs, games and saves inside this container are deleted permanently. This can't be undone.")
        }
        .confirmationDialog("Uninstall “\(model.pendingUninstall?.name ?? "")”?",
                            isPresented: Binding(get: { model.pendingUninstall != nil }, set: { if !$0 { model.pendingUninstall = nil } }),
                            presenting: model.pendingUninstall) { app in
            Button("Uninstall", role: .destructive) { model.uninstall(app) }
        } message: { app in
            Text(model.uninstallPlan(for: app).explanation)
        }
        .confirmationDialog("“\(model.dotNetSuggestion?.name ?? "")” needs Microsoft's .NET Framework",
                            isPresented: Binding(get: { model.dotNetSuggestion != nil }, set: { if !$0 { model.dotNetSuggestion = nil } }),
                            presenting: model.dotNetSuggestion) { app in
            Button("Install .NET Framework 4.8 and Start Again") {
                if let container = model.container(app.containerID) { model.installDotNet(in: container, thenStart: app) }
            }
        } message: { _ in
            Text("Wine's built-in .NET (Wine Mono) lacks something this program uses. Microsoft's .NET Framework 4.8 replaces it in this translation layer (download about 110 MB, a few minutes to install).")
        }
        .alert(item: $model.errorMessage) { error in
            Alert(title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .task { model.bootstrap() }
        .frame(minWidth: 940, minHeight: 600)
        .background(SnapshotWindowHider())
    }

    @ViewBuilder private var detail: some View {
        switch model.selection ?? .home {
        case .home:
            LibraryView(model: model, title: "Home", apps: model.visibleApps)
        case .running:
            RunningView(model: model)
        case .virtualMachine(let id):
            if let machine = model.virtualMachine(id) {
                VirtualMachineDetailView(model: model, machine: machine).id(machine.id)
            } else {
                EmptyStateView(title: "Virtual machine not found", systemImage: "desktopcomputer", message: "It may have been moved to the Trash.")
            }
        case .settings:
            SettingsPage(model: model)
        case .container(let id):
            if let container = model.container(id) {
                ContainerView(model: model, container: container)
                    .id(container.id)
            } else {
                EmptyStateView(title: "Container not found", systemImage: "shippingbox", message: "It may have been deleted.")
            }
        case .engines:
            EnginesView(model: model)
        case .downloads:
            DownloadsView(model: model)
        case .setup:
            SetupView(model: model)
        case .plugins:
            PluginsView(model: model)
        case .network:
            NetworkView(model: model)
        }
    }
}

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            if model.setupNeeded || model.setupRunning || model.selection == .setup {
                Section {
                    Label(model.setupRunning ? "Setting Up…" : "Set Up Cell", systemImage: "wand.and.stars")
                        .badge(model.setupNeeded ? 1 : 0)
                        .tag(SidebarItem.setup)
                }
            }
            Section {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Usage", systemImage: "chart.bar.xaxis")
                    .badge(model.runningCount)
                    .tag(SidebarItem.running)
            }
            Section("Translation Layer") {
                ForEach(model.visibleContainers) { container in
                    ContainerSidebarRow(model: model, container: container)
                        .tag(SidebarItem.container(container.id))
                }
                Button {
                    model.showNewContainer = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Section {
                ForEach(model.virtualMachines) { machine in
                    Label {
                        HStack {
                            Text(machine.name).lineLimit(1)
                            Spacer()
                            if model.isRunning(machine) { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green) }
                        }
                    } icon: {
                        Image(systemName: machine.guest.symbol)
                    }
                    .tag(SidebarItem.virtualMachine(machine.id))
                }
                Button {
                    model.showNewVirtualMachine = true
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) {
                    Text("Virtual System")
                    ExperimentalBadge()
                }
            }
            Section("Manage") {
                Label("Engine", systemImage: "cpu")
                    .badge(model.hasEngine ? 0 : 1)
                    .tag(SidebarItem.engines)
                Label("Download", systemImage: "arrow.down.circle")
                    .badge(model.activeDownloadCount)
                    .tag(SidebarItem.downloads)
                Label("Plugin", systemImage: "puzzlepiece.extension").tag(SidebarItem.plugins)
                Label("Network", systemImage: "network").tag(SidebarItem.network)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { ActivityFooter(model: model) }
    }
}

struct ContainerSidebarRow: View {
    let model: AppModel
    let container: Container

    var body: some View {
        Label {
            HStack {
                Text(container.name).lineLimit(1)
                if container.isDefault { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                Spacer()
                let count = model.apps(in: container).count
                if count > 0 { Text("\(count)").font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: "shippingbox")
        }
        .contextMenu {
            if container.platform == .windows {
                Button("Open C: Drive") { model.openDriveC(container) }
                Button("Look for New Apps") { model.rescan(container) }
                Button("Stop Everything") { model.stopAll(container) }
                if !container.isDefault { Button("Make Default") { model.makeDefault(container) } }
            }
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDeletion = container }
        }
    }
}

/// Background work at the bottom of the sidebar.
struct ActivityFooter: View {
    let model: AppModel

    var body: some View {
        if !model.activities.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.activities) { activity in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if activity.failure != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            } else if activity.finished {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                ProgressView().controlSize(.mini)
                            }
                            Text(activity.title).font(.caption.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            if let stop = activity.stop, !activity.finished {
                                Button(action: stop) { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Stop")
                            }
                        }
                        if !activity.detail.isEmpty && !activity.finished {
                            Text(activity.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let progress = activity.progress, !activity.finished {
                            ProgressView(value: progress).controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(10)
        }
    }
}

struct ToastView: View {
    let model: AppModel

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8, y: 3)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct NewContainerSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var platform: PlatformKind = .windows
    @State private var runtimeID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Translation Layer").font(.title2.weight(.semibold))
            Text("A translation layer runs apps made for another system directly on your Mac, with no emulator. Most people only need the default Windows layer: it picks the right graphics engine for every game automatically. Make another one to keep an app completely separate.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name, prompt: Text("My Games"))
                Picker("Runs", selection: $platform) {
                    Text("Windows apps").tag(PlatformKind.windows)
                    Text("Linux apps (coming later)").tag(PlatformKind.linux).disabled(true)
                }
                if platform == .windows {
                    Picker("Wine engine", selection: $runtimeID) {
                        Text("Recommended").tag(String?.none)
                        ForEach(model.runtimes) { runtime in Text(runtime.name).tag(Optional(runtime.id)) }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let fallback = "Container \(model.containers.count + 1)"
                    model.createContainer(name: name.isEmpty ? fallback : name, platform: platform, runtimeID: runtimeID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(platform == .linux)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
/// A small "Experimental" label.
struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .textCase(nil)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .foregroundStyle(.orange)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}
