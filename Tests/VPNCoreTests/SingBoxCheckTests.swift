import Foundation
import Testing
@testable import VPNCore

/// Runs the real sing-box over generated configs. Golden files prove the
/// output did not change; this proves sing-box accepts it.
///
/// Uses `$SING_BOX`, then `Resources/sing-box/sing-box`, then PATH. Without a
/// binary the tests are skipped, not passed.
@Suite(.enabled(if: SingBox.path != nil, "sing-box binary not found"))
struct SingBoxCheckTests {
    @Test func fullProfileIsAccepted() throws {
        try SingBox.check(SingBoxConfig.generate(Fixtures.profile, env: SingBox.env))
    }

    @Test func probeConfigIsAccepted() throws {
        try SingBox.check(SingBoxConfig.probe(Fixtures.h2, socksPort: 11099))
        try SingBox.check(SingBoxConfig.probe(Fixtures.vless, socksPort: 11099))
    }

    @Test func everyProtocolAndTransportIsAccepted() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let tls = TLS(serverName: "s.example.org", alpn: ["h2"], fingerprint: "firefox")
        let protos: [TunnelProtocol] = [
            .hysteria2(Hysteria2(password: "p", tls: TLS(), serverPorts: ["20000:30000"], upMbps: 50, downMbps: 200)),
            .vless(VLESS(uuid: uuid, tls: tls, transport: .ws(path: "/ws?ed=2048", host: "h.example.org"))),
            .vless(VLESS(uuid: uuid, tls: tls, transport: .grpc(serviceName: "svc"))),
            .vless(VLESS(uuid: uuid, tls: tls, transport: .httpUpgrade(path: "/u", host: "h.example.org"))),
            .vless(VLESS(uuid: uuid, tls: tls, transport: .http(path: "/h", host: ["a.example.org"]))),
            .trojan(Trojan(password: "p", tls: tls, transport: .tcp)),
            .shadowsocks(Shadowsocks(method: "2022-blake3-aes-128-gcm", password: "AAAAAAAAAAAAAAAAAAAAAA==")),
            .shadowsocks(Shadowsocks(method: "aes-256-gcm", password: "p", plugin: "obfs-local", pluginOptions: "obfs=http;obfs-host=a.example.org")),
            .vmess(VMess(uuid: uuid, security: "auto", tls: tls, transport: .ws(path: "/", host: nil))),
            .proxy(Proxy(kind: .socks5, username: "u", password: "p")),
            .proxy(Proxy(kind: .socks5)),
            .proxy(Proxy(kind: .http, username: "u", password: "p")),
            .proxy(Proxy(kind: .http, tls: TLS(serverName: "s.example.org"))),
        ]
        let tunnels = protos.enumerated().map { i, p in
            Tunnel(name: "t\(i)", server: Endpoint(host: i % 2 == 0 ? "s.example.org" : "198.51.100.\(i)", port: 443), proto: p)
        }
        try SingBox.check(SingBoxConfig.generate(Profile.example(tunnels: tunnels), env: SingBox.env))
    }

    /// Random profiles: any combination the model allows must be a config
    /// sing-box accepts.
    @Test func randomProfilesAreAccepted() throws {
        var rng = SplitMix(seed: 7)
        func pick<T>(_ a: [T]) -> T { a[Int(rng.next() % UInt64(a.count))] }
        let socks = Tunnel(name: "socks", server: Endpoint(host: "198.51.100.9", port: 1080),
                           proto: .proxy(Proxy(kind: .socks5, username: "u", password: "p")))
        let tunnels = [Fixtures.h2, Fixtures.vless, socks]
        let dests: [Destination] = [.cidr(IPNetwork("10.0.0.0/8")!), .cidr(IPNetwork("2001:db8::/32")!),
                                    .domain("a.example"), .domainSuffix("b.example"), .domainKeyword("kw"), .geoIP("cn")]
        let apps: [AppMatcher] = [.bundle(path: "/Applications/Safari.app"), .executable(path: "/usr/bin/curl"),
                                  .processName("ssh")]
        let ids = tunnels.map(\.id)
        func target() -> Route.Target {
            switch rng.next() % 4 {
            case 0: .direct
            case 1: .block
            default: .servers((0..<Int(1 + rng.next() % 3)).map { _ in pick(ids) })
            }
        }
        for _ in 0..<12 {
            var p = Profile.example(tunnels: tunnels)
            p.lan = pick([.allow, .block])
            p.defaultRoute.target = target()
            p.defaultRoute.killSwitch = rng.next() % 2 == 0
            for i in 0..<Int(rng.next() % 6) {
                var c = Conditions()
                repeat {
                    c.destinations = (0..<Int(rng.next() % 3)).map { _ in pick(dests) }
                    c.apps = (0..<Int(rng.next() % 2)).map { _ in pick(apps) }
                    c.ports = rng.next() % 3 == 0 ? [PortRange(443), PortRange(1000, 2000)] : []
                    c.network = pick([nil, .tcp, .udp])
                } while c.isEmpty
                p.routes.append(Route(name: "r\(i)", conditions: c, target: target(), killSwitch: rng.next() % 2 == 0))
            }
            try SingBox.check(SingBoxConfig.generate(p, env: SingBox.env))
        }
    }
}

enum SingBox {
    static let path: String? = {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates: [String?] = [ProcessInfo.processInfo.environment["SING_BOX"],
                                     root.appendingPathComponent("Resources/sing-box/sing-box").path,
                                     "/usr/local/bin/sing-box", "/opt/homebrew/bin/sing-box"]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    }()

    /// A scratch directory with tiny compiled rule-sets, built once.
    static let work: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("silentroute-check-\(getpid())")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        for (name, rule) in [("geoip-cn", #"{"ip_cidr": ["203.0.113.0/24"]}"#),
                             ("geosite-cn", #"{"domain_suffix": ["cn"]}"#),
                             ("geosite-geolocation-cn", #"{"domain_suffix": ["gov.cn"]}"#)] {
            let src = dir.appendingPathComponent("\(name).json")
            try? #"{"version": 3, "rules": [\#(rule)]}"#.write(to: src, atomically: true, encoding: .utf8)
            _ = try? run(["rule-set", "compile", src.path, "-o", dir.appendingPathComponent("rules/\(name).srs").path])
        }
        return dir
    }()

    static var env: SingBoxConfig.Environment {
        var e = Fixtures.env
        e.ruleSetDirectory = work.appendingPathComponent("rules").path
        e.cacheFile = work.appendingPathComponent("cache.db").path
        return e
    }

    struct CheckFailed: Error, CustomStringConvertible {
        var description: String
    }

    @discardableResult
    static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path!)
        p.arguments = args
        // A neutral cwd: the config must not depend on it.
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CheckFailed(description: out) }
        return out
    }

    static func check(_ config: JSON) throws {
        let file = work.appendingPathComponent("config-\(UUID().uuidString).json")
        try config.encoded().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try run(["check", "-c", file.path])
        } catch let e as CheckFailed {
            Issue.record("sing-box check failed: \(e.description)\n\(config.text)")
        }
    }
}
