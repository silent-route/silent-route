import Foundation

// The data model. This is the only thing that crosses from the app to the
// root helper, so it is typed all the way down: no free-form config
// fragments, no raw JSON, no pf text. Anything the helper writes to disk is
// generated from these types by VPNCore.

// MARK: - Profile

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    /// 2: routes with server lists and per-route kill switch. Version 1
    /// (rules, a main tunnel, per-tunnel fallbacks) still loads and is
    /// converted.
    public static let currentSchema = 2

    public var schemaVersion: Int
    public var id: UUID
    /// What the user calls it ("Home", "Work") — shown in the menu bar.
    public var name: String
    /// The servers: tunnels and proxies. Connection details only — where
    /// traffic goes is decided by the routes.
    public var tunnels: [Tunnel]
    /// Checked top to bottom; the first match wins.
    public var routes: [Route]
    /// Everything no route claims. Its conditions are ignored.
    public var defaultRoute: Route
    public var dns: DNSSettings
    public var lan: LANPolicy
    /// Only `.always` still means something (blocking within one boot while
    /// off); otherwise protection follows the routes' kill switches.
    public var killSwitch: KillSwitchMode
    /// The tunnel interface's MTU; nil lets sing-box choose (9000). Lower it
    /// (1400, 1280) on networks where large packets get lost.
    public var mtu: Int?
    /// Lists of sites or addresses, by name; routes use them as
    /// `list:<name>`.
    public var lists: [RuleList] = []

    public static let mtuRange = 1280...9000

    public init(schemaVersion: Int = Profile.currentSchema, id: UUID = UUID(), name: String = "Profile",
                tunnels: [Tunnel] = [], routes: [Route] = [], defaultRoute: Route? = nil,
                dns: DNSSettings = .default, lan: LANPolicy = .allow, killSwitch: KillSwitchMode = .whileConnected,
                lists: [RuleList] = []) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.tunnels = tunnels
        self.routes = routes
        self.defaultRoute = defaultRoute ?? Route.everythingElse(servers: tunnels.first.map { [$0.id] } ?? [])
        self.dns = dns
        self.lan = lan
        self.killSwitch = killSwitch
        self.lists = lists
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, tunnels, routes, defaultRoute, dns, lan, killSwitch, mtu, lists
        // schema 1
        case mainTunnel, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        // Profiles saved before profiles had names lack id and name.
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Profile"
        tunnels = try c.decode([Tunnel].self, forKey: .tunnels)
        dns = try c.decode(DNSSettings.self, forKey: .dns)
        lan = try c.decode(LANPolicy.self, forKey: .lan)
        killSwitch = try c.decode(KillSwitchMode.self, forKey: .killSwitch)
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        lists = try c.decodeIfPresent([RuleList].self, forKey: .lists) ?? []
        if schemaVersion >= 2 {
            routes = try c.decode([Route].self, forKey: .routes)
            defaultRoute = try c.decode(Route.self, forKey: .defaultRoute)
        } else {
            // Schema 1: rules → routes; the main tunnel → "Everything else".
            // A tunnel's fallbacks and kill switch move to every route that
            // used it; a profile-wide "off" means no route blocks.
            let legacy = try c.decode([LegacyTunnel].self, forKey: .tunnels)
            let rules = try c.decodeIfPresent([LegacyRule].self, forKey: .rules) ?? []
            let main = try c.decodeIfPresent(UUID.self, forKey: .mainTunnel)
            let globalOff = killSwitch == .off
            func chain(_ id: UUID) -> [UUID] {
                var out = [id]
                for f in legacy.first(where: { $0.id == id })?.fallbacks ?? [] where !out.contains(f) { out.append(f) }
                return out
            }
            func ks(_ id: UUID) -> Bool { !globalOff && (legacy.first { $0.id == id }?.killSwitch ?? true) }
            func target(_ a: LegacyRule.Action) -> (Route.Target, Bool) {
                switch a {
                case .direct: (.direct, true)
                case .block: (.block, true)
                case .tunnel(let id): (.servers(chain(id)), ks(id))
                case .main: main.map { (.servers(chain($0)), ks($0)) } ?? (.direct, true)
                }
            }
            routes = rules.map { r in
                let (t, k) = target(r.action)
                return Route(id: r.id, name: r.name, enabled: r.enabled, conditions: r.conditions, target: t, killSwitch: k)
            }
            let (t, k) = target(.main)
            defaultRoute = Route.everythingElse(servers: [])
            defaultRoute.target = t
            defaultRoute.killSwitch = k
            schemaVersion = Profile.currentSchema
            if killSwitch == .off { killSwitch = .whileConnected }
        }
        if !c.contains(.lists) { adoptLegacyLists() }
    }

    /// Profiles from before lists (no `lists` at all) named the sing-box
    /// project's rule-sets `geoip:cn` and `geosite:…`; they read back as
    /// `list:geoip-cn`, and get the address they always came from.
    private mutating func adoptLegacyLists() {
        let legacy = [("geoip-", "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/"),
                      ("geosite-", "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/")]
        for r in routes {
            for case .list(let n) in r.conditions.destinations where !lists.contains(where: { $0.name == n }) {
                guard let (_, base) = legacy.first(where: { n.hasPrefix($0.0) }) else { continue }
                lists.append(RuleList(name: n, url: base + n + ".srs"))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(tunnels, forKey: .tunnels)
        try c.encode(routes, forKey: .routes)
        try c.encode(defaultRoute, forKey: .defaultRoute)
        try c.encode(dns, forKey: .dns)
        try c.encode(lan, forKey: .lan)
        try c.encode(killSwitch, forKey: .killSwitch)
        try c.encodeIfPresent(mtu, forKey: .mtu)
        // Always written, empty too: its absence marks a profile from before
        // lists (see adoptLegacyLists).
        try c.encode(lists, forKey: .lists)
    }

    struct LegacyTunnel: Decodable {
        var id: UUID
        var fallbacks: [UUID]?
        var killSwitch: Bool?
    }

    struct LegacyRule: Decodable {
        enum Action: Decodable { case main, tunnel(UUID), direct, block }
        var id: UUID
        var name: String
        var enabled: Bool
        var conditions: Conditions
        var action: Action
    }

    /// An example (tests, previews): one country's segment goes direct
    /// (traffic and DNS), everything else through the servers. New
    /// profiles start empty (`blank`).
    public static func example(name: String = "Profile", tunnels: [Tunnel] = []) -> Profile {
        Profile(name: name, tunnels: tunnels, routes: [
            Route(name: "Domestic", conditions: Conditions(destinations: domestic), target: .direct),
        ], dns: .exampleSplit, lists: domesticLists)
    }

    /// A new profile: no routes, nothing built in, and "Everything else"
    /// direct — it changes nothing until the user sends something through a
    /// server: a route of its own, or "Everything else" itself. (Through
    /// servers with none chosen yet, it could not be turned on at all, which
    /// left "only this app through the tunnel" stuck.)
    public static func blank(name: String) -> Profile {
        Profile(name: name, defaultRoute: Route(name: "Everything else", target: .direct))
    }

    /// The example's segment: addresses, site lists and domain zones.
    public static let domestic: [Destination] = [
        .list("geoip-cn"), .list("geosite-cn"), .list("geosite-geolocation-cn"),
        .domainSuffix("cn"), .domainSuffix("xn--fiqs8s"),
    ]

    /// The example's lists: the sing-box project's.
    public static let domesticLists = [
        RuleList(name: "geoip-cn", url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"),
        RuleList(name: "geosite-cn", url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"),
        RuleList(name: "geosite-geolocation-cn",
                 url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs"),
    ]

    public func tunnel(_ id: Tunnel.ID) -> Tunnel? { tunnels.first { $0.id == id } }

    /// Every route in evaluation order, the default one last.
    public var allRoutes: [Route] { routes + [defaultRoute] }

    public func route(_ id: Route.ID) -> Route? { allRoutes.first { $0.id == id } }

    /// The servers a route may use, in order: existing ones only, each once.
    public func chain(of r: Route) -> [Tunnel.ID] {
        guard case .servers(let ids) = r.target else { return [] }
        var out: [Tunnel.ID] = []
        for id in ids where !out.contains(id) && tunnel(id) != nil { out.append(id) }
        return out
    }

    /// Routes that currently send traffic to servers.
    public var serverRoutes: [Route] {
        allRoutes.filter { r in
            guard r.enabled || r.id == defaultRoute.id else { return false }
            if case .servers = r.target { return true }
            return false
        }
    }

    /// What pf does while sing-box itself is down (starting, restarting):
    /// block everything that bypasses it if any route in use has its kill
    /// switch on. While sing-box runs, each route decides for itself.
    public var protectionMode: KillSwitchMode {
        if killSwitch == .always { return .always }
        return serverRoutes.contains { $0.killSwitch } ? .whileConnected : .off
    }
}

public enum KillSwitchMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// No blocking at all.
    case off
    /// Blocking only while the VPN is on (and while it is reconnecting).
    /// After a reboot or a clean stop the network is open.
    case whileConnected
    /// Blocking from boot, before login, until the user turns it off.
    case always
}

public enum LANPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    /// Private and link-local ranges go directly (printers, AirDrop, router).
    case allow
    /// Private ranges are treated like any other destination.
    case block
}

public struct DNSSettings: Codable, Hashable, Sendable {
    /// Plain UDP resolver used for directly routed domains and for resolving
    /// the tunnel servers themselves.
    public var directServer: IPNetwork
    /// DNS-over-HTTPS resolver reached through the main tunnel.
    public var tunnelServer: IPNetwork
    /// Domain suffixes always resolved through `directServer`, in addition to
    /// the domains of rules that send traffic directly.
    public var directSuffixes: [String]
    /// Names only the local network knows (a NAS, a printer, the router's
    /// own page) are asked of the router's DNS — these zones only, and only
    /// while the local network is reachable directly. Everything else goes
    /// through Silent Route.
    public var localZones: [String]

    public static let defaultLocalZones = ["lan", "home.arpa", "internal"]

    public init(directServer: IPNetwork, tunnelServer: IPNetwork, directSuffixes: [String],
                localZones: [String] = DNSSettings.defaultLocalZones) {
        self.directServer = directServer
        self.tunnelServer = tunnelServer
        self.directSuffixes = directSuffixes
        self.localZones = localZones
    }

    enum CodingKeys: String, CodingKey { case directServer, tunnelServer, directSuffixes, localZones }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directServer = try c.decode(IPNetwork.self, forKey: .directServer)
        tunnelServer = try c.decode(IPNetwork.self, forKey: .tunnelServer)
        directSuffixes = try c.decode([String].self, forKey: .directSuffixes)
        // Added in 1.1.4: earlier profiles get the defaults.
        localZones = try c.decodeIfPresent([String].self, forKey: .localZones) ?? DNSSettings.defaultLocalZones
    }

    /// Neutral: nothing country-specific is built in. Names follow the
    /// routes; everything else is resolved over DoH through the tunnel.
    public static let `default` = DNSSettings(
        directServer: IPNetwork("1.1.1.1")!,
        tunnelServer: IPNetwork("1.1.1.1")!,
        directSuffixes: [])

    /// The example's split: its zones via a domestic resolver directly,
    /// everything else via DoH inside the tunnel.
    public static let exampleSplit = DNSSettings(
        directServer: IPNetwork("223.5.5.5")!,
        tunnelServer: IPNetwork("1.1.1.1")!,
        directSuffixes: ["cn", "xn--fiqs8s"])
}

// MARK: - Tunnel

public struct Endpoint: Codable, Hashable, Sendable {
    /// A hostname or an IP literal (IPv6 without brackets).
    public var host: String
    public var port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct Tunnel: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var server: Endpoint
    public var proto: TunnelProtocol
    /// Where it came from. A link is kept verbatim so it can be re-parsed
    /// after the parser learns something new.
    public var origin: Origin
    /// Several connections inside one, to a server that supports it (off
    /// when nil). See `Multiplex`.
    public var multiplex: Multiplex?
    /// The TLS handshake split up, for DPI that reads the server name
    /// (off when nil). See `TLSFragment`.
    public var tlsFragment: TLSFragment?

    public enum Origin: Codable, Hashable, Sendable {
        case link(String)
        case manual
    }

    public init(id: UUID = UUID(), name: String, server: Endpoint, proto: TunnelProtocol, origin: Origin = .manual) {
        self.id = id
        self.name = name
        self.server = server
        self.proto = proto
        self.origin = origin
    }

    /// Whether it carries UDP: a SOCKS5 proxy only with UDP turned on, an
    /// HTTP proxy never; tunnels always.
    public var carriesUDP: Bool {
        guard case .proxy(let p) = proto else { return true }
        return p.kind == .socks5 && p.udp
    }
}

/// sing-box multiplexing: many connections carried inside a few to the
/// server, instead of one each. Fewer handshakes, and `padding` blurs the
/// traffic's shape; but one slow connection can hold up the others, and
/// the server must have multiplexing enabled too, or nothing connects.
public struct Multiplex: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case h2mux, smux, yamux
    }
    public var kind: Kind
    /// Connections to the server at most; streams are spread over them.
    public var maxConnections: Int
    public var padding: Bool

    public init(kind: Kind = .h2mux, maxConnections: Int = 4, padding: Bool = false) {
        self.kind = kind
        self.maxConnections = maxConnections
        self.padding = padding
    }

    /// Hysteria2 is QUIC (multiplexed already); VLESS with XTLS Vision
    /// cannot be multiplexed; plain proxies do not speak it.
    public static func isSupported(by proto: TunnelProtocol) -> Bool {
        switch proto {
        case .vless(let v): v.flow == nil || v.flow?.isEmpty == true
        case .trojan, .shadowsocks, .vmess: true
        case .hysteria2, .proxy: false
        }
    }
}

