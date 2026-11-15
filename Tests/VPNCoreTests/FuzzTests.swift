import Foundation
import Testing
@testable import VPNCore

/// Whatever is pasted or imported, parsing answers with a result or an
/// error — never a crash. Links and rule lines are mutated from real-looking
/// seeds with a fixed generator, so a failure reproduces.
@Suite struct FuzzTests {
    /// SplitMix64: deterministic, so a crash names its input every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let links = [
        "vless://0b1e2a4c-1111-4222-8333-944455556666@example.com:443?security=reality&pbk=abc&sid=01&sni=a.com&type=tcp&flow=xtls-rprx-vision#n",
        "vless://u@h:443?type=ws&path=%2Fws%3Fed%3D2048&host=x.com&security=tls",
        "trojan://pass@example.com:443?sni=a.com&type=grpc&serviceName=s#x",
        "hysteria2://auth@example.com:443/?sni=a.com&obfs=salamander&obfs-password=p&mport=1000-2000",
        "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#x",
        "ss://2022-blake3-aes-128-gcm:cGFzcw==@example.com:8388?plugin=obfs-local%3Bobfs%3Dhttp",
        "vmess://eyJ2IjoiMiIsImFkZCI6ImV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoiYSIsIm5ldCI6IndzIn0=",
        "socks5://alice:p%40ss@198.51.100.4:8000#lv",
        "http://user:pass@[2001:db8::1]:8080",
        "1.2.3.4:1080:user:pass", "user:pass@host.example:3128", "host:1|u:p",
    ]

    /// Pieces of link syntax, inserted whole: a query key with no value, an
    /// encoded separator, an empty port — what single characters rarely hit.
    static let tokens = ["plugin=", "%3B", ";", "?", "&", "=", "#", "@", ":", "[", "]", "::", "%", "%zz", "//",
                         "type=", "security=", "path=", "host=", "mport=", "sni=", "obfs=", "flow=", "pbk=", "sid=",
                         "serviceName=", "alpn=", ",", "-", "0", "65536", "99999999999999999999", "=="]

    static let alphabet = Array(":/@?&=#%[]|;,. -_+0123456789abcxyzAZ\u{0}\u{FEFF}é𝔸\n\t\"'\\")

    static func mutate(_ s: String, _ g: inout Seeded) -> String {
        var c = Array(s)
        for _ in 0..<Int.random(in: 1...6, using: &g) {
            switch Int.random(in: 0..<6, using: &g) {
            case 0 where !c.isEmpty: c.remove(at: Int.random(in: 0..<c.count, using: &g))
            case 1: c.insert(alphabet.randomElement(using: &g)!, at: Int.random(in: 0...c.count, using: &g))
            case 2 where !c.isEmpty: c[Int.random(in: 0..<c.count, using: &g)] = alphabet.randomElement(using: &g)!
            case 4: c.insert(contentsOf: tokens.randomElement(using: &g)!, at: Int.random(in: 0...c.count, using: &g))
            case 3 where c.count > 2:
                let a = Int.random(in: 0..<c.count, using: &g)
                c.removeSubrange(a..<min(c.count, a + Int.random(in: 1...12, using: &g)))
            default: c = Array(String(c.prefix(Int.random(in: 0...c.count, using: &g))))
            }
        }
        return String(c)
    }

    @Test func linksNeverCrash() {
        var g = Seeded(state: 42)
        for _ in 0..<25_000 {
            let seed = Self.links.randomElement(using: &g)!
            let s = Self.mutate(seed, &g)
            _ = try? LinkParser.parse(s)
            _ = try? LinkParser.parse(s, expecting: .proxy)
            _ = try? LinkParser.parse(s, expecting: .tunnel)
        }
        _ = LinkParser.parseMany(Self.links.joined(separator: "\n"))
    }

    /// Found by reading (it crashed): a plugin value with no name.
    @Test func shadowsocksPluginWithoutName() throws {
        let base = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388?"
        for q in ["plugin=%3B", "plugin=%3Bobfs%3Dhttp"] {
            #expect(throws: LinkParser.Failure.self) { try LinkParser.parse(base + q) }
        }
        // Empty: no plugin at all.
        for q in ["plugin=", "plugin"] {
            guard case .shadowsocks(let ss) = try LinkParser.parse(base + q).tunnel.proto else { Issue.record(); continue }
            #expect(ss.plugin == nil)
        }
    }

    @Test func ruleTextNeverCrashes() {
        var g = Seeded(state: 7)
        let seeds = ["example.com", "=a.b.c", "keyword:tube", "list:geoip-cn", "list:a@b", "10.0.0.0/8",
                     "2001:db8::/32", "https://a.com/x", "443, 8000-8100", "::1", "1.2.3.4/33"]
        for _ in 0..<20_000 {
            let s = Self.mutate(seeds.randomElement(using: &g)!, &g)
            _ = RuleText.destinations(s)
            _ = RuleText.ports(s)
            _ = IPNetwork(s)
        }
    }

    /// A profile comes to the root helper from any user of the Mac. Whatever
    /// decodes is checked and turned into a config — or refused — without
    /// a crash. Mutated at the JSON level, and as values.
    @Test func profilesNeverCrashTheGenerator() throws {
        var g = Seeded(state: 5)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        var seed = Fixtures.profile
        seed.mtu = 1400
        let base = String(decoding: try enc.encode(seed), as: UTF8.self)
        let jsonTokens = ["\"\"", "-1", "0", "1e308", "-9223372036854775809", "18446744073709551616", "[]", "{}", "null",
                          "true", "\"\\u0000\"", "\"../../etc\"", "\"a\\nb\"", "\"\\\"\"", "65535", "65536", "4294967296"]
        var decoded = 0
        for _ in 0..<1_500 {
            var c = Array(base)
            for _ in 0..<Int.random(in: 1...4, using: &g) {
                // Replace a value: from a ':' to the next ',' or '}'.
                let colons = c.indices.filter { c[$0] == ":" }
                guard let at = colons.randomElement(using: &g) else { break }
                var end = at + 1
                while end < c.count, c[end] != ",", c[end] != "}" { end += 1 }
                if Bool.random(using: &g) {
                    c.replaceSubrange((at + 1)..<end, with: Array(jsonTokens.randomElement(using: &g)!))
                } else {
                    c = Array(Self.mutate(String(c), &g))
                }
            }
            guard let p = try? JSONDecoder().decode(Profile.self, from: Data(String(c).utf8)) else { continue }
            decoded += 1
            _ = Validation.check(p)
            _ = p.protectionMode
            _ = try? SingBoxConfig.generate(p, env: Fixtures.env).encoded()
            for t in p.tunnels { _ = SingBoxConfig.probe(t, socksPort: 1080, auth: ("u", "p"), direct: true).encoded() }
        }
        #expect(decoded > 5, "some mutations should still decode")
    }

    /// The same, value by value: what decodes fine but is extreme or odd.
    @Test func oddProfileValues() {
        var g = Seeded(state: 11)
        let rounds = 6_000
        let odd = ["", " ", "\u{0}", "a\nb", "../..", "*", "é.com", "xn--", String(repeating: "a", count: 300), "1.2.3.4",
                   "::", "[::1]", "a..b", ".", "-a.com", "😀.com", "%00", "\"", "\\"]
        for _ in 0..<rounds {
            var p = Fixtures.profile
            p.mtu = [nil, 0, -1, 1279, 1280, 9000, 9001, Int.max, Int.min].randomElement(using: &g)!
            if !p.tunnels.isEmpty {
                let i = Int.random(in: 0..<p.tunnels.count, using: &g)
                p.tunnels[i].server.port = [0, 1, 65535].randomElement(using: &g)!
                p.tunnels[i].server.host = odd.randomElement(using: &g)!
                p.tunnels[i].name = odd.randomElement(using: &g)!
            }
            if !p.routes.isEmpty {
                let i = Int.random(in: 0..<p.routes.count, using: &g)
                let v = odd.randomElement(using: &g)!
                p.routes[i].conditions.destinations += [.domain(v), .domainSuffix(v), .domainKeyword(v), .list(v), .localNetwork]
                p.lists.append(RuleList(name: v, url: odd.randomElement(using: &g)!))
                p.routes[i].conditions.apps += [.processName(v), .executable(path: v), .bundle(path: v)]
                p.routes[i].conditions.ports += [PortRange(0), PortRange(65535, 1)]
                p.routes[i].name = v
                if Bool.random(using: &g) { p.routes[i].target = .servers([UUID()]) }
            }
            if Bool.random(using: &g) { p.tunnels = [] }
            _ = Validation.check(p)
            _ = try? SingBoxConfig.generate(p, env: Fixtures.env).encoded()
        }
    }
}

@Suite struct SecretTests {
    @Test func randomSecrets() {
        let a = Secret.random(), b = Secret.random()
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit))
        #expect(a != b)
    }
}
