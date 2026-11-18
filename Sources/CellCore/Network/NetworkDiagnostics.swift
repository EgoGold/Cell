import Foundation
import SystemConfiguration

/// Finds out what stands between multiplayer games and other players: VPN / proxy apps that swallow UDP,
/// the router's NAT type, and the firewall (see `FirewallHelper`).
///
/// Games' UDP is tested twice when a VPN is on: the way games send it (through the VPN) and directly
/// over Wi-Fi/Ethernet, so Cell can tell "your VPN drops UDP" apart from "your network blocks UDP".
/// STUN servers from several regions (including mainland China) are asked in parallel.
public enum NetworkDiagnostics {
    public enum NATType: String, Sendable {
        case open = "Open"
        case moderate = "Moderate"
        case strict = "Strict"

        public var explanation: String {
            switch self {
            case .open: return "Your Mac is directly reachable. Hosting and joining both work."
            case .moderate: return "Peer-to-peer works: your router keeps the same public port for every player."
            case .strict: return "Your router gives every player a different port, so direct connections often fail and games fall back to slower relays. Router port mapping helps."
            }
        }
    }

    public struct VPN: Hashable, Sendable {
        /// "Shadowrocket", or a generic name when the app couldn't be identified.
        public var name: String
        public var bundleIdentifier: String?
        public var interface: String
    }

    /// One UDP path's results.
    public struct PathResult: Sendable {
        /// "server → your public address" for every STUN server that answered.
        public var replies: [(server: String, mapped: String)]
        /// Plain UDP (a time-server query) got an answer.
        public var plainUDPWorks: Bool
        public var nat: NATType?

        public var stunWorks: Bool { !replies.isEmpty }
        public var udpWorks: Bool { stunWorks || plainUDPWorks }
        public var publicAddress: String? { replies.first?.mapped }
    }

    public enum Verdict: Sendable {
        /// UDP works for games; the NAT type.
        case good(NATType?)
        /// The VPN drops games' UDP; the network itself is fine (NAT type measured directly).
        case vpnBlocksUDP(NATType?)
        /// UDP gets through the VPN but STUN is filtered (privacy rules); games mostly work.
        case vpnFiltersSTUN
        /// No UDP at all, even directly.
        case udpBlocked
    }

    public struct Report: Sendable {
        public var vpn: VPN?
        public var physicalInterface: String?
        /// What games get (default route, system DNS).
        public var games: PathResult
        /// Bypassing the VPN (only measured when a VPN is on).
        public var direct: PathResult?

        public var verdict: Verdict {
            if games.stunWorks { return .good(games.nat) }
            if vpn != nil, games.plainUDPWorks { return .vpnFiltersSTUN }
            if vpn != nil, let direct, direct.udpWorks { return .vpnBlocksUDP(direct.nat) }
            if games.plainUDPWorks { return .good(nil) }
            return .udpBlocked
        }
    }

    /// STUN servers in several regions; mainland China ones answer where Google's are blocked.
    public static let stunServers: [(host: String, port: UInt16)] = [
        ("stun.miwifi.com", 3478), ("stun.chat.bilibili.com", 3478), ("stun.cloudflare.com", 3478),
        ("stun.l.google.com", 19302), ("stun1.l.google.com", 19302), ("global.stun.twilio.com", 3478),
        ("stun.nextcloud.com", 3478),
    ]
    static let timeServers = ["time.apple.com", "ntp.aliyun.com", "pool.ntp.org"]
    static let fallbackDNS = ["223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8"]

