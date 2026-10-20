import Foundation
import Testing
@testable import VPNCore

// Fictitious servers and secrets throughout.

enum Fixtures {
    static let h2ID = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    static let vlessID = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!

    static let h2 = Tunnel(
        id: h2ID, name: "NL hysteria2", server: Endpoint(host: "vpn.example.org", port: 443),
        proto: .hysteria2(Hysteria2(password: "pw", obfsPassword: "obfs",
                                    tls: TLS(serverName: "vpn.example.org", alpn: ["h3"]))))

    static let vless = Tunnel(
        id: vlessID, name: "DE reality", server: Endpoint(host: "203.0.113.10", port: 443),
        proto: .vless(VLESS(uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                            flow: "xtls-rprx-vision",
                            tls: TLS(serverName: "www.example.com", fingerprint: "chrome",
                                     reality: .init(publicKey: "ZcUXAS9Ch2aP6IAJBcrLFmdPtjQxAm1sWaA2hvpWtXc", shortID: "ab12")))))

    static let env = SingBoxConfig.Environment(
        ruleSetDirectory: "/Library/Application Support/Silent Route/rules",
        cacheFile: "/Library/Application Support/Silent Route/run/cache.db",
        clashAPIPort: 19090, clashAPISecret: "SECRET",
        geoIPCountries: ["cn"], siteLists: ["cn", "geolocation-cn"])

    static let defaultRouteID = UUID(uuidString: "00000000-0000-0000-0000-0000000000d0")!
    static let telegramID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

    /// Exercises every kind of condition and target.
    static var profile: Profile {
        var p = Profile.example(tunnels: [h2, vless])
        p.routes[0].id = UUID(uuidString: "00000000-0000-0000-0000-0000000000c0")!
        p.defaultRoute = Route(id: defaultRouteID, name: "Everything else", target: .servers([h2ID, vlessID]))
        p.routes += [
            Route(id: telegramID, name: "Telegram via DE",
                  conditions: Conditions(apps: [.bundle(path: "/Applications/Telegram.app")]), target: .servers([vlessID])),
            Route(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!, name: "Work",
                  conditions: Conditions(destinations: [.domainSuffix(".Corp.example"), .cidr(IPNetwork("10.20.0.0/16")!)]),
                  target: .direct),
            Route(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!, name: "Games UDP",
                  conditions: Conditions(apps: [.processName("Minecraft"), .executable(path: "/usr/local/bin/game+1")],
                                         ports: [PortRange(25565), PortRange(27000, 27100)], network: .udp),
                  target: .servers([h2ID]), killSwitch: false),
            Route(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c4")!, name: "Ads",
                  conditions: Conditions(destinations: [.domainKeyword("adserver")]), target: .block),
            Route(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c5")!, name: "Disabled", enabled: false,
                  conditions: Conditions(destinations: [.domain("off.example")]), target: .block),
        ]
        return p
    }
}

@Suite struct SingBoxConfigTests {
    /// A list not on disk is downloaded by sing-box (through no server, so
    /// a dead tunnel cannot keep it from starting); one on disk is used as is.
    @Test func ruleSetsNotOnDiskAreDownloaded() throws {
        var p = Fixtures.profile
        p.routes[0].conditions.destinations += [.geoIP("de"), .geoSite("netflix")]
        let json = try SingBoxConfig.generate(p, env: Fixtures.env)
        let sets = try #require(json["route"]?["rule_set"]?.arrayValue)
        func set(_ tag: String) -> JSON? { sets.first { $0["tag"]?.stringValue == tag } }
        #expect(set("geoip-cn")?["type"]?.stringValue == "local")
        #expect(set("geoip-de")?["type"]?.stringValue == "remote")
        #expect(set("geoip-de")?["url"]?.stringValue == "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-de.srs")
        #expect(set("geoip-de")?["download_detour"]?.stringValue == "direct")
        #expect(set("geosite-netflix")?["url"]?.stringValue == "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-netflix.srs")
    }