/// sing-box TLS fragmentation: the ClientHello is split so that DPI
/// matching on its plain text (the server name) does not see it whole.
/// `records` splits it into several TLS records and costs nothing;
/// `packets` sends it in small TCP segments with pauses, slower, for DPI
/// that reassembles records.
public enum TLSFragment: String, Codable, CaseIterable, Sendable {
    case records, packets

    /// TLS over TCP only: Hysteria2 is QUIC. Not Reality: sing-box (1.13,
    /// 1.14) accepts the option there but does not split anything.
    public static func isSupported(by proto: TunnelProtocol) -> Bool {
        let tls: TLS?
        switch proto {
        case .vless(let v): tls = v.tls
        case .trojan(let t): tls = t.tls
        case .vmess(let v): tls = v.tls
        case .proxy(let p): tls = p.tls
        case .hysteria2, .shadowsocks: tls = nil
        }
        return tls != nil && tls?.reality == nil
    }
}

public enum TunnelProtocol: Codable, Hashable, Sendable {
    case hysteria2(Hysteria2)
    case vless(VLESS)
    case trojan(Trojan)
    case shadowsocks(Shadowsocks)
    case vmess(VMess)
    /// A plain SOCKS5 or HTTP(S) proxy — usable in rules exactly like a tunnel.
    case proxy(Proxy)

