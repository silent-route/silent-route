import Foundation
import Testing
@testable import VPNCore

// All servers, passwords and keys below are fictitious.

@Suite struct LinkParserTests {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: proxies

    @Test func socks5WithCredentials() throws {
        let r = try LinkParser.parse("socks5://alice:p%40ss@198.51.100.4:8000#lv", id: id)
        #expect(r.warnings.isEmpty)
        #expect(r.tunnel.name == "lv")
        #expect(r.tunnel.server == Endpoint(host: "198.51.100.4", port: 8000))
        #expect(r.tunnel.proto == .proxy(Proxy(kind: .socks5, username: "alice", password: "p@ss")))
    }

    @Test func proxyVariants() throws {
        // v2rayN: base64("user:pass") as userinfo; socks5h and bare socks are SOCKS5.
        let b64 = Data("bob:pw".utf8).base64EncodedString()
        #expect(try LinkParser.parse("socks://\(b64)@proxy.example.org:1080").tunnel.proto
                == .proxy(Proxy(kind: .socks5, username: "bob", password: "pw")))
        #expect(try LinkParser.parse("socks5h://proxy.example.org").tunnel.server.port == 1080)
        #expect(try LinkParser.parse("http://proxy.example.org:3128").tunnel.proto == .proxy(Proxy(kind: .http)))
        #expect(throws: LinkParser.Failure.self) { try LinkParser.parse("https://www.youtube.com/watch?v=1") }
        let https = try LinkParser.parse("https://u:p@proxy.example.org:443")
        #expect(https.tunnel.server.port == 443)
        #expect(https.tunnel.proto == .proxy(Proxy(kind: .http, username: "u", password: "p",
                                                    tls: TLS(serverName: "proxy.example.org"))))
        #expect(https.tunnel.proto.displayName == "HTTPS proxy")
    }

    /// The shapes proxy sellers use, in the proxy sheet. Fictitious values.
    @Test(arguments: [
        "203.0.113.7:8514:User42:Pa55word",
        "203.0.113.7:8514 User42:Pa55word",
        "203.0.113.7:8514@User42:Pa55word",
        "203.0.113.7:8514|User42:Pa55word",
        "User42:Pa55word:203.0.113.7:8514",
        "User42:Pa55word@203.0.113.7:8514",
        "User42:Pa55word|203.0.113.7:8514",
        "User42:Pa55word 203.0.113.7:8514",
        "  socks5://203.0.113.7:8514:User42:Pa55word  ",
    ])
    func sellerProxyFormats(_ text: String) throws {
        let t = try LinkParser.parse(text, expecting: .proxy).tunnel
        #expect(t.server == Endpoint(host: "203.0.113.7", port: 8514))
        #expect(t.proto == .proxy(Proxy(kind: .socks5, username: "User42", password: "Pa55word")))
    }

    @Test func sellerProxyFormatsWithDomainsAndOddPasswords() throws {
        let a = try LinkParser.parse("proxy.example.org:3128:bob:p:a@ss", expecting: .proxy, proxyKind: .http).tunnel
        #expect(a.server == Endpoint(host: "proxy.example.org", port: 3128))
        #expect(a.proto == .proxy(Proxy(kind: .http, username: "bob", password: "p:a@ss")))
        let b = try LinkParser.parse("bob:p:a@ss:proxy.example.org:3128", expecting: .proxy).tunnel
        #expect(b.server == Endpoint(host: "proxy.example.org", port: 3128))
        #expect(b.proto == .proxy(Proxy(kind: .socks5, username: "bob", password: "p:a@ss")))
        // Plain host:port and bad text are left to the usual parser.
        #expect(try LinkParser.parse("203.0.113.7:1080", expecting: .proxy).tunnel.server.port == 1080)
        #expect(throws: LinkParser.Failure.self) { try LinkParser.parse("not a proxy at all", expecting: .proxy) }
    }

    @Test func theKindIsEnforcedWhereItIsKnown() throws {
        #expect(throws: LinkParser.Failure.self) { try LinkParser.parse("socks5://h.example.org:1080", expecting: .tunnel) }
        #expect(throws: LinkParser.Failure.self) {
            try LinkParser.parse("trojan://p@h.example.org:443", expecting: .proxy)
        }
        // In the proxy sheet: no port needed, bare host:port works.
        #expect(try LinkParser.parse("http://proxy.example.org", expecting: .proxy).tunnel.server.port == 8080)
        let bare = try LinkParser.parse("u:p@198.51.100.4:3128", expecting: .proxy, proxyKind: .http).tunnel
        #expect(bare.proto == .proxy(Proxy(kind: .http, username: "u", password: "p")))
        #expect(bare.server == Endpoint(host: "198.51.100.4", port: 3128))
        #expect(try LinkParser.parse("hy2://pw@h.example.org:443", expecting: .tunnel).tunnel.proto.displayName == "Hysteria2")
    }

    @Test func plainProxyIsWarnedAbout() throws {
        let t = try LinkParser.parse("socks5://u:p@198.51.100.4:8000").tunnel
        let issues = Validation.check(Profile.example(tunnels: [t]))
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("not encrypted") })
        #expect(!issues.contains { $0.severity == .error })
    }

    // MARK: hysteria2

    @Test func hysteria2WithObfs() throws {
        let link = "hysteria2://s3cret@vpn.example.org:443?sni=vpn.example.org&obfs=salamander&obfs-password=0bfs#h2-nl"
        let r = try LinkParser.parse(link, id: id)
        #expect(r.warnings.isEmpty)
        #expect(r.tunnel.name == "h2-nl")
        #expect(r.tunnel.server == Endpoint(host: "vpn.example.org", port: 443))
        #expect(r.tunnel.origin == .link(link))
        guard case .hysteria2(let h) = r.tunnel.proto else { Issue.record("not hysteria2"); return }
        #expect(h.password == "s3cret")
        #expect(h.obfsPassword == "0bfs")
        #expect(h.tls.serverName == "vpn.example.org")
        #expect(!h.tls.insecure)
    }

    @Test func hysteria2XrayFinalMask() throws {
        // Xray's form: salamander inside "fm", and security=tls.
        let fm = #"{"udp":[{"settings":{"password":"m4sk"},"type":"salamander"}]}"#
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let r = try LinkParser.parse("hysteria2://pw@h.example.org:35361?security=tls&fm=\(fm)&sni=h.example.org#x")
        #expect(r.warnings.isEmpty)
        guard case .hysteria2(let h) = r.tunnel.proto else { Issue.record("not hysteria2"); return }
        #expect(h.obfsPassword == "m4sk")

        let gecko = #"{"udp":[{"type":"gecko"}]}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(throws: LinkParser.Failure.unsupported("obfs \"gecko\"")) {
            try LinkParser.parse("hysteria2://pw@h.example.org?fm=\(gecko)")
        }
        #expect(throws: (any Error).self) { try LinkParser.parse("hysteria2://pw@h.example.org?fm=nope") }
        #expect(throws: (any Error).self) { try LinkParser.parse("hysteria2://pw@h.example.org?security=none") }
    }

    @Test func hysteria2UserPassIsPercentDecoded() throws {
        // "user%3Apass" in userinfo is "user:pass" auth, sent as one password.
        let r = try LinkParser.parse("hy2://alice%3Ap%40ss@203.0.113.7:1893?insecure=1#x")
        guard case .hysteria2(let h) = r.tunnel.proto else { Issue.record("not hysteria2"); return }
        #expect(h.password == "alice:p@ss")
        #expect(h.tls.serverName == nil)          // IP host: no SNI guessed
        #expect(h.tls.insecure)
        #expect(r.tunnel.server.port == 1893)
    }

    @Test func hysteria2PortHoppingAndDefaults() throws {
        let r = try LinkParser.parse("hysteria2://pw@h.example.org/?mport=20000-30000,443")
        guard case .hysteria2(let h) = r.tunnel.proto else { Issue.record("not hysteria2"); return }
        #expect(h.serverPorts == ["20000:30000", "443:443"])
        #expect(r.tunnel.server.port == 443)
        #expect(r.tunnel.name == "h.example.org:443")
    }

    @Test func hysteria2Refusals() {
        #expect(throws: LinkParser.Failure.missing("password")) { try LinkParser.parse("hysteria2://h.example.org:443") }
        #expect(throws: LinkParser.Failure.unsupported("obfs \"gecko\"")) {
            try LinkParser.parse("hysteria2://pw@h.example.org?obfs=gecko&obfs-password=x")
        }
        #expect(throws: LinkParser.Failure.missing("obfs-password")) {
            try LinkParser.parse("hysteria2://pw@h.example.org?obfs=salamander")
        }
        // Pinning cannot be honoured; connecting without it would be a silent downgrade.
        #expect(throws: (any Error).self) { try LinkParser.parse("hysteria2://pw@h.example.org?pinSHA256=ab:cd") }
    }

    @Test func unknownParametersAreReportedNotDropped() throws {
        let r = try LinkParser.parse("hysteria2://pw@h.example.org?sni=h.example.org&foo=bar&lazy=1")
        #expect(r.warnings == [
            "Unknown parameter \"foo=bar\" — not applied",
            "Unknown parameter \"lazy=1\" — not applied",
        ])
    }

    // MARK: VLESS

    static let uuid = "11111111-2222-3333-4444-555555555555"

    @Test func vlessReality() throws {
        let link = "vless://\(Self.uuid)@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality"
            + "&sni=www.example.com&fp=chrome&pbk=PUBKEYbase64_-x&sid=6ba85179e30d4fc2&spx=%2F&type=tcp&headerType=none#reality"
        let r = try LinkParser.parse(link)
        guard case .vless(let v) = r.tunnel.proto else { Issue.record("not vless"); return }
        #expect(v.uuid == UUID(uuidString: Self.uuid))
        #expect(v.flow == "xtls-rprx-vision")
        #expect(v.transport == .tcp)
        #expect(v.tls?.serverName == "www.example.com")
        #expect(v.tls?.fingerprint == "chrome")
        #expect(v.tls?.reality == TLS.Reality(publicKey: "PUBKEYbase64_-x", shortID: "6ba85179e30d4fc2"))
        #expect(r.warnings == ["\"spx=/\" ignored: sing-box has no Reality spider"])
        #expect(r.tunnel.proto.displayName == "VLESS Reality")
    }

    @Test func vlessPostQuantumRealityIsRefused() {
        // sing-box 1.13 rejects the whole config over this field.
        #expect(throws: (any Error).self) {
            try LinkParser.parse("vless://\(Self.uuid)@h.example.org:443?security=reality&pbk=k&pqv=MLDSA65KEY")
        }
    }

    @Test func vlessWebSocketTLS() throws {
        let r = try LinkParser.parse("vless://\(Self.uuid)@cdn.example.org:8443?security=tls&type=ws&path=%2Fws%3Fed%3D2048&host=front.example.org&alpn=h2,http/1.1")
        guard case .vless(let v) = r.tunnel.proto else { Issue.record("not vless"); return }
        #expect(v.transport == .ws(path: "/ws?ed=2048", host: "front.example.org"))
        #expect(v.tls?.alpn == ["h2", "http/1.1"])
        #expect(v.tls?.serverName == "cdn.example.org")
        #expect(r.warnings.isEmpty)
    }

    @Test func vlessRefusals() {
        #expect(throws: LinkParser.Failure.malformed("user ID is not a UUID")) {
            try LinkParser.parse("vless://not-a-uuid@h.example.org:443")
        }
        #expect(throws: LinkParser.Failure.unsupported("transport \"xhttp\" (Xray only)")) {
            try LinkParser.parse("vless://\(Self.uuid)@h.example.org:443?type=xhttp")
        }
        #expect(throws: LinkParser.Failure.missing("Reality public key (pbk)")) {
            try LinkParser.parse("vless://\(Self.uuid)@h.example.org:443?security=reality")
        }
    }

    // MARK: Trojan, Shadowsocks, VMess

    @Test func trojanDefaultsToTLS() throws {
        let r = try LinkParser.parse("trojan://pa%23ss@t.example.org:443?peer=sni.example.org#T")
        guard case .trojan(let t) = r.tunnel.proto else { Issue.record("not trojan"); return }
        #expect(t.password == "pa#ss")
        #expect(t.tls?.serverName == "sni.example.org")
        #expect(r.warnings.isEmpty)
    }

    @Test func shadowsocksSIP002() throws {
        let creds = Data("chacha20-ietf-poly1305:pw:with:colons".utf8).base64EncodedString()
        let r = try LinkParser.parse("ss://\(creds)@198.51.100.4:8388#SS")
        guard case .shadowsocks(let s) = r.tunnel.proto else { Issue.record("not ss"); return }
        #expect(s.method == "chacha20-ietf-poly1305")
        #expect(s.password == "pw:with:colons")
        #expect(r.tunnel.name == "SS")
    }

    @Test func shadowsocksLegacyAndPlugin() throws {
        let legacy = Data("aes-256-gcm:pw@198.51.100.4:8388".utf8).base64EncodedString()
        let r = try LinkParser.parse("ss://\(legacy)#old")
        #expect(r.tunnel.server == Endpoint(host: "198.51.100.4", port: 8388))
        #expect(r.tunnel.name == "old")

        let p = try LinkParser.parse("ss://2022-blake3-aes-128-gcm:a2V5@198.51.100.4:443?plugin=simple-obfs%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com")
        guard case .shadowsocks(let s) = p.tunnel.proto else { Issue.record("not ss"); return }
        #expect(s.plugin == "obfs-local")
        #expect(s.pluginOptions == "obfs=http;obfs-host=example.com")

        #expect(throws: LinkParser.Failure.unsupported("Shadowsocks method \"rc4-md5\"")) {
            try LinkParser.parse("ss://rc4-md5:pw@198.51.100.4:1")
        }
    }

    @Test func vmessJSON() throws {
        let json = #"{"v":"2","ps":"VM","add":"v.example.org","port":"443","id":"\#(Self.uuid)","aid":"0","scy":"auto","net":"ws","type":"none","host":"v.example.org","path":"/p","tls":"tls","sni":"","extra":"1"}"#
        let r = try LinkParser.parse("vmess://" + Data(json.utf8).base64EncodedString())
        guard case .vmess(let v) = r.tunnel.proto else { Issue.record("not vmess"); return }
        #expect(v.transport == .ws(path: "/p", host: "v.example.org"))
        #expect(v.tls?.serverName == "v.example.org")
        #expect(r.tunnel.name == "VM")
        #expect(r.warnings == ["Unknown field \"extra\" — not applied"])
    }

    // MARK: Generic

    @Test func ipv6Host() throws {
        let r = try LinkParser.parse("trojan://pw@[2001:db8::5]:443")
        #expect(r.tunnel.server.host == "2001:db8::5")
    }

    @Test func subscription() {
        let body = """
        hysteria2://pw@a.example.org:443#A
        # comment
        vless://bad@b.example.org:443
        trojan://pw@c.example.org:443#C
        """
        let enc = Data(body.utf8).base64EncodedString()
        let (ok, bad) = LinkParser.parseMany(enc)
        #expect(ok.map(\.tunnel.name) == ["A", "C"])
        #expect(bad.count == 1)
    }

    @Test(arguments: [
        "", "nonsense", "http://example.org", "hysteria2://", "hysteria2://pw@", "hysteria2://pw@h:0",
        "hysteria2://pw@h:99999", "hysteria2://pw@bad_host!:443", "hysteria2://pw@[::1:443", "vmess://!!!",
        "ss://", "vless://@h.example.org", "trojan://pw@h.example.org:443\n; rm -rf /",
    ])
    func garbageIsAnErrorNotACrash(input: String) {
        #expect(throws: (any Error).self) { try LinkParser.parse(input) }
    }

    @Test func fuzzNeverCrashes() {
        var rng = SplitMix(seed: 42)
        let alphabet = Array("abc:/@?&=#%[]._-0123456789+") + ["\u{0}", "ü", "\n"]
        for _ in 0..<5000 {
            let scheme = ["hysteria2://", "vless://", "trojan://", "ss://", "vmess://"][Int(rng.next() % 5)]
            let body = String((0..<Int(rng.next() % 60)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
            _ = try? LinkParser.parse(scheme + body)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
