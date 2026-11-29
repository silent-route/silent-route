import Foundation
import VPNCore

/// The add/edit server form as plain fields. Built from a pasted link or an
/// existing exit, turned back into a Tunnel by `build()`, which says what is
/// wrong in words a person can act on.
struct ServerDraft: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case tunnel = "Tunnel", proxy = "Proxy"
        var id: Self { self }
    }

    enum Proto: String, CaseIterable, Identifiable {
        case hysteria2 = "Hysteria2", vless = "VLESS", trojan = "Trojan", shadowsocks = "Shadowsocks", vmess = "VMess"
        var id: Self { self }
    }

    enum Security: String, CaseIterable, Identifiable {
        case none = "None", tls = "TLS", reality = "Reality"
        var id: Self { self }
    }

    enum TransportKind: String, CaseIterable, Identifiable {
        case tcp = "TCP", ws = "WebSocket", grpc = "gRPC", httpUpgrade = "HTTPUpgrade", http = "HTTP/2"
        var id: Self { self }
    }

    enum ProxyType: String, CaseIterable, Identifiable {
        case socks5 = "SOCKS5", http = "HTTP", https = "HTTPS"
        var id: Self { self }
    }

    var kind: Kind = .tunnel
    var name = ""
    var host = ""
    var port = ""

    var proto: Proto = .vless
    var password = ""
    var obfsPassword = ""
    var portHopping = ""
    var uuid = ""
    var flow = ""
    var security: Security = .tls
    var sni = ""
    var alpn = ""
    var fingerprint = ""
    var insecure = false
    var realityKey = ""
    var realityShortID = ""
    var transport: TransportKind = .tcp
    var path = ""
    var transportHost = ""
    var serviceName = ""
    var ssMethod = "2022-blake3-aes-128-gcm"
    var vmessSecurity = "auto"

    var proxyType: ProxyType = .socks5
    var username = ""
    /// SOCKS5: UDP through the proxy (see Proxy.udp).
    var proxyUDP = false

    /// New servers start with it on: a failed handshake can get the
    /// server's address blocked for a while, before anyone thinks of it.
    var tlsFragment: TLSFragment? = .records

    var muxOn = false
    var muxKind: Multiplex.Kind = .h2mux
    var muxConnections = 4
    var muxPadding = false

    /// What a link can set but the form has no field for: kept as it came,
    /// so adding or editing the server does not lose it.
    var ssPlugin: String?
    var ssPluginOptions: String?
    var upMbps: Int?
    var downMbps: Int?
    var vmessAlterID = 0

    /// Kept from the server being edited.
    var id = UUID()
    /// The link the fields came from, kept as the origin if nothing changed.
    var sourceLink: String?
    var sourceTunnel: Tunnel?

    init(kind: Kind = .tunnel) { self.kind = kind }

    init(_ t: Tunnel) {
        id = t.id
        name = t.name
        host = t.server.host
        port = String(t.server.port)
        if case .link(let l) = t.origin { sourceLink = l }
        sourceTunnel = t
        tlsFragment = t.tlsFragment
        if let m = t.multiplex {
            muxOn = true
            muxKind = m.kind
            muxConnections = m.maxConnections
            muxPadding = m.padding
        }
        func takeTLS(_ tls: TLS?) {
            guard let tls else { security = .none; return }
            security = tls.reality != nil ? .reality : .tls
            sni = tls.serverName ?? ""
            alpn = tls.alpn.joined(separator: ",")
            fingerprint = tls.fingerprint ?? ""
            insecure = tls.insecure
            realityKey = tls.reality?.publicKey ?? ""
            realityShortID = tls.reality?.shortID ?? ""
        }
        func takeTransport(_ tr: Transport) {
            switch tr {
            case .tcp: transport = .tcp
            case .ws(let p, let h): transport = .ws; path = p; transportHost = h ?? ""
            case .grpc(let s): transport = .grpc; serviceName = s
            case .httpUpgrade(let p, let h): transport = .httpUpgrade; path = p; transportHost = h ?? ""
            case .http(let p, let h): transport = .http; path = p; transportHost = h.joined(separator: ",")
            }
        }
        switch t.proto {
        case .hysteria2(let h):
            kind = .tunnel; proto = .hysteria2
            password = h.password
            obfsPassword = h.obfsPassword ?? ""
            portHopping = h.serverPorts.joined(separator: ", ")
            upMbps = h.upMbps
            downMbps = h.downMbps
            takeTLS(h.tls)
        case .vless(let v):
            kind = .tunnel; proto = .vless
            uuid = v.uuid.uuidString.lowercased()
            flow = v.flow ?? ""
            takeTLS(v.tls)
            takeTransport(v.transport)
        case .trojan(let tr):
            kind = .tunnel; proto = .trojan
            password = tr.password
            takeTLS(tr.tls)
            takeTransport(tr.transport)
        case .shadowsocks(let s):
            kind = .tunnel; proto = .shadowsocks
            ssMethod = s.method
            password = s.password
            ssPlugin = s.plugin
            ssPluginOptions = s.pluginOptions
        case .vmess(let v):
            kind = .tunnel; proto = .vmess
            uuid = v.uuid.uuidString.lowercased()
            vmessSecurity = v.security
            vmessAlterID = v.alterID
            takeTLS(v.tls)
            takeTransport(v.transport)
        case .proxy(let p):
            kind = .proxy
            proxyType = p.kind == .socks5 ? .socks5 : (p.tls != nil ? .https : .http)
            username = p.username ?? ""
            password = p.password ?? ""
            proxyUDP = p.udp
            sni = p.tls?.serverName ?? ""
            insecure = p.tls?.insecure ?? false
        }
    }

    /// Which protocol fields apply.
    /// Multiplexing applies: not Hysteria2 (QUIC), not VLESS with XTLS
    /// Vision, not plain proxies.
    var supportsMux: Bool {
        guard kind == .tunnel else { return false }
        switch proto {
        case .trojan, .shadowsocks, .vmess: return true
        case .vless: return flow.isEmpty
        case .hysteria2: return false
        }
    }

    var usesTLSChoice: Bool { kind == .tunnel && [.vless, .trojan, .vmess].contains(proto) }
    var usesTransport: Bool { kind == .tunnel && [.vless, .trojan, .vmess].contains(proto) }
    var tlsOn: Bool {
        switch kind {
        case .proxy: proxyType == .https
        case .tunnel: proto == .hysteria2 || (usesTLSChoice && security != .none)
        }
    }

    struct Problem: Error { var message: String }

    func build() throws(Problem) -> Tunnel {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !h.isEmpty else { throw Problem(message: "Enter the server address") }
        let defaultPort: UInt16 = kind == .proxy ? (proxyType == .socks5 ? 1080 : proxyType == .https ? 443 : 8080) : 443
        let portText = port.trimmingCharacters(in: .whitespaces)
        guard let p = portText.isEmpty ? defaultPort : UInt16(portText), p > 0 else {
            throw Problem(message: "The port is a number from 1 to 65535")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        func tls() -> TLS {
            TLS(serverName: clean(sni) ?? (IPNetwork(h) == nil ? h : nil),
                alpn: alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                insecure: insecure, fingerprint: clean(fingerprint),
                // Reality is VLESS's alone: a choice left from VLESS before
                // another protocol was picked does not carry over.
                reality: security == .reality && proto == .vless ? .init(publicKey: realityKey.trimmingCharacters(in: .whitespaces),
                                                      shortID: realityShortID.trimmingCharacters(in: .whitespaces)) : nil)
        }
        func uuidValue() throws(Problem) -> UUID {
            guard let u = UUID(uuidString: uuid.trimmingCharacters(in: .whitespaces)) else {
                throw Problem(message: "The UUID looks like 1b2c3d4e-0000-4000-8000-123456789abc")
            }
            return u
        }
        func transportValue() -> Transport {
            switch transport {
            case .tcp: .tcp
            case .ws: .ws(path: clean(path) ?? "/", host: clean(transportHost))
            case .grpc: .grpc(serviceName: serviceName.trimmingCharacters(in: .whitespaces))
            case .httpUpgrade: .httpUpgrade(path: clean(path) ?? "/", host: clean(transportHost))
            case .http: .http(path: clean(path) ?? "/", host: transportHost.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }

        let protocolValue: TunnelProtocol
        switch kind {
        case .proxy:
            let user = clean(username), pass = clean(password)
            protocolValue = .proxy(Proxy(kind: proxyType == .socks5 ? .socks5 : .http, username: user, password: pass,
                                         tls: proxyType == .https ? TLS(serverName: clean(sni) ?? (IPNetwork(h) == nil ? h : nil), insecure: insecure) : nil,
                                         udp: proxyType == .socks5 && proxyUDP))
        case .tunnel:
            switch proto {
            case .hysteria2:
                protocolValue = .hysteria2(Hysteria2(password: password, obfsPassword: clean(obfsPassword), tls: tls(),
                                                     serverPorts: portHopping.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                                     upMbps: upMbps, downMbps: downMbps))
            case .vless:
                protocolValue = .vless(VLESS(uuid: try uuidValue(), flow: clean(flow), tls: security == .none ? nil : tls(),
                                             transport: transportValue()))
            case .trojan:
                protocolValue = .trojan(Trojan(password: password, tls: security == .none ? nil : tls(), transport: transportValue()))
            case .shadowsocks:
                protocolValue = .shadowsocks(Shadowsocks(method: ssMethod, password: password,
                                                         plugin: ssPlugin, pluginOptions: ssPluginOptions))
            case .vmess:
                protocolValue = .vmess(VMess(uuid: try uuidValue(), security: vmessSecurity, alterID: vmessAlterID,
                                             tls: security == .none ? nil : tls(),
                                             transport: transportValue()))
            }
        }
        var t = Tunnel(id: id, name: trimmedName.isEmpty ? "\(h):\(p)" : trimmedName, server: Endpoint(host: h, port: p),
                       proto: protocolValue, origin: .manual)
        if TLSFragment.isSupported(by: t.proto) { t.tlsFragment = tlsFragment }
        if muxOn, supportsMux {
            t.multiplex = Multiplex(kind: muxKind, maxConnections: muxConnections, padding: muxPadding)
        }
        // Still exactly what the link said: keep the link as its origin.
        if let link = sourceLink, let src = sourceTunnel, src.server == t.server, src.proto == t.proto {
            t.origin = .link(link)
        }
        return t
    }
}