    public var displayName: String {
        switch self {
        case .proxy(let p):
            switch p.kind {
            case .socks5: "SOCKS5"
            case .http: p.tls != nil ? "HTTPS proxy" : "HTTP proxy"
            }
        case .hysteria2: "Hysteria2"
        case .vless(let v): v.tls?.reality != nil ? "VLESS Reality" : "VLESS"
        case .trojan: "Trojan"
        case .shadowsocks: "Shadowsocks"
        case .vmess: "VMess"
        }
    }
}

public struct TLS: Codable, Hashable, Sendable {
    public var serverName: String?
    public var alpn: [String]
    public var insecure: Bool
    /// uTLS client fingerprint ("chrome", "firefox", …); nil = Go's own.
    public var fingerprint: String?
    public var reality: Reality?

    public struct Reality: Codable, Hashable, Sendable {
        public var publicKey: String
        public var shortID: String
        public init(publicKey: String, shortID: String) {
            self.publicKey = publicKey
            self.shortID = shortID
        }
    }

    public init(serverName: String? = nil, alpn: [String] = [], insecure: Bool = false,
                fingerprint: String? = nil, reality: Reality? = nil) {
        self.serverName = serverName
        self.alpn = alpn
        self.insecure = insecure
        self.fingerprint = fingerprint
        self.reality = reality
    }
}

