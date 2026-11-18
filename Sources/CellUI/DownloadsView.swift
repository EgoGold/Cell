import SwiftUI
import CellCore

struct DownloadsView: View {
    let model: AppModel
    @State private var showSpeed = false

    var body: some View {
        Group {
            if model.downloads.isEmpty {
                EmptyStateView(title: "No downloads", systemImage: "arrow.down.circle",
                               message: "Engines, graphics layers, Steam and runtimes download here from every server that has them at once, over many connections. You can pause and resume them at any time, even after quitting Cell, and a download that loses its connection carries on by itself.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing) {
                        summary
                        ForEach(model.downloads.reversed()) { download in
                            DownloadRow(model: model, download: download)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 900, alignment: .leading)
                }
            }
        }
        .navigationTitle("Download")
        .toolbar {
            ToolbarItemGroup {
                Button { showSpeed.toggle() } label: { Label("Speed", systemImage: "speedometer") }
                    .help("Connections, mirrors and reconnecting")
                    .popover(isPresented: $showSpeed, arrowEdge: .bottom) { DownloadSpeedSettings(model: model) }
                Button("Clear Finished") { DownloadManager.shared.clearFinished() }
                    .disabled(!model.downloads.contains { !$0.isActive && $0.state != .paused })
            }
        }
    }

