import Foundation

/// Checks a profile before anything is generated from it. The helper runs this
/// on every profile it receives; a profile with errors is refused as a whole.
public enum Validation {
    public struct Issue: Hashable, Sendable, CustomStringConvertible {
        public enum Severity: Sendable { case error, warning }
        public var severity: Severity
        public var message: String
        /// What it is about, so the app can show it next to that thing.
        public var tunnel: UUID?
        public var route: UUID?
        public var description: String { "\(severity == .error ? "error" : "warning"): \(message)" }

        public init(severity: Severity, message: String, tunnel: UUID? = nil, rule: UUID? = nil) {
            self.severity = severity
            self.message = message
            self.tunnel = tunnel
            self.route = rule
        }
    }

    /// Hostname syntax: letters, digits, hyphens, dots; punycode for IDNs.
    /// Deliberately strict — these strings end up in configs.
    public static func isValidDomain(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 253 else { return false }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { l in
            !l.isEmpty && l.utf8.count <= 63 && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// Lowercases and strips a leading dot, so ".cn" and "CN" both mean "cn".
    public static func normalizeDomain(_ s: String) -> String {
        var d = s.trimmingCharacters(in: .whitespaces).lowercased()
        while d.hasPrefix(".") { d.removeFirst() }
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// Address databases and site lists are checked for their form only:
    /// any country or list can be used — one not shipped with the helper is
    /// downloaded by sing-box on first use.
    public static func check(_ profile: Profile) -> [Issue] {
        var issues: [Issue] = []
        func error(_ m: String, tunnel: UUID? = nil, rule: UUID? = nil) {
            issues.append(Issue(severity: .error, message: m, tunnel: tunnel, rule: rule))
        }
        func warn(_ m: String, tunnel: UUID? = nil, rule: UUID? = nil) {
            issues.append(Issue(severity: .warning, message: m, tunnel: tunnel, rule: rule))
        }

        if profile.schemaVersion != Profile.currentSchema {
            error("profile schema \(profile.schemaVersion) is not \(Profile.currentSchema)")
        }

        if let mtu = profile.mtu, !Profile.mtuRange.contains(mtu) {
            error("MTU \(mtu) is outside \(Profile.mtuRange.lowerBound)–\(Profile.mtuRange.upperBound)")
        }

        var ids: Set<UUID> = []
        for t in profile.tunnels {
            if !ids.insert(t.id).inserted { error("two servers share the id \(t.id)", tunnel: t.id) }
            if let m = t.multiplex {
                if !Multiplex.isSupported(by: t.proto) {
                    error("server \"\(t.name)\": \(t.proto.displayName) cannot be multiplexed", tunnel: t.id)
                }
                if !(1...16).contains(m.maxConnections) {
                    error("server \"\(t.name)\": multiplexing needs 1–16 connections", tunnel: t.id)
                }
            }
            if t.name.trimmingCharacters(in: .whitespaces).isEmpty { error("a server has no name", tunnel: t.id) }
            let host = t.server.host
            if IPNetwork.parseV4(host) == nil, IPNetwork.parseV6(host) == nil, !isValidDomain(host) {
                error("server \"\(t.name)\": bad address \"\(host)\"", tunnel: t.id)
            }
            if t.server.port == 0 { error("server \"\(t.name)\": port 0", tunnel: t.id) }
            issues += tunnelIssues(t)
        }

        var routeIDs: Set<UUID> = []
        for r in profile.allRoutes {
            let isDefault = r.id == profile.defaultRoute.id
            let label = "route \"\(r.name)\""
            if !routeIDs.insert(r.id).inserted { error("two routes share the id \(r.id)", rule: r.id) }
            if !isDefault, r.name.trimmingCharacters(in: .whitespaces).isEmpty {
                error("a route has no name", rule: r.id)
            }
            if !isDefault, r.conditions.isEmpty {
                error("\(label) has no conditions and would match everything", rule: r.id)
            }
            if case .servers(let list) = r.target {
                let existing = profile.chain(of: r)
                if existing.isEmpty {
                    error("\(label) has no servers to send traffic to", rule: r.id)
                } else if existing.count < list.count {
                    warn("\(label): a server in its list no longer exists and is skipped", rule: r.id)
                }
            }
            for d in r.conditions.destinations {
                switch d {
                case .cidr: break
                case .domain(let s), .domainSuffix(let s):
                    if !isValidDomain(normalizeDomain(s)) { error("\(label): bad domain \"\(s)\"", rule: r.id) }
                case .domainKeyword(let s):
                    if s.isEmpty || !s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) {
                        error("\(label): bad domain keyword \"\(s)\"", rule: r.id)
                    }
                case .geoSite(let n):
                    if n.range(of: #"^[a-z0-9][a-z0-9!@._-]*$"#, options: .regularExpression) == nil {
                        error("\(label): bad site list name \"\(n)\"", rule: r.id)
                    }
                case .geoIP(let c):
                    if c.range(of: #"^[a-z]{2}$"#, options: .regularExpression) == nil {
                        error("\(label): bad country code \"\(c)\" (two letters, like de)", rule: r.id)
                    }
                }
            }
            for a in r.conditions.apps {
                switch a {
                case .bundle(let p), .executable(let p):
                    if !p.hasPrefix("/") || p.contains("\n") {
                        error("\(label): app path must be absolute: \"\(p)\"", rule: r.id)
                    }
                case .processName(let n):
                    if n.isEmpty || n.contains("/") || n.contains("\n") {
                        error("\(label): bad process name \"\(n)\"", rule: r.id)
                    }
                }
            }
            for p in r.conditions.ports where p.lower == 0 || p.lower > p.upper {
                error("\(label): bad port range \(p.lower)-\(p.upper)", rule: r.id)
            }
            if r.target == .direct, r.conditions.destinations.contains(where: {
                if case .domainKeyword = $0 { true } else { false }
            }) {
                warn("\(label): keyword conditions match by the name the app connects to; with plain IP connections they never match", rule: r.id)
            }
        }

        for s in profile.dns.directSuffixes where !isValidDomain(normalizeDomain(s)) {
            error("bad direct DNS suffix \"\(s)\"")
        }
        return issues
    }

    /// X25519 public key as Xray prints it: 32 bytes, base64url without padding.
    static func isRealityPublicKey(_ s: String) -> Bool {
        guard s.count == 43, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return false
        }
        let std = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: std)?.count == 32
    }

