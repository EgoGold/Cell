import SwiftUI
import CellCore

/// First-run setup: one button, Cell downloads and configures everything.
struct SetupView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.setupRunning ? "Setting up Cell…" : "Set up Cell").font(.largeTitle.weight(.bold))
                    Text("Cell downloads and configures everything games need — Wine, the graphics translators, Windows, Steam and the usual runtimes. You don't have to choose anything; Cell picks the right engine for every game when it starts.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    ForEach(model.setupSteps) { step in
                        SetupStepRow(model: model, step: step)
                        if step.id != model.setupSteps.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                HStack(spacing: 12) {
                    if model.setupRunning {
                        ProgressView().controlSize(.small)
                        Text("You can keep using your Mac. Downloads can be paused in Downloads.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Downloads") { model.selection = .downloads }
                    } else if model.setupNeeded {
                        Button {
                            model.runSetup()
                        } label: {
                            Label("Set Up Everything", systemImage: "wand.and.stars").frame(minWidth: 200)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.extraLarge)
                        .keyboardShortcut(.defaultAction)
                        Text(estimate).foregroundStyle(.secondary)
                        Spacer()
                        Button("Later") {
                            model.updateSettings { $0.setupCompleted = true }
                            model.selection = .home
                        }
                    } else {
                        Label("Everything is in place.", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.headline)
                        Spacer()
                        Button("Open Home") { model.selection = .home }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Setup")
        .task { if !model.setupRunning { model.reloadSetup() } }
    }

    private var estimate: String {
        let needed = Set(model.setupSteps.filter { $0.needed && !model.setupSkipped.contains($0.kind) }.map(\.kind))
        var megabytes = 0
        if needed.contains(.downloadWine) { megabytes += Int((Catalog.wineEngines.first(where: \.recommended)?.sizeBytes ?? 0) / 1_000_000) }
        if needed.contains(.downloadDXMT) { megabytes += 19 }
        if needed.contains(.installSteam) { megabytes += 3 }
        if needed.contains(.installRuntimes) { megabytes += 50 }
        return megabytes > 0 ? "About \(megabytes) MB to download." : "Nothing to download."
    }
}

private struct SetupStepRow: View {
    let model: AppModel
    let step: SetupStep

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            icon.frame(width: 24, height: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title).font(.headline).foregroundStyle(step.needed ? .primary : .secondary)
                switch model.setupStatus[step.kind] ?? .pending {
                case .running(let text, let fraction):
                    Text(text).font(.callout).foregroundStyle(Color.accentColor)
                    if let fraction { ProgressView(value: fraction).frame(maxWidth: 420) }
                case .done(let text):
                    Text(text).font(.callout).foregroundStyle(.secondary)
                case .failed(let text):
                    Text(text).font(.callout).foregroundStyle(.red)
                case .pending:
                    Text(step.needed ? step.detail : "Already done.").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if step.needed && !model.setupRunning && model.setupStatus[step.kind] == nil {
                Toggle("", isOn: Binding(
                    get: { !model.setupSkipped.contains(step.kind) },
                    set: { on in if on { model.setupSkipped.remove(step.kind) } else { model.setupSkipped.insert(step.kind) } }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help("Include this step")
            }
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var icon: some View {
        switch model.setupStatus[step.kind] ?? .pending {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .pending:
            if step.needed {
                Image(systemName: model.setupSkipped.contains(step.kind) ? "circle.dashed" : "circle")
                    .foregroundStyle(.secondary).font(.title3)
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).font(.title3)
            }
        }
    }
}
