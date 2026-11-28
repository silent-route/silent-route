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
        cacheFile: "/Library/Application Support/Silent Route/run/cache.db",
        clashAPIPort: 19090, clashAPISecret: "SECRET", lists: lists(in: "/Library/Application Support/Silent Route/rules"))

    /// The example's lists, as the helper keeps them in `dir`: the site
    /// lists match names, the country's addresses do not.
    static func lists(in dir: String) -> [String: SingBoxConfig.LocalList] {
        Dictionary(uniqueKeysWithValues: Profile.domesticLists.map {
            ($0.url, .init(path: "\(dir)/\(RuleLists.fileKey($0.url)).srs", matchesNames: $0.name.hasPrefix("geosite-")))
        })
    }

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
    /// Lists are read from the helper's files; a list it has not got is
    /// refused rather than left out (what it should catch would slip past).
    @Test func listsComeFromDisk() throws {
        var p = Fixtures.profile
        let sets = try #require(try SingBoxConfig.generate(p, env: Fixtures.env)["route"]?["rule_set"]?.arrayValue)
        let cn = try #require(sets.first { $0["tag"]?.stringValue == "list-geoip-cn" })
        #expect(cn["type"] == "local" && cn["format"] == "binary")
        #expect(cn["path"]?.stringValue == Fixtures.env.lists[Profile.domesticLists[0].url]?.path)
        p.lists.append(RuleList(name: "more", url: "https://example.org/more.txt"))
        p.routes[0].conditions.destinations.append(.list("more"))
        #expect(throws: SingBoxConfig.Failure.listMissing("more")) { try SingBoxConfig.generate(p, env: Fixtures.env) }
    }

    /// Local names go to the router only while the local network is
    /// reachable directly, and only the zones listed.
    @Test func localZonesFollowTheLANChoice() throws {
        var p = Fixtures.profile
        p.lan = .block
        var rules = try SingBoxConfig.generate(p, env: Fixtures.env)["dns"]?["rules"]
        #expect(!(rules?.text.contains("dns-local") ?? true))
        p.lan = .allow
        p.dns.localZones = []
        rules = try SingBoxConfig.generate(p, env: Fixtures.env)["dns"]?["rules"]
        #expect(!(rules?.text.contains("dns-local") ?? true))
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

    /// Split for TLS over TCP; Reality and Hysteria2 get nothing (sing-box
    /// would not split them) and a warning.
    @Test func tlsFragmentPerServer() throws {
        let trojan = Tunnel(name: "TLS", server: Endpoint(host: "t.example.org", port: 443),
                            proto: .trojan(Trojan(password: "pw", tls: TLS(serverName: "t.example.org"))))
        var p = Fixtures.profile
        p.tunnels.append(trojan)
        for i in p.tunnels.indices { p.tunnels[i].tlsFragment = .records }
        let outbounds = try #require(try SingBoxConfig.generate(p, env: Fixtures.env)["outbounds"]?.arrayValue)
        func tls(_ t: Tunnel) -> JSON? {
            outbounds.first { $0["tag"] == .string(SingBoxConfig.tag(t.id)) }?["tls"]
        }
        #expect(tls(trojan)?["record_fragment"] == true)
        #expect(tls(Fixtures.vless)?["record_fragment"] == nil)
        #expect(tls(Fixtures.h2)?["record_fragment"] == nil)
        p.tunnels[2].tlsFragment = .packets
        let packets = try #require(try SingBoxConfig.generate(p, env: Fixtures.env)["outbounds"]?.arrayValue)
            .first { $0["tag"] == .string(SingBoxConfig.tag(trojan.id)) }?["tls"]
        #expect(packets?["fragment"] == true && packets?["record_fragment"] == nil)
        let warnings = Validation.check(p).filter { $0.severity == .warning }.map(\.tunnel)
        #expect(Set(warnings.compactMap { $0 }) == [Fixtures.h2ID, Fixtures.vlessID])
    }

    /// Profiles and .srprofile files from before these options still open.
    @Test func olderProfilesStillDecode() throws {
        let enc = JSONEncoder()
        var json = try JSONSerialization.jsonObject(with: enc.encode(Fixtures.profile)) as! [String: Any]
        json["mtu"] = nil
        var routes = json["routes"] as! [[String: Any]]
        for i in routes.indices { routes[i]["fragmentTLS"] = nil }
        json["routes"] = routes
        var tunnels = json["tunnels"] as! [[String: Any]]
        for i in tunnels.indices { tunnels[i]["tlsFragment"] = nil }
        json["tunnels"] = tunnels
        let p = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(p.mtu == nil)
        #expect(p.routes.allSatisfy { !$0.fragmentTLS })
        #expect(p.tunnels.allSatisfy { $0.tlsFragment == nil })
    }

    @Test func geoNamesAreCheckedForForm() {
        var p = Fixtures.profile
        p.routes[0].conditions.destinations = [.list("nowhere")]
        p.lists += [RuleList(name: "Bad Name", url: "https://a.example/x"), RuleList(name: "plain", url: "http://a.example/x"),
                    RuleList(name: "plain", url: "https://a.example/y")]
        let errors = Validation.check(p).filter { $0.severity == .error }.map(\.message)
        #expect(errors.contains { $0.contains("\"nowhere\", which is not in the profile's lists") })
        #expect(errors.contains { $0.contains("bad list name") })
        #expect(errors.contains { $0.contains("must be an https://") })
        #expect(errors.contains { $0.contains("two lists are named") })
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
        // sniff, hijack-dns, LAN, then user rules in order (a route through
        // servers preceded by its ping refusal); disabled rule absent; the
        // default route's ping refusal last.
        #expect(rules.count == 3 + 5 + 2)
        #expect(rules[2]["ip_is_private"] == true)
        // Domestic: lists (geoip + geosite) OR the domain zones.
        #expect(rules[3]["mode"] == "or")
        guard case .array(let dom)? = rules[3]["rules"] else { Issue.record("Domestic is not logical"); return }
        #expect(dom.contains { $0["rule_set"] == ["list-geoip-cn", "list-geosite-cn", "list-geosite-geolocation-cn"] })
        #expect(dom.contains { $0["domain_suffix"] == ["cn", "xn--fiqs8s"] })
        #expect(rules[3]["outbound"] == "direct")
        // Telegram goes through servers: its pings are refused first — the
        // same match AND icmp — never sent direct.
        #expect(rules[4]["mode"] == "and")
        #expect(rules[4]["action"] == "reject")
        guard case .array(let ping)? = rules[4]["rules"] else { Issue.record("ping refusal is not logical"); return }
        #expect(ping.contains { $0["process_path_regex"] == [#"^/Applications/Telegram\.app/"#] })
        #expect(ping.contains { $0["network"] == ["icmp"] })
        // Single condition group → plain rule.
        #expect(rules[5]["process_path_regex"] == [#"^/Applications/Telegram\.app/"#])
        #expect(rules[5]["outbound"] == .string(SingBoxConfig.routeTag(Fixtures.telegramID)))
        // Two destination kinds → OR inside, no AND wrapper needed.
        #expect(rules[6]["type"] == "logical")
        #expect(rules[6]["mode"] == "or")
        // Apps + ports + network → AND of three groups; limited to a
        // network, it never sees a ping, so no refusal before it.
        #expect(rules[7]["mode"] == "and")
        #expect(rules[7]["outbound"] == .string(SingBoxConfig.routeTag(UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!)))
        #expect(rules[8]["action"] == "reject")
        // Everything else goes through servers: pings left over are refused.
        #expect(rules[9]["network"] == ["icmp"])
        #expect(rules[9]["action"] == "reject")
        #expect(cfg["route"]?["final"] == .string(SingBoxConfig.routeTag(Fixtures.defaultRouteID)))
    }

    @Test func dnsFollowsTheRules() throws {
        let cfg = try SingBoxConfig.generate(Fixtures.profile, env: Fixtures.env)
        guard case .array(let rules)? = cfg["dns"]?["rules"] else { Issue.record("no dns rules"); return }
        // Local names → the router; the domestic zones and site lists →
        // direct resolver, "Work" → direct, "Ads" → rejected, then the defaults.
        #expect(rules[0]["domain_suffix"] == ["lan", "home.arpa", "internal"])
        #expect(rules[0]["server"] == "dns-local")
        // Only the lists that match names: an address list says nothing
        // about a name before it is looked up.
        #expect(rules[1]["rule_set"] == ["list-geosite-cn", "list-geosite-geolocation-cn"])
        #expect(rules[1]["server"] == "dns-direct")
        #expect(rules[2]["domain_suffix"] == ["corp.example"])
        #expect(rules[2]["server"] == "dns-direct")
        #expect(rules[3]["action"] == "reject")
        #expect(rules.last?["domain_suffix"] == ["cn", "xn--fiqs8s"])
        #expect(cfg["dns"]?["final"] == .string("dns-r-" + Fixtures.defaultRouteID.uuidString.lowercased()))
    }

    @Test func refusesInvalidProfiles() {
        var p = Fixtures.profile
        p.routes.append(Route(name: "ghost", conditions: Conditions(destinations: [.list("geoip-cn")]), target: .servers([UUID()])))
        #expect(throws: SingBoxConfig.Failure.self) { try SingBoxConfig.generate(p, env: Fixtures.env) }

        var rel = Fixtures.env
        rel.lists = Fixtures.lists(in: "rules")     // relative paths would resolve against the cwd
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
        #expect(p.defaultRoute.target == .direct)
        p.tunnels = [Fixtures.h2]
        p.defaultRoute.target = .servers([Fixtures.h2ID])
        let text = try SingBoxConfig.generate(p, env: Fixtures.env).text
        for word in ["geoip", "geosite", "list-", "223.5.5.5", "\"cn\"", "xn--fiqs8s", "rule_set"] {
            #expect(!text.contains(word), "a blank profile's config contains \(word)")
        }
    }

    /// The common setup: one app through a server, everything else
    /// untouched. A new profile starts with "Everything else" direct and
    /// can be turned on as it is; "Everything else" can still go through
    /// servers or be blocked, like any route.
    @Test func oneRouteThroughAServerTheRestDirect() throws {
        var p = Profile.blank(name: "New")
        #expect(Validation.check(p).filter { $0.severity == .error }.isEmpty)
        p.tunnels = [Fixtures.h2]
        // Servers no route uses: allowed, said once, on "Everything else".
        let idle = Validation.check(p)
        #expect(idle.filter { $0.severity == .error }.isEmpty)
        let defaultID = p.defaultRoute.id
        #expect(idle.contains(where: { $0.severity == .warning && $0.route == defaultID }))
        p.routes = [Route(name: "Telegram", conditions: Conditions(apps: [.bundle(path: "/Applications/Telegram.app")]),
                          target: .servers([Fixtures.h2ID]))]
        #expect(Validation.check(p).isEmpty)
        #expect(p.protectionMode == .whileConnected, "the route's kill switch still holds")
        _ = try SingBoxConfig.generate(p, env: Fixtures.env)
        // And the other way round: everything else through the server.
        p.defaultRoute.target = .servers([Fixtures.h2ID])
        #expect(Validation.check(p).isEmpty)
    }

    /// "Everything else" through servers with none chosen still cannot be
    /// turned on, and the message says what to do.
    @Test func everythingElseWithNoServersSaysHowToFixIt() {
        var p = Profile.blank(name: "New")
        p.defaultRoute.target = .servers([])
        let e = Validation.check(p).filter { $0.severity == .error }
        #expect(e.count == 1 && e[0].message.contains("send it Direct"))
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
        // Safari runs from the system cryptex, under either name; other apps
        // keep their one path.
        let cryptex = #"^(?:/System/Volumes/Preboot|/System)/Cryptexes/App/System/Applications/Safari\.app/"#
        #expect(SingBoxConfig.appRegexes(.bundle(path: "/Applications/Safari.app")) == [#"^/Applications/Safari\.app/"#, cryptex])
        #expect(SingBoxConfig.appRegexes(.bundle(path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")).last == cryptex)
        #expect(SingBoxConfig.appRegexes(.bundle(path: "/Applications/Telegram.app")).count == 1)
        for path in ["/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                     "/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"] {
            #expect(path.range(of: cryptex, options: .regularExpression) != nil)
        }
    }

    /// SOCKS5 carries TCP only unless UDP is asked for; HTTP never has UDP.
    @Test func socksUDPOnlyWhenAsked() throws {
        func outbound(_ p: Proxy) -> JSON {
            SingBoxConfig.outbound(Tunnel(name: "p", server: Endpoint(host: "198.51.100.7", port: 1080), proto: .proxy(p)), tag: "t")
        }
        #expect(outbound(Proxy(kind: .socks5))["network"] == "tcp")
        #expect(outbound(Proxy(kind: .socks5, udp: true))["network"] == nil)
        #expect(outbound(Proxy(kind: .http))["network"] == nil)
    }

    /// Profiles saved before the setting existed read as UDP off.
    @Test func oldProxyReadsWithUDPOff() throws {
        let p = try JSONDecoder().decode(Proxy.self, from: Data(#"{"kind":"socks5","username":"u"}"#.utf8))
        #expect(p.udp == false && p.username == "u")
        let back = try JSONDecoder().decode(Proxy.self, from: JSONEncoder().encode(Proxy(kind: .socks5, udp: true)))
        #expect(back.udp)
    }
}

extension JSON {
    var arrayValue: [JSON]? { if case .array(let a) = self { a } else { nil } }
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}