    static func tunnelIssues(_ t: Tunnel) -> [Issue] {
        var out: [Issue] = []
        let label = "server \"\(t.name)\""
        func add(_ sev: Issue.Severity, _ m: String) {
            out.append(Issue(severity: sev, message: "\(label): \(m)", tunnel: t.id))
        }
        func tlsCheck(_ tls: TLS?) {
            guard let tls else { return }
            if tls.insecure {
                add(.warning, "certificate checks are off — anyone on the path can impersonate the server")
            }
            if let sni = tls.serverName, !Validation.isValidDomain(sni), IPNetwork.parseV4(sni) == nil {
                add(.error, "bad TLS server name \"\(sni)\"")
            }
        }
        switch t.proto {
        case .hysteria2(let h):
            if h.password.isEmpty { add(.error, "empty password") }
            tlsCheck(h.tls)
        case .vless(let v):
            tlsCheck(v.tls)
            if let r = v.tls?.reality {
                if !isRealityPublicKey(r.publicKey) {
                    add(.error, "the Reality public key is not a 32-byte base64url key")
                }
                if r.shortID.count > 16 || r.shortID.count % 2 != 0 || !r.shortID.allSatisfy(\.isHexDigit) {
                    add(.error, "the Reality short ID must be up to 16 hex digits, even length")
                }
            }
            if v.flow != nil, v.transport != .tcp {
                add(.error, "XTLS flow needs the plain TCP transport")
            }
        case .trojan(let tr):
            if tr.password.isEmpty { add(.error, "empty password") }
            tlsCheck(tr.tls)
        case .shadowsocks(let s):
            if s.password.isEmpty { add(.error, "empty password") }
        case .proxy(let p):
            tlsCheck(p.tls)
            if p.tls == nil {
                add(.warning, "a plain proxy is not encrypted — the network between you and the proxy sees the traffic\(p.password != nil ? " and the password" : "")")
            }
            if p.kind == .http {
                add(.warning, "an HTTP proxy carries TCP only — UDP (QUIC, calls, games) sent to it fails")
            }
            if (p.username == nil) != (p.password == nil) {
                add(.error, "give both a username and a password, or neither")
            }
        case .vmess(let v):
            tlsCheck(v.tls)
            if v.tls == nil { add(.warning, "VMess without TLS is easy to detect") }
        }
        return out
    }
}
