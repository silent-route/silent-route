import Foundation
import Testing
@testable import VPNCore

/// A route that goes direct by address is left to macOS's routing table,
/// which decides every packet by where it goes (`SingBoxConfig.systemDirect`).
@Suite struct SystemDirectTests {
    static let siteID = UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!
    static let blockID = UUID(uuidString: "00000000-0000-0000-0000-0000000000e2")!
    static let country = [IPNetwork("198.51.100.0/24")!, IPNetwork("2001:db8:100::/48")!]

    /// Like the example's: a site through a server above the domestic
    /// route (its lists of addresses and of sites, and a zone).
    static var profile: Profile {
        var p = Profile.example(tunnels: [Fixtures.h2, Fixtures.vless])
        p.defaultRoute = Route(id: Fixtures.defaultRouteID, name: "Everything else", target: .servers([Fixtures.h2ID]))
        p.routes.insert(Route(id: siteID, name: "Video",
                              conditions: Conditions(destinations: [.domainSuffix("video.example"), .domainKeyword("vid")]),
                              target: .servers([Fixtures.vlessID])), at: 0)
        return p
    }

    /// The helper's lists, with what it knows of their addresses.
    static func env(_ base: SingBoxConfig.Environment = Fixtures.env) -> SingBoxConfig.Environment {
        var e = base
        for (url, var list) in e.lists {
            list.addresses = url == Profile.domesticLists[0].url ? country : []
            e.lists[url] = list
        }
        return e
    }

    // MARK: Networks

