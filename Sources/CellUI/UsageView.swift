import SwiftUI
import CellCore

struct ContainerUsageView: View {
    let model: AppModel
    let container: Container
    var didClean: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                let running = model.runningPrograms(in: container)
                SectionCard("Running now", systemImage: "play.circle") {
                    if running.isEmpty {
                        Text("No programs are running in this layer.").foregroundStyle(.secondary)
                    } else {
                        ForEach(running, id: \.self) { process in
                            RunningProgramRow(model: model, container: container, process: process)
                        }
                        HStack {
                            if model.isStoppingSteam(in: container) || running.contains(where: { $0.executableName == "steam.exe" }) {
                                Button(model.steamQuitTitle(in: container)) { model.quitSteam(in: container) }
                            }
                            Button("Stop Everything", role: .destructive) { model.stopAll(in: container) }
                        }
                    }
                }
                ContainerCleanupCard(model: model, container: container, didClean: didClean)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }
}

struct RunningProgramRow: View {
    let model: AppModel
    let container: Container
    let process: WineProcess
    @State private var hovered = false
    @FocusState private var focused: Bool

    private var stopping: Bool {
        process.executableName == "steam.exe" ? model.isStoppingSteam(in: container) : model.isStopping(process)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.green)
            Text(process.executable.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? process.executable)
                .lineLimit(1)
            Text(process.executable).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button(stopping ? "Force Quit" : "Stop") { model.stop(process) }
                .controlSize(.small)
                .focused($focused)
                .opacity(hovered || stopping || focused ? 1 : 0)
                .help("Stop this process (PID \(process.pid))")
                .accessibilityLabel(stopping ? "Force quit \(process.executableName)" : "Stop \(process.executableName)")
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button(stopping ? "Force Quit" : "Stop") { model.stop(process) }
        }
        .disabled(process.startedAt == nil)
    }
}

struct ContainerCleanupCard: View {
    let model: AppModel
    let container: Container
    var didClean: () -> Void = {}
    var showContainerName = false
    @State private var plan: ContainerCleanup.Plan?
    @State private var confirmation = false
    @State private var cleaning = false
    @State private var report: String?
    @State private var revision = 0

    private var busy: Bool {
        !model.runningPrograms(in: container).isEmpty
            || model.sessions.values.contains { $0.plan.container.id == container.id && $0.isRunning }
    }

    var body: some View {
        SectionCard(showContainerName ? "Trash · \(container.name)" : "Trash", systemImage: "trash") {
            HStack {
                if let plan {
                    Text(plan.candidates.isEmpty ? "No cleanup candidates" : "\(plan.bytes.byteDescription) eligible for cleanup")
                        .font(.headline)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Checking for temporary files and caches…")
                }
                Spacer(minLength: 0)
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Scan again").accessibilityLabel("Scan again")
                    .disabled(plan == nil || cleaning)
                Button(cleaning ? "Cleaning…" : "Clean…") { confirmation = true }
                    .disabled(plan?.candidates.isEmpty != false || busy || cleaning)
            }
            if let plan, !plan.candidates.isEmpty {
                ForEach(ContainerCleanup.Category.allCases, id: \.self) { category in
                    let files = plan.candidates.filter { $0.category == category }
                    if !files.isEmpty {
                        HStack {
                            Text(category.rawValue).foregroundStyle(.secondary)
                            Spacer()
                            Text(files.reduce(Int64(0)) { $0 + $1.bytes }.byteDescription).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
            Text(report ?? (busy ? "Quit the running programs in this layer before cleaning."
                                : "Moves eligible files to the macOS Trash. Installed games, saves and downloads stay in place."))
                .foregroundStyle(.secondary)
        }
        .task(id: revision) {
            plan = nil
            let container = container
            let result = await Task.detached(priority: .utility) { ContainerCleanup.plan(for: container) }.value
            if !Task.isCancelled { plan = result }
        }
        .alert("Move eligible files to the Trash?", isPresented: $confirmation, presenting: plan) { review in
            Button("Move to Trash", role: .destructive) { clean(review) }
            Button("Cancel", role: .cancel) {}
        } message: { review in
            Text("Move \(review.candidates.count) items (\(review.bytes.byteDescription)) from “\(container.name)” to the macOS Trash. Empty the Trash when you’re ready to reclaim the space.")
        }
    }

    private func clean(_ review: ContainerCleanup.Plan) {
        guard !busy, !cleaning else { return }
        cleaning = true
        let container = container
        model.perform("Cleaning “\(container.name)”") { _ in
            defer {
                cleaning = false
                revision += 1
                didClean()
            }
            let result = try await Task.detached(priority: .utility) {
                try ContainerCleanup.moveToTrash(review, in: container)
            }.value
            report = result.skipped == 0
                ? "Moved \(result.moved) items to the Trash."
                : "Moved \(result.moved) items to the Trash. Skipped \(result.skipped) items that changed or couldn't be moved."
        }
    }
}
