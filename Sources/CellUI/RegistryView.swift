import SwiftUI
import CellCore

/// Native registry browser. Reads Wine's hive files directly, so it never shows a blank regedit window.
struct RegistryView: View {
    let model: AppModel
    let container: Container

    enum Hive: String, CaseIterable, Identifiable {
        case user = "HKEY_CURRENT_USER", machine = "HKEY_LOCAL_MACHINE"
        var id: String { rawValue }
        var file: String { self == .user ? "user.reg" : "system.reg" }
        var registryHive: RegistryHive { self == .user ? .currentUser : .localMachine }
    }

    @State private var hive: Hive = .user
    @State private var nodes: [RegistryKeyNode] = []
    @State private var selection: RegistryKeyNode?
    @State private var filter = ""
    @State private var loading = false
    @State private var editing: RegistryValueDraft?

    var body: some View {
        if !container.isInitialized {
            EmptyStateView(title: "No registry yet", systemImage: "list.bullet.indent",
                           message: "The registry is created when the container is set up.",
                           actionTitle: "Set Up Now", action: { model.setUp(container) })
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    Picker("Hive", selection: $hive) {
                        ForEach(Hive.allCases) { hive in Text(hive == .user ? "Current User" : "Local Machine").tag(hive) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(8)
                    TextField("Filter keys", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 8).padding(.bottom, 8)
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(filteredNodes, children: \.children, selection: $selection) { node in
                            Label(node.name, systemImage: "folder").tag(node)
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(minWidth: 260, idealWidth: 320)

                VStack(alignment: .leading, spacing: 0) {
                    if let selection {
                        HStack {
                            Text("\(hive.rawValue)\\\(selection.path)").font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                            Spacer()
                            Button("Add Value…") { editing = RegistryValueDraft(key: selection.path) }.controlSize(.small)
                        }
                        .padding(10)
                        Table(selection.values) {
                            TableColumn("Name") { value in Text(value.name.isEmpty ? "(Default)" : value.name) }
                            TableColumn("Type") { value in Text(value.type).foregroundStyle(.secondary) }.width(min: 90, ideal: 110)
                            TableColumn("Data") { value in Text(value.display).lineLimit(1).textSelection(.enabled) }
                        }
                        .contextMenu(forSelectionType: RegistryValueEntry.ID.self) { ids in
                            if let id = ids.first, let value = selection.values.first(where: { $0.id == id }) {
                                Button("Edit…") { editing = RegistryValueDraft(key: selection.path, value: value) }
                                Button("Delete", role: .destructive) { apply(.set(hive.registryHive, selection.path, value.name.isEmpty ? nil : value.name, .delete)) }
                            }
                        } primaryAction: { ids in
                            if let id = ids.first, let value = selection.values.first(where: { $0.id == id }) {
                                editing = RegistryValueDraft(key: selection.path, value: value)
                            }
                        }
                    } else {
                        EmptyStateView(title: "Choose a key", systemImage: "list.bullet.indent",
                                       message: "Cell's own settings live under Software ▸ Wine. Changes are applied through Wine, so they are safe while apps run.")
                    }
                }
                .frame(minWidth: 380)
            }
            .task(id: hive) { await load() }
            .sheet(item: $editing) { draft in
                RegistryEditSheet(draft: draft) { edit in apply(edit.toEdit(hive: hive.registryHive)) }
            }
            .toolbar {
                ToolbarItem {
                    Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                }
            }
        }
    }

    private var filteredNodes: [RegistryKeyNode] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        var matches: [RegistryKeyNode] = []
        func walk(_ node: RegistryKeyNode) {
            if node.name.localizedCaseInsensitiveContains(query) { matches.append(node) }
            if matches.count < 300 { node.childNodes.forEach(walk) }
        }
        nodes.forEach(walk)
        return matches
    }

    private func load() async {
        loading = true
        let url = container.prefixURL.appendingPathComponent(hive.file)
        let root = hive.rawValue
        let tree = await Task.detached(priority: .userInitiated) { () -> [RegistryKeyNode] in
            (try? WineRegistryHive.load(url, rootName: root).tree()) ?? []
        }.value
        nodes = tree
        selection = nil
        loading = false
    }

    private func apply(_ edit: RegistryEdit) {
        guard let runtime = model.runtime(for: container) else { return }
        let target = container
        model.perform("Updating registry") { _ in
            try await WineCommands.applyRegistry([edit], container: target, runtime: runtime)
            _ = try? await WineCommands.waitForServer(container: target, runtime: runtime, timeout: 15)
            await load()
        }
    }
}

struct RegistryValueDraft: Identifiable {
    let id = UUID()
    var key: String
    var name: String = ""
    var type: String = "REG_SZ"
    var data: String = ""

    init(key: String, value: RegistryValueEntry? = nil) {
        self.key = key
        if let value {
            name = value.name
            type = value.type
            data = value.type == "REG_DWORD" ? String(value.display.split(separator: " ").first ?? "") : value.display
        }
    }

    func toEdit(hive: RegistryHive) -> RegistryEdit {
        let valueName = name.isEmpty ? nil : name
        switch type {
        case "REG_DWORD":
            let text = data.lowercased().hasPrefix("0x") ? String(data.dropFirst(2)) : data
            let number = data.lowercased().hasPrefix("0x") ? UInt32(text, radix: 16) : UInt32(text)
            return .set(hive, key, valueName, .dword(number ?? 0))
        case "REG_EXPAND_SZ": return .set(hive, key, valueName, .expandString(data))
        case "REG_MULTI_SZ": return .set(hive, key, valueName, .multiString(data.components(separatedBy: " · ")))
        default: return .set(hive, key, valueName, .string(data))
        }
    }
}

struct RegistryEditSheet: View {
    @State var draft: RegistryValueDraft
    let onSave: (RegistryValueDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Registry value").font(.title3.weight(.semibold))
            Text(draft.key).font(.caption.monospaced()).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $draft.name, prompt: Text("(Default)"))
                Picker("Type", selection: $draft.type) {
                    Text("String").tag("REG_SZ")
                    Text("Number (DWORD)").tag("REG_DWORD")
                    Text("Expandable string").tag("REG_EXPAND_SZ")
                    Text("Multi-string (separate with ·)").tag("REG_MULTI_SZ")
                }
                TextField("Data", text: $draft.data)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
