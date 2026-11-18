import SwiftUI
import CellCore

/// Helps multiplayer games: VPN / proxy apps that swallow UDP, NAT type, firewall, router port mapping.
struct NetworkView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                header
                udpCard
                firewallCard
                portMappingCard
                SectionCard("Steam networking", systemImage: "gamecontroller") {
                    Text("Many games use Steam's relay network, which works without open ports once Steam is fully running. Start games from Cell so Steam is ready first.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .navigationTitle("Network")
        .task {
            model.refreshFirewall()
            if model.networkReport == nil { model.runNetworkTest() }
        }
    }

    // MARK: Header with the one button

    private var problems: [String] {
        var list: [String] = []
        if let report = model.networkReport {
            switch report.verdict {
            case .vpnBlocksUDP: list.append("\(report.vpn?.name ?? "A VPN") drops UDP")
            case .udpBlocked: list.append("UDP is blocked")
            case .good(.strict) where !model.portMappingEverywhere: list.append("Strict NAT")
            default: break
            }
        }
        if model.firewallStatus.state == .on && !model.firewallStatus.wineAllowed { list.append("Firewall blocks Wine") }
        if model.firewallStatus.state == .blockingAll { list.append("Firewall blocks everything") }
        return list
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Network").font(.largeTitle.weight(.bold))
                if model.networkTesting && model.networkReport == nil {
                    Text("Checking how games can reach other players…").foregroundStyle(.secondary)
                } else if problems.isEmpty {
                    Label("Ready for online play", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label(problems.joined(separator: " · "), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                model.fixNetwork()
            } label: {
                Label(model.networkFixing ? "Fixing…" : "Fix Network", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.networkFixing)
            .help("Allows Wine through the firewall, turns on router port mapping if your NAT is strict, tests again, and opens your VPN app if it is the problem.")
        }
    }

    // MARK: UDP / NAT

    private var udpCard: some View {
        SectionCard("Peer-to-peer (UDP)", systemImage: "point.3.connected.trianglepath.dotted") {
            if model.networkTesting {
                ProgressView("Testing with STUN servers in several regions…")
            } else if let report = model.networkReport {
                verdict(report)
                details(report)
            } else {
                Text("Find out whether other players can reach you directly.").foregroundStyle(.secondary)
            }
            Button(model.networkReport == nil ? "Test" : "Test Again") { model.runNetworkTest() }
                .disabled(model.networkTesting)
        }
    }

    @ViewBuilder private func verdict(_ report: NetworkDiagnostics.Report) -> some View {
        switch report.verdict {
        case .good(let nat):
            Label(nat.map { "NAT: \($0.rawValue)" } ?? "UDP works", systemImage: nat == .strict ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.headline).foregroundStyle(nat == .strict ? .orange : .green)
            if let nat { Text(nat.explanation).foregroundStyle(.secondary) }
            if report.vpn != nil {
                Text("Games' traffic goes through \(report.vpn!.name), and UDP gets through it.").font(.caption).foregroundStyle(.secondary)
            }
        case .vpnBlocksUDP(let nat):
            let vpn = report.vpn?.name ?? "Your VPN"
            Label("\(vpn) is dropping UDP", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.orange)
            Text("Everything on this Mac goes through \(vpn), and it throws away UDP — the kind of traffic multiplayer games, voice chat and peer-to-peer lobbies use. Your internet connection itself is fine\(nat.map { " (NAT: \($0.rawValue))" } ?? "").")
                .foregroundStyle(.secondary)
            Text("To play online, do one of these in \(vpn): turn on UDP forwarding / UDP relay for your server, set games (or “Final”) to DIRECT, or pause it while you play. Cell can't change another app's settings.")
                .foregroundStyle(.secondary)
            if report.vpn?.bundleIdentifier != nil {
                Button("Open \(vpn)") { model.openVPNApp() }
            }
        case .vpnFiltersSTUN:
            Label("UDP works", systemImage: "checkmark.circle").font(.headline).foregroundStyle(.green)
            Text("\(report.vpn?.name ?? "Your VPN") lets UDP through but blocks the servers used to measure NAT, so the NAT type is unknown. Games should still connect.")
                .foregroundStyle(.secondary)
        case .udpBlocked:
            Label("UDP is blocked", systemImage: "xmark.octagon").font(.headline).foregroundStyle(.red)
            Text("No UDP gets out, even directly. Networks at schools, offices and some hotels do this; games that need UDP won't connect here.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func details(_ report: NetworkDiagnostics.Report) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let vpn = report.vpn {
                Text("VPN / proxy: \(vpn.name) (\(vpn.interface))")
            }
            if let address = report.games.publicAddress ?? report.direct?.publicAddress {
                Text("Public address: \(address)")
            }
            let answered = (report.games.replies.isEmpty ? report.direct?.replies ?? [] : report.games.replies).map(\.server)
            if !answered.isEmpty {
                Text("Answered: \(answered.joined(separator: ", "))")
            }
        }
        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
    }

    // MARK: Firewall

    private var firewallCard: some View {
        SectionCard("macOS Firewall", systemImage: "flame") {
            let status = model.firewallStatus
            switch status.state {
            case .off:
                Label("The firewall is off. Nothing blocks incoming connections.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .on where status.wineAllowed:
                Label("The firewall is on, and every Wine engine may accept connections.", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .on:
                Label(status.notAllowed.count == status.engineBinaryCount
                      ? "The firewall is on and Wine isn't allowed yet, so other players can't connect to games you host."
                      : "The firewall is on. \(status.notAllowed.count) Wine program\(status.notAllowed.count == 1 ? "" : "s") (new engines or graphics flavors) aren't allowed yet.",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Button("Allow Wine…") { model.allowIncomingConnections() }
                Text("macOS asks for your administrator password once.").font(.caption).foregroundStyle(.secondary)
            case .blockingAll:
                Label("The firewall blocks all incoming connections. Hosting games won't work until you turn off “Block all incoming connections” in System Settings ▸ Network ▸ Firewall ▸ Options.",
                      systemImage: "xmark.octagon").foregroundStyle(.red)
            case .unknown:
                Text("Checking…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Router

    private var portMappingCard: some View {
        SectionCard("Router port mapping", systemImage: "arrow.left.arrow.right") {
            if model.portMappingEverywhere {
                Label("On: while a game runs, Cell asks your router (NAT-PMP, PCP or UPnP) to forward its ports.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Text("While a game runs, Cell can ask your router (NAT-PMP, PCP or UPnP) to forward the game's ports. This helps with a strict NAT. Plugins declare which ports a game needs.")
                    .foregroundStyle(.secondary)
                Button("Turn On for All Containers") { model.enablePortMapping() }
            }
        }
    }
}
