import Foundation
import Testing
@testable import VPNCore

@Suite struct RuleListsTests {
    @Test func names() {
        #expect(RuleText.destinations("list:blocked-sites").values == [.list("blocked-sites")])
        for bad in ["list:", "list:../x", "list:a/b", "list:-x", "list:a..b", "list:" + String(repeating: "a", count: 65)] {
            #expect(!RuleText.destinations(bad).errors.isEmpty, "\(bad)")
        }
        #expect(RuleText.text(.list("blocked-sites")) == "list:blocked-sites")
    }

    @Test func addresses() {
        #expect(RuleLists.isValidURL("https://example.org/lists/a.srs"))
        for bad in ["http://example.org/a", "file:///etc/passwd", "https://u:p@example.org/a", "https://", "https://a.org/a b", "ftp://a.org/x"] {
            #expect(!RuleLists.isValidURL(bad), "\(bad)")
        }
        // One file per address, whatever profiles call it.
        #expect(RuleLists.fileKey("https://a.org/x").count == 24)
        #expect(RuleLists.fileKey("https://a.org/x") != RuleLists.fileKey("https://a.org/y"))
    }

    @Test func savedWithTheProfile() throws {
        var p = Profile(name: "P")
        #expect(String(decoding: try JSONEncoder().encode(p), as: UTF8.self).contains(#""lists":[]"#))
        p.lists = [RuleList(name: "a", url: "https://a.org/a.txt")]
        #expect(try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(p)) == p)
    }

