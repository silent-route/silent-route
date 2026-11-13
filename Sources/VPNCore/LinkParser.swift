import Foundation

/// Turns share links into tunnels.
///
/// The rule: **nothing is dropped silently.** Every query parameter is
/// either understood, or reported as a warning the user sees before saving.
/// Parameters that would change how the connection works but that sing-box
/// cannot do are errors, not warnings — a tunnel that only half-works is worse
/// than none.
public enum LinkParser {
    public struct Result: Sendable {
        public var tunnel: Tunnel
        public var warnings: [String]
    }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case unsupportedScheme(String)
        case malformed(String)
        case missing(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .unsupportedScheme(let s): "Unsupported link type \"\(s)\""
            case .malformed(let s): "Malformed link: \(s)"
            case .missing(let s): "The link has no \(s)"
            case .unsupported(let s): "Not supported by sing-box: \(s)"
            }
        }
    }

    /// Parses one link. `id` is injectable for deterministic tests.
    public static func parse(_ link: String, id: UUID = UUID()) throws(Failure) -> Result {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = text.range(of: "://") else { throw .malformed("no scheme") }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        let rest = String(text[schemeEnd.upperBound...])
        var r: Result
        switch scheme {
        case "hysteria2", "hy2": r = try hysteria2(rest, id: id)
        case "vless": r = try vless(rest, id: id)
        case "trojan": r = try trojan(rest, id: id)
        case "ss": r = try shadowsocks(rest, id: id)
        case "vmess": r = try vmess(rest, id: id)
        case "socks5", "socks5h", "socks": r = try proxy(rest, kind: .socks5, tls: false, id: id)
        case "http": r = try proxy(rest, kind: .http, tls: false, id: id)
        case "https": r = try proxy(rest, kind: .http, tls: true, id: id)
        default: throw .unsupportedScheme(scheme)
        }
        r.tunnel.origin = .link(text)
        return r
    }

    public enum Kind: Sendable { case tunnel, proxy }

    static let proxySchemes: Set<String> = ["socks5", "socks5h", "socks", "http", "https"]

    /// Parses a link pasted where the kind is already known (the add-exit
    /// sheet). A link of the other kind is refused with a clear message.
    /// For proxies the context removes the http(s) ambiguity: a missing port
    /// takes the default, and a bare `[user:pass@]host:port` is taken as
    /// the given `proxyKind`.
    public static func parse(_ link: String, expecting kind: Kind, proxyKind: Proxy.Kind = .socks5,
                             id: UUID = UUID()) throws(Failure) -> Result {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = text.range(of: "://").map { text[..<$0.lowerBound].lowercased() }
        switch kind {
        case .proxy:
            guard let scheme else {
                var r = try proxy(normalizedProxy(text) ?? text, kind: proxyKind, tls: false, id: id, lenient: true)
                r.tunnel.origin = .manual
                return r
            }
            guard proxySchemes.contains(scheme) else {
                throw .unsupported("a \(scheme):// link is a tunnel, not a proxy — add it as a tunnel")
            }
            var rest = String(text[text.range(of: "://")!.upperBound...])
            rest = normalizedProxy(rest) ?? rest
            var r = try proxy(rest, kind: scheme.hasPrefix("socks") ? .socks5 : .http, tls: scheme == "https",
                              id: id, lenient: true)
            r.tunnel.origin = .link(text)
            return r
        case .tunnel:
            if let scheme, proxySchemes.contains(scheme) {
                throw .unsupported("a \(scheme):// link is a proxy — add it as a proxy")
            }
            return try parse(text, id: id)
        }
    }

    /// A subscription body: links one per line, or the same base64-encoded.
    /// Returns what parsed and, separately, what did not, so one bad line does
    /// not hide the rest.
    public static func parseMany(_ body: String) -> (results: [Result], failures: [(line: String, error: Failure)]) {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://"), let decoded = base64Decode(text), decoded.contains("://") {
            text = decoded
        }
        var ok: [Result] = []
        var bad: [(String, Failure)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { continue }
            do { ok.append(try parse(l)) } catch { bad.append((l, error)) }
        }
        return (ok, bad)
    }

    // MARK: - Generic URL pieces

    /// scheme-less `userinfo@host:port/path?query#fragment`, split by hand:
    /// URLComponents rejects some real-world links (unencoded characters in
    /// passwords) and silently normalises others.
    struct Parts {
        var userinfo: String?          // percent-decoded
        var host: String
        var port: UInt16?
        var path: String
        var query: [(key: String, value: String)]   // percent-decoded, order kept
        var fragment: String?          // percent-decoded

        func value(_ key: String) -> String? { query.last { $0.key == key }?.value }
    }

    static func split(_ s: String) throws(Failure) -> Parts {
        var rest = Substring(s)
        var fragment: String?
        if let h = rest.firstIndex(of: "#") {
            fragment = percentDecode(String(rest[rest.index(after: h)...]))
            rest = rest[..<h]
        }
        var query: [(String, String)] = []
        if let q = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: q)...].split(separator: "&") where !pair.isEmpty {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                // '+' means space in form encoding, but in these links it is
                // far more often a literal '+' inside base64 keys. Keep it.
                query.append((percentDecode(String(kv[0])), kv.count > 1 ? percentDecode(String(kv[1])) : ""))
            }
            rest = rest[..<q]
        }
        var path = ""
        if let p = rest.firstIndex(of: "/") {
            path = percentDecode(String(rest[p...]))
            rest = rest[..<p]
        }
        var userinfo: String?
        if let at = rest.lastIndex(of: "@") {
            userinfo = percentDecode(String(rest[..<at]))
            rest = rest[rest.index(after: at)...]
        }
        var host: String
        var port: UInt16?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { throw .malformed("unclosed IPv6 bracket") }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { throw .malformed("text after IPv6 address") }
                port = try parsePort(String(after.dropFirst()))
            }
        } else if let c = rest.lastIndex(of: ":") {
            host = String(rest[..<c])
            port = try parsePort(String(rest[rest.index(after: c)...]))
        } else {
            host = String(rest)
        }
        host = host.lowercased()
        guard !host.isEmpty else { throw .missing("server address") }
        guard isValidHost(host) else { throw .malformed("bad server address \"\(host)\"") }
        return Parts(userinfo: userinfo, host: host, port: port, path: path, query: query, fragment: fragment)
    }

    static func parsePort(_ s: String) throws(Failure) -> UInt16 {
        guard !s.isEmpty, s.allSatisfy(\.isASCIIDigit), let p = UInt16(s), p > 0 else {
            throw .malformed("bad port \"\(s)\"")
        }
        return p
    }

    static func isValidHost(_ h: String) -> Bool {
        if IPNetwork.parseV4(h) != nil || IPNetwork.parseV6(h) != nil { return true }
        return Validation.isValidDomain(h)
    }

    static func percentDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    static func base64Decode(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Collects warnings for parameters nobody consumed.
    struct Params {
        let parts: Parts
        private(set) var used: Set<String> = []
        var warnings: [String] = []

        init(_ parts: Parts) { self.parts = parts }

        mutating func take(_ key: String) -> String? {
            used.insert(key)
            guard let v = parts.value(key), !v.isEmpty else { return nil }
            return v
        }

        /// Acknowledged but deliberately ignored, with the reason shown.
        mutating func ignore(_ key: String, because reason: String) {
            used.insert(key)
            if let v = parts.value(key), !v.isEmpty {
                warnings.append("\"\(key)=\(v)\" ignored: \(reason)")
            }
        }

        mutating func bool(_ key: String) -> Bool {
            guard let v = take(key)?.lowercased() else { return false }
            return v == "1" || v == "true" || v == "yes"
        }

        mutating func finish() -> [String] {
            var seen: Set<String> = []
            for (k, v) in parts.query where !used.contains(k) && seen.insert(k).inserted {
                warnings.append("Unknown parameter \"\(k)\(v.isEmpty ? "" : "=\(v)")\" — not applied")
            }
            return warnings
        }
    }

    static func name(_ parts: Parts, fallback: String) -> String {
        let n = parts.fragment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return n.isEmpty ? fallback : n
    }

    /// TLS server name when the link gives none: the host, unless it is an IP.
    static func defaultSNI(_ host: String) -> String? {
        IPNetwork.parseV4(host) == nil && IPNetwork.parseV6(host) == nil ? host : nil
    }

    static func alpn(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - hysteria2

    static func hysteria2(_ s: String, id: UUID) throws(Failure) -> Result {
        let parts = try split(s)
        var p = Params(parts)
        // The whole userinfo is the password; "user:pass" auth is sent as is.
        guard let password = parts.userinfo, !password.isEmpty else { throw .missing("password") }
        var tls = TLS(serverName: p.take("sni") ?? defaultSNI(parts.host),
                      alpn: alpn(p.take("alpn")))
        tls.insecure = p.bool("insecure")
        var obfsPassword: String?
        if let obfs = p.take("obfs") {
            guard obfs == "salamander" else { throw .unsupported("obfs \"\(obfs)\"") }
            guard let op = p.take("obfs-password") else { throw .missing("obfs-password") }
            obfsPassword = op
        } else if p.take("obfs-password") != nil {
            p.warnings.append("\"obfs-password\" without \"obfs\" — obfuscation not enabled")
        }
        if let pin = p.take("pinSHA256") {
            throw .unsupported("certificate pinning (pinSHA256=\(pin)) — refusing rather than connecting unpinned")
        }
        var ports: [String] = []
        if let m = p.take("mport") {
            for r in m.split(separator: ",") {
                let bounds = r.split(separator: "-").map(String.init)
                guard (1...2).contains(bounds.count), bounds.allSatisfy({ UInt16($0) != nil }) else {
                    throw .malformed("bad port hopping range \"\(r)\"")
                }
                ports.append(bounds.count == 1 ? "\(bounds[0]):\(bounds[0])" : "\(bounds[0]):\(bounds[1])")
            }
        }
        let up = p.take("upmbps").flatMap { Int($0.filter(\.isASCIIDigit)) }
        let down = p.take("downmbps").flatMap { Int($0.filter(\.isASCIIDigit)) }
        let h = Hysteria2(password: password, obfsPassword: obfsPassword, tls: tls, serverPorts: ports,
                          upMbps: up, downMbps: down)
        let port = parts.port ?? 443
        let t = Tunnel(id: id, name: name(parts, fallback: "\(parts.host):\(port)"),
                       server: Endpoint(host: parts.host, port: port), proto: .hysteria2(h))
        return Result(tunnel: t, warnings: p.finish())
    }

    // MARK: - VLESS / Trojan (shared V2Ray-style parameters)

    static func transport(_ p: inout Params, host: String) throws(Failure) -> Transport {
        let type = p.take("type")?.lowercased() ?? "tcp"
        switch type {
        case "tcp", "raw":
            if let ht = p.take("headerType"), ht != "none" {
                throw .unsupported("TCP header obfuscation \"\(ht)\"")
            }
            p.ignore("host", because: "only used by ws/http transports")
            p.ignore("path", because: "only used by ws/http transports")
            return .tcp
        case "ws":
            return .ws(path: p.take("path") ?? "/", host: p.take("host"))
        case "grpc":
            p.ignore("mode", because: "sing-box gRPC has no multi mode")
            return .grpc(serviceName: p.take("serviceName") ?? "")
        case "httpupgrade":
            return .httpUpgrade(path: p.take("path") ?? "/", host: p.take("host"))
        case "http", "h2":
            return .http(path: p.take("path") ?? "/", host: (p.take("host") ?? "").split(separator: ",").map(String.init))
        case "xhttp", "splithttp":
            throw .unsupported("transport \"\(type)\" (Xray only)")
        default:
            throw .unsupported("transport \"\(type)\"")
        }
    }

    static func tls(_ p: inout Params, host: String, defaultOn: Bool) throws(Failure) -> TLS? {
        let security = p.take("security")?.lowercased() ?? (defaultOn ? "tls" : "none")
        switch security {
        case "none", "":
            for k in ["sni", "fp", "alpn", "pbk", "sid", "spx", "allowInsecure"] {
                p.ignore(k, because: "TLS is off (security=none)")
            }
            return nil
        case "tls", "reality":
            let sni = p.take("sni"), peer = p.take("peer")
            var t = TLS(serverName: sni ?? peer, alpn: alpn(p.take("alpn")))
            t.insecure = p.bool("allowInsecure") || p.bool("insecure")
            t.fingerprint = p.take("fp")?.lowercased()
            if security == "reality" {
                guard let pbk = p.take("pbk") else { throw .missing("Reality public key (pbk)") }
                t.reality = .init(publicKey: pbk, shortID: p.take("sid") ?? "")
                p.ignore("spx", because: "sing-box has no Reality spider")
                if t.fingerprint == nil { t.fingerprint = "chrome" }   // Reality requires uTLS
                if let pqv = p.take("pqv") {
                    // An ML-DSA-65 verify key makes sing-box 1.13
                    // refuse the whole config. Better to say so here.
                    throw .unsupported("post-quantum Reality verification (pqv, \(pqv.prefix(12))…)")
                }
            } else {
                for k in ["pbk", "sid", "spx", "pqv"] { p.ignore(k, because: "only used with security=reality") }
            }
            if t.serverName == nil { t.serverName = defaultSNI(host) }
            return t
        default:
            throw .unsupported("security \"\(security)\"")
        }
    }

    static func vless(_ s: String, id: UUID) throws(Failure) -> Result {
        let parts = try split(s)
        var p = Params(parts)
        guard let u = parts.userinfo, !u.isEmpty else { throw .missing("user ID") }
        guard let uuid = UUID(uuidString: u) else { throw .malformed("user ID is not a UUID") }
        if let enc = p.take("encryption"), enc != "none" { throw .unsupported("VLESS encryption \"\(enc)\"") }
        let tls = try tls(&p, host: parts.host, defaultOn: false)
        let transport = try transport(&p, host: parts.host)
        var flow = p.take("flow")
        if let f = flow {
            guard f == "xtls-rprx-vision" || f == "xtls-rprx-vision-udp443" else { throw .unsupported("flow \"\(f)\"") }
            if f == "xtls-rprx-vision-udp443" {
                p.warnings.append("flow \"xtls-rprx-vision-udp443\" treated as \"xtls-rprx-vision\"")
                flow = "xtls-rprx-vision"
            }
        }
        p.ignore("packetEncoding", because: "sing-box uses xudp by default")
        let port = parts.port ?? 443
        let t = Tunnel(id: id, name: name(parts, fallback: "\(parts.host):\(port)"),
                       server: Endpoint(host: parts.host, port: port),
                       proto: .vless(VLESS(uuid: uuid, flow: flow, tls: tls, transport: transport)))
        return Result(tunnel: t, warnings: p.finish())
    }

    static func trojan(_ s: String, id: UUID) throws(Failure) -> Result {
        let parts = try split(s)
        var p = Params(parts)
        guard let password = parts.userinfo, !password.isEmpty else { throw .missing("password") }
        let tls = try tls(&p, host: parts.host, defaultOn: true)
        let transport = try transport(&p, host: parts.host)
        let port = parts.port ?? 443
        let t = Tunnel(id: id, name: name(parts, fallback: "\(parts.host):\(port)"),
                       server: Endpoint(host: parts.host, port: port),
                       proto: .trojan(Trojan(password: password, tls: tls, transport: transport)))
        return Result(tunnel: t, warnings: p.finish())
    }

    // MARK: - Proxies

    /// `socks5://user:pass@host:port#name`, `http://…`, `https://…`. Also the
    /// v2rayN form with base64("user:pass") as the userinfo.
    static func proxy(_ s: String, kind: Proxy.Kind, tls useTLS: Bool, id: UUID, lenient: Bool = false) throws(Failure) -> Result {
        let parts = try split(s)
        // http(s):// is also what a pasted web address looks like. Out of
        // context a proxy link must name its port and have no path; in the
        // add-proxy sheet (`lenient`) only the path is refused.
        if kind == .http, !(parts.path.isEmpty || parts.path == "/") || (!lenient && parts.port == nil) {
            throw .malformed("this looks like a web address; an HTTP proxy link is http://[user:pass@]host:port")
        }
        var p = Params(parts)
        var user: String?
        var pass: String?
        if var info = parts.userinfo, !info.isEmpty {
            if !info.contains(":"), let d = base64Decode(info), d.contains(":") { info = d }
            let up = info.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            user = up[0].isEmpty ? nil : up[0]
            pass = up.count > 1 && !up[1].isEmpty ? up[1] : nil
        }
        var tls: TLS?
        if useTLS {
            tls = TLS(serverName: p.take("sni") ?? defaultSNI(parts.host), insecure: p.bool("insecure") || p.bool("allowInsecure"))
        }
        let defaultPort: UInt16 = switch kind {
        case .socks5: 1080
        case .http: useTLS ? 443 : 8080
        }
        let port = parts.port ?? defaultPort
        let t = Tunnel(id: id, name: name(parts, fallback: "\(parts.host):\(port)"),
                       server: Endpoint(host: parts.host, port: port),
                       proto: .proxy(Proxy(kind: kind, username: user, password: pass, tls: tls)))
        return Result(tunnel: t, warnings: p.finish())
    }

    /// The forms proxy sellers hand out, rewritten as `user:pass@host:port`:
    ///
    ///     host:port:user:pass     user:pass:host:port
    ///     host:port@user:pass     user:pass@host:port
    ///     host:port user:pass     user:pass host:port
    ///     host:port|user:pass     user:pass|host:port
    ///
    /// Which half is the server is decided by its shape: an IP address or a
    /// domain name, then a port. Nil when the text is none of these; it is
    /// then parsed as it is.
    static func normalizedProxy(_ s: String) -> String? {
        var body = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = ""
        if let i = body.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            tail = String(body[i...])
            body = String(body[..<i])
        }
        guard !body.isEmpty, !body.contains("["), !body.contains("/") else { return nil }

        func server(_ x: Substring) -> (host: String, port: String)? {
            let p = x.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 2, !p[1].isEmpty, p[1].allSatisfy(\.isASCIIDigit), let n = UInt16(p[1]), n > 0 else { return nil }
            let host = String(p[0]).lowercased()
            guard host.contains(".") || host == "localhost", isValidHost(host) else { return nil }
            return (host, String(p[1]))
        }
        func build(_ host: (host: String, port: String), user: Substring, pass: Substring) -> String? {
            guard !user.isEmpty else { return nil }
            let u = String(user).addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? String(user)
            let p = String(pass).addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? String(pass)
            return (p.isEmpty ? u : "\(u):\(p)") + "@\(host.host):\(host.port)" + tail
        }
        func credentials(_ x: Substring) -> (Substring, Substring) {
            guard let c = x.firstIndex(of: ":") else { return (x, "") }
            return (x[..<c], x[x.index(after: c)...])
        }

        // Two halves around a separator: the server on either side.
        for (i, ch) in zip(body.indices, body) where ch == "@" || ch == "|" || ch == " " || ch == "\t" {
            let a = body[..<i].trimmingCharacters(in: .whitespaces)[...]
            let b = body[body.index(after: i)...].trimmingCharacters(in: .whitespaces)[...]
            if let srv = server(b), server(a) == nil || ch == "@" {
                // user:pass@host:port is already the standard form.
                if ch == "@" { return nil }
                let (u, p) = credentials(a)
                if let r = build(srv, user: u, pass: p) { return r }
            }
            if let srv = server(a), server(b) == nil {
                let (u, p) = credentials(b)
                if let r = build(srv, user: u, pass: p) { return r }
            }
        }

        // No separator: four (or more) fields joined by colons.
        let f = body.split(separator: ":", omittingEmptySubsequences: false)
        guard f.count >= 4 else { return nil }
        if let srv = server(body[f[0].startIndex..<f[1].endIndex]) {
            return build(srv, user: f[2], pass: body[f[3].startIndex...])
        }
        if let srv = server(body[f[f.count - 2].startIndex..<f[f.count - 1].endIndex]) {
            return build(srv, user: f[0], pass: body[f[1].startIndex..<f[f.count - 3].endIndex])
        }
        return nil
    }

    // MARK: - Shadowsocks

    public static let ssMethods: Set<String> = [
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
        "aes-128-gcm", "aes-192-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "none",
    ]

    static func shadowsocks(_ s: String, id: UUID) throws(Failure) -> Result {
        var body = s
        // Legacy form: ss://base64(method:password@host:port)#name
        let beforeFragment = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        if !beforeFragment.contains("@"), let decoded = base64Decode(beforeFragment), decoded.contains("@") {
            body = decoded + (body.contains("#") ? "#" + body.split(separator: "#", maxSplits: 1)[1] : "")
        }
        let parts = try split(body)
        var p = Params(parts)
        guard let info = parts.userinfo, !info.isEmpty else { throw .missing("method and password") }
        // SIP002: userinfo is base64(method:password), or plain for 2022 methods.
        var creds = info
        if !info.contains(":"), let d = base64Decode(info) { creds = d }
        let mp = creds.split(separator: ":", maxSplits: 1).map(String.init)
        guard mp.count == 2, !mp[1].isEmpty else { throw .malformed("method and password not found") }
        let method = mp[0].lowercased()
        guard ssMethods.contains(method) else { throw .unsupported("Shadowsocks method \"\(method)\"") }
        var plugin: String?
        var opts: String?
        if let pl = p.take("plugin"), !pl.isEmpty {
            // "name;options"; a value with no name (";…") names no plugin.
            let pieces = pl.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let given = pieces.first, !given.isEmpty else { throw .malformed("the plugin has no name") }
            let name = given == "simple-obfs" ? "obfs-local" : given
            guard name == "obfs-local" || name == "v2ray-plugin" else { throw .unsupported("plugin \"\(given)\"") }
            plugin = name
            opts = pieces.count > 1 ? pieces[1] : nil
        }
        guard let port = parts.port else { throw .missing("port") }
        let t = Tunnel(id: id, name: name(parts, fallback: "\(parts.host):\(port)"),
                       server: Endpoint(host: parts.host, port: port),
                       proto: .shadowsocks(Shadowsocks(method: method, password: mp[1], plugin: plugin, pluginOptions: opts)))
        return Result(tunnel: t, warnings: p.finish())
    }

    // MARK: - VMess (base64 JSON, the v2rayN format)

    static func vmess(_ s: String, id: UUID) throws(Failure) -> Result {
        let encoded = s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s
        guard let json = base64Decode(encoded), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("VMess body is not base64 JSON")
        }
        func str(_ k: String) -> String? {
            switch obj[k] {
            case let s as String: s.isEmpty ? nil : s
            case let n as NSNumber: n.stringValue
            default: nil
            }
        }
        var warnings: [String] = []
        guard let host = str("add")?.lowercased(), isValidHost(host) else { throw .missing("server address") }
        guard let portText = str("port"), let port = UInt16(portText), port > 0 else { throw .malformed("bad port") }
        guard let uuid = str("id").flatMap(UUID.init(uuidString:)) else { throw .malformed("user ID is not a UUID") }
        let aid = Int(str("aid") ?? "0") ?? 0
        let net = str("net")?.lowercased() ?? "tcp"
        let transport: Transport
        switch net {
        case "tcp":
            if let t = str("type"), t != "none" { throw .unsupported("TCP header obfuscation \"\(t)\"") }
            transport = .tcp
        case "ws": transport = .ws(path: str("path") ?? "/", host: str("host"))
        case "grpc": transport = .grpc(serviceName: str("path") ?? "")
        case "httpupgrade": transport = .httpUpgrade(path: str("path") ?? "/", host: str("host"))
        case "h2", "http": transport = .http(path: str("path") ?? "/", host: (str("host") ?? "").split(separator: ",").map(String.init))
        default: throw .unsupported("transport \"\(net)\"")
        }
        var tls: TLS?
        if str("tls") == "tls" {
            tls = TLS(serverName: str("sni") ?? defaultSNI(host),
                      alpn: alpn(str("alpn")), fingerprint: str("fp"))
        }
        let known: Set<String> = ["v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "alpn", "fp"]
        for k in obj.keys.sorted() where !known.contains(k) {
            warnings.append("Unknown field \"\(k)\" — not applied")
        }
        let name: String = {
            let n = str("ps")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty ? "\(host):\(port)" : n
        }()
        let t = Tunnel(id: id, name: name, server: Endpoint(host: host, port: port),
                       proto: .vmess(VMess(uuid: uuid, security: str("scy") ?? "auto", alterID: aid, tls: tls, transport: transport)))
        return Result(tunnel: t, warnings: warnings)
    }
}
