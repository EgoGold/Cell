import Foundation
import dnssd

/// Opens router ports with NAT-PMP / PCP (via mDNSResponder) while a game runs.
public final class PortMapper: @unchecked Sendable {
    public struct Mapping: Hashable, Sendable {
        public var request: PortMapping
        public var externalPort: UInt16?
        public var externalAddress: String?
        public var error: Int32?
    }

    private var references: [DNSServiceRef] = []
    private let queue = DispatchQueue(label: "cell.portmapper")
    public private(set) var mappings: [Mapping] = []
    public var onUpdate: (([Mapping]) -> Void)?

    public init() {}

    deinit { unmapAll() }

    public func map(_ ports: [PortMapping], lifetime: UInt32 = 7200) {
        queue.sync {
            for port in ports {
                var reference: DNSServiceRef?
                let proto = UInt32(port.proto == .udp ? kDNSServiceProtocol_UDP : kDNSServiceProtocol_TCP)
                let context = Unmanaged.passUnretained(self).toOpaque()
                let error = DNSServiceNATPortMappingCreate(&reference, 0, 0, proto, port.port.bigEndian, port.port.bigEndian,
                                                           lifetime, PortMapper.callback, context)
                mappings.append(Mapping(request: port, externalPort: nil, externalAddress: nil,
                                        error: error == kDNSServiceErr_NoError ? nil : error))
                if error == kDNSServiceErr_NoError, let reference {
                    DNSServiceSetDispatchQueue(reference, queue)
                    references.append(reference)
                }
            }
        }
    }

    public func unmapAll() {
        queue.sync {
            for reference in references { DNSServiceRefDeallocate(reference) }
            references.removeAll()
            mappings.removeAll()
        }
    }

    private static let callback: DNSServiceNATPortMappingReply = { _, _, _, error, externalAddress, proto, internalPort, externalPort, _, context in
        guard let context else { return }
        let mapper = Unmanaged<PortMapper>.fromOpaque(context).takeUnretainedValue()
        let port = UInt16(bigEndian: internalPort)
        let protocolKind: NetworkProtocol = proto == UInt32(kDNSServiceProtocol_TCP) ? .tcp : .udp
        if let index = mapper.mappings.firstIndex(where: { $0.request.port == port && $0.request.proto == protocolKind }) {
            mapper.mappings[index].error = error == kDNSServiceErr_NoError ? nil : error
            mapper.mappings[index].externalPort = UInt16(bigEndian: externalPort)
            var address = in_addr(s_addr: externalAddress)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN))
            mapper.mappings[index].externalAddress = String(cString: buffer)
        }
        mapper.onUpdate?(mapper.mappings)
    }
}

