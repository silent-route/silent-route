import Foundation
@testable import VPNCore
@testable import VPNHelperKit

/// A shared, ordered log of everything done to the "system", plus the
/// system's resulting state, so tests can assert both order and outcome.
actor World {
    var log: [String] = []
    // pf
    var anchorRules: String?
    var tokens: Set<String> = []
    var nextToken = 1
    var pfLoadFails = false
    var pfEnableFails = false
    // engine
    var running: Set<Int32> = []
    var exitHandlers: [Int32: @Sendable (Int32) -> Void] = [:]
    var nextPID: Int32 = 100
    var checkFails = false
    var launchFails = false
    var dieRightAfterLaunch = false
    var tunAppears = true
    var healthy = true
    /// Outbound tags that do not answer even while `healthy`.
    var deadTags: Set<String> = []
    /// selector → member, as set through the clash API.
    var selections: [String: String] = [:]
    /// The config sing-box was last started with.
    var lastConfig: Data?
    /// Its log level.
    var logLevel: String? {
        guard let d = lastConfig, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (o["log"] as? [String: Any])?["level"] as? String
    }
    // network
    var foreign: String?
    var routingRestored = 0
    var dnsOverridden = false
    /// macOS points at each interface's own address (sing-box on port 53).
    var dnsLocal = false
    /// The pf guard keeping port 53 to this Mac is in place.
    var dnsGuard = false
    /// Something else already listens on port 53.
    var port53Taken = false
    /// The network wants a login (a hotel Wi-Fi).
    var captive = false

    func record(_ s: String) { log.append(s) }
    func set(_ body: @Sendable (isolated World) -> Void) { body(self) }

    /// The kill switch is effective: rules loaded and pf held on by a token.
    var blocking: Bool { anchorRules != nil && !tokens.isEmpty }
    var tun: String? { tunAppears && !running.isEmpty ? "utun9" : nil }

    func crash(_ pid: Int32) {
        guard running.remove(pid) != nil else { return }
        record("engine.crash(\(pid))")
        exitHandlers.removeValue(forKey: pid)?(pid)
    }

    func crashAll() { for pid in running { crash(pid) } }

    func index(of prefix: String) -> Int? { log.firstIndex { $0.hasPrefix(prefix) } }
}

struct FakePF: PacketFilter {
    let world: World
    func validate(_ rules: String) async throws { await world.record("pf.validate") }
    func load(_ rules: String) async throws {
        await world.set { w in
            w.log.append(rules.contains("utun") ? "pf.load(connected)" : "pf.load(blocked)")
        }
        if await world.pfLoadFails { throw TestError("pf load failed") }
        await world.set { $0.anchorRules = rules }
    }
    func flush() async { await world.set { $0.anchorRules = nil; $0.log.append("pf.flush") } }
    func enable() async throws -> String {
        if await world.pfEnableFails { throw TestError("pfctl -E failed") }
        return await world.set2 { w in
            let t = "T\(w.nextToken)"
            w.nextToken += 1
            w.tokens.insert(t)
            w.log.append("pf.enable")
            return t
        }
    }
    func release(token: String) async { await world.set { $0.tokens.remove(token); $0.log.append("pf.release") } }
    func isLoaded() async -> Bool { await world.anchorRules != nil }
}

extension World {
    func set2<T: Sendable>(_ body: @Sendable (isolated World) -> T) -> T { body(self) }
}

struct FakeEngine: Engine {
    let world: World
    func check(config: Data) async throws {
        await world.record("engine.check")
        if await world.checkFails { throw TestError("bad config") }
    }
    func launch(config: Data, onExit: @escaping @Sendable (Int32) -> Void) async throws -> Int32 {
        await world.set { $0.lastConfig = config }
        if await world.launchFails { await world.record("engine.launch(failed)"); throw TestError("launch failed") }
        let pid = await world.set2 { w in
            let pid = w.nextPID
            w.nextPID += 1
            w.running.insert(pid)
            w.exitHandlers[pid] = onExit
            w.log.append("engine.launch(\(pid))")
            return pid
        }
        if await world.dieRightAfterLaunch { await world.crash(pid) }
        return pid
    }
    func terminate(pid: Int32) async {
        // Like the real engine: the exit of a deliberately stopped process is
        // reported too, and it can arrive while the caller is still waiting
        // here — the integration run caught panic racing with exactly that.
        let handler = await world.set2 { w -> (@Sendable (Int32) -> Void)? in
            if w.running.remove(pid) != nil { w.log.append("engine.terminate(\(pid))") }
            return w.exitHandlers.removeValue(forKey: pid)
        }
        handler?(pid)
        for _ in 0..<20 { await Task.yield() }
    }
    func isRunning(pid: Int32) async -> Bool { await world.running.contains(pid) }
    func select(_ selector: String, member: String) async throws {
        await world.set { $0.selections[selector] = member; $0.log.append("engine.select") }
    }
    func delay(_ tag: String) async -> Int? {
        await world.record("engine.health")
        let w = world
        return await w.set2 { $0.healthy && !$0.running.isEmpty && !$0.deadTags.contains(tag) } ? 40 : nil
    }
}