/// V2Ray-style transports carried by VLESS, VMess and Trojan.
public enum Transport: Codable, Hashable, Sendable {
    case tcp
    case ws(path: String, host: String?)
    case grpc(serviceName: String)
    case httpUpgrade(path: String, host: String?)
    case http(path: String, host: [String])
}

public struct Hysteria2: Codable, Hashable, Sendable {
    public var password: String
    public var obfsPassword: String?   // salamander, the only obfs type
    public var tls: TLS
    /// Port hopping ranges, sing-box syntax "20000:30000".
    public var serverPorts: [String]
    public var upMbps: Int?
    public var downMbps: Int?

    public init(password: String, obfsPassword: String? = nil, tls: TLS, serverPorts: [String] = [],
                upMbps: Int? = nil, downMbps: Int? = nil) {
        self.password = password
        self.obfsPassword = obfsPassword
        self.tls = tls
        self.serverPorts = serverPorts
        self.upMbps = upMbps
        self.downMbps = downMbps
    }
}

public struct VLESS: Codable, Hashable, Sendable {
    public var uuid: UUID
    public var flow: String?           // "xtls-rprx-vision"
    public var tls: TLS?
    public var transport: Transport

    public init(uuid: UUID, flow: String? = nil, tls: TLS? = nil, transport: Transport = .tcp) {
        self.uuid = uuid
        self.flow = flow
        self.tls = tls
        self.transport = transport
    }
}