    private var summary: some View {
        let active = model.downloads.filter(\.isActive)
        let speed = active.reduce(0) { $0 + $1.bytesPerSecond }
        return HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(active.isEmpty ? "Nothing downloading" : "\(active.count) downloading").font(.headline)
                if !active.isEmpty {
                    Text("\(Int64(speed).byteDescription)/s across \(active.reduce(0) { $0 + $1.activeConnections }) connections")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

struct DownloadRow: View {
    let model: AppModel
    let download: DownloadSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(color)
                Text(download.title).font(.headline)
                Spacer()
                controls
            }
            if download.state != .completed && download.state != .cancelled {
                if let fraction = download.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(detail).font(.caption).foregroundStyle(download.state == .failed ? .red : .secondary).monospacedDigit()
            if download.state == .downloading || download.state == .connecting, download.sources.count > 1 || download.sources.contains(where: { $0.problem != nil }) {
                Text(sourcesLine).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
            }
        }
        .padding(Theme.spacing)
        .background(Theme.subtleBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            switch download.state {
            case .reconnecting:
                Button { DownloadManager.shared.resume(download.id) } label: { Label("Try Now", systemImage: "arrow.clockwise") }
                Button { DownloadManager.shared.pause(download.id) } label: { Label("Pause", systemImage: "pause.fill") }
                Button(role: .destructive) { DownloadManager.shared.cancel(download.id) } label: { Label("Cancel", systemImage: "xmark") }
            case .queued, .connecting, .downloading:
                Button { DownloadManager.shared.pause(download.id) } label: { Label("Pause", systemImage: "pause.fill") }
                Button(role: .destructive) { DownloadManager.shared.cancel(download.id) } label: { Label("Cancel", systemImage: "xmark") }
            case .paused:
                Button { DownloadManager.shared.resume(download.id) } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { DownloadManager.shared.cancel(download.id) } label: { Label("Cancel", systemImage: "xmark") }
            case .failed:
                Button { DownloadManager.shared.resume(download.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { DownloadManager.shared.cancel(download.id) } label: { Label("Remove", systemImage: "trash") }
            case .completed:
                if FileManager.default.fileExists(atPath: download.destination.path) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([download.destination]) } label: { Label("Show", systemImage: "magnifyingglass") }
                }
            case .verifying, .cancelled:
                EmptyView()
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    private var icon: String {
        switch download.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle.fill"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .cancelled: return "xmark.circle"
        case .verifying: return "checkmark.shield"
        default: return "arrow.down.circle"
        }
    }

    private var color: Color {
        switch download.state {
        case .completed: return .green
        case .failed: return .red
        case .paused, .cancelled: return .secondary
        case .reconnecting: return .orange
        default: return .accentColor
        }
    }

    private var detail: String {
        let received = download.receivedBytes.byteDescription
        let total = download.totalBytes > 0 ? download.totalBytes.byteDescription : "?"
        switch download.state {
        case .queued: return "Waiting…"
        case .connecting: return "Connecting… \(received) of \(total)"
        case .downloading:
            let servers = download.sources.filter { $0.connections > 0 }.count
            var parts = ["\(received) of \(total)", "\(Int64(download.bytesPerSecond).byteDescription)/s",
                         "\(download.activeConnections) connection\(download.activeConnections == 1 ? "" : "s")"
                            + (servers > 1 ? " to \(servers) servers" : "")]
            if let seconds = download.secondsRemaining { parts.append(Self.remaining(seconds)) }
            return parts.joined(separator: " · ")
        case .reconnecting:
            let wait = download.retryAt.map { max(0, Int($0.timeIntervalSinceNow.rounded())) } ?? 0
            let when = wait > 0 ? "in \(wait) s" : "now"
            let why = download.error.map { " (\($0))" } ?? ""
            return "Connection lost at \(received) of \(total) — trying again \(when)\(why)"
        case .paused: return "Paused at \(received) of \(total)"
        case .verifying: return "Checking the file…"
        case .completed: return "Done · \(total)"
        case .failed: return download.error ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// "ghfast.top 6× 4.1 MB/s · github.com 2× 20 KB/s (slow) · gh.monlor.com unavailable"
    private var sourcesLine: String {
        download.sources.map { source in
            switch source.health {
            case .unavailable: return "\(source.label) unavailable"
            case .checking: return "\(source.label) checking…"
            case .resting: return "\(source.label) resting"
            case .fast, .slow:
                let speed = source.connections > 0 || source.bytesPerSecond > 0
                    ? " \(source.connections)× \(Int64(source.bytesPerSecond).byteDescription)/s" : " idle"
                return source.label + speed + (source.health == .slow ? " (slow)" : "")
            }
        }.joined(separator: " · ")
    }

    static func remaining(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s left" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min left" }
        return String(format: "%.1f h left", seconds / 3600)
    }
}

/// Download settings, in a popover so they stay usable while downloads run (their list refreshes several
/// times a second, which closes a menu). Changes apply to running downloads at once.
struct DownloadSpeedSettings: View {
    let model: AppModel

    var body: some View {
        let connections = Binding(get: { model.settings.downloadConnections },
                                  set: { value in model.updateSettings { $0.downloadConnections = min(max(value, 1), 32) } })
        let automatic = Binding(get: { model.settings.automaticDownloadConnections },
                                set: { value in model.updateSettings { $0.automaticDownloadConnections = value } })
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections").font(.headline)
                Spacer()
                Button { connections.wrappedValue -= 1 } label: { Image(systemName: "minus") }
                    .disabled(connections.wrappedValue <= 1).help("One connection fewer")
                Text("\(connections.wrappedValue)").monospacedDigit().frame(minWidth: 26)
                Button { connections.wrappedValue += 1 } label: { Image(systemName: "plus") }
                    .disabled(connections.wrappedValue >= 32).help("One connection more")
            }
            Slider(value: Binding(get: { Double(connections.wrappedValue) }, set: { connections.wrappedValue = Int($0.rounded()) }),
                   in: 1...32)
            Toggle("Add more while that makes it faster", isOn: automatic)
            Text(automatic.wrappedValue
                 ? "Downloads start with \(connections.wrappedValue) and grow up to 32."
                 : "Downloads use exactly \(connections.wrappedValue).")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Reconnect when the connection is lost", isOn: Binding(get: { model.settings.reconnectDownloads },
                                                                         set: { value in model.updateSettings { $0.reconnectDownloads = value } }))
            Toggle("Use verified mirrors", isOn: Binding(get: { model.settings.useDownloadMirrors },
                                                         set: { value in model.updateSettings { $0.useDownloadMirrors = value } }))
            Text("A server that only takes a few connections from one Mac keeps the number it allows; the download goes on instead of failing. Mirrors are only used for files whose checksum is known.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 320)
    }
}
