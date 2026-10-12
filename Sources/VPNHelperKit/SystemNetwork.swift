import Foundation
import VPNCore

public struct SystemNetwork: NetworkInspector {
    public init() {}

    /// The interface carrying sing-box's TUN address.
    public func tunInterface() async -> String? {
        let want = SingBoxConfig.tunAddress4.split(separator: "/")[0]
        return Self.interfaces().first { $0.address == want }?.name
    }

    /// Another VPN owns the route to the internet. Only asked before our own
    /// sing-box starts, so any utun on that route belongs to someone else.
    /// (auto_route installs two /1 routes rather than a default, so the
    /// default route is not the thing to look at.)
    public func foreignTunnel() async -> String? {
        guard let iface = await Self.routeInterface(for: "1.1.1.1"), iface.hasPrefix("utun") else { return nil }
        return iface
    }

    public func restoreRouting() async {
        // Put the default route back through the physical gateway, but only
        // if the route to the internet is broken or still ours. A live utun
        // of another VPN is that VPN's business: rebuilding routes under it
        // cuts its traffic (an integration run once did exactly that).
        let iface = await Self.routeInterface(for: "1.1.1.1")
        let tun = await tunInterface()
        let repair = Self.needsRouteRepair(routeInterface: iface,
                                           interfaceExists: iface.map { if_nametoindex($0) != 0 } ?? false,
                                           isOurTUN: iface != nil && iface == tun)
        if repair, let gw = await Self.physicalGateway() {
            await Command.run("/sbin/route", ["-n", "delete", "-net", "0.0.0.0/1"])
            await Command.run("/sbin/route", ["-n", "delete", "-net", "128.0.0.0/1"])
            await Command.run("/sbin/route", ["-n", "delete", "default"])
            await Command.run("/sbin/route", ["-n", "add", "default", gw])
        }
        await Command.run("/usr/bin/dscacheutil", ["-flushcache"])
        await Command.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }

    /// Whether panic may rebuild the default route: no route at all, a route
    /// into an interface that no longer exists, or into our own TUN.
    static func needsRouteRepair(routeInterface: String?, interfaceExists: Bool, isOurTUN: Bool) -> Bool {
        guard let iface = routeInterface else { return true }
        guard iface.hasPrefix("utun") else { return false }
        return !interfaceExists || isOurTUN
    }

    // MARK: helpers

    struct Interface { var name: String; var address: String }

    static func interfaces() -> [Interface] {
        var out: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ok = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                return inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil
            }
            if ok { out.append(Interface(name: String(cString: p.pointee.ifa_name), address: cString(buf))) }
        }
        return out
    }

    static func cString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func routeInterface(for address: String) async -> String? {
        let r = await Command.run("/sbin/route", ["-n", "get", address], timeout: 5)
        return r.text.split(separator: "\n")
            .first { $0.contains("interface:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    /// The router of the primary physical interface, from DHCP.
    static func physicalGateway() async -> String? {
        for iface in ["en0", "en1", "en2", "en3", "en4", "en5"] {
            let r = await Command.run("/usr/sbin/ipconfig", ["getoption", iface, "router"], timeout: 5)
            let gw = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok, let net = IPNetwork(gw), net.family == .v4, net.prefix == 32 { return gw }
        }
        return nil
    }

    static func processRunning(_ names: [String]) -> Bool {
        // Best effort, used only to word an error message.
        let r = Process()
        r.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        r.arguments = ["-x", names.joined(separator: "|")]
        r.standardOutput = FileHandle.nullDevice
        r.standardError = FileHandle.nullDevice
        do { try r.run(); r.waitUntilExit() } catch { return false }
        return r.terminationStatus == 0
    }
}

public final class FileStateStore: StateStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func load() -> PersistedState? {
        lock.withLock {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PersistedState.self, from: d)
        }
    }

    public func save(_ s: PersistedState) {
        lock.withLock {
            guard let d = try? JSONEncoder().encode(s) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }
}

public struct SystemClock: Clock {
    public init() {}
    public func sleep(seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    public func now() -> Date { Date() }
    public func bootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }
}
