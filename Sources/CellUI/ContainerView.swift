import SwiftUI
import CellCore

struct ContainerView: View {
    let model: AppModel
    let container: Container

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", usage = "Usage", settings = "Settings", plugins = "Plugins"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview
    @State private var sizeText = "…"
    @State private var storageRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .overview: ContainerOverview(model: model, container: container)
                case .usage: ContainerUsageView(model: model, container: container) { storageRevision += 1 }
                case .settings: ContainerSettingsView(model: model, containerID: container.id)
                case .plugins: ContainerPluginsView(model: model, container: container)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(container.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $tab) {
                    ForEach(availableTabs) { tab in Text(label(for: tab)).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { tab = .usage } label: { Text("Disk usage \(sizeText)").monospacedDigit() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open usage and cleanup")
                Button(role: .destructive) {
                    model.pendingDeletion = container
                } label: {
                    Label("Delete Translation Layer", systemImage: "trash")
                }
                .help("Delete this translation layer and everything in it…")
            }
        }
        .task(id: StorageTaskID(container: container.id, revision: storageRevision, apps: model.apps(in: container).count)) {
            let directory = container.directory
            while !Task.isCancelled {
                let size = await Task.detached(priority: .utility) { FileOps.allocatedSize(of: directory) }.value
                guard !Task.isCancelled else { return }
                sizeText = size.byteDescription
                try? await Task.sleep(for: .seconds(90))
            }
        }
        .onAppear(perform: selectRequestedTab)
        .onChange(of: model.requestedContainerTab) { _, _ in selectRequestedTab() }
    }

    private struct StorageTaskID: Hashable {
        let container: UUID
        let revision: Int
        let apps: Int
    }

    private func selectRequestedTab() {
        guard let requested = model.requestedContainerTab else { return }
        if let match = availableTabs.first(where: { $0.rawValue.lowercased() == requested }) { tab = match }
        else if requested == "running" { tab = .usage }
        else if requested == "registry" { tab = .settings }
        model.requestedContainerTab = nil
    }

    private var availableTabs: [Tab] { container.platform == .windows ? Tab.allCases : [.overview, .usage, .settings] }

    private func label(for tab: Tab) -> String {
        guard tab == .usage else { return tab.rawValue }
        let count = model.runningPrograms(in: container).count
        return count > 0 ? "Usage (\(count))" : "Usage"
    }

    private var subtitle: String {
        return model.runtime(for: container)?.shortName ?? "No Wine engine"
    }
}

/// A layer's apps, with its tools as icons. Drop a program or installer anywhere on it to add it here.
struct ContainerOverview: View {
    let model: AppModel
    let container: Container
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                if container.platform == .windows && model.runtime(for: container) == nil {
                    SectionCard("This translation layer needs a Wine engine", systemImage: "exclamationmark.triangle") {
                        Text("Install or import one in Engine; Cell will use it automatically.").foregroundStyle(.secondary)
                        Button("Open Engine") { model.selection = .engines }.buttonStyle(.borderedProminent)
                    }
                } else if container.platform == .windows && !container.isInitialized {
                    SectionCard("Not set up yet", systemImage: "sparkles") {
                        Text("Windows is set up the first time you run something here (about a minute). You can do it now.")
                            .foregroundStyle(.secondary)
                        Button("Set Up Now") { model.setUp(container) }.buttonStyle(.borderedProminent)
                    }
                }
                appsSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, into: container)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(8)
                    .overlay(Text("Drop to install in “\(container.name)”").font(.title3.weight(.semibold))
                        .padding(14).background(.regularMaterial, in: Capsule()))
                    .allowsHitTesting(false)
            }
        }
    }

    private var appsSection: some View {
        let apps = model.apps(in: container)
        let suggestSteam = container.platform == .windows && !container.settings.hideSteamSuggestion
            && !SteamIntegration.isInstalled(in: container) && !apps.contains { $0.kind == .steamClient }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label {
                    Text("Apps").font(.headline)
                } icon: {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
                Spacer()
                if container.platform == .windows { windowsTools }
            }
            if suggestSteam { SteamSuggestionRow(model: model, container: container) }
            ForEach(apps) { app in
                HStack(spacing: 12) {
                    AppIconView(app: app, size: 32)
                    VStack(alignment: .leading) {
                        HStack(spacing: 6) {
                            Text(app.name)
                            if app.isHidden { Badge(text: "Not on Home") }
                        }
                        if let status = model.launchStatus[app.id] {
                            Text(status).font(.caption).foregroundStyle(Color.accentColor)
                        } else if model.isRunning(app) {
                            Label("Running", systemImage: "circle.fill").font(.caption).foregroundStyle(.green)
                        } else if let detail = detail(for: app) {
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Button {
                        model.selection = .home
                        model.libraryPath = NavigationPath([app.id])
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Details")
                    PlayButton(model: model, app: app, compact: true)
                }
                .padding(.vertical, 2)
                .contextMenu { AppContextMenu(model: model, app: app) }
            }
        }
        .padding(Theme.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func detail(for app: AppEntry) -> String? {
        return app.windowsPath
    }

    /// The layer's tools, as icons next to "Apps".
    @ViewBuilder private var windowsTools: some View {
        toolIcon("plus.app", help: "Run a program or installer…") {
            let urls = Panels.chooseFiles(title: "Run in “\(container.name)”", extensions: ["exe", "msi", "bat", "lnk"])
            if let url = urls.first { model.open([url], into: container) }
        }
        toolIcon("arrow.clockwise", help: "Look for new apps") { model.rescan(container) }
        toolIcon("folder", help: "Open the C: drive") { model.openDriveC(container) }
        toolIcon("doc.text.magnifyingglass", help: "Show logs") { model.openLogs(container) }
        let running = !model.runningPrograms(in: container).isEmpty
        toolIcon("stop.fill", help: "Stop everything running here", tint: running ? .red : nil) { model.stopAll(in: container) }
            .disabled(!running)
    }

    private func toolIcon(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .help(help)
    }
}

/// "Install Steam", shaped like an app in the list, until Steam is installed or the card is closed
/// (Install Steam is always in the layer's Settings too).
struct SteamSuggestionRow: View {
    let model: AppModel
    let container: Container

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.16, blue: 0.29), Color(red: 0.16, green: 0.42, blue: 0.68)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: "gamecontroller.fill").font(.system(size: 15)).foregroundStyle(.white))
            VStack(alignment: .leading) {
                Text("Steam")
                Text("Install Steam to play your Steam games here").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Install") { model.installSteam(in: container) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                model.hideSteamSuggestion(container)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide (Install Steam stays in Settings)")
        }
        .padding(.vertical, 2)
    }
}

