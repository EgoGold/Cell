import SwiftUI
import CellCore

/// All plugins: what they fix, where they apply (every translation layer or chosen ones), and adding new ones.
struct PluginsView: View {
    let model: AppModel
    @State private var selectedID: String?
    @State private var showNewPlugin = false
    @State private var editing: InstalledPlugin?
    @State private var search = ""
    @State private var filter: Filter = .all
    @State private var isDropTargeted = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", added = "Added", builtIn = "Built In"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    TextField("Search plugins", text: $search).textFieldStyle(.roundedBorder)
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(12)
                List(selection: $selectedID) {
                    if !model.pluginErrors.isEmpty {
                        Section("Problems") {
                            ForEach(model.pluginErrors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                            }
                        }
                    }
                    let added = shown.filter { !$0.isBuiltin }
                    let builtIn = shown.filter(\.isBuiltin)
                    if filter != .builtIn {
                        Section("Added by you") {
                            ForEach(added) { plugin in PluginRow(model: model, plugin: plugin).tag(plugin.id) }
                            if added.isEmpty {
                                Text("Drop a .cell plugin here, or create your own for a game you fixed.").foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                    if filter != .added && !builtIn.isEmpty {
                        Section("Built in") {
                            ForEach(builtIn) { plugin in PluginRow(model: model, plugin: plugin).tag(plugin.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

            Group {
                if let plugin = model.plugins.first(where: { $0.id == selectedID }) {
                    PluginDetail(model: model, plugin: plugin, edit: { editing = plugin })
                } else {
                    EmptyStateView(title: "Plugins fix games", systemImage: "puzzlepiece.extension",
                                   message: "A plugin recognizes a game by its Steam app ID, program, engine or version and applies fixes: graphics engine, launch arguments, registry values, settings files and more. Plugins apply in every translation layer unless you choose some; each layer also has its own Plugins tab.",
                                   actionTitle: "Import Plugin…", action: addGlobalPlugin)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Plugin")
        .dropDestination(for: URL.self) { urls, _ in model.importDroppedPlugins(urls) } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { PluginDropOverlay(text: "Drop to add the plugin to every translation layer") } }
        .toolbar {
            ToolbarItemGroup {
                Button(action: addGlobalPlugin) { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import a .cell package")
                Button { showNewPlugin = true } label: { Label("Create", systemImage: "plus") }
                    .help("Create a plugin of your own")
                Button {
                    if let plugin = model.plugins.first(where: { $0.id == selectedID }) { model.exportPlugin(plugin) }
                } label: {
                    Label("Export .cell", systemImage: "square.and.arrow.up")
                }
                .disabled(!model.plugins.contains { $0.id == selectedID })
                Button { model.revealPluginsFolder() } label: { Label("Show Folder", systemImage: "folder") }
                Button { model.checkPluginUpdates() } label: { Label("Reload and Check for Updates", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showNewPlugin) {
            NewPluginSheet(model: model) { selectedID = $0.id }
        }
        .sheet(item: $editing) { PluginEditor(model: model, plugin: $0) }
    }

    private var shown: [InstalledPlugin] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.plugins }
        return model.plugins.filter {
            $0.manifest.name.localizedCaseInsensitiveContains(query) || ($0.manifest.summary ?? "").localizedCaseInsensitiveContains(query)
                || model.apps(matching: $0).contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    private func addGlobalPlugin() {
        if let url = Panels.chooseFiles(title: "Import a .cell Plugin", extensions: ["zip"] + PluginManager.pluginExtensions, allowFolders: true).first {
            model.importPlugin(url)
        }
    }
}

/// One plugin in a list: what it is, where it applies, and its switch.
struct PluginRow: View {
    let model: AppModel
    let plugin: InstalledPlugin

    var body: some View {
        HStack(spacing: 10) {
            PluginIcon(plugin: plugin)
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.manifest.name).lineLimit(1)
                if let useWhen = plugin.manifest.useWhen {
                    Text(useWhen).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(PluginText.scope(of: plugin, model: model)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { !model.pluginState.disabled.contains(plugin.id) },
                                     set: { model.setEnabled($0, plugin: plugin) }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
                .help("Turn the plugin on or off everywhere")
        }
        .padding(.vertical, 3)
    }
}

struct PluginIcon: View {
    let plugin: InstalledPlugin
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let url = plugin.iconURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill((plugin.isBuiltin ? Color.accentColor : Color.purple).gradient)
                    .overlay(Image(systemName: plugin.hasScripts ? "terminal" : "puzzlepiece.extension.fill")
                        .font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
    }
}

private struct PluginDetail: View {
    let model: AppModel
    let plugin: InstalledPlugin
    let edit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .top, spacing: 14) {
                    PluginIcon(plugin: plugin, size: 52)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plugin.manifest.name).font(.title.weight(.bold))
                        HStack(spacing: 6) {
                            Badge(text: "v\(plugin.manifest.version)")
                            if let author = plugin.manifest.author { Badge(text: author, systemImage: "person") }
                            if plugin.isBuiltin { Badge(text: "Built in", color: .accentColor) }
                            if plugin.hasScripts { Badge(text: "Runs scripts", color: .orange) }
                        }
                        if let summary = plugin.manifest.summary { Text(summary).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Toggle("On", isOn: Binding(get: { !model.pluginState.disabled.contains(plugin.id) },
                                               set: { model.setEnabled($0, plugin: plugin) }))
                        .toggleStyle(.switch)
                }

                if let useWhen = plugin.manifest.useWhen {
                    SectionCard("When to use it", systemImage: "lightbulb") { Text(useWhen) }
                }

                if let options = plugin.manifest.options, !options.isEmpty {
                    SectionCard("Options", systemImage: "slider.horizontal.3") {
                        ForEach(options) { option in PluginOptionControl(model: model, plugin: plugin, option: option) }
                    }
                }

                PluginScopeCard(model: model, plugin: plugin)

                let matching = model.apps(matching: plugin)
                SectionCard("Apps it fixes", systemImage: "gamecontroller") {
                    if matching.isEmpty {
                        Text("None of your apps match it yet. It applies as soon as one does.").foregroundStyle(.secondary)
                    }
                    ForEach(matching) { app in
                        HStack(spacing: 10) {
                            AppIconView(app: app, size: 24)
                            Text(app.name)
                            Spacer()
                            if let container = model.container(app.containerID) {
                                Text(container.name).font(.caption).foregroundStyle(.secondary)
                                if !model.isPluginActive(plugin, in: container) { Badge(text: "Off here") }
                            }
                        }
                    }
                }

                if let fixes = plugin.manifest.fixes {
                    SectionCard("What it changes", systemImage: "wrench.adjustable") {
                        ForEach(PluginText.describe(fixes), id: \.self) { line in Label(line, systemImage: "checkmark").font(.callout) }
                        ForEach(fixes.notes ?? [], id: \.self) { note in
                            Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                SectionCard("How it recognizes apps", systemImage: "scope") {
                    ForEach(Array(((plugin.manifest.match.any ?? []) + (plugin.manifest.match.all ?? [])).enumerated()), id: \.offset) { _, rule in
                        Text(PluginText.describe(rule)).font(.callout)
                    }
                }

                if plugin.hasScripts {
                    SectionCard("Scripts", systemImage: "terminal") {
                        Text("Allow trusted plugins to run their scripts and programs.")
                            .foregroundStyle(.secondary)
                        Toggle("Allow scripts and programs", isOn: Binding(
                            get: { model.pluginState.trustedScripts.contains(plugin.id) },
                            set: { model.setTrusted($0, plugin: plugin) }))
                        let layers = model.visibleContainers.filter { model.isPluginActive(plugin, in: $0) }
                        ForEach(plugin.manifest.actions ?? []) { action in
                            Menu(action.title) {
                                ForEach(layers) { layer in
                                    Button(layer.name) { model.runPluginAction(action, plugin: plugin, in: layer) }
                                }
                            }
                            .disabled(layers.isEmpty || !model.pluginState.trustedScripts.contains(plugin.id))
                        }
                    }
                }

                HStack {
                    Button("Edit Plugin…", action: edit)
                    if plugin.manifest.updateURL != nil {
                        Button("Check for Update") { model.checkPluginUpdates(only: plugin) }
                    }
                    Spacer()
                }
                HStack {
                    Button("Restore Default Config…") { model.restorePluginDefaults(plugin) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([plugin.packageURL ?? plugin.directory])
                    }
                    Spacer()
                    if !plugin.isBuiltin { Button("Remove Plugin", role: .destructive) { model.remove(plugin) } }
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

/// Every translation layer, or only the chosen ones (with a switch per layer).
struct PluginScopeCard: View {
    let model: AppModel
    let plugin: InstalledPlugin

    var body: some View {
        let layers = model.visibleContainers.filter { plugin.applies(to: $0.platform) }
        let scope = model.pluginState.scope(of: plugin)
        SectionCard("Where it applies", systemImage: "square.stack.3d.up") {
            Picker("Applies in", selection: Binding(
                get: { scope == nil },
                set: { everywhere in
                    model.setPluginScope(plugin, containers: everywhere ? nil : Set(layers.filter { model.isPluginActive(plugin, in: $0) }.map(\.id)))
                })) {
                Text("Every translation layer").tag(true)
                Text("Only the layers I choose").tag(false)
            }
            .pickerStyle(.radioGroup)
            ForEach(layers) { container in
                Toggle(isOn: Binding(get: { model.isPluginActive(plugin, in: container) },
                                     set: { model.setPlugin(plugin, active: $0, in: container) })) {
                    Label(container.name, systemImage: "shippingbox")
                }
            }
            if plugin.isChosenPerLayer {
                Text("This plugin asks to be turned on per translation layer.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// A translation layer's own plugins: the ones fixing its apps first, with a switch for this layer only.
struct ContainerPluginsView: View {
    let model: AppModel
    let container: Container
    @State private var showOthers = false
    @State private var isDropTargeted = false

    var body: some View {
        let applicable = model.plugins.filter { $0.applies(to: container.platform) }
        let fixing = applicable.filter { !model.apps(matching: $0, in: container).isEmpty }
        let others = applicable.filter { plugin in !fixing.contains { $0.id == plugin.id } }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Plugins fix specific games and apps. Switch one off here and it stays on in your other translation layers.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Plugin to This Layer…") {
                        if let url = Panels.chooseFiles(title: "Choose a .cell plugin or .zip", extensions: ["zip"] + PluginManager.pluginExtensions, allowFolders: true).first {
                            model.importPlugin(url, onlyIn: container)
                        }
                    }
                    Button("All Plugins") { model.selection = .plugins }
                }

                SectionCard("Fixing apps here", systemImage: "wrench.adjustable") {
                    if fixing.isEmpty {
                        Text("No plugin matches the apps in “\(container.name)” yet.").foregroundStyle(.secondary)
                    }
                    ForEach(fixing) { plugin in row(plugin, apps: model.apps(matching: plugin, in: container)) }
                }

                if !others.isEmpty {
                    SectionCard("Other plugins", systemImage: "puzzlepiece.extension") {
                        DisclosureGroup(isExpanded: $showOthers) {
                            ForEach(others) { plugin in row(plugin, apps: []) }
                        } label: {
                            Text("\(others.count) plugin\(others.count == 1 ? "" : "s") that would apply here once a matching app is added")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .dropDestination(for: URL.self) { urls, _ in model.importDroppedPlugins(urls, onlyIn: container) } isTargeted: { isDropTargeted = $0 }
        .overlay { if isDropTargeted { PluginDropOverlay(text: "Drop to add the plugin to “\(container.name)”") } }
    }

    private func row(_ plugin: InstalledPlugin, apps: [AppEntry]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PluginIcon(plugin: plugin)
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.manifest.name)
                if let useWhen = plugin.manifest.useWhen {
                    Text(useWhen).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if let first = plugin.manifest.fixes.map(PluginText.describe)?.first {
                    Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !apps.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(apps.prefix(6)) { app in AppIconView(app: app, size: 16).help(app.name) }
                        Text(apps.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.isPluginActive(plugin, in: container) },
                                     set: { model.setPlugin(plugin, active: $0, in: container) }))
                .toggleStyle(.switch).labelsHidden()
                .help("On in “\(container.name)”")
        }
        .padding(.vertical, 2)
    }
}

/// Plain-language descriptions of plugin rules and fixes.
enum PluginText {
    @MainActor static func scope(of plugin: InstalledPlugin, model: AppModel) -> String {
        if model.pluginState.disabled.contains(plugin.id) { return "Off" }
        let layers = model.visibleContainers.filter { plugin.applies(to: $0.platform) }
        let active = layers.filter { model.isPluginActive(plugin, in: $0) }
        let apps = model.apps(matching: plugin).count
        let place = active.count == layers.count ? "Every layer" : active.isEmpty ? "No layer" : active.count == 1 ? active[0].name : "\(active.count) layers"
        return apps > 0 ? "\(place) · fixes \(apps) app\(apps == 1 ? "" : "s")" : place
    }

    static func describe(_ rule: MatchRule) -> String {
        var parts: [String] = []
        if let id = rule.steamAppID { parts.append("Steam app \(id)") }
        if let exe = rule.executable { parts.append("program \(exe)") }
        if let engine = rule.engine { parts.append("\(engine) games" + (rule.engineVersion.map { " \($0)" } ?? "")) }
        else if let version = rule.engineVersion { parts.append("engine version \(version)") }
        if let api = rule.graphicsAPI { parts.append("\(GraphicsAPI(rawValue: api)?.displayName ?? api) games") }
        if let product = rule.productName { parts.append("product \(product)") }
        if let file = rule.fileExists { parts.append("folders containing \(file)") }
        if let kind = rule.appKind { parts.append(kind == "steamClient" ? "the Steam client" : kind) }
        if let arch = rule.architecture { parts.append("\(arch) programs") }
        return "• " + (parts.isEmpty ? "Everything" : parts.joined(separator: ", "))
    }

    static func describe(_ fixes: PluginFixes) -> [String] {
        var lines: [String] = []
        if let prefer = fixes.graphics?.prefer, !prefer.isEmpty {
            lines.append("Prefers \(prefer.compactMap { GraphicsBackend(rawValue: $0)?.displayName }.joined(separator: ", then "))")
        }
        if let avoid = fixes.graphics?.avoid, !avoid.isEmpty { lines.append("Avoids \(avoid.joined(separator: ", "))") }
        if let args = fixes.arguments?.append, !args.isEmpty { lines.append("Adds arguments: \(args.joined(separator: " "))") }
        for (backend, args) in fixes.arguments?.whenBackend ?? [:] { lines.append("With \(backend): \(args.joined(separator: " "))") }
        if let env = fixes.environment?.set, !env.isEmpty { lines.append("Sets \(env.keys.sorted().joined(separator: ", "))") }
        if let overrides = fixes.dllOverrides, !overrides.isEmpty { lines.append("DLL overrides: \(overrides.keys.sorted().joined(separator: ", "))") }
        if let registry = fixes.registry, !registry.isEmpty { lines.append("\(registry.count) registry value(s)") }
        if let wine = fixes.wine {
            if let scroll = wine.scrollMode { lines.append("Scrolling: \(scroll)") }
            if wine.captureDisplays == true { lines.append("Asks to lock the display in fullscreen (Cell leaves that to you)") }
            if let version = wine.windowsVersion { lines.append("Windows version: \(version)") }
            if let warp = wine.mouseWarp { lines.append("Mouse capture: \(warp)") }
            if let high = wine.highResolution { lines.append(high ? "High resolution on" : "High resolution off") }
            if let mappings = wine.keyMappings, !mappings.isEmpty {
                lines.append("Remaps \(mappings.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", "))")
            }
        }
        if let overlay = fixes.steam?.overlay { lines.append("Steam overlay: \(overlay)") }
        if let ini = fixes.ini, !ini.isEmpty { lines.append("Edits \(ini.count) settings file(s)") }
        if let files = fixes.files, !files.isEmpty { lines.append("Copies \(files.count) file(s)") }
        if let ports = fixes.network?.ports, !ports.isEmpty { lines.append("Opens \(ports.map(\.displayName).joined(separator: ", "))") }
        return lines
    }
}

struct NewPluginSheet: View {
    let model: AppModel
    var onCreate: (InstalledPlugin) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var executable = ""
    @State private var steamAppID = ""
    @State private var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Plugin").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("My Game fixes"))
                TextField("Package ID", text: $identifier, prompt: Text("com.example.mygame"))
                TextField("Program", text: $executable, prompt: Text("Game.exe"))
                TextField("Steam app ID", text: $steamAppID, prompt: Text("optional"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    if let plugin = model.createPlugin(named: name, executable: executable, steamAppID: steamAppID,
                                                       identifier: identifier.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        onCreate(plugin)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// "Drop to add…" over a plugin page while a plugin is dragged over it.
struct PluginDropOverlay: View {
    let text: String

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.cornerRadius)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            .padding(8)
            .overlay(Text(text).font(.title3.weight(.semibold)).padding(14).background(.regularMaterial, in: Capsule()))
            .allowsHitTesting(false)
    }
}

/// One option a plugin offers, as the control that fits it.
struct PluginOptionControl: View {
    let model: AppModel
    let plugin: InstalledPlugin
    let option: PluginOption

    var body: some View {
        let value = model.pluginState.values(for: plugin)[option.id] ?? ""
        VStack(alignment: .leading, spacing: 3) {
            switch option.type {
            case "toggle":
                Toggle(option.title, isOn: Binding(get: { value == "true" },
                                                   set: { model.setPluginOption(plugin, id: option.id, to: $0 ? "true" : "false") }))
            case "choice":
                Picker(option.title, selection: Binding(get: { value }, set: { model.setPluginOption(plugin, id: option.id, to: $0) })) {
                    ForEach(option.choices ?? [], id: \.self) { Text($0).tag($0) }
                }
            default:
                LabeledContent(option.title) {
                    TextField(option.title, text: Binding(get: { value }, set: { model.setPluginOption(plugin, id: option.id, to: $0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
            }
            if let help = option.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
