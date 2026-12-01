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

    /// The helper's server check: a password on the local port, and bound
    /// to the physical interface (past the VPN's tunnel).
    @Test func directProbeIsAccepted() throws {
        let json = SingBoxConfig.probe(Fixtures.h2, socksPort: 28_124, auth: ("probe", "secret"), direct: true)
        #expect(json.text.contains("\"auto_detect_interface\" : true"))
        #expect(json.text.contains("\"users\""))
        try SingBox.check(json)
    }

    /// The Wi-Fi login proxy and the router's DNS for local names.
    @Test func captiveLoginProxyIsAccepted() throws {
        var env = SingBox.env
        env.captive = .init(port: 28_123, username: "sr", password: "secret")
        let json = try SingBoxConfig.generate(Fixtures.profile, env: env)
        #expect(json.text.contains("\"captive-in\""))
        #expect(json.text.contains("\"resolve\""))
        try SingBox.check(json)
    }

    /// DNS on the Mac's own port 53: an inbound on every address, whose
    /// traffic is always handed to sing-box's DNS — never passed on.
    @Test func localDNSIsAccepted() throws {
        var env = SingBox.env
        env.localDNS = true
        let json = try SingBoxConfig.generate(Fixtures.profile, env: env)
        guard case .array(let inbounds)? = json["inbounds"],
              let dns = inbounds.first(where: { $0["tag"] == "dns-in" }) else { Issue.record("no dns-in inbound"); return }
        #expect(dns["listen"] == "0.0.0.0" && dns["listen_port"] == 53)
        guard case .array(let rules)? = json["route"]?["rules"] else { Issue.record("no rules"); return }
        #expect(rules.first?["inbound"] == ["dns-in"] && rules.first?["action"] == "hijack-dns")
        try SingBox.check(json)
        // Off: no listener at all.
        #expect(!(try SingBoxConfig.generate(Fixtures.profile, env: SingBox.env).text.contains("dns-in")))
    }

    /// MTU, multiplexing and TLS fragmentation as sing-box expects them.
    @Test func advancedOptionsAreAccepted() throws {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let tls = TLS(serverName: "s.example.org")
        var tunnels = [
            Tunnel(name: "trojan", server: Endpoint(host: "s.example.org", port: 443), proto: .trojan(Trojan(password: "p", tls: tls, transport: .tcp))),
            Tunnel(name: "vless", server: Endpoint(host: "198.51.100.2", port: 443), proto: .vless(VLESS(uuid: uuid, tls: tls))),
            Tunnel(name: "ss", server: Endpoint(host: "198.51.100.3", port: 8388), proto: .shadowsocks(Shadowsocks(method: "aes-256-gcm", password: "p"))),
            Tunnel(name: "vmess", server: Endpoint(host: "198.51.100.4", port: 443), proto: .vmess(VMess(uuid: uuid, security: "auto", tls: tls, transport: .tcp))),
        ]
        for (i, kind) in Multiplex.Kind.allCases.enumerated() {
            tunnels[i].multiplex = Multiplex(kind: kind, maxConnections: 2 + i, padding: i % 2 == 0)
        }
        tunnels[3].multiplex = Multiplex()
        var p = Profile.example(tunnels: tunnels)
        p.mtu = 1400
        p.routes[0].fragmentTLS = true                                   // direct
        p.routes.append(Route(name: "via trojan", conditions: Conditions(destinations: [.domainSuffix("c.example")]),
                              target: .servers([tunnels[0].id]), fragmentTLS: true))
        p.defaultRoute.target = .servers(tunnels.map(\.id))
        p.defaultRoute.fragmentTLS = true
        #expect(Validation.check(p).filter { $0.severity == .error }.isEmpty)
        let json = try SingBoxConfig.generate(p, env: SingBox.env)
        #expect(json.text.contains("\"mtu\" : 1400"))
        #expect(json.text.contains("\"tls_fragment\" : true"))
        #expect(json.text.contains("\"multiplex\""))
        try SingBox.check(json)
    }

    /// Some of what sing-box is about to drop it says only once it runs, not
    /// in `check`: the full config is run for a moment, its TUN swapped for
    /// a local proxy (a TUN needs root), and must start without a warning.
    /// A list of sites and addresses is in it, its names apart for DNS — in
    /// a DNS rule, the whole list is what sing-box warns about (checked
    /// too, so the test is known to see it).
    @Test func fullProfileRunsWithoutWarnings() throws {
        let dir = SingBox.work.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = Data(#"{"version":3,"rules":[{"domain_suffix":["cn"]},{"ip_cidr":["203.0.113.0/24"]}]}"#.utf8)
        guard case .part(let names) = RuleLists.names(source) else { Issue.record("no names part"); return }
        for (name, data) in [("mixed", source), ("names", names)] {
            try data.write(to: dir.appendingPathComponent("\(name).json"))
            try SingBox.run(["rule-set", "compile", dir.appendingPathComponent("\(name).json").path,
                             "-o", dir.appendingPathComponent("\(name).srs").path])
        }
        let mixedURL = try #require(Profile.domesticLists.first { $0.name == "geosite-cn" }?.url)
        var env = SingBox.env
        env.clashAPIPort = SingBox.freePort()
        env.captive = .init(port: SingBox.freePort(), username: "sr", password: "secret")
        env.lists[mixedURL] = .init(path: dir.appendingPathComponent("mixed.srs").path,
                                    namesPath: dir.appendingPathComponent("names.srs").path)
        let out = try SingBox.runBriefly(SingBoxConfig.generate(Fixtures.profile, env: env), in: dir)
        #expect(!out.contains("WARN") && !out.contains("ERROR") && !out.contains("FATAL"), "sing-box said: \(out)")

        env.lists[mixedURL]?.namesPath = dir.appendingPathComponent("mixed.srs").path
        #expect(try SingBox.runBriefly(SingBoxConfig.generate(Fixtures.profile, env: env), in: dir).contains("WARN"))
    }

    /// The helper's server check, as it runs: no TUN, nothing to swap.
    @Test func probeRunsWithoutWarnings() throws {
        let dir = SingBox.work.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for t in [Fixtures.h2, Fixtures.vless] {
            let out = try SingBox.runBriefly(SingBoxConfig.probe(t, socksPort: SingBox.freePort(), auth: ("probe", "secret"), direct: true), in: dir)
            #expect(!out.contains("WARN") && !out.contains("ERROR") && !out.contains("FATAL"), "sing-box said: \(out)")
        }
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
                                    .domain("a.example"), .domainSuffix("b.example"), .domainKeyword("kw"), .list("geoip-cn")]
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

/// In CI the checks above must run, not be skipped: a missing binary is a
/// failure there (GitHub sets CI=true).
@Suite struct SingBoxAvailability {
    @Test func singBoxIsThereInCI() {
        guard ProcessInfo.processInfo.environment["CI"] != nil else { return }
        #expect(SingBox.path != nil, "sing-box not found: run scripts/fetch-sing-box.sh")
    }
}

enum SingBox {
    static let path: String? = {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // The pinned build first (scripts/fetch-sing-box.sh puts it there,
        // in CI too), so the tests check the version that ships.
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let arch = machine == "arm64" ? "arm64" : "amd64"
        let candidates: [String?] = [ProcessInfo.processInfo.environment["SING_BOX"],
                                     root.appendingPathComponent("Resources/sing-box/sing-box-darwin-\(arch)").path,
                                     root.appendingPathComponent("Resources/sing-box/sing-box").path,
                                     "/usr/local/bin/sing-box", "/opt/homebrew/bin/sing-box"]
        return candidates.compactMap { $0 }.first { fm.isExecutableFile(atPath: $0) }
    }()

    /// A scratch directory with tiny compiled rule-sets, built once.
    static let work: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("silentroute-check-\(getpid())")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("rules"), withIntermediateDirectories: true)
        let rules = [#"{"ip_cidr": ["203.0.113.0/24"]}"#, #"{"domain_suffix": ["cn"]}"#, #"{"domain_suffix": ["gov.cn"]}"#]
        for (list, rule) in zip(Profile.domesticLists, rules) {
            let name = RuleLists.fileKey(list.url)
            let src = dir.appendingPathComponent("\(name).json")
            try? #"{"version": 3, "rules": [\#(rule)]}"#.write(to: src, atomically: true, encoding: .utf8)
            _ = try? run(["rule-set", "compile", src.path, "-o", dir.appendingPathComponent("rules/\(name).srs").path])
        }
        return dir
    }()

    static var env: SingBoxConfig.Environment {
        var e = Fixtures.env
        e.lists = Fixtures.lists(in: work.appendingPathComponent("rules").path)
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

    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        return UInt16(bigEndian: addr.sin_port)
    }

    /// Runs a config for two seconds, its TUN inbound (if any) swapped for
    /// a local proxy with the same tag; what sing-box printed. Fails if it
    /// stopped by itself.
    static func runBriefly(_ config: JSON, in dir: URL) throws -> String {
        var obj = try #require(try JSONSerialization.jsonObject(with: config.encoded()) as? [String: Any])
        var inbounds = try #require(obj["inbounds"] as? [[String: Any]])
        if let tun = inbounds.firstIndex(where: { $0["type"] as? String == "tun" }) {
            inbounds[tun] = ["type": "mixed", "tag": inbounds[tun]["tag"] ?? "", "listen": "127.0.0.1", "listen_port": Int(freePort())]
        }
        obj["inbounds"] = inbounds
        let file = dir.appendingPathComponent("run-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path!)
        p.arguments = ["run", "-c", file.path, "-D", dir.path, "--disable-color"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        Thread.sleep(forTimeInterval: 2)
        let stoppedByItself = !p.isRunning
        p.terminate()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if stoppedByItself { throw CheckFailed(description: "sing-box stopped by itself: \(out)") }
        return out
    }

    static func check(_ config: JSON) throws {
        let file = work.appendingPathComponent("config-\(UUID().uuidString).json")
        try config.encoded().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            // Accepted is not enough: a warning names an option sing-box is
            // about to drop (deprecated), which a later version refuses.
            let out = try run(["check", "-c", file.path])
            if out.contains("WARN") { Issue.record("sing-box warns: \(out)\n\(config.text)") }
        } catch let e as CheckFailed {
            Issue.record("sing-box check failed: \(e.description)\n\(config.text)")
        }
    }
}