    /// Profiles of 1.4 named the sing-box project's lists: they keep
    /// working, as lists with the address they always came from.
    @Test func earlierGeoNamesBecomeLists() throws {
        let old = #"""
        {"schemaVersion": 2, "name": "Old", "tunnels": [], "lan": "allow", "killSwitch": "whileConnected",
         "dns": {"directServer": "1.1.1.1/32", "tunnelServer": "1.1.1.1/32", "directSuffixes": []},
         "routes": [{"id": "00000000-0000-0000-0000-000000000001", "name": "R", "enabled": true, "target": {"direct": {}},
                     "killSwitch": true, "conditions": {"destinations": [{"geoIP": {"_0": "fr"}}, {"geoSite": {"_0": "netflix"}},
                                                                           {"domainSuffix": {"_0": "a.example"}}], "apps": [], "ports": []}}],
         "defaultRoute": {"id": "00000000-0000-0000-0000-000000000002", "name": "Everything else", "enabled": true,
                          "target": {"direct": {}}, "killSwitch": true, "conditions": {"destinations": [], "apps": [], "ports": []}}}
        """#
        let p = try JSONDecoder().decode(Profile.self, from: Data(old.utf8))
        #expect(p.routes[0].conditions.destinations == [.list("geoip-fr"), .list("geosite-netflix"), .domainSuffix("a.example")])
        // Saved again, they are lists like any other: nothing more is added.
        #expect(try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(p)) == p)
        #expect(p.lists == [
            RuleList(name: "geoip-fr", url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-fr.srs"),
            RuleList(name: "geosite-netflix", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs"),
        ])
    }

    @Test func profileURLs() {
        let p = Profile(name: "P", routes: [
            Route(name: "A", conditions: Conditions(destinations: [.list("a"), .domainSuffix("a.com"), .localNetwork]), target: .direct),
            Route(name: "B", conditions: Conditions(destinations: [.list("b"), .list("a")]), target: .direct),
        ], lists: [RuleList(name: "a", url: "https://a.org/a"), RuleList(name: "b", url: "https://a.org/b"),
                   RuleList(name: "unused", url: "https://a.org/c")])
        #expect(RuleLists.urls(p) == ["https://a.org/a", "https://a.org/b"])
    }

    /// Plain text in the common styles becomes a sing-box source.
    @Test func textLists() throws {
        let text = """
        # a comment
        example.com
        *.wild.example
        domain:v2fly.example @cn
        full:exact.example
        keyword:tube
        DOMAIN-SUFFIX,clash.example
        IP-CIDR,10.0.0.0/8,no-resolve
        203.0.113.0/24
        regexp:.*
        not a site
        """
        let src = try #require(RuleLists.sourceFromText(Data(text.utf8)))
        let obj = try #require(try JSONSerialization.jsonObject(with: src) as? [String: Any])
        let rules = try #require(obj["rules"] as? [[String: [String]]])
        #expect(rules.contains { $0["domain_suffix"] == ["example.com", "wild.example", "v2fly.example", "clash.example"] })
        #expect(rules.contains { $0["domain"] == ["exact.example"] })
        #expect(rules.contains { $0["domain_keyword"] == ["tube"] })
        #expect(rules.contains { $0["ip_cidr"] == ["10.0.0.0/8", "203.0.113.0/24"] })
        #expect(RuleLists.matchesNames(src))
        #expect(!RuleLists.matchesNames(try #require(RuleLists.sourceFromText(Data("1.2.3.0/24".utf8)))))
        #expect(RuleLists.sourceFromText(Data("<html><body>Not found</body></html>".utf8)) == nil)
    }
}

@Suite struct LocalNetworkTests {
    @Test func becomesPrivateAddresses() throws {
        let r = Route(name: "LAN", conditions: Conditions(destinations: [.localNetwork, .cidr(IPNetwork("100.64.0.0/10")!)]), target: .direct)
        let kinds = try #require(SingBoxConfig.routeRule(r)["rules"]?.arrayValue)
        #expect(kinds.contains { $0["ip_is_private"] == true })
        #expect(kinds.contains { $0["ip_cidr"] == ["100.64.0.0/10"] })
        #expect(SingBoxConfig.routeRule(Route(name: "L", conditions: Conditions(destinations: [.localNetwork]), target: .direct))["ip_is_private"] == true)
        #expect(SingBoxConfig.domainFields([.localNetwork]).isEmpty)
    }

    /// While the local network is reachable directly, it never reaches a
    /// route: said in the route.
    @Test func shadowedByReachableDirectly() {
        var p = Profile(name: "P", routes: [Route(name: "LAN", conditions: Conditions(destinations: [.localNetwork]), target: .block)])
        p.lan = .allow
        #expect(Validation.check(p).contains { $0.severity == .warning && $0.message.contains("local network") })
        p.lan = .block
        #expect(Validation.check(p).isEmpty)
    }

    @Test func roundTrips() throws {
        let c = Conditions(destinations: [.localNetwork, .list("a")])
        #expect(try JSONDecoder().decode(Conditions.self, from: try JSONEncoder().encode(c)) == c)
    }
}

/// Apps and sites in one route each match on their own; ports and a
/// protocol narrow both.
@Suite struct RouteSemanticsTests {
    let remote = AppMatcher.bundle(path: "/Applications/Remote Desktop.app")

    @Test func appsOrSites() throws {
        let r = Route(name: "de", conditions: Conditions(destinations: [.domainSuffix("de")], apps: [remote]), target: .direct)
        let rule = SingBoxConfig.routeRule(r)
        #expect(rule["mode"] == "or")
        let kinds = try #require(rule["rules"]?.arrayValue)
        #expect(kinds.contains { $0["domain_suffix"] == ["de"] })
        #expect(kinds.contains { $0["process_path_regex"] != nil })
        #expect(rule["outbound"] == "direct")
    }

    @Test func portsNarrowBoth() throws {
        let r = Route(name: "t", conditions: Conditions(destinations: [.domainSuffix("de")], apps: [remote],
                                                       ports: [PortRange(443)]), target: .direct)
        let rule = SingBoxConfig.routeRule(r)
        #expect(rule["mode"] == "and")
        let parts = try #require(rule["rules"]?.arrayValue)
        #expect(parts.count == 2)
        #expect(parts.contains { $0["mode"] == "or" })
        #expect(parts.contains { $0["port_range"] == ["443:443"] })
    }

    /// A route's sites decide their DNS even when it also lists apps.
    @Test func sitesOfARouteWithAppsStillSteerDNS() throws {
        var p = Fixtures.profile
        p.routes.insert(Route(name: "de", conditions: Conditions(destinations: [.domainSuffix("shop.example")], apps: [remote]),
                              target: .direct), at: 0)
        let cfg = try SingBoxConfig.generate(p, env: Fixtures.env)
        let rules = try #require(cfg["dns"]?["rules"]?.arrayValue)
        #expect(rules.contains { $0["domain_suffix"] == ["shop.example"] && $0["server"] == "dns-direct" })
    }
}

/// UDP to servers that cannot carry it is refused at once, as ping is: a
/// browser then uses TCP instead of waiting on HTTP/3.
@Suite struct UncarriedTrafficTests {
    func profile(udp: Bool) -> Profile {
        let socks = Tunnel(name: "proxy", server: Endpoint(host: "198.51.100.9", port: 1080),
                           proto: .proxy(Proxy(kind: .socks5, udp: udp)))
        var p = Profile(name: "P", tunnels: [socks], routes: [
            Route(name: "sites", conditions: Conditions(destinations: [.domainSuffix("a.example")]), target: .servers([socks.id])),
        ])
        p.defaultRoute.target = .servers([socks.id])
        return p
    }

    func refusals(_ p: Profile) throws -> [JSON] {
        let rules = try #require(try SingBoxConfig.generate(p, env: Fixtures.env)["route"]?["rules"]?.arrayValue)
        return rules.filter { $0["action"] == "reject" }
    }

    @Test func tcpOnlyServersRefuseUDP() throws {
        let r = try refusals(profile(udp: false))
        #expect(r.contains { $0["mode"] == "and" && ($0["rules"]?.arrayValue ?? []).contains { $0["network"] == ["icmp", "udp"] } })
        #expect(r.contains { $0["inbound"] != nil && $0["network"] == ["icmp", "udp"] })
    }

    @Test func udpCarryingServersKeepIt() throws {
        let r = try refusals(profile(udp: true))
        #expect(!r.contains { ($0["network"]?.arrayValue ?? []).contains("udp") })
        #expect(r.contains { $0["inbound"] != nil && $0["network"] == ["icmp"] })
    }
}
