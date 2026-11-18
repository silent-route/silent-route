import Foundation
import Testing
import VPNCore
@testable import SilentRouteUI
@testable import VPNRuntime

@Suite struct RouteAdditionTests {
    let telegram = TrafficMonitor.app("/Applications/Telegram.app/Contents/MacOS/Telegram (user)")

    @Test func appBecomesItsBundleOrProgram() {
        #expect(RouteAddition.matcher(for: telegram) == .bundle(path: "/Applications/Telegram.app"))
        #expect(RouteAddition.matcher(for: TrafficMonitor.app("/usr/bin/curl")) == .executable(path: "/usr/bin/curl"))
        #expect(RouteAddition.matcher(for: TrafficMonitor.app("")) == nil)
    }

    @Test func hostChoices() {
        #expect(RouteAddition.destinations(forHost: "rr1.googlevideo.com") ==
                [.domainSuffix("rr1.googlevideo.com"), .domainSuffix("googlevideo.com"), .domain("rr1.googlevideo.com")])
        // A country's company zone is not offered on its own.
        #expect(RouteAddition.destinations(forHost: "www.bbc.co.uk") ==
                [.domainSuffix("www.bbc.co.uk"), .domainSuffix("bbc.co.uk"), .domain("www.bbc.co.uk")])
        #expect(RouteAddition.destinations(forHost: "149.154.167.51") == [.cidr(IPNetwork("149.154.167.51/32")!)])
        #expect(RouteAddition.destinations(forHost: "?").isEmpty)
        #expect(RouteAddition.suggested(RouteAddition.destinations(forHost: "rr1.googlevideo.com")) == .domainSuffix("googlevideo.com"))
    }

    @Test func newRouteGoesFirst() throws {
        let p = Profile(name: "P", routes: [Route(name: "Old", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)])
        let item = RouteAddition.Item.app(.bundle(path: "/Applications/Telegram.app"))
        let out = try #require(RouteAddition.apply(item, to: .new(name: "Telegram", target: .block), in: p))
        #expect(out.routes.map(\.name) == ["Telegram", "Old"])
        #expect(out.routes[0].conditions.apps == [.bundle(path: "/Applications/Telegram.app")])
        #expect(out.routes[0].target == .block)
    }

    @Test func addingToAnExistingRoute() throws {
        let r = Route(name: "Sites", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)
        let p = Profile(name: "P", routes: [r])
        let site = RouteAddition.Item.destination(.domainSuffix("b.com"))
        let out = try #require(RouteAddition.apply(site, to: .existing(r.id), in: p))
        #expect(out.routes[0].conditions.destinations == [.domainSuffix("a.com"), .domainSuffix("b.com")])
        #expect(RouteAddition.contains(out.routes[0], site))
        #expect(!RouteAddition.narrows(r, site))
        // "Everything else" and gone routes take nothing.
        #expect(RouteAddition.apply(site, to: .existing(p.defaultRoute.id), in: p) == nil)
        #expect(RouteAddition.apply(site, to: .existing(UUID()), in: p) == nil)
    }

    /// An app added to a route of sites simply joins it; only ports or a
    /// protocol narrow what is added — said before adding.
    @Test func narrowingIsNoticed() {
        let sites = Route(name: "Sites", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)
        let app = RouteAddition.Item.app(.executable(path: "/usr/bin/curl"))
        #expect(!RouteAddition.narrows(sites, app))
        var tcp = sites
        tcp.conditions.network = .tcp
        #expect(RouteAddition.narrows(tcp, app))
        var ports = sites
        ports.conditions.ports = [PortRange(443)]
        #expect(RouteAddition.narrows(ports, app))
    }
}

@Suite struct RouteSummaryTests {
    @Test func summary() {
        let both = Conditions(destinations: [.domainSuffix("de")], apps: [.bundle(path: "/Applications/Remote Desktop.app")])
        #expect(RouteSummary.conditions(both) == "de · apps: Remote Desktop")
        #expect(RouteSummary.conditions(Conditions()) == "nothing yet")
    }
}

@Suite struct ServerCopyTests {
    /// Into a profile (or the library) as a new server of its own.
    @Test func copyHasItsOwnIdAndAFreeName() {
        let a = Tunnel(name: "NL", server: Endpoint(host: "a.example", port: 443), proto: .proxy(Proxy(kind: .socks5)))
        let c = ServerCopy.copy(a, among: [a])
        #expect(c.id != a.id && c.name == "NL 2" && c.server == a.server)
        #expect(ServerCopy.copy(a, among: []).name == "NL")
    }
}

/// A failed server check says what sing-box saw, not macOS's "bad URL".
@Suite struct ProbeReasonTests {
    @Test func lastConnectionError() {
        let log = """
        INFO[0000] sing-box started (0.01s)
        ERROR[0002] [344241730 596ms] connection: open connection to ipinfo.io:443 using outbound/socks[probe]: dial tcp 192.0.2.1:1080: i/o timeout
        """
        #expect(Probe.reason(inLog: log) == "dial tcp 192.0.2.1:1080: i/o timeout")
        #expect(Probe.reason(inLog: "ERROR[0002] [1 5ms] connection: open connection to ipinfo.io:443 using outbound/socks[probe]: EOF")
                == "the connection was closed (EOF)")
        #expect(Probe.reason(inLog: "INFO[0000] sing-box started") == nil)
    }
}