public struct Trojan: Codable, Hashable, Sendable {
    public var password: String
    public var tls: TLS?
    public var transport: Transport

    public init(password: String, tls: TLS? = TLS(), transport: Transport = .tcp) {
        self.password = password
        self.tls = tls
        self.transport = transport
    }
}

public struct Shadowsocks: Codable, Hashable, Sendable {
    public var method: String
    public var password: String
    /// SIP003 plugin; sing-box supports "obfs-local" and "v2ray-plugin".
    public var plugin: String?
    public var pluginOptions: String?

    public init(method: String, password: String, plugin: String? = nil, pluginOptions: String? = nil) {
        self.method = method
        self.password = password
        self.plugin = plugin
        self.pluginOptions = pluginOptions
    }
}

public struct VMess: Codable, Hashable, Sendable {
    public var uuid: UUID
    public var security: String        // "auto", "aes-128-gcm", …
    public var alterID: Int
    public var tls: TLS?
    public var transport: Transport

    public init(uuid: UUID, security: String = "auto", alterID: Int = 0, tls: TLS? = nil, transport: Transport = .tcp) {
        self.uuid = uuid
        self.security = security
        self.alterID = alterID
        self.tls = tls
        self.transport = transport
    }
}

/// SOCKS5 or HTTP CONNECT proxy. Not a tunnel: the traffic to it is not
/// encrypted unless the proxy itself speaks TLS (HTTPS proxy), and HTTP
/// proxies carry TCP only.
public struct Proxy: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        case socks5
        case http
    }

    public var kind: Kind
    public var username: String?
    public var password: String?
    /// HTTPS proxy (TLS to the proxy). SOCKS5 has no TLS.
    public var tls: TLS?
    /// SOCKS5 only: UDP through the proxy (UDP ASSOCIATE). Off by default,
    /// as in most clients: each UDP flow (QUIC, HTTP/3 — Google uses it
    /// everywhere) holds a connection of its own to the proxy, and many
    /// proxies limit those or do not carry UDP well. Without it, browsers
    /// use TCP instead; UDP for such a route does not get through (nothing
    /// goes past the tunnel). An HTTP proxy never carries UDP.
    public var udp: Bool

    public init(kind: Kind, username: String? = nil, password: String? = nil, tls: TLS? = nil, udp: Bool = false) {
        self.kind = kind
        self.username = username
        self.password = password
        self.tls = tls
        self.udp = udp
    }

    enum CodingKeys: String, CodingKey { case kind, username, password, tls, udp }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        tls = try c.decodeIfPresent(TLS.self, forKey: .tls)
        // Profiles from before this setting: off, the new default.
        udp = try c.decodeIfPresent(Bool.self, forKey: .udp) ?? false
    }
}

// MARK: - Rules

/// A route: a named group of traffic and where it goes.
///
/// What it matches, deliberately simple: a connection matches when it
/// matches **any** destination AND **any** app AND **any** port AND the
/// protocol — each empty group is "anything". The generator writes this as
/// explicit logical rules, because sing-box's own grouping inside a single
/// rule is not the same.
///
/// Where it goes: directly, blocked, or through a list of servers (tunnels
/// and proxies, mixed) — the first that answers carries the traffic. When
/// none answers, the kill switch blocks the traffic, or it goes direct.
public struct Route: Codable, Hashable, Identifiable, Sendable {
    public enum Target: Codable, Hashable, Sendable {
        case direct
        case block
        /// In order of preference; the first is the route's own server.
        case servers([Tunnel.ID])
    }

    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var conditions: Conditions
    public var target: Target
    public var killSwitch: Bool
    /// Split the first packet of TLS connections (where the site's name is
    /// visible) into pieces. Meant for routes that go direct; through a
    /// tunnel the traffic is encrypted already.
    public var fragmentTLS: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, conditions: Conditions = Conditions(),
                target: Target, killSwitch: Bool = true, fragmentTLS: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.target = target
        self.killSwitch = killSwitch
        self.fragmentTLS = fragmentTLS
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, conditions, target, killSwitch, fragmentTLS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        conditions = try c.decode(Conditions.self, forKey: .conditions)
        target = try c.decode(Target.self, forKey: .target)
        killSwitch = try c.decode(Bool.self, forKey: .killSwitch)
        // Added in 1.1.3: earlier profiles have none.
        fragmentTLS = try c.decodeIfPresent(Bool.self, forKey: .fragmentTLS) ?? false
    }

    public static func everythingElse(servers: [Tunnel.ID]) -> Route {
        Route(name: "Everything else", target: servers.isEmpty ? .direct : .servers(servers))
    }

    public var servers: [Tunnel.ID] { if case .servers(let s) = target { s } else { [] } }
}