    public static func run() async -> Report {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: runBlocking()) }
        }
    }

    static func runBlocking() -> Report {
        let network = currentNetwork()
        let games = testPath(boundTo: nil, dnsServers: [])
        var direct: PathResult?
        if network.vpn != nil, let physical = network.physical {
            direct = testPath(boundTo: physical, dnsServers: network.physicalDNS + fallbackDNS)
        }
        return Report(vpn: network.vpn, physicalInterface: network.physical, games: games, direct: direct)
    }

    // MARK: Which network

    struct NetworkState {
        var vpn: VPN?
        var physical: String?
        var physicalDNS: [String]
    }

    static func currentNetwork() -> NetworkState {
        var state = NetworkState(vpn: nil, physical: nil, physicalDNS: [])
        guard let store = SCDynamicStoreCreate(nil, "Cell" as CFString, nil, nil) else { return state }
        let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?["PrimaryInterface"] as? String

        let keys = (SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String]) ?? []
        var candidates: [(interface: String, service: String)] = []
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let interface = value["InterfaceName"] as? String, value["Router"] != nil, isPhysical(interface) else { continue }
            let service = key.components(separatedBy: "/").dropLast().last ?? ""
            candidates.append((interface, service))
        }
        candidates.sort { $0.interface < $1.interface }
        if let best = candidates.first(where: { $0.interface == primary }) ?? candidates.first {
            state.physical = best.interface
            let dns = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(best.service)/DNS" as CFString) as? [String: Any]
            state.physicalDNS = (dns?["ServerAddresses"] as? [String] ?? []).filter { !$0.contains(":") && !$0.hasPrefix("198.18.") }
        }
        if let primary, isTunnel(primary) {
            let named = connectedVPNs().first
            state.vpn = VPN(name: named?.name ?? "A VPN or proxy app", bundleIdentifier: named?.bundleIdentifier, interface: primary)
        }
        return state
    }

    static func isTunnel(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap", "wg"].contains { interface.hasPrefix($0) }
    }

    static func isPhysical(_ interface: String) -> Bool {
        !isTunnel(interface) && !["bridge", "awdl", "llw", "lo", "anpi", "ap"].contains { interface.hasPrefix($0) }
    }

    /// Connected VPN services from `scutil --nc list`, e.g.
    /// `* (Connected)  UUID VPN (com.liguangming.Shadowrocket) "Shadowrocket"  [VPN:com.liguangming.Shadowrocket]`.
    static func connectedVPNs() -> [(name: String, bundleIdentifier: String?)] {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/scutil"), arguments: ["--nc", "list"], timeout: 10) else { return [] }
        return parseServiceList(result.combinedOutput)
    }

    static func parseServiceList(_ text: String) -> [(name: String, bundleIdentifier: String?)] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard line.contains("(Connected)"), let open = line.firstIndex(of: "\""),
                  let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
            let name = String(line[line.index(after: open)..<close])
            var bundle: String?
            if let start = line.range(of: "[VPN:"), let end = line[start.upperBound...].firstIndex(of: "]") {
                bundle = String(line[start.upperBound..<end])
            }
            return (name, bundle)
        }
    }

    // MARK: UDP tests

    static func testPath(boundTo interface: String?, dnsServers: [String]) -> PathResult {
        let index = interface.map { if_nametoindex($0) } ?? 0
        func resolve(_ host: String) -> in_addr? {
            if interface != nil { return dnsLookup(host, servers: dnsServers, interfaceIndex: index) }
            return systemLookup(host)
        }
        var targets: [(label: String, address: sockaddr_in)] = []
        for (host, port) in stunServers {
            guard let ip = resolve(host) else { continue }
            targets.append((host, socketAddress(ip, port: port)))
        }
        let replies = stun(targets, interfaceIndex: index)
        var plain = false
        if replies.isEmpty {
            let times = timeServers.compactMap { resolve($0).map { socketAddress($0, port: 123) } }
            plain = ntpAnswers(times, interfaceIndex: index)
        }
        let localPort = replies.first?.localPort ?? 0
        var nat: NATType?
        let mapped = replies.map(\.mapped)
        if let first = mapped.first {
            if localIPv4Addresses().contains(first.address), first.port == localPort {
                nat = .open
            } else if Set(replies.map(\.serverAddress)).count >= 2 {
                nat = mapped.allSatisfy { $0 == first } ? .moderate : .strict
            }
        }
        return PathResult(replies: replies.map { ($0.server, "\($0.mapped.address):\($0.mapped.port)") },
                          plainUDPWorks: plain || !replies.isEmpty, nat: nat)
    }

    struct Endpoint: Hashable { var address: String; var port: UInt16 }
    struct StunReply { var server: String; var serverAddress: String; var mapped: Endpoint; var localPort: UInt16 }

    static func socketAddress(_ ip: in_addr, port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = ip
        return address
    }

    static func makeSocket(interfaceIndex: UInt32, timeout: TimeInterval) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        if interfaceIndex != 0 {
            var index = interfaceIndex
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = timeout
        return fd
    }

    static func send(_ fd: Int32, _ bytes: [UInt8], to address: sockaddr_in) {
        var target = address
        _ = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    /// Sends a STUN binding request to every server from one socket (so the mapped ports can be compared)
    /// and collects the answers for up to 2.5 seconds.
    static func stun(_ targets: [(label: String, address: sockaddr_in)], interfaceIndex: UInt32, timeout: TimeInterval = 2.5) -> [StunReply] {
        guard !targets.isEmpty, let fd = makeSocket(interfaceIndex: interfaceIndex, timeout: timeout) else { return [] }
        defer { close(fd) }
        var transactions: [[UInt8]: (label: String, address: String)] = [:]
        for target in targets {
            var request: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42]
            let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
            request += transaction
            transactions[transaction] = (target.label, String(cString: inet_ntoa(target.address.sin_addr)))
            send(fd, request, to: target.address)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        let localPort = UInt16(bigEndian: bound.sin_port)

        var replies: [StunReply] = []
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 1500)
        var resent = false
        while Date() < deadline && replies.count < targets.count {
            let received = recv(fd, &buffer, buffer.count, 0)
            if received < 20 {
                // UDP can drop the first packet; ask once more halfway through.
                if !resent && Date() > deadline.addingTimeInterval(-timeout / 2) {
                    resent = true
                    for (transaction, target) in transactions where !replies.contains(where: { $0.server == target.label }) {
                        if let match = targets.first(where: { $0.label == target.label }) {
                            send(fd, [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + transaction, to: match.address)
                        }
                    }
                }
                continue
            }
            let packet = Array(buffer[0..<received])
            guard packet[0] == 0x01, packet[1] == 0x01, let target = transactions[Array(packet[8..<20])],
                  !replies.contains(where: { $0.server == target.label }),
                  let mapped = mappedAddress(in: packet) else { continue }
            replies.append(StunReply(server: target.label, serverAddress: target.address, mapped: mapped, localPort: localPort))
        }
        return replies
    }

    /// XOR-MAPPED-ADDRESS (or the older MAPPED-ADDRESS) from a STUN binding response.
    static func mappedAddress(in packet: [UInt8]) -> Endpoint? {
        var offset = 20
        var fallback: Endpoint?
        while offset + 4 <= packet.count {
            let type = UInt16(packet[offset]) << 8 | UInt16(packet[offset + 1])
            let length = Int(UInt16(packet[offset + 2]) << 8 | UInt16(packet[offset + 3]))
            let value = offset + 4
            guard value + length <= packet.count else { break }
            if (type == 0x0020 || type == 0x0001), length >= 8, packet[value + 1] == 0x01 {
                var port = UInt16(packet[value + 2]) << 8 | UInt16(packet[value + 3])
                var bytes = Array(packet[(value + 4)..<(value + 8)])
                if type == 0x0020 {
                    port ^= 0x2112
                    let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
                    for i in 0..<4 { bytes[i] ^= cookie[i] }
                    return Endpoint(address: bytes.map(String.init).joined(separator: "."), port: port)
                }
                fallback = Endpoint(address: bytes.map(String.init).joined(separator: "."), port: port)
            }
            offset = value + ((length + 3) & ~3)
        }
        return fallback
    }

    /// Whether any time server answers an NTP query (plain UDP, nothing STUN-specific).
    static func ntpAnswers(_ servers: [sockaddr_in], interfaceIndex: UInt32) -> Bool {
        guard !servers.isEmpty, let fd = makeSocket(interfaceIndex: interfaceIndex, timeout: 2) else { return false }
        defer { close(fd) }
        let request: [UInt8] = [0x1b] + [UInt8](repeating: 0, count: 47)
        for server in servers { send(fd, request, to: server) }
        var buffer = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if recv(fd, &buffer, buffer.count, 0) >= 48 { return true }
        }
        return false
    }

    static func systemLookup(_ host: String) -> in_addr? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result, let addr = info.pointee.ai_addr else { return nil }
        defer { freeaddrinfo(result) }
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    /// A DNS A-record lookup sent over a specific interface, so a VPN's made-up addresses don't get in the way.
    static func dnsLookup(_ host: String, servers: [String], interfaceIndex: UInt32) -> in_addr? {
        var query: [UInt8] = [UInt8.random(in: 0...255), UInt8.random(in: 0...255), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            query.append(UInt8(label.utf8.count))
            query += Array(label.utf8)
        }
        query += [0x00, 0x00, 0x01, 0x00, 0x01]
        for server in servers {
            var address = in_addr()
            guard inet_pton(AF_INET, server, &address) == 1, let fd = makeSocket(interfaceIndex: interfaceIndex, timeout: 1.5) else { continue }
            defer { close(fd) }
            send(fd, query, to: socketAddress(address, port: 53))
            var buffer = [UInt8](repeating: 0, count: 1500)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                let received = recv(fd, &buffer, buffer.count, 0)
                guard received > 12, buffer[0] == query[0], buffer[1] == query[1] else { continue }
                if let ip = firstARecord(Array(buffer[0..<received])) { return ip }
                break
            }
        }
        return nil
    }

    static func firstARecord(_ packet: [UInt8]) -> in_addr? {
        guard packet.count > 12 else { return nil }
        let questions = Int(packet[4]) << 8 | Int(packet[5])
        let answers = Int(packet[6]) << 8 | Int(packet[7])
        var offset = 12
        func skipName() {
            while offset < packet.count {
                let length = Int(packet[offset])
                if length == 0 { offset += 1; return }
                if length & 0xC0 == 0xC0 { offset += 2; return }
                offset += length + 1
            }
        }
        for _ in 0..<questions { skipName(); offset += 4 }
        for _ in 0..<answers {
            skipName()
            guard offset + 10 <= packet.count else { return nil }
            let type = Int(packet[offset]) << 8 | Int(packet[offset + 1])
            let length = Int(packet[offset + 8]) << 8 | Int(packet[offset + 9])
            offset += 10
            guard offset + length <= packet.count else { return nil }
            if type == 1, length == 4 {
                return in_addr(s_addr: UInt32(packet[offset]) | UInt32(packet[offset + 1]) << 8
                               | UInt32(packet[offset + 2]) << 16 | UInt32(packet[offset + 3]) << 24)
            }
            offset += length
        }
        return nil
    }

    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return [] }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.append(String(cString: host))
                }
            }
            pointer = current.pointee.ifa_next
        }
        return addresses
    }
}