    @Test func advancedOptionsAreChecked() {
        var p = Fixtures.profile
        p.mtu = 576
        p.tunnels[0].multiplex = Multiplex()          // hysteria2: QUIC, no multiplexing
        p.tunnels[1].multiplex = Multiplex()          // VLESS with XTLS Vision
        let errors = Validation.check(p).filter { $0.severity == .error }.map(\.message)
        #expect(errors.contains { $0.contains("MTU 576") })
        #expect(errors.filter { $0.contains("cannot be multiplexed") }.count == 2)
        // Nothing of it reaches sing-box when it is off.
        let plain = try? SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env).text
        #expect(plain?.contains("multiplex") == false && plain?.contains("tls_fragment") == false)
    }

    /// Profiles and .srprofile files from before these options still open.
    @Test func olderProfilesStillDecode() throws {
        let enc = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: enc.encode(Fixtures.profile)) as! [String: Any]
        json["mtu"] = nil
        var routes = json["routes"] as! [[String: Any]]
        for i in routes.indices { routes[i]["fragmentTLS"] = nil }
        json["routes"] = routes
        let p = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(p.mtu == nil)
        #expect(p.routes.allSatisfy { !$0.fragmentTLS })
    }

    @Test func geoNamesAreCheckedForForm() {
        var p = Fixtures.profile
        p.routes[0].conditions.destinations = [.geoIP("deu"), .geoSite("bad name")]
        let errors = Validation.check(p).filter { $0.severity == .error }.map(\.message)
        #expect(errors.contains { $0.contains("bad country code") })
        #expect(errors.contains { $0.contains("bad site list name") })
    }

    static let goldenDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("golden")

    /// The generated config must equal the reviewed golden file. To accept a
    /// deliberate change: `UPDATE_GOLDEN=1 scripts/test.sh`, then review the diff.
    @Test func golden() throws {
        let text = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env).text + "\n"
        let file = Self.goldenDir.appendingPathComponent("full.json")
        if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] != nil {
            try FileManager.default.createDirectory(at: Self.goldenDir, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: file, encoding: .utf8)
        #expect(text == expected, "generated config differs from golden/full.json")
    }

    @Test func deterministic() throws {
        let a = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env).text
        let b = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env).text
        #expect(a == b)
    }

    @Test func ruleOrderAndSemantics() throws {
        let cfg = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env)
        guard case .array(let rules)? = cfg["route"]?["rules"] else { Issue.record("no rules"); return }
        // sniff, hijack-dns, LAN, then user rules in order; disabled rule absent.
        #expect(rules.count == 3 + 5)
        #expect(rules[2]["ip_is_private"] == true)
        // Domestic: lists (geoip + geosite) OR the domain zones.
        #expect(rules[3]["mode"] == "or")
        guard case .array(let dom)? = rules[3]["rules"] else { Issue.record("Domestic is not logical"); return }
        #expect(dom.contains { $0["rule_set"] == ["geoip-cn", "geosite-cn", "geosite-geolocation-cn"] })
        #expect(dom.contains { $0["domain_suffix"] == ["cn", "xn--fiqs8s"] })
        #expect(rules[3]["outbound"] == "direct")
        // Single condition group → plain rule.
        #expect(rules[4]["process_path_regex"] == [#"^/Applications/Telegram\.app/"#])
        #expect(rules[4]["outbound"] == .string(SingBoxConfig.routeTag(Fixtures.telegramID)))
        // Two destination kinds → OR inside, no AND wrapper needed.
        #expect(rules[5]["type"] == "logical")
        #expect(rules[5]["mode"] == "or")
        // Apps + ports + network → AND of three groups.
        #expect(rules[6]["mode"] == "and")
        #expect(rules[6]["outbound"] == .string(SingBoxConfig.routeTag(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)))
        #expect(rules[7]["action"] == "reject")
        #expect(cfg["route"]?["final"] == .string(SingBoxConfig.routeTag(Fixtures.defaultRouteID)))
    }

    @Test func dnsFollowsTheRules() throws {
        let cfg = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env)
        guard case .array(let rules)? = cfg["dns"]?["rules"] else { Issue.record("no dns rules"); return }
        // The domestic zones and site lists → direct resolver, "Work" → direct,
        // "Ads" → rejected, then the defaults.
        #expect(rules[0]["rule_set"] == ["geosite-cn", "geosite-geolocation-cn"])
        #expect(rules[0]["server"] == "dns-direct")
        #expect(rules[1]["domain_suffix"] == ["corp.example"])
        #expect(rules[1]["server"] == "dns-direct")
        #expect(rules[2]["action"] == "reject")
        #expect(rules.last?["domain_suffix"] == ["cn", "xn--fiqs8s"])
        #expect(cfg["dns"]?["final"] == .string("dns-r-" + Fixtures.defaultRouteID.uuidString.lowercased()))
    }

    @Test func refusesInvalidProfiles() {
        var p = Fixtures.profile
        p.routes.append(Route(name: "ghost", conditions: Conditions(destinations: [.geoIP("de")]), target: .servers([UUID()])))
        #expect(throws: SingBoxConfig.Failure.self) { try SingBoxConfig.generate(p, env: Fixtures.env) }

        var rel = Fixtures.env
        rel.ruleSetDirectory = "rules"     // relative paths would resolve against the cwd
        #expect(throws: SingBoxConfig.Failure.badEnvironment("paths must be absolute")) {
            try SingBoxConfig.generate(Fixtures.profile, env: rel)
        }
    }

    @Test func hostileStringsStayInsideJSONStrings() throws {
        var p = Fixtures.profile
        p.tunnels[0].name = "\"}, {\"type\": \"direct"
        if case .hysteria2(var h) = p.tunnels[0].proto {
            h.password = "\"\n\\u0000\"}"
            p.tunnels[0].proto = .hysteria2(h)
        }
        let data = try SingBoxConfig.generate(p, env: Fixtures.env).encoded()
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let outbounds = obj?["outbounds"] as? [[String: Any]]
        // 2 tunnels, 2 exit selectors, main, direct — nothing injected.
        #expect(outbounds?.count == 6)
        #expect(outbounds?.first?["password"] as? String == "\"\n\\u0000\"}")
    }

    /// Each route with servers is a selector over them, in order; direct is
    /// a member only without kill switch. Unknown and repeated servers drop.
    @Test func routeSelectors() throws {
        var p = Fixtures.profile
        p.defaultRoute.target = .servers([Fixtures.vlessID, Fixtures.vlessID, UUID(), Fixtures.h2ID])
        let obj = try JSONSerialization.jsonObject(with: SingBoxConfig.generate(p, env: Fixtures.env).encoded()) as! [String: Any]
        let outs = obj["outbounds"] as! [[String: Any]]
        func members(_ tag: String) -> [String]? { outs.first { $0["tag"] as? String == tag }?["outbounds"] as? [String] }
        #expect(members(SingBoxConfig.routeTag(Fixtures.defaultRouteID)) == [SingBoxConfig.tag(Fixtures.vlessID), SingBoxConfig.tag(Fixtures.h2ID)])
        #expect(members(SingBoxConfig.routeTag(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)) == [SingBoxConfig.tag(Fixtures.h2ID), "direct"])
        // Routes that go direct or block need no selector.
        #expect(members(SingBoxConfig.routeTag(UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!)) == nil)
    }

    @Test func aDirectOrBlockedDefaultRoute() throws {
        var p = Fixtures.profile
        p.defaultRoute.target = .direct
        var cfg = try SingBoxConfig.generate(p, env: Fixtures.env)
        #expect(cfg["route"]?["final"] == "direct")
        #expect(cfg["dns"]?["final"] == "dns-direct")
        p.defaultRoute.target = .block
        cfg = try SingBoxConfig.generate(p, env: Fixtures.env)
        guard case .array(let rules)? = cfg["route"]?["rules"] else { Issue.record("no rules"); return }
        #expect(rules.last?["action"] == "reject")
        #expect(rules.last?["inbound"] == ["tun-in"])
    }

    /// A new profile has nothing country-specific built in: no routes, no
    /// site lists, no zones, no domestic resolver — only what the user adds.
    @Test func aBlankProfileHasNothingBuiltIn() throws {
        var p = Profile.blank(name: "New")
        #expect(p.routes.isEmpty)
        #expect(p.defaultRoute.target == .servers([]))
        p.tunnels = [Fixtures.h2]
        p.defaultRoute.target = .servers([Fixtures.h2ID])
        let text = try SingBoxConfig.generate(p, env: Fixtures.env).text
        for word in ["geoip", "geosite", "223.5.5.5", "\"cn\"", "xn--fiqs8s", "rule_set"] {
            #expect(!text.contains(word), "a blank profile's config contains \(word)")
        }
    }

    @Test func protectionFollowsTheRoutes() {
        var p = Fixtures.profile          // default route and Telegram have kill switch on
        #expect(p.protectionMode == .whileConnected)
        p.defaultRoute.killSwitch = false
        #expect(p.protectionMode == .whileConnected, "Telegram's route still blocks")
        p.routes[1].killSwitch = false
        #expect(p.protectionMode == .off)
    }

    @Test func webSocketEarlyData() {
        let t = SingBoxConfig.transport(.ws(path: "/ws?ed=2048", host: "h.example"))
        #expect(t?["path"] == "/ws")
        #expect(t?["max_early_data"] == 2048)
        #expect(t?["headers"]?["Host"] == "h.example")
    }

    @Test func regexEscaping() {
        #expect(SingBoxConfig.appRegex(.executable(path: "/a/b+c (1).app")) == #"^/a/b\+c \(1\)\.app$"#)
        #expect(SingBoxConfig.appRegex(.bundle(path: "/Applications/X.app/")) == #"^/Applications/X\.app/"#)
        #expect(SingBoxConfig.appRegex(.processName("a.b")) == #"/a\.b$"#)
    }
}

extension JSON {
    var arrayValue: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}
