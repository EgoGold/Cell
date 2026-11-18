import SwiftUI
import CellCore

/// Everything running right now: apps in every translation layer and virtual machines, with ways to stop them.
struct RunningView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                Text("Usage").font(.largeTitle.weight(.bold))
                Text("See what’s running and clean temporary files from your translation layers.")
                    .foregroundStyle(.secondary)

                let layers = model.visibleContainers.filter { container in
                    !model.runningPrograms(in: container).isEmpty
                        || model.apps(in: container).contains(where: model.isRunning)
                }
                let machines = model.virtualMachines.filter { model.isRunning($0) }
                if layers.isEmpty && machines.isEmpty {
                    EmptyStateView(title: "Nothing is running", systemImage: "moon.zzz",
                                   message: "Games, apps and virtual machines you start show up here.")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }

                ForEach(layers) { container in
                    let processes = model.runningPrograms(in: container)
                    SectionCard(container.name, systemImage: "shippingbox") {
                        let apps = model.apps(in: container).filter { model.isRunning($0) }
                        ForEach(apps) { app in
                            HStack(spacing: 10) {
                                AppIconView(app: app, size: 28)
                                Text(app.name)
                                if let backend = model.sessions[app.id]?.plan.decision.backend {
                                    Badge(text: backend.displayName, color: .accentColor)
                                }
                                Spacer()
                                Button(model.quitTitle(for: app)) { model.stop(app) }.controlSize(.small)
                            }
                        }
                        let known = Set(apps.flatMap { model.scannedRunning[$0.id] ?? [] })
                        let others = processes.filter { !known.contains($0.pid) }
                        if !others.isEmpty {
                            DisclosureGroup("\(others.count) more Windows program\(others.count == 1 ? "" : "s")") {
                                ForEach(others, id: \.pid) { process in
                                    RunningProgramRow(model: model, container: container, process: process)
                                }
                            }
                        }
                        HStack {
                            if model.isStoppingSteam(in: container) || processes.contains(where: { $0.executableName == "steam.exe" }) {
                                Button(model.steamQuitTitle(in: container)) { model.quitSteam(in: container) }
                            }
                            if container.platform == .windows {
                                Button("Stop Everything", role: .destructive) { model.stopAll(in: container) }
                            }
                            Spacer()
                            Button("Open Layer Usage") {
                                model.requestedContainerTab = "usage"
                                model.selection = .container(container.id)
                            }
                        }
                    }
                }

                ForEach(model.visibleContainers.filter { $0.platform == .windows }) { container in
                    ContainerCleanupCard(model: model, container: container, showContainerName: true)
                }

                ForEach(machines) { machine in
                    SectionCard(machine.name, systemImage: machine.guest.symbol) {
                        HStack {
                            Text("\(machine.guest.displayName) · \(machine.cpuCount) CPUs · \(machine.memoryMiB / 1024) GB memory")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Show Window") { openWindow(id: "vm", value: machine.id) }
                            Button("Shut Down") { model.shutDown(machine) }
                            Button("Turn Off", role: .destructive) { model.forceStop(machine) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle("Usage")
    }
}

/// Shown when Cell's engine checks found no installed engine that can draw Direct3D 11 games.
struct NoDirect3D11Warning: View {
    let model: AppModel

    var body: some View {
        SectionCard("Games can't draw yet", systemImage: "exclamationmark.triangle") {
            Text("None of the installed engines can show Direct3D 10/11 games — most Windows games use it. DXMT and D3DMetal need a CrossOver-based Wine engine: download the recommended one, or import one from Porting Kit, CrossOver, Whisky or Kegworks.")
                .foregroundStyle(.secondary)
            Button("Open Engines") { model.selection = .engines }
        }
    }
}
