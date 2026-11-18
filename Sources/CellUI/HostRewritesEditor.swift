import CellCore
import SwiftUI

struct HostRewritesEditor: View {
    let model: AppModel
    let container: Container
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = HostRewrites()
    @State private var source = ""
    @State private var target = ""
    @State private var checking = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Host/DNS Rewriter").font(.title2.weight(.semibold))
            Text("Rewrite a hostname to another name or IP address in \(container.name).")
                .foregroundStyle(.secondary)
            List {
                ForEach(configuration.rules.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(configuration.rules[host] ?? "")
                        Spacer()
                        Button(role: .destructive) { configuration.rules.removeValue(forKey: host) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(host)")
                    }
                }
            }
            HStack {
                TextField("Hostname", text: $source)
                TextField("Destination hostname or IP", text: $target)
                Button("Add", action: addRule).disabled(source.isEmpty || target.isEmpty)
            }
            Toggle("Retry the original hostname if the destination fails", isOn: $configuration.retryOriginal)
            Toggle("Resolve IPv4 first", isOn: Binding(get: { configuration.preferIPv4 == true },
                                                     set: { configuration.preferIPv4 = $0 }))
            if let message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button(checking ? "Checking…" : "Test & Repair", action: test).disabled(checking || configuration.rules.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 610, minHeight: 390)
        .onAppear { configuration = container.settings.hostRewrites }
    }

    private func addRule() {
        var next = configuration
        next.rules[source] = target
        do {
            configuration = try next.validated()
            source = ""
            target = ""
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func test() {
        let config = configuration
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let missing = try await Task.detached(priority: .utility) { try config.unresolvedTargets() }.value
                if missing.isEmpty { message = "All destinations resolved." }
                else {
                    configuration.retryOriginal = true
                    message = "Couldn’t resolve \(missing.joined(separator: ", ")). Cell will retry the original hostname when a rewrite fails."
                }
            } catch { message = error.localizedDescription }
        }
    }

    private func save() {
        do {
            if !source.isEmpty || !target.isEmpty {
                var next = configuration
                next.rules[source] = target
                configuration = try next.validated()
            }
            var updated = model.container(container.id) ?? container
            updated.settings.hostRewrites = try configuration.validated()
            try updated.settings.hostRewrites.write(for: updated)
            try model.services.library.save(updated)
            model.refresh()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
