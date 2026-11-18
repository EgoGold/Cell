import CellCore
import SwiftUI

struct PluginEditor: View {
    private struct OptionDraft: Identifiable {
        let id = UUID()
        var value: PluginOption?
    }
    let model: AppModel
    let plugin: InstalledPlugin
    @Environment(\.dismiss) private var dismiss
    @State private var manifestText = ""
    @State private var assets: [URL] = []
    @State private var removed: Set<String> = []
    @State private var icon: URL?
    @State private var optionDraft: OptionDraft?
    @State private var saving = false
    @State private var error: String?

    private var packageAssets: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: plugin.directory.path)) ?? []
        return files.filter { $0 != "plugin.json" && !removed.contains($0) && !$0.hasPrefix(".") }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(plugin.manifest.name)").font(.title2.weight(.semibold))
            if plugin.isBuiltin { Text("Saving creates an editable copy in your plugins.").foregroundStyle(.secondary) }
            HStack {
                Text("plugin.json").font(.headline)
                Spacer()
                Menu("Options") {
                    Button("Add Option…") { optionDraft = OptionDraft() }
                    ForEach((try? decodeManifest().options) ?? []) { option in
                        Button("Edit \(option.title)…") { optionDraft = OptionDraft(value: option) }
                    }
                }
                Button("Set Picture…") {
                    icon = Panels.chooseFiles(title: "Choose Plugin Picture", extensions: ["png", "jpg", "jpeg", "webp", "icns"]).first ?? icon
                }
            }
            TextEditor(text: $manifestText)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .border(.quaternary)
                .accessibilityLabel("Plugin manifest")
            HStack {
                Text("Package Files").font(.headline)
                Spacer()
                Button("Add Files or Folders…") {
                    for file in Panels.chooseFiles(title: "Add Plugin Assets", allowFolders: true, multiple: true) {
                        assets.removeAll { $0.lastPathComponent == file.lastPathComponent }
                        removed.insert(file.lastPathComponent)
                        assets.append(file)
                    }
                }
            }
            List {
                ForEach(packageAssets, id: \.self) { name in
                    assetRow(name) { removed.insert(name) }
                }
                ForEach(assets, id: \.self) { url in
                    assetRow(url.lastPathComponent) { assets.removeAll { $0 == url } }
                }
                if let icon { assetRow(icon.lastPathComponent) { self.icon = nil } }
            }
            .frame(height: 115)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : "Save Plugin", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 690, minHeight: 570)
        .disabled(saving)
        .onAppear { writeManifest(plugin.manifest) }
        .sheet(item: $optionDraft) { draft in
            PluginOptionEditor(initial: draft.value) { option in
                do {
                    var manifest = try decodeManifest()
                    var options = manifest.options ?? []
                    if let index = options.firstIndex(where: { $0.id == option.id }) { options[index] = option }
                    else { options.append(option) }
                    manifest.options = options
                    writeManifest(manifest)
                    error = nil
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func assetRow(_ name: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Label(name, systemImage: "doc")
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).accessibilityLabel("Remove \(name)")
        }
    }

    private func decodeManifest() throws -> PluginManifest {
        try JSONDecoder().decode(PluginManifest.self, from: Data(manifestText.utf8))
    }

    private func writeManifest(_ manifest: PluginManifest) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(manifest) { manifestText = String(decoding: data, as: UTF8.self) }
    }

    private func save() {
        do {
            let manifest = try decodeManifest()
            let manager = model.services.plugins
            let assets = assets, removed = removed, icon = icon, plugin = plugin
            saving = true
            error = nil
            Task { @MainActor in
                do {
                    _ = try await Task.detached(priority: .utility) {
                        try manager.saveEdit(plugin, manifest: manifest, adding: assets, removing: removed, icon: icon)
                    }.value
                    model.refresh()
                    dismiss()
                } catch {
                    saving = false
                    self.error = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct PluginOptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var title = ""
    @State private var type = "toggle"
    @State private var defaultValue = ""
    @State private var choices = ""
    @State private var help = ""
    let initial: PluginOption?
    let onSave: (PluginOption) -> Void

    private var choiceValues: [String] {
        choices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil ? "Add Plugin Option" : "Edit Plugin Option").font(.title2.weight(.semibold))
            Form {
                TextField("ID", text: $id, prompt: Text("enablePatch")).disabled(initial != nil)
                TextField("Label", text: $title)
                Picker("Type", selection: $type) {
                    Text("Switch").tag("toggle")
                    Text("Choice").tag("choice")
                    Text("Number").tag("number")
                    Text("Text").tag("text")
                }
                if type == "choice" { TextField("Choices, separated by commas", text: $choices) }
                if type == "toggle" {
                    Toggle("Default On", isOn: Binding(get: { defaultValue == "true" }, set: { defaultValue = $0 ? "true" : "false" }))
                } else { TextField("Default", text: $defaultValue) }
                TextField("Help", text: $help)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Add Option" : "Save Option") {
                    onSave(PluginOption(id: id, title: title, type: type,
                                        defaultValue: type == "toggle" ? (defaultValue == "true" ? "true" : "false")
                                            : (defaultValue.isEmpty ? nil : defaultValue),
                                        choices: type == "choice" ? choiceValues : nil, help: help.isEmpty ? nil : help))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) == nil ||
                          title.isEmpty || (type == "choice" && choiceValues.isEmpty))
            }
        }
        .padding(20)
        .frame(minWidth: 420)
        .onAppear {
            guard let initial else { return }
            id = initial.id
            title = initial.title
            type = initial.type
            defaultValue = initial.defaultValue ?? ""
            choices = initial.choices?.joined(separator: ", ") ?? ""
            help = initial.help ?? ""
        }
    }
}
