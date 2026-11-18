import Foundation

/// Generates the sing-box configuration from a profile.
///
/// Pure function: everything that depends on the machine (paths, the clash
/// API port and secret) comes in through `Environment`, chosen by the helper.
/// Nothing in the profile can name a file.
public enum SingBoxConfig {
    public struct Environment: Sendable {
        /// sing-box cache file. Absolute.
        public var cacheFile: String
        public var clashAPIPort: UInt16
        /// Fresh random secret for every start; handed to the app over XPC.
        public var clashAPISecret: String
        /// The lists on disk, by address (`RuleList.url`). A profile using a
        /// list that is not there is refused: nothing it should match may
        /// slip past its route.
        public var lists: [String: LocalList]
        public var logLevel: String
        /// The way out for a Wi-Fi login page: a SOCKS/HTTP proxy on
        /// localhost whose traffic goes directly, past the tunnel, with the
        /// router's DNS. Only with its fresh per-start password, which only
        /// the owner's app gets. Nil: none (probe configs, tests).
        public var captive: LocalProxy?
        /// sing-box also answers DNS on this Mac's port 53 (every address):
        /// macOS is then pointed at each interface's own address, which is
        /// reachable even by queries it scopes to that interface.
        public var localDNS = false

        public init(cacheFile: String, clashAPIPort: UInt16, clashAPISecret: String,
                    lists: [String: LocalList] = [:], logLevel: String = "warn") {
            self.cacheFile = cacheFile
            self.clashAPIPort = clashAPIPort
            self.clashAPISecret = clashAPISecret
            self.lists = lists
            self.logLevel = logLevel
        }
    }

    /// A list as the helper keeps it: a compiled rule-set.
    public struct LocalList: Codable, Hashable, Sendable {
        /// Absolute.
        public var path: String
        /// It matches names, not only addresses: it also decides which DNS
        /// server a name is asked of.
        public var matchesNames: Bool
        public init(path: String, matchesNames: Bool) {
            self.path = path
            self.matchesNames = matchesNames
        }
    }

    /// A proxy on 127.0.0.1 with a user name and password.
    public struct LocalProxy: Codable, Equatable, Sendable {
        public var port: UInt16
        public var username: String
        public var password: String
        public init(port: UInt16, username: String, password: String) {
            self.port = port
            self.username = username
            self.password = password
        }
    }

    /// How long connecting to a server may take (see `outbound`).
    static let serverConnectTimeout = "15s"
    static let captiveTag = "captive-in"
    /// The inbound answering DNS on port 53 of this Mac.
    static let localDNSTag = "dns-in"
    /// Inside the TUN's /30, next to its own address: macOS's resolver is
    /// pointed here while connected, and sing-box answers (hijack-dns).
    public static let tunDNS = "172.19.0.6"

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidProfile([String])
        case noTunnels
        case badEnvironment(String)
        case listMissing(String)