    @Test func subtracting() {
        let n = IPNetwork("10.0.0.0/8")!
        #expect(n.subtracting(IPNetwork("192.0.2.0/24")!) == [n])
        #expect(n.subtracting(IPNetwork("10.0.0.0/7")!) == [])
        #expect(n.subtracting(n) == [])
        #expect(n.subtracting(IPNetwork("2001:db8::/32")!) == [n])
        let left = n.subtracting(IPNetwork("10.1.2.0/24")!)
        #expect(left.count == 16)
        #expect(left.contains(IPNetwork("10.128.0.0/9")!) && left.contains(IPNetwork("10.1.3.0/24")!))
        #expect(!left.contains { $0.contains(IPNetwork("10.1.2.7")!) })
        // Together they cover everything else in it, once.
        let hosts = (0..<256).map { IPNetwork("10.1.\($0).1")! }
        for h in hosts where h != IPNetwork("10.1.2.1")! { #expect(left.filter { $0.contains(h) }.count == 1) }
        #expect(IPNetwork("2001:db8::/32")!.subtracting(IPNetwork("2001:db8:8000::/33")!) == [IPNetwork("2001:db8::/33")!])
    }

    // MARK: A list's addresses

    func src(_ rules: String) -> Data { Data(#"{"version":3,"rules":[\#(rules)]}"#.utf8) }

    @Test func listAddresses() {
        #expect(RuleLists.addresses(src(#"{"domain_suffix":["a.example"]}"#)) == [])
        #expect(RuleLists.addresses(src(#"{"ip_cidr":["198.51.100.0/24","2001:db8::/32"]},{"domain":["b.example"]}"#))
                == [IPNetwork("198.51.100.0/24")!, IPNetwork("2001:db8::/32")!])
        // One network, as sing-box writes it back.
        #expect(RuleLists.addresses(src(#"{"ip_cidr":"192.0.2.0/24"}"#)) == [IPNetwork("192.0.2.0/24")!])
        // Names and addresses in one rule match either: its addresses alone.
        #expect(RuleLists.addresses(src(#"{"domain":["c.example"],"ip_cidr":["192.0.2.0/24"]}"#)) == [IPNetwork("192.0.2.0/24")!])
        // Tied to what only sing-box can see: the list is left to it.
        #expect(RuleLists.addresses(src(#"{"ip_cidr":["192.0.2.0/24"],"port":[443]}"#)) == nil)
        #expect(RuleLists.addresses(src(#"{"ip_cidr":["192.0.2.0/24"],"invert":true}"#)) == nil)
        #expect(RuleLists.addresses(src(#"{"type":"logical","mode":"and","rules":[{"ip_cidr":["192.0.2.0/24"]},{"domain":["d.example"]}]}"#)) == nil)
        #expect(RuleLists.addresses(src(#"{"ip_is_private":true}"#)) == nil)
        // Nothing but a network ever comes out.
        #expect(RuleLists.addresses(src(#"{"ip_cidr":["192.0.2.0/24 } pass all"]}"#)) == nil)
        #expect(RuleLists.addresses(Data("not json".utf8)) == nil)
    }

    // MARK: The config

    func tun(_ cfg: JSON) throws -> JSON {
        guard case .array(let inbounds)? = cfg["inbounds"] else { throw CancellationError() }
        return try #require(inbounds.first { $0["type"] == "tun" })
    }

    @Test func theCountrysAddressesAreLeftToMacOS() throws {
        let cfg = try SingBoxConfig.generate(Self.profile, env: Self.env())
        #expect(try tun(cfg)["route_exclude_address"] == ["198.51.100.0/24", "2001:db8:100::/48"])
        #expect(SingBoxConfig.directAddresses(Self.profile, env: Self.env()) == Self.country)
        // sing-box keeps the route's sites, never its addresses: what still
        // comes in for one (a socket bound to the tunnel) goes the tunnel's way.
        guard case .array(let rules)? = cfg["route"]?["rules"] else { Issue.record("no rules"); return }
        let domestic = try #require(rules.first { $0["outbound"] == "direct" && $0.text.contains("list-geosite-cn") })
        #expect(!domestic.text.contains("list-geoip-cn") && !domestic.text.contains("ip_cidr"))
        #expect(!cfg["route"]!["rule_set"]!.text.contains("list-geoip-cn"))
    }

    /// The site above it through a server: its names get fake addresses, so
    /// its traffic comes into the tunnel whatever its real address is.
    @Test func sitesAboveGetFakeAddresses() throws {
        let cfg = try SingBoxConfig.generate(Self.profile, env: Self.env())
        guard case .array(let servers)? = cfg["dns"]?["servers"], case .array(let rules)? = cfg["dns"]?["rules"] else {
            Issue.record("no dns"); return
        }
        #expect(servers.contains { $0["type"] == "fakeip" && $0["inet4_range"] == .string(SingBoxConfig.fakeIPRange) })
        let fake = try #require(rules.firstIndex { $0["server"] == "fakeip" })
        #expect(rules[fake]["domain_suffix"] == ["video.example"] && rules[fake]["domain_keyword"] == ["vid"])
        #expect(rules[fake]["query_type"] == ["A", "AAAA"] && rules[fake]["rewrite_ttl"] == 1)
        // Records with address hints are answered empty, then the rest as before.
        #expect(rules[fake + 1]["query_type"] == ["HTTPS", "SVCB"] && rules[fake + 1]["action"] == "predefined")
        #expect(rules[fake + 2]["domain_suffix"] == ["video.example"] && rules[fake + 2]["server"] != "fakeip")
        #expect(cfg["experimental"]?["cache_file"]?["store_fakeip"] == true)
        // Nothing below the last such route, nothing going direct.
        #expect(rules.filter { $0["server"] == "fakeip" }.count == 1)
    }

    /// A route above that claims some of the addresses (blocked, or through
    /// a server) keeps them: the first route that matches still wins.
    @Test func addressesClaimedAboveStayWithSingBox() throws {
        var p = Self.profile
        p.routes.insert(Route(id: Self.blockID, name: "Blocked", conditions: Conditions(destinations: [.cidr(IPNetwork("198.51.100.128/25")!)]),
                              target: .block), at: 0)
        #expect(SingBoxConfig.directAddresses(p, env: Self.env()) == [IPNetwork("198.51.100.0/25")!, IPNetwork("2001:db8:100::/48")!])
    }

    @Test func leftToSingBoxWhenMacOSCannotDoIt() throws {
        // A list whose addresses are not known.
        #expect(SingBoxConfig.directAddresses(Self.profile, env: Fixtures.env).isEmpty)
        // Only for some apps, ports or one protocol.
        for change in [{ (r: inout Route) in r.conditions.apps = [.processName("x")] },
                       { r in r.conditions.ports = [PortRange(443)] },
                       { r in r.conditions.network = .udp }] {
            var p = Self.profile
            change(&p.routes[1])
            #expect(SingBoxConfig.directAddresses(p, env: Self.env()).isEmpty)
            let cfg = try SingBoxConfig.generate(p, env: Self.env())
            #expect(try tun(cfg)["route_exclude_address"] == nil)
            #expect(cfg["dns"]!.text.contains("fakeip") == false)
        }
    }

    /// Said where it is not obvious: a route above by app does not hold the
    /// addresses back.
    @Test func noteWhenARouteAboveIsByApp() {
        var p = Self.profile
        let domestic = p.routes[1].id
        func notes(_ p: Profile, _ lists: Set<String>) -> [String] {
            Validation.check(p, listsWithAddresses: lists).filter { $0.route == domestic && $0.severity == .warning }.map(\.message)
        }
        let geoip: Set<String> = [Profile.domesticLists[0].url]
        #expect(notes(p, geoip).isEmpty)
        p.routes[0].conditions.apps = [.bundle(path: "/Applications/Telegram.app")]
        #expect(notes(p, geoip) == ["route \"Domestic\": its addresses go direct for every app, also for a route above it by app"])
        // Its lists hold no networks: nothing of it goes by macOS.
        #expect(notes(p, []).isEmpty)
        // A route above by app that goes direct too changes nothing.
        p.routes[0].target = .direct
        #expect(notes(p, geoip).isEmpty)
    }
}
