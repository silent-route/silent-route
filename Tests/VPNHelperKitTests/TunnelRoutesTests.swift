import Darwin
import Foundation
import Testing
@testable import VPNHelperKit
import VPNCore

/// sing-box's routes, told apart by their gateway (the TUN's own address).
/// Reading the table needs no privileges; removing is left to the
/// integration run.
@Suite struct TunnelRoutesTests {
    @Test func readsTheRoutingTable() throws {
        let dump = try #require(TunnelRoutes.dump())
        let entries = TunnelRoutes.entries(dump)
        #expect(!entries.isEmpty)
        // Every message accounted for, whole.
        #expect(entries.reduce(0) { $0 + $1.message.count } == dump.count)
        // A Mac on a network has gateway routes with an address it can read.
        if entries.contains(where: \.isGatewayRoute) {
            #expect(entries.contains { $0.isGatewayRoute && $0.gateway != nil })
        }
        // Ours, if the VPN is on here, go through the TUN's own address.
        for r in TunnelRoutes.ours(entries) { #expect(TunnelRoutes.gateways.contains(r.gateway ?? "")) }
    }

    @Test func oursAreThoseThroughTheTunnelsOwnAddress() {
        #expect(TunnelRoutes.gateways == ["172.19.0.5", "fdfe:dcba:9876::5"])
        func entry(_ gw: String?, gateway: Bool = true) -> TunnelRoutes.Entry {
            .init(message: [], gateway: gw, isGatewayRoute: gateway)
        }
        let all = [entry("172.19.0.5"), entry("fdfe:dcba:9876::5"), entry("172.19.0.1"), entry("192.168.1.1"),
                   entry(nil), entry("172.19.0.5", gateway: false)]
        #expect(TunnelRoutes.ours(all) == [all[0], all[1]])
    }

    /// A routing message's addresses, each rounded up to 4 bytes.
    @Test func readsAGatewayAfterTheDestination() {
        let header = MemoryLayout<rt_msghdr>.size
        var msg = [UInt8](repeating: 0, count: header)
        // Destination 198.51.100.0 (sockaddr_in, 16 bytes), then gateway
        // fdfe:dcba:9876::5 (sockaddr_in6, 28 bytes, padded to 28).
        msg += [16, UInt8(AF_INET), 0, 0, 198, 51, 100, 0] + [UInt8](repeating: 0, count: 8)
        var six = [UInt8](repeating: 0, count: 28)
        six[0] = 28; six[1] = UInt8(AF_INET6)
        let addr: [UInt8] = [0xfd, 0xfe, 0xdc, 0xba, 0x98, 0x76, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5]
        six.replaceSubrange(8..<24, with: addr)
        msg += six
        let addrs = Int32(RTA_DST | RTA_GATEWAY)
        #expect(TunnelRoutes.address(msg, header: header, addrs: addrs, index: RTAX_DST) == "198.51.100.0")
        #expect(TunnelRoutes.address(msg, header: header, addrs: addrs, index: RTAX_GATEWAY) == "fdfe:dcba:9876::5")
        #expect(TunnelRoutes.address(Array(msg.prefix(header + 20)), header: header, addrs: addrs, index: RTAX_GATEWAY) == nil)
    }
}
