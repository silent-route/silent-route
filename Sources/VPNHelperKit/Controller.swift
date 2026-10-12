import Foundation
import VPNCore

/// The helper's state machine. One actor owns all network state; every
/// transition happens here.
///
/// ```
/// off ──start──▶ connecting ──tunnel proven──▶ connected ◀──switch──▶ connected
///  ▲                 │ any failure                  │ sing-box died / unhealthy
///  │                 ▼                              ▼
///  └──────────── off + error                  reconnecting  (pf keeps blocking,
///     network untouched, no kill switch                       retries with backoff)
/// stop / panic from any state ──▶ off, pf anchor empty, network as before
/// ```
///
/// Rules this code keeps:
/// - The kill switch goes on last, only after the tunnel has been proven to
///   work. A failed start leaves the network exactly as it was.
/// - Once on, it stays on until the user stops or panics — a crash of
///   sing-box never opens the network.
/// - Actor methods can interleave at `await`. Every operation records the
///   epoch it started in and, after each await, gives up (cleaning what it
///   created) if a newer command has taken over.
public actor Controller {
    public typealias Phase = VPNPhase
    public typealias Status = VPNStatus

    public struct Options: Sendable {
        public var singBoxGroup: UInt32
        public var tunWaitSeconds: Double = 15
        public var maxBackoffSeconds: Double = 30
        /// Environment for config generation, minus the per-start clash API
        /// port and secret, which the controller fills in.
        public var configEnvironment: SingBoxConfig.Environment

        public init(singBoxGroup: UInt32, configEnvironment: SingBoxConfig.Environment) {
            self.singBoxGroup = singBoxGroup
            self.configEnvironment = configEnvironment
        }
    }

    public enum CommandError: Error, Equatable, Sendable, CustomStringConvertible {
        case busy(Phase)
        case notConnected
        case noSuchTunnel
        case failed(String)

        public var description: String {
            switch self {
            case .busy(let p): "Not possible while \(p.rawValue)"
            case .notConnected: "The VPN is not connected"
            case .noSuchTunnel: "No such tunnel in the profile"
            case .failed(let s): s
            }
        }
    }

    let pf: PacketFilter
    let engine: Engine
    let network: NetworkInspector
    let store: StateStore
    let clock: Clock
    let options: Options

    public private(set) var profile: Profile
    private var phase: Phase = .off
    private var epoch = 0
    private var enginePID: Int32?
    private var pfToken: String?
    private var connectedSince: Date?
    private var lastError: String?
    private var attempts = 0
    private var wantConnected = false
    private var recovery: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var apiSecret: String?
    /// Last measured round trip per server (nil inside: not answering).
    private var latency: [UUID: Int?] = [:]
    /// Where each route's selector points now.
    private var via: [UUID: RouteState.Via] = [:]
    /// Consecutive checks in which no exit at all answered.
    private var allDownChecks = 0

    public init(profile: Profile, options: Options, pf: PacketFilter, engine: Engine, network: NetworkInspector,
                store: StateStore, clock: Clock) {
        self.profile = profile
        self.options = options
        self.pf = pf
        self.engine = engine
        self.network = network
        self.store = store
        self.clock = clock
    }

    // MARK: - Status

    public var status: Status {
        Status(phase: phase, connectedSince: connectedSince,
               killSwitchOn: pfToken != nil, lastError: lastError, reconnectAttempts: attempts,
               servers: phase == .connected ? latency.keys.sorted { $0.uuidString < $1.uuidString }
                   .map { ServerState(id: $0, latencyMs: latency[$0] ?? nil) } : [],
               routes: phase == .connected ? profile.serverRoutes.compactMap { r in via[r.id].map { RouteState(id: r.id, via: $0) } } : [])
    }

    /// A stream of status changes, starting with the current one.
    public func updates() -> AsyncStream<Status> {
        let id = UUID()
        let (stream, cont) = AsyncStream<Status>.makeStream(bufferingPolicy: .bufferingNewest(1))
        cont.yield(status)
        watchers[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeWatcher(id) } }
        return stream
    }

    private func removeWatcher(_ id: UUID) { watchers[id] = nil }

    private func publish() {
        let s = status
        for w in watchers.values { w.yield(s) }
        store.save(PersistedState(wantConnected: wantConnected, enginePID: enginePID, pfToken: pfToken,
                                  bootTime: clock.bootTime()))
    }

    private func set(_ p: Phase, error: String? = nil) {
        phase = p
        if let error { lastError = error }
        publish()
    }

    // MARK: - Commands

    public func start() async throws(CommandError) {
        guard phase == .off else { throw .busy(phase) }
        epoch += 1
        let my = epoch
        wantConnected = true
        lastError = nil
        attempts = 0
        set(.connecting)
        do {
            try await connect(epoch: my, keepBlockingOnFailure: false)
        } catch let e as CommandError {
            if epoch == my {
                wantConnected = false
                set(.off, error: e.description)
            }
            throw e
        } catch {
            if epoch == my {
                wantConnected = false
                set(.off, error: error.localizedDescription)
            }
            throw .failed(error.localizedDescription)
        }
    }

    public func stop() async {
        epoch += 1
        wantConnected = false
        recovery?.cancel()
        recovery = nil
        set(.stopping)
        await teardown()
        lastError = nil
        set(.off)
    }

    /// Like stop, but assumes nothing works: kills hard, releases pf, repairs
    /// routing and DNS. Never waits on anything that might hang.
    public func panic() async {
        epoch += 1
        wantConnected = false
        recovery?.cancel()
        recovery = nil
        // Before the first await: sing-box's exit, reported while we wait
        // below, must not look like a crash and start a reconnect (which
        // would put the kill switch back — found by the integration run).
        let pid = enginePID
        enginePID = nil
        let token = pfToken
        pfToken = nil
        set(.stopping)
        await pfRun { await $0.flush() }
        if let token { await pfRun { await $0.release(token: token) } }
        if let pid { await engine.terminate(pid: pid) }
        await network.restoreRouting()
        connectedSince = nil
        set(.off)
    }

    /// A new profile. If connected, sing-box restarts with it. When either
    /// profile has a kill switch, blocking goes on before the old sing-box
    /// stops and stays until the new one is proven, so nothing leaks during
    /// the swap whichever way it goes.
    /// While off, an incomplete profile is accepted (it is being edited);
    /// `start` reports what is missing.
    public func update(profile new: Profile) async throws(CommandError) {
        let running = phase == .connected || phase == .reconnecting
        if running {
            let errors = Validation.check(new)
                .filter { $0.severity == .error }
            guard errors.isEmpty else { throw .failed(errors.map(\.message).joined(separator: "; ")) }
        }
        guard phase == .connected || phase == .reconnecting || phase == .off else { throw .busy(phase) }
        let guarded = profile.protectionMode != .off || new.protectionMode != .off
        profile = new
        guard running else { publish(); return }
        epoch += 1
        let my = epoch
        if guarded { await holdBlocking(epoch: my) }
        guard epoch == my else { return }
        if let pid = enginePID { enginePID = nil; await engine.terminate(pid: pid) }
        guard epoch == my else { return }
        beginRecovery(epoch: my, reason: nil)
    }

    // MARK: - Engine events

    /// Called (via the engine's onExit) whenever a sing-box process ends.
    public func engineExited(pid: Int32) async {
        guard pid == enginePID else { return }      // an old process we already replaced
        enginePID = nil
        switch phase {
        case .connected:
            epoch += 1
            beginRecovery(epoch: epoch, reason: "sing-box stopped unexpectedly")
        case .connecting, .reconnecting, .stopping, .off:
            break   // the operation in flight notices on its own
        }
    }

    /// Periodic check while connected: sing-box alive, anchor still loaded,
    /// tunnel answering.
    public func healthTick() async {
        guard phase == .connected else { return }
        let my = epoch
        if pfToken != nil, !(await pfRun { await $0.isLoaded() }) {
            // Someone flushed our anchor (e.g. a pfctl -f elsewhere). Put it back.
            if let tun = await network.tunInterface(), epoch == my {
                if let r = try? rules(tun: tun) { try? await pfTry { try await $0.load(r) } }
            }
        }
        guard epoch == my, phase == .connected else { return }
        let anyUp = await checkServers(epoch: my)
        guard epoch == my, phase == .connected else { return }
        // Fallbacks handle single exits. Nothing answering twice in a row —
        // not even through a fallback — means sing-box or the network under
        // it is stuck (sleep, a network change): restart it behind the
        // kill switch.
        allDownChecks = anyUp ? 0 : allDownChecks + 1
        if allDownChecks >= 2 {
            allDownChecks = 0
            epoch += 1
            if let pid = enginePID { enginePID = nil; await engine.terminate(pid: pid) }
            beginRecovery(epoch: epoch, reason: "no exit answers")
        }
    }

    /// Measures every server in use and points each route's selector at
    /// the first server of its list that answers; with none, direct (kill
    /// switch off) or its first, dead server, which fails every connection
    /// (kill switch on). Returns whether any server answered.
    @discardableResult
    private func checkServers(epoch my: Int) async -> Bool {
        let engine = self.engine
        let routes = profile.serverRoutes
        var ids: [UUID] = []
        for r in routes { for id in profile.chain(of: r) where !ids.contains(id) { ids.append(id) } }
        let measured = await withTaskGroup(of: (UUID, Int?).self) { group in
            for id in ids { group.addTask { (id, await engine.delay(SingBoxConfig.tag(id))) } }
            var out: [UUID: Int?] = [:]
            for await (id, ms) in group { out[id] = ms }
            return out
        }
        guard epoch == my else { return false }
        latency = measured
        for r in routes {
            let chain = profile.chain(of: r)
            let up = chain.first { (measured[$0] ?? nil) != nil }
            let next: RouteState.Via = up.map { .server($0) } ?? (r.killSwitch ? .blocked : .direct)
            guard via[r.id] != next else { continue }
            let member: String = switch next {
            case .server(let id): SingBoxConfig.tag(id)
            case .direct: SingBoxConfig.direct
            case .blocked: SingBoxConfig.tag(chain[0])
            }
            do {
                try await engine.select(SingBoxConfig.routeTag(r.id), member: member)
                guard epoch == my else { return false }
                via[r.id] = next
            } catch {
                // Left as it was; the next check tries again.
            }
        }
        publish()
        return measured.values.contains { $0 != nil }
    }

    /// After sleep or a network change: check right away rather than waiting
    /// for the next tick.
    public func networkChanged() async {
        await healthTick()
    }

    // MARK: - Helper start-up

    /// Reconcile with reality when the helper (re)starts: after a crash of the
    /// helper, after a reboot, or on first install.
    public func reconcileOnLaunch() async {
        let saved = store.load()
        let rebooted = saved.map { abs($0.bootTime.timeIntervalSince(clock.bootTime())) > 1 } ?? true

        // An orphaned sing-box from a crashed helper: we can no longer observe
        // it, so it goes. pf (if it was on) keeps blocking meanwhile.
        if !rebooted, let pid = saved?.enginePID, await engine.isRunning(pid: pid) {
            await engine.terminate(pid: pid)
        }

        let resume = !rebooted && (saved?.wantConnected ?? false)
        // The user's rule: after a reboot the network is pristine, whatever
        // the mode. "Always" blocks only within one boot (after a helper
        // restart), never from boot.
        let always = profile.protectionMode == .always && !rebooted

        if resume || always {
            // Block first, then (maybe) connect: no window where traffic leaks.
            do {
                let r = try rules(tun: nil)
                try await pfTry { try await $0.load(r) }
                if !rebooted, let old = saved?.pfToken { pfToken = old } else { pfToken = try await pfTry { try await $0.enable() } }
            } catch {
                lastError = "Could not enable the kill switch: \(error.localizedDescription)"
            }
            if resume {
                wantConnected = true
                epoch += 1
                beginRecovery(epoch: epoch, reason: nil)
                return
            }
            set(.off)
            return
        }

        // Clean slate: whatever a previous instance left in our anchor goes.
        // After a reboot pf has nothing of ours anyway, and the network is
        // exactly as macOS brought it up.
        await pfRun { await $0.flush() }
        if !rebooted, let old = saved?.pfToken { await pfRun { await $0.release(token: old) } }
        wantConnected = false
        set(.off)
    }

    // MARK: - Internals

    private func rules(tun: String?) throws -> String {
        try PFRules.generate(.init(tunInterface: tun, singBoxGroup: options.singBoxGroup, lan: profile.lan))
    }

    private func makeConfig() throws -> Data {
        var env = options.configEnvironment
        env.clashAPISecret = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        let data = try SingBoxConfig.generate(profile, env: env).encoded()
        apiSecret = env.clashAPISecret
        return data
    }

    /// The clash API secret of the running sing-box, for the app's live stats.
    public var currentAPISecret: String? { phase == .connected ? apiSecret : nil }

    /// launchd is stopping the helper (shutdown, reboot, or an update). Leave
    /// the network clean but remember whether the user wanted the VPN, so an
    /// update resumes it (behind the kill switch) and a reboot does not.
    public func shutdownForExit() async {
        epoch += 1
        recovery?.cancel()
        recovery = nil
        let wanted = wantConnected
        await teardown()
        wantConnected = wanted
        phase = .off
        publish()
    }

    /// One connection attempt. With `keepBlockingOnFailure` (recovery), a
    /// failure leaves pf as it is; on a first start nothing has been blocked
    /// yet and a failure leaves the network untouched.
    private func connect(epoch my: Int, keepBlockingOnFailure: Bool) async throws {
        if !keepBlockingOnFailure, let other = await network.foreignTunnel() {
            throw CommandError.failed("Another VPN is active (\(other)). Turn it off first.")
        }
        try Task.checkCancellation()
        guard epoch == my else { return }

        let config: Data
        let blocked: String
        do {
            config = try makeConfig()
            blocked = try rules(tun: nil)
        } catch {
            throw CommandError.failed("\(error)")
        }
        // Validate both before touching anything.
        try await engine.check(config: config)
        try await pf.validate(blocked)
        guard epoch == my else { return }

        let pid = try await engine.launch(config: config) { [weak self] pid in
            Task { await self?.engineExited(pid: pid) }
        }
        guard epoch == my else { await engine.terminate(pid: pid); return }
        enginePID = pid
        publish()

        // Wait for the TUN interface.
        var tun: String?
        let deadline = clock.now().addingTimeInterval(options.tunWaitSeconds)
        while tun == nil {
            guard epoch == my else { return }
            guard enginePID == pid, await engine.isRunning(pid: pid) else {
                enginePID = nil
                throw CommandError.failed("sing-box exited during start")
            }
            tun = await network.tunInterface()
            if tun == nil {
                guard clock.now() < deadline else {
                    await killEngine(pid)
                    throw CommandError.failed("sing-box did not bring up its interface in time")
                }
                try await clock.sleep(seconds: 0.25)
            }
        }
        guard epoch == my else { return }

        // Prove the servers carry traffic before locking anything down:
        // "Everything else" must reach one of its servers; any other route
        // using servers must reach at least one too, or there is no VPN.
        via = [:]
        await checkServers(epoch: my)
        guard epoch == my else { return }
        let def = profile.defaultRoute
        if case .servers = def.target, case .server = via[def.id] {
            // fine
        } else if case .servers = def.target {
            if epoch == my { await killEngine(pid) }
            throw CommandError.failed("No server of “\(def.name)” answers — check the servers")
        } else if !profile.serverRoutes.isEmpty, !latency.values.contains(where: { $0 != nil }) {
            if epoch == my { await killEngine(pid) }
            throw CommandError.failed("No server answers — check the servers")
        }
        guard epoch == my, let tun else { return }
        allDownChecks = 0

        // Kill switch last.
        if profile.protectionMode == .off {
            // Blocking held over from a profile switch: the new profile wants
            // none, and its tunnel is proven.
            if let t = pfToken {
                pfToken = nil
                await pfRun { await $0.flush() }
                await pfRun { await $0.release(token: t) }
                guard epoch == my else { return }
            }
            connectedSince = clock.now()
            attempts = 0
            lastError = nil
            set(.connected)
            return
        }
        let connectedRules = try rules(tun: tun)
        try await pf.validate(connectedRules)
        try await pfTry { try await $0.load(connectedRules) }
        guard epoch == my else { return }
        if pfToken == nil {
            do {
                pfToken = try await pfTry { try await $0.enable() }
            } catch {
                await pfRun { await $0.flush() }
                await killEngine(pid)
                throw CommandError.failed("Could not enable the kill switch: \(error.localizedDescription)")
            }
        }
        guard epoch == my else { return }
        connectedSince = clock.now()
        attempts = 0
        lastError = nil
        set(.connected)
    }

    // MARK: pf, in order

    /// pfctl calls run as separate processes; two in flight at once could land
    /// in either order (an old reconnect's load after a panic's flush). Every
    /// call goes through one FIFO queue, enqueued synchronously on the actor,
    /// so pf sees them in the order the controller issued them.
    private let pfQueue = SerialQueue()

    private func pfTry<T: Sendable>(_ op: @escaping @Sendable (PacketFilter) async throws -> T) async throws -> T {
        let pf = self.pf
        return try await pfQueue.enqueue { try await op(pf) }.value
    }

    private func pfRun<T: Sendable>(_ op: @escaping @Sendable (PacketFilter) async -> T) async -> T {
        let pf = self.pf
        // Non-throwing op: the task cannot fail.
        return try! await pfQueue.enqueue { await op(pf) }.value
    }

    /// Blocks everything outside sing-box, with no tunnel allowed yet. A
    /// newer command (stop, panic) may take over while pf works: then the
    /// token is handed back rather than kept, so pf ends as that command left it.
    private func holdBlocking(epoch my: Int) async {
        if let r = try? rules(tun: nil) { try? await pfTry { try await $0.load(r) } }
        guard epoch == my, pfToken == nil else { return }
        let token = try? await pfTry { try await $0.enable() }
        if epoch == my {
            pfToken = token
        } else if let token {
            await pfRun { await $0.release(token: token) }
        }
    }

    private func killEngine(_ pid: Int32) async {
        if enginePID == pid { enginePID = nil }
        await engine.terminate(pid: pid)
    }

    /// Reconnect loop with exponential backoff. pf keeps blocking throughout.
    private func beginRecovery(epoch my: Int, reason: String?) {
        recovery?.cancel()
        if let reason { lastError = reason }
        set(.reconnecting)
        recovery = Task { [weak self] in
            await self?.recover(epoch: my)
        }
    }

    private func recover(epoch my: Int) async {
        // The task may start after a newer command (stop, panic) took over;
        // then pf is that command's business.
        guard epoch == my, wantConnected, !Task.isCancelled else { return }
        // Make sure pf blocks without a TUN while there is none (also when
        // blocking is held over from the previous profile).
        if profile.protectionMode != .off || pfToken != nil {
            await holdBlocking(epoch: my)
            guard epoch == my else { return }
        }
        while epoch == my, wantConnected, !Task.isCancelled {
            do {
                try await connect(epoch: my, keepBlockingOnFailure: true)
                if epoch == my, phase == .connected { return }
            } catch {
                guard epoch == my else { return }
                attempts += 1
                lastError = "\(error)"
                set(.reconnecting)
                if let pid = enginePID { await killEngine(pid) }
                let delay = min(options.maxBackoffSeconds, pow(2, Double(min(attempts, 10)) - 1))
                do { try await clock.sleep(seconds: delay) } catch { return }
            }
        }
    }

    private func teardown() async {
        via = [:]
        latency = [:]
        if let pid = enginePID {
            enginePID = nil
            await engine.terminate(pid: pid)
        }
        connectedSince = nil
        apiSecret = nil
        if profile.protectionMode == .always, let r = try? rules(tun: nil) {
            // "Always" means blocked whenever not connected.
            do {
                try await pfTry { try await $0.load(r) }
                if pfToken == nil { pfToken = try await pfTry { try await $0.enable() } }
                return
            } catch {
                lastError = "Could not keep the kill switch on: \(error.localizedDescription)"
            }
        }
        await pfRun { await $0.flush() }
        if let t = pfToken { await pfRun { await $0.release(token: t) } }
        pfToken = nil
    }
}

/// A FIFO of async operations: each starts after the previous one finished.
final class SerialQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        lock.withLock {
            let previous = tail
            let task = Task { () async throws -> T in
                await previous?.value
                return try await op()
            }
            tail = Task { _ = try? await task.value }
            return task
        }
    }
}