struct FakeNetwork: NetworkInspector {
    let world: World
    func tunInterface() async -> String? { await world.tun }
    func foreignTunnel() async -> String? { await world.foreign }
    func restoreRouting() async { await world.set { $0.routingRestored += 1; $0.log.append("net.restore") } }
    func overrideDNS(server: String, local: Bool) async {
        await world.set { $0.dnsOverridden = true; $0.dnsLocal = local; $0.log.append(local ? "dns.override(local)" : "dns.override") }
    }
    func prepareLocalDNS() async -> Bool {
        await world.set2 { w in
            guard !w.port53Taken else { w.log.append("dns.local?no"); return false }
            w.dnsGuard = true
            w.log.append("dns.guard")
            return true
        }
    }
    func releaseLocalDNS() async { await world.set { $0.dnsGuard = false; $0.log.append("dns.unguard") } }
    func restoreDNS() async { await world.set { $0.dnsOverridden = false; $0.log.append("dns.restore") } }
    func captivePortal(via proxy: SingBoxConfig.LocalProxy) async -> Bool {
        await world.set2 { w in w.log.append("net.captive?"); return w.captive }
    }
}

final class FakeStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: PersistedState?
    init(_ v: PersistedState? = nil) { value = v }
    func load() -> PersistedState? { lock.withLock { value } }
    func save(_ s: PersistedState) { lock.withLock { value = s } }
}

/// Time only moves when the controller sleeps. Sleeping yields so other
/// tasks (tests, recovery) get to run.
final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    private(set) var sleeps: [Double] = []
    let boot: Date
    /// Real time spent per sleep, for tests that must act while the
    /// controller is waiting.
    var realDelay: Duration? {
        get { lock.withLock { _realDelay } }
        set { lock.withLock { _realDelay = newValue } }
    }
    private var _realDelay: Duration?
    init(boot: Date = Date(timeIntervalSince1970: 500_000)) { self.boot = boot }
    func sleep(seconds: Double) async throws {
        lock.withLock { t += seconds; sleeps.append(seconds) }
        if let d = realDelay { try await Task.sleep(for: d) }
        try Task.checkCancellation()
        await Task.yield()
    }
    func now() -> Date { lock.withLock { t } }
    func bootTime() -> Date { boot }
    /// Nil: like a state file from before boot sessions were recorded.
    var session: String? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }
    private var _session: String?
    func bootSession() -> String? { session }
    var recordedSleeps: [Double] { lock.withLock { sleeps } }
}

struct TestError: Error, LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Harness {
    let world = World()
    let store: FakeStore
    let clock: FakeClock
    let controller: Controller

    static let h2 = Tunnel(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, name: "A",
                           server: Endpoint(host: "a.example.org", port: 443),
                           proto: .hysteria2(Hysteria2(password: "p", tls: TLS(serverName: "a.example.org"))))
    static let h2b = Tunnel(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!, name: "B",
                            server: Endpoint(host: "b.example.org", port: 443),
                            proto: .hysteria2(Hysteria2(password: "p", tls: TLS(serverName: "b.example.org"))))

    init(killSwitch: KillSwitchMode = .whileConnected, saved: PersistedState? = nil, boot: Date = Date(timeIntervalSince1970: 500_000),
         captivePort: UInt16? = nil, ruleLists: Controller.RuleListHooks? = nil) {
        store = FakeStore(saved)
        clock = FakeClock(boot: boot)
        var profile = Profile.example(tunnels: [Self.h2, Self.h2b])
        profile.defaultRoute.target = .servers([Self.h2.id, Self.h2b.id])
        // Kill switches are per route; "off" means off on every route.
        if killSwitch == .off {
            profile.defaultRoute.killSwitch = false
            for i in profile.routes.indices { profile.routes[i].killSwitch = false }
        } else {
            profile.killSwitch = killSwitch
        }
        let env = SingBoxConfig.Environment(cacheFile: "/tmp/cache.db", clashAPIPort: 19090, clashAPISecret: "",
                                            lists: Dictionary(uniqueKeysWithValues: Profile.domesticLists.map {
                                                ($0.url, .init(path: "/tmp/rules/\($0.name).srs", matchesNames: false))
                                            }))
        var options = Controller.Options(singBoxGroup: 4242, configEnvironment: env)
        options.captivePort = captivePort
        options.ruleLists = ruleLists
        controller = Controller(profile: profile, options: options,
                                pf: FakePF(world: world), engine: FakeEngine(world: world),
                                network: FakeNetwork(world: world), store: store, clock: clock)
    }

    /// Waits (bounded) until the world satisfies a condition.
    func waitWorld(_ cond: @Sendable (isolated World) -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if await world.set2(cond) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    /// Waits (bounded) until the controller reaches a phase.
    func wait(for phase: Controller.Phase, _ extra: (@Sendable (Controller.Status) -> Bool)? = nil) async -> Bool {
        for _ in 0..<2000 {
            let s = await controller.status
            if s.phase == phase && (extra?(s) ?? true) { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}