        public var description: String {
            switch self {
            case .invalidProfile(let e): "The profile has errors: " + e.joined(separator: "; ")
            case .noTunnels: "The profile has no tunnels"
            case .badEnvironment(let s): "Internal error: \(s)"
            case .listMissing(let n): "The list “\(n)” could not be downloaded yet — see Network › Lists"
            }
        }
    }

    // Fixed tags. Tunnel tags are "t-<uuid>", which no user text can produce.
    static let directTag = "direct"
    static let dnsDirect = "dns-direct"
    static let dnsLocal = "dns-local"
    static let tunTag = "tun-in"

    /// The outbound tag of a tunnel itself: the clash API checks it.
    public static func tag(_ id: UUID) -> String { "t-" + id.uuidString.lowercased() }
    /// A route's selector: its servers in order and, without kill switch,
    /// direct. The helper points it at the first member that answers.
    public static func routeTag(_ id: UUID) -> String { "r-" + id.uuidString.lowercased() }
    public static let direct = "direct"
    static func dnsTag(_ id: UUID) -> String { "dns-r-" + id.uuidString.lowercased() }

    /// The address of the TUN interface; the helper finds the interface by
    /// it. Deliberately not sing-box's usual 172.19.0.1, so
    /// another sing-box-based VPN is never mistaken for ours.
    public static let tunAddress4 = "172.19.0.5/30"
    public static let tunAddress6 = "fdfe:dcba:9876::5/126"

    // MARK: - Full config

    public static func generate(_ profile: Profile, env: Environment) throws(Failure) -> JSON {
        guard env.cacheFile.hasPrefix("/"), env.lists.values.allSatisfy({ $0.path.hasPrefix("/") }) else {
            throw .badEnvironment("paths must be absolute")
        }
        let errors = Validation.check(profile)
            .filter { $0.severity == .error }
        guard errors.isEmpty else { throw .invalidProfile(errors.map(\.message)) }
        let routes = profile.routes.filter(\.enabled)
        let def = profile.defaultRoute

        // Outbounds: every server; per route that uses servers a selector
        // over them; direct.
        var outbounds: [JSON] = profile.tunnels.map { outbound($0, tag: tag($0.id)) }
        for r in profile.serverRoutes {
            var members = profile.chain(of: r).map(tag)
            if !r.killSwitch { members.append(directTag) }
            outbounds.append([
                "type": "selector", "tag": .string(routeTag(r.id)),
                "outbounds": .strings(members),
                "default": .string(members[0]),
                // Moving to the next server must move existing connections
                // too, or long-lived sessions would hang on the dead one.
                "interrupt_exist_connections": true,
            ])
        }
        outbounds.append(["type": "direct", "tag": .string(directTag)])

        // Route rules.
        var routeRules: [JSON] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
        ]
        if env.localDNS {
            // Whatever arrives there is a query for sing-box's DNS, never
            // something to pass on.
            routeRules.insert(["inbound": [.string(localDNSTag)], "action": "hijack-dns"], at: 0)
        }
        if env.captive != nil {
            // The login page's proxy: straight out, resolved by the router.
            routeRules += [
                ["inbound": [.string(captiveTag)], "action": "resolve", "server": .string(dnsLocal)],
                ["inbound": [.string(captiveTag)], "action": "route", "outbound": .string(directTag)],
            ]
        }
        if profile.lan == .allow {
            routeRules.append(["ip_is_private": true, "action": "route", "outbound": .string(directTag)])
        }
        for r in routes {
            if let refusal = refusal(r, in: profile) { routeRules.append(refusal) }
            routeRules.append(routeRule(r))
        }
        var final = directTag
        switch def.target {
        case .servers:
            final = routeTag(def.id)
            routeRules.append(["inbound": [.string(tunTag)], "network": .strings(uncarried(def, in: profile)), "action": "reject"])
        case .direct: break
        // A rule needs a condition: everything enters through the TUN.
        case .block: routeRules.append(["inbound": [.string(tunTag)], "action": "reject"])
        }
        // `final` takes no options: fragmenting the default route needs a
        // catch-all rule of its own.
        if def.fragmentTLS, def.target != .block {
            routeRules.append(["inbound": [.string(tunTag)], "action": "route", "outbound": .string(final), "tls_fragment": true])
        }

        // The lists actually referenced, each as its compiled file.
        var ruleSets: [JSON] = []
        for name in usedLists(routes) {
            guard let url = profile.lists.first(where: { $0.name == name })?.url, let file = env.lists[url] else {
                throw .listMissing(name)
            }
            ruleSets.append(["type": "local", "tag": .string(RuleLists.tag(name)), "format": "binary", "path": .string(file.path)])
        }

        var route: [String: JSON] = [
            "rules": .array(routeRules),
            "final": .string(final),
            "auto_detect_interface": true,
            "default_domain_resolver": .string(dnsDirect),
            "find_process": true,
        ]
        if !ruleSets.isEmpty { route["rule_set"] = .array(ruleSets) }

        return [
            "log": ["level": .string(env.logLevel), "timestamp": true],
            "dns": dns(profile, routes: routes, env: env),
            "inbounds": .array([[
                "type": "tun", "tag": .string(tunTag),
                "address": [.string(tunAddress4), .string(tunAddress6)],
                "mtu": .int(profile.mtu ?? 9000),
                "auto_route": true,
                "stack": "gvisor",
            ]] + (env.captive.map { c -> [JSON] in [[
                "type": "mixed", "tag": .string(captiveTag),
                "listen": "127.0.0.1", "listen_port": .int(Int(c.port)),
                "users": [["username": .string(c.username), "password": .string(c.password)]],
            ]] } ?? []) + (env.localDNS ? [[
                "type": "direct", "tag": .string(localDNSTag),
                "listen": "0.0.0.0", "listen_port": 53,
            ]] : [])),
            "outbounds": .array(outbounds),
            "route": .object(route),
            "experimental": [
                "cache_file": ["enabled": true, "path": .string(env.cacheFile)],
                "clash_api": [
                    "external_controller": .string("127.0.0.1:\(env.clashAPIPort)"),
                    "secret": .string(env.clashAPISecret),
                ],
            ],
        ]
    }

    static func usedLists(_ routes: [Route]) -> [String] {
        var out: [String] = []
        for r in routes {
            for case .list(let n) in r.conditions.destinations where !out.contains(n) { out.append(n) }
        }
        return out
    }

    // MARK: - Server check config

    /// A config that only exposes one tunnel as a local SOCKS proxy: no TUN,
    /// no routes, no clash API, no cache file. Used to test a server while
    /// the real connection (or none) stays untouched.
    /// - Parameters:
    ///   - auth: a user name and password for the SOCKS port, so nothing else
    ///     on the Mac can use it while the check runs.
    ///   - direct: bind to the physical interface, past any tunnel — the
    ///     helper's checks, made the way the real connection is made.
    public static func probe(_ tunnel: Tunnel, socksPort: UInt16, dns: DNSSettings = .default,
                             auth: (user: String, password: String)? = nil, direct: Bool = false) -> JSON {
        var inbound: [String: JSON] = ["type": "socks", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": .int(Int(socksPort))]
        if let auth { inbound["users"] = [["username": .string(auth.user), "password": .string(auth.password)]] }
        var route: [String: JSON] = ["final": "probe", "default_domain_resolver": .string(dnsDirect)]
        if direct { route["auto_detect_interface"] = true }
        return [
            "log": ["level": "warn"],
            "dns": [
                "servers": [["type": "udp", "tag": .string(dnsDirect), "server": .string(address(dns.directServer))]],
                "final": .string(dnsDirect),
                "strategy": "ipv4_only",
            ],
            "inbounds": [.object(inbound)],
            "outbounds": [outbound(tunnel, tag: "probe"), ["type": "direct", "tag": .string(directTag)]],
            "route": .object(route),
        ]
    }

    // MARK: - DNS

    static func address(_ net: IPNetwork) -> String {
        String(net.description.split(separator: "/")[0])
    }

    static func dns(_ profile: Profile, routes: [Route], env: Environment) -> JSON {
        var servers: [JSON] = [
            ["type": "udp", "tag": .string(dnsDirect), "server": .string(address(profile.dns.directServer))],
            // The network's own resolver (the router), as DHCP gives it for
            // the interface in use; follows the Mac to another network.
            ["type": "dhcp", "tag": .string(dnsLocal)],
        ]
        var dnsRules: [JSON] = []
        let zones = profile.dns.localZones.map(Validation.normalizeDomain).filter { !$0.isEmpty }
        if profile.lan == .allow, !zones.isEmpty {
            dnsRules.append(["domain_suffix": .strings(zones), "action": "route", "server": .string(dnsLocal)])
        }
        // DoH through a route's own selector, so a name is looked up through
        // the same server its traffic will take (and fails over with it).
        func viaRoute(_ r: Route) -> String {
            let t = dnsTag(r.id)
            if !servers.contains(where: { $0["tag"] == .string(t) }) {
                servers.append(["type": "https", "tag": .string(t),
                                "server": .string(address(profile.dns.tunnelServer)), "detour": .string(routeTag(r.id))])
            }
            return t
        }

        // A route's sites are mirrored unless ports or a protocol narrow
        // them: a DNS query does not carry the port of the connection that
        // will follow. Its apps do not matter — its sites match from any
        // app (and the query comes from mDNSResponder anyway).
        for r in routes where r.conditions.ports.isEmpty && r.conditions.network == nil {
            var domains = domainFields(r.conditions.destinations)
            let sites = r.conditions.destinations.compactMap { d -> String? in
                guard case .list(let n) = d, let url = profile.lists.first(where: { $0.name == n })?.url,
                      env.lists[url]?.matchesNames == true else { return nil }
                return RuleLists.tag(n)
            }
            if !sites.isEmpty { domains["rule_set"] = .strings(sites) }
            guard !domains.isEmpty else { continue }
            var rule = domains
            switch r.target {
            case .direct: rule["server"] = .string(dnsDirect)
            case .servers: rule["server"] = .string(viaRoute(r))
            case .block: rule["action"] = "reject"
            }
            if rule["action"] == nil { rule["action"] = "route" }
            dnsRules.append(.object(rule))
        }

        // Nothing country-specific is built in: site lists are resolved
        // directly only when a route sends them direct (above).
        let suffixes = profile.dns.directSuffixes.map(Validation.normalizeDomain)
        if !suffixes.isEmpty {
            dnsRules.append(["domain_suffix": .strings(suffixes), "action": "route", "server": .string(dnsDirect)])
        }

        // Everything else is resolved the way the default route goes.
        let def = profile.defaultRoute
        let final: String
        if case .servers = def.target { final = viaRoute(def) } else { final = dnsDirect }
        return [
            "servers": .array(servers),
            "rules": .array(dnsRules),
            "final": .string(final),
            "strategy": "ipv4_only",
            "independent_cache": true,
        ]
    }

    /// Only the domain-name parts of a destination list, as one default rule
    /// (sing-box ORs domain, domain_suffix and domain_keyword together).
    static func domainFields(_ ds: [Destination]) -> [String: JSON] {
        var exact: [String] = [], suffix: [String] = [], keyword: [String] = []
        for d in ds {
            switch d {
            case .domain(let s): exact.append(Validation.normalizeDomain(s))
            case .domainSuffix(let s): suffix.append(Validation.normalizeDomain(s))
            case .domainKeyword(let s): keyword.append(s.lowercased())
            case .cidr, .list, .localNetwork: break
            }
        }
        var out: [String: JSON] = [:]
        if !exact.isEmpty { out["domain"] = .strings(exact) }
        if !suffix.isEmpty { out["domain_suffix"] = .strings(suffix) }
        if !keyword.isEmpty { out["domain_keyword"] = .strings(keyword) }
        return out
    }

    // MARK: - Route rules

    /// One profile rule as one sing-box rule. Each condition group becomes a
    /// What it is about — its sites and addresses, its apps — each match on
    /// its own (OR); ports and protocol narrow that down (AND). Explicit
    /// logical rules, so the meaning never depends on sing-box's implicit
    /// field grouping.
    static func routeRule(_ r: Route) -> JSON {
        var parts: [[String: JSON]] = []
        let c = r.conditions

        var what: [[String: JSON]] = []
        if !c.destinations.isEmpty {
            var kinds: [[String: JSON]] = []
            let cidrs = c.destinations.compactMap { if case .cidr(let n) = $0 { n.description } else { nil } }
            if !cidrs.isEmpty { kinds.append(["ip_cidr": .strings(cidrs)]) }
            if c.destinations.contains(.localNetwork) { kinds.append(["ip_is_private": true]) }
            let geo = c.destinations.compactMap { if case .list(let n) = $0 { RuleLists.tag(n) } else { nil } }
            if !geo.isEmpty { kinds.append(["rule_set": .strings(geo)]) }
            for (k, v) in domainFields(c.destinations).sorted(by: { $0.key < $1.key }) { kinds.append([k: v]) }
            what += kinds
        }
        if !c.apps.isEmpty {
            // One field for every kind of app matcher: sing-box AND-s
            // process_name with process_path, which is not what a list of
            // apps means.
            what.append(["process_path_regex": .strings(c.apps.flatMap(appRegexes))])
        }
        if !what.isEmpty {
            parts.append(what.count == 1 ? what[0] : ["type": "logical", "mode": "or", "rules": .array(what.map(JSON.object))])
        }
        if !c.ports.isEmpty {
            parts.append(["port_range": .strings(c.ports.map { "\($0.lower):\($0.upper)" })])
        }
        if let n = c.network {
            parts.append(["network": .strings([n.rawValue])])
        }

        var rule: [String: JSON] = parts.count == 1
            ? parts[0]
            : ["type": "logical", "mode": "and", "rules": .array(parts.map(JSON.object))]
        switch r.target {
        case .servers: rule["action"] = "route"; rule["outbound"] = .string(routeTag(r.id))
        case .direct: rule["action"] = "route"; rule["outbound"] = .string(directTag)
        case .block: rule["action"] = "reject"
        }
        if r.fragmentTLS, r.target != .block { rule["tls_fragment"] = true }
        return .object(rule)
    }

    /// What a route's servers cannot carry: ping (ICMP) never travels
    /// through a proxy server, and UDP not when none of them takes it (a
    /// SOCKS5 proxy without UDP, an HTTP proxy). Sent there, sing-box drops
    /// every packet with an error in the log, and the app waits for nothing.
    static func uncarried(_ r: Route, in p: Profile) -> [String] {
        guard case .servers = r.target else { return [] }
        let chain = p.chain(of: r).compactMap(p.tunnel)
        return chain.isEmpty || chain.contains(where: \.carriesUDP) ? ["icmp"] : ["icmp", "udp"]
    }

    /// Refused at once instead: a browser then moves from HTTP/3 to TCP
    /// right away, and nothing is ever sent direct, which would show the
    /// destination past the tunnel. Routes that go direct keep both; a route
    /// limited to TCP or UDP only ever sees its own.
    static func refusal(_ r: Route, in p: Profile) -> JSON? {
        let networks = uncarried(r, in: p).filter { r.conditions.network == nil || $0 == r.conditions.network?.rawValue }
        guard !networks.isEmpty else { return nil }
        var match = r
        match.target = .block
        match.fragmentTLS = false
        guard case .object(var inner) = routeRule(match) else { return nil }
        inner["action"] = nil
        return .object(["type": "logical", "mode": "and",
                        "rules": .array([.object(inner), ["network": .strings(networks)]]),
                        "action": "reject"])
    }

    static func appRegex(_ a: AppMatcher) -> String { appRegexes(a)[0] }

    /// Every path the matcher's processes run from. Usually one; an Apple
    /// app that macOS keeps in its updatable system part (a cryptex — today
    /// Safari) runs from there, under either of two names, while it shows
    /// in /Applications only as a link — which a process path never is.
    static func appRegexes(_ a: AppMatcher) -> [String] {
        switch a {
        case .bundle(let path):
            var p = path
            while p.hasSuffix("/") { p.removeLast() }
            var out = ["^" + regexEscape(p) + "/"]
            if let name = cryptexAppName(p) {
                out.append("^(?:/System/Volumes/Preboot|/System)" + regexEscape(cryptexApps + "/" + name) + "/")
            }
            return out
        case .executable(let path): return ["^" + regexEscape(path) + "$"]
        case .processName(let name): return ["/" + regexEscape(name) + "$"]
        }
    }

    /// Where macOS keeps cryptex apps: under /System, and the same folder
    /// as /System/Volumes/Preboot/Cryptexes/… (processes show either).
    static let cryptexApps = "/Cryptexes/App/System/Applications"
    /// Apps known to live there, by the link in /Applications.
    static let knownCryptexApps: Set<String> = ["Safari.app"]

    /// "Safari.app" for /Applications/Safari.app or either cryptex path of
    /// any app; nil for everything else.
    static func cryptexAppName(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        if parent == "/Applications", knownCryptexApps.contains(name) { return name }
        if parent == "/System" + cryptexApps || parent == "/System/Volumes/Preboot" + cryptexApps { return name }
        return nil
    }

    static func regexEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // MARK: - Outbounds

    static func outbound(_ t: Tunnel, tag: String) -> JSON {
        var o: [String: JSON] = [
            "tag": .string(tag),
            "server": .string(t.server.host),
            "server_port": .int(Int(t.server.port)),
            // sing-box gives up on connecting to a server after 5 s. A busy
            // proxy can take longer to accept and still work — other clients
            // just wait — so a slow server stays slow rather than failing.
            "connect_timeout": .string(serverConnectTimeout),
        ]
        if IPNetwork.parseV4(t.server.host) == nil, IPNetwork.parseV6(t.server.host) == nil {
            // Tunnel servers are always resolved outside every tunnel.
            o["domain_resolver"] = .string(dnsDirect)
        }
        switch t.proto {
        case .hysteria2(let h):
            o["type"] = "hysteria2"
            o["password"] = .string(h.password)
            if let op = h.obfsPassword { o["obfs"] = ["type": "salamander", "password": .string(op)] }
            if !h.serverPorts.isEmpty { o["server_ports"] = .strings(h.serverPorts) }
            if let u = h.upMbps { o["up_mbps"] = .int(u) }
            if let d = h.downMbps { o["down_mbps"] = .int(d) }
            o["tls"] = tls(h.tls)
        case .vless(let v):
            o["type"] = "vless"
            o["uuid"] = .string(v.uuid.uuidString.lowercased())
            if let f = v.flow { o["flow"] = .string(f) }
            if let t = v.tls { o["tls"] = tls(t) }
            if let tr = transport(v.transport) { o["transport"] = tr }
        case .trojan(let tr):
            o["type"] = "trojan"
            o["password"] = .string(tr.password)
            if let t = tr.tls { o["tls"] = tls(t) }
            if let x = transport(tr.transport) { o["transport"] = x }
        case .shadowsocks(let s):
            o["type"] = "shadowsocks"
            o["method"] = .string(s.method)
            o["password"] = .string(s.password)
            if let p = s.plugin {
                o["plugin"] = .string(p)
                if let opts = s.pluginOptions { o["plugin_opts"] = .string(opts) }
            }
        case .proxy(let p):
            switch p.kind {
            case .socks5:
                o["type"] = "socks"
                o["version"] = "5"
                // UDP only when asked for (see Proxy.udp).
                if !p.udp { o["network"] = "tcp" }
            case .http:
                o["type"] = "http"
                if let t = p.tls { o["tls"] = tls(t) }
            }
            if let u = p.username { o["username"] = .string(u) }
            if let pw = p.password { o["password"] = .string(pw) }
        case .vmess(let v):
            o["type"] = "vmess"
            o["uuid"] = .string(v.uuid.uuidString.lowercased())
            o["security"] = .string(v.security)
            o["alter_id"] = .int(v.alterID)
            if let t = v.tls { o["tls"] = tls(t) }
            if let x = transport(v.transport) { o["transport"] = x }
        }
        if let m = t.multiplex, Multiplex.isSupported(by: t.proto) {
            o["multiplex"] = ["enabled": true, "protocol": .string(m.kind.rawValue),
                              "max_connections": .int(m.maxConnections), "padding": .bool(m.padding)]
        }
        return .object(o)
    }

    static func tls(_ t: TLS) -> JSON {
        var o: [String: JSON] = ["enabled": true]
        if let sni = t.serverName { o["server_name"] = .string(sni) }
        if !t.alpn.isEmpty { o["alpn"] = .strings(t.alpn) }
        if t.insecure { o["insecure"] = true }
        if let fp = t.fingerprint { o["utls"] = ["enabled": true, "fingerprint": .string(fp)] }
        if let r = t.reality {
            o["reality"] = ["enabled": true, "public_key": .string(r.publicKey), "short_id": .string(r.shortID)]
        }
        return .object(o)
    }

    static func transport(_ t: Transport) -> JSON? {
        switch t {
        case .tcp:
            return nil
        case .ws(let path, let host):
            var o: [String: JSON] = ["type": "ws"]
            // Xray puts WebSocket early data in the path ("/ws?ed=2048");
            // sing-box wants it as separate options.
            var p = path
            if let q = path.range(of: "?ed="), let n = Int(path[q.upperBound...]) {
                p = String(path[..<q.lowerBound])
                o["max_early_data"] = .int(n)
                o["early_data_header_name"] = "Sec-WebSocket-Protocol"
            }
            o["path"] = .string(p)
            if let h = host { o["headers"] = ["Host": .string(h)] }
            return .object(o)
        case .grpc(let name):
            return ["type": "grpc", "service_name": .string(name)]
        case .httpUpgrade(let path, let host):
            var o: [String: JSON] = ["type": "httpupgrade", "path": .string(path)]
            if let h = host { o["host"] = .string(h) }
            return .object(o)
        case .http(let path, let hosts):
            var o: [String: JSON] = ["type": "http", "path": .string(path)]
            if !hosts.isEmpty { o["host"] = .strings(hosts) }
            return .object(o)
        }
    }
}
