import Darwin
import Foundation
import VPNCore

/// sing-box's routes into the TUN, read from and removed through the
/// kernel's routing socket. sing-box removes them itself when it stops; a
/// sing-box killed outright can leave them, into an interface gone or no
/// longer forwarding. A profile whose addresses macOS sends direct has tens
/// of thousands (the rest of the internet, piece by piece), too many to
/// remove one `route` command at a time.
///
/// They are told apart by their gateway: the TUN's own address
/// (`SingBoxConfig.tunAddress4`/`6`), which no other VPN uses.
enum TunnelRoutes {
    struct Entry: Equatable {
        /// The whole routing message, as the kernel reported it.
        var message: [UInt8]
        var gateway: String?
        var isGatewayRoute: Bool
    }

    static let gateways: Set<String> = [SingBoxConfig.tunAddress4, SingBoxConfig.tunAddress6].map {
        String($0.split(separator: "/")[0])
    }.reduce(into: []) { $0.insert($1) }

    /// The routing table, as the kernel dumps it (no privileges needed).
    static func dump() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            // Room for routes added between the two calls.
            size += size / 8 + 4096
            var buf = [UInt8](repeating: 0, count: size)
            if sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) == 0 { return Array(buf.prefix(size)) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    /// Each route of a dump with its gateway's address.
    static func entries(_ dump: [UInt8]) -> [Entry] {
        var out: [Entry] = []
        var off = 0
        let header = MemoryLayout<rt_msghdr>.size
        while off + header <= dump.count {
            let msg = dump.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: rt_msghdr.self) }
            let len = Int(msg.rtm_msglen)
            guard len >= header, off + len <= dump.count else { break }
            defer { off += len }
            guard msg.rtm_version == RTM_VERSION else { continue }
            let bytes = Array(dump[off..<(off + len)])
            out.append(Entry(message: bytes, gateway: address(bytes, header: header, addrs: msg.rtm_addrs, index: RTAX_GATEWAY),
                             isGatewayRoute: msg.rtm_flags & RTF_GATEWAY != 0))
        }
        return out
    }

    /// The `index`th address of a routing message, as text (IPv4 or IPv6
    /// only).
    static func address(_ msg: [UInt8], header: Int, addrs: Int32, index: Int32) -> String? {
        var off = header
        for i in 0..<RTAX_MAX {
            guard addrs & (1 << i) != 0 else { continue }
            guard off < msg.count else { return nil }
            let saLen = Int(msg[off])
            if i == index {
                let family = Int32(msg[off + 1])
                if family == AF_INET, saLen >= MemoryLayout<sockaddr_in>.size, off + saLen <= msg.count {
                    var a = in_addr()
                    withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: msg[(off + 4)..<(off + 8)]) }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    return inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)).map { _ in SystemNetwork.cString(buf) }
                }
                if family == AF_INET6, saLen >= MemoryLayout<sockaddr_in6>.size, off + saLen <= msg.count {
                    var a = in6_addr()
                    withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: msg[(off + 8)..<(off + 24)]) }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    return inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)).map { _ in SystemNetwork.cString(buf) }
                }
                return nil
            }
            // Each address takes its length rounded up to 4 bytes; an empty
            // one, 4.
            off += saLen > 0 ? (saLen + 3) & ~3 : 4
        }
        return nil
    }

    /// The routes through the TUN's own address.
    static func ours(_ entries: [Entry]) -> [Entry] {
        entries.filter { $0.isGatewayRoute && $0.gateway.map(gateways.contains) == true }
    }

    /// Removes sing-box's routes; returns how many went. Root only.
    @discardableResult
    static func removeAll() -> Int {
        guard let table = dump() else { return 0 }
        let routes = ours(entries(table))
        guard !routes.isEmpty else { return 0 }
        let fd = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        // Nothing to read back: only replies to our own messages would come.
        shutdown(fd, SHUT_RD)
        var removed = 0
        for (seq, route) in routes.enumerated() {
            // The route as dumped, sent back as a request to delete it.
            var msg = route.message
            msg.withUnsafeMutableBytes { raw in
                var h = raw.loadUnaligned(as: rt_msghdr.self)
                h.rtm_type = UInt8(RTM_DELETE)
                h.rtm_seq = Int32(truncatingIfNeeded: seq + 1)
                h.rtm_pid = 0
                h.rtm_errno = 0
                raw.storeBytes(of: h, as: rt_msghdr.self)
            }
            if msg.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == msg.count { removed += 1 }
        }
        return removed
    }
}