public struct Conditions: Codable, Hashable, Sendable {
    public var destinations: [Destination]
    public var apps: [AppMatcher]
    public var ports: [PortRange]
    public var network: Network?

    public init(destinations: [Destination] = [], apps: [AppMatcher] = [], ports: [PortRange] = [], network: Network? = nil) {
        self.destinations = destinations
        self.apps = apps
        self.ports = ports
        self.network = network
    }

    public var isEmpty: Bool { destinations.isEmpty && apps.isEmpty && ports.isEmpty && network == nil }
}

public enum Destination: Hashable, Sendable {
    case cidr(IPNetwork)
    /// The domain and all its subdomains.
    case domainSuffix(String)
    /// Exactly this name.
    case domain(String)
    case domainKeyword(String)
    /// One of the profile's lists, by name (`Profile.lists`).
    case list(String)
    /// Addresses of local networks — 10.0.0.0/8, 172.16.0.0/12,
    /// 192.168.0.0/16, link-local and the like — wherever the Mac is.
    case localNetwork
}

extension Destination: Codable {
    /// As stored, including what earlier versions wrote.
    private enum Stored: Codable {
        case cidr(IPNetwork), domainSuffix(String), domain(String), domainKeyword(String), list(String), localNetwork
        /// Before lists: a country's addresses, and a named site list.
        case geoIP(String), geoSite(String)
    }

    public init(from decoder: Decoder) throws {
        self = switch try Stored(from: decoder) {
        case .cidr(let n): .cidr(n)
        case .domainSuffix(let s): .domainSuffix(s)
        case .domain(let s): .domain(s)
        case .domainKeyword(let s): .domainKeyword(s)
        case .list(let n): .list(n)
        case .localNetwork: .localNetwork
        case .geoIP(let n): .list("geoip-" + n)
        case .geoSite(let n): .list("geosite-" + n)
        }
    }

    public func encode(to encoder: Encoder) throws {
        let s: Stored = switch self {
        case .cidr(let n): .cidr(n)
        case .domainSuffix(let v): .domainSuffix(v)
        case .domain(let v): .domain(v)
        case .domainKeyword(let v): .domainKeyword(v)
        case .list(let n): .list(n)
        case .localNetwork: .localNetwork
        }
        try s.encode(to: encoder)
    }
}

public enum AppMatcher: Codable, Hashable, Sendable {
    /// Everything inside an app bundle — the main binary and all helper
    /// processes (browsers and Electron apps run their traffic from helpers).
    case bundle(path: String)
    /// One executable, by absolute path.
    case executable(path: String)
    /// Any process with this executable name.
    case processName(String)
}

extension AppMatcher {
    /// Apple's web content: the system process that loads the web pages
    /// Apple's apps show — Safari, Mail, the App Store and others — one per
    /// app, all with this name, so traffic cannot tell them apart. A route
    /// takes it only as a setting of its own ("Apple web content"), never
    /// implied by an app.
    public static let webKitNetworking = AppMatcher.processName(webKitNetworkingName)
    public static let webKitNetworkingName = "com.apple.WebKit.Networking"

    /// Safari, by the link in /Applications (where people find it).
    public static let safari = AppMatcher.bundle(path: "/Applications/Safari.app")

    /// Safari, by the link in /Applications or where macOS keeps it.
    public var isSafari: Bool {
        guard case .bundle(let path) = self else { return false }
        var p = path
        while p.hasSuffix("/") { p.removeLast() }
        return SingBoxConfig.cryptexAppName(p) == "Safari.app"
    }
}

public struct PortRange: Codable, Hashable, Sendable {
    public var lower: UInt16
    public var upper: UInt16

    public init(_ port: UInt16) { lower = port; upper = port }
    public init(_ lower: UInt16, _ upper: UInt16) { self.lower = lower; self.upper = upper }
}

public enum Network: String, Codable, Hashable, Sendable {
    case tcp, udp
}
