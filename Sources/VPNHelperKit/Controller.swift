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
///     network as before, no kill switch                       retries with backoff)
/// stop / panic from any state ──▶ off, pf anchor empty, network as before
/// ```
///
/// Rules this code keeps:
/// - With a kill switch on any active route, blocking goes on as soon as a
///   start's checks pass — before sing-box runs — and the tunnel is proven
///   behind it. A failed start lifts it: the network ends exactly as it was.
///   Without a kill switch nothing is blocked at any point.
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
        /// sing-box's start: its interface, routes and API.
        public var startWaitSeconds: Double = 30
        public var maxBackoffSeconds: Double = 30
        /// sing-box is restarted only after no server has answered for this
        /// long. A restart drops every connection (a call, a download), and
        /// a network change usually heals by itself within a few seconds.
        public var restartAfterSeconds: Double = 12
        /// After a network change, how often to look until servers answer.
        public var probeIntervalSeconds: Double = 2
        /// Failed checks in a row before a server that was answering counts
        /// as down: one lost check (a dropped packet, a busy moment) does
        /// not move or block its routes.
        public var failAfterChecks = 2
        /// Free localhost ports, asked for at each sing-box start: the Wi-Fi
        /// login-page proxy and its clash API. Nil: the environment's API
        /// port and no login proxy (tests).
        public var localPorts: (@Sendable (Int) -> [UInt16]?)?
        /// While a network wants a login: how often to look whether the
        /// servers answer yet.
        public var captiveCheckSeconds: Double = 3
        /// Environment for config generation, minus the per-start clash API
        /// port and secret, which the controller fills in.
        public var configEnvironment: SingBoxConfig.Environment
        /// The address and site lists on disk; nil: none (tests).
        public var ruleLists: RuleListHooks?

        public init(singBoxGroup: UInt32, configEnvironment: SingBoxConfig.Environment) {
            self.singBoxGroup = singBoxGroup
            self.configEnvironment = configEnvironment
        }
    }

    /// The helper's list store, as the controller uses it.
    public struct RuleListHooks: Sendable {
        /// Which of these lists are on disk, and where.
        public var local: @Sendable ([String]) async -> [String: SingBoxConfig.LocalList]
        /// Downloads the lists a profile uses that are not on disk yet.
        public var fetchMissing: @Sendable (Profile) async -> Void
        public init(local: @escaping @Sendable ([String]) async -> [String: SingBoxConfig.LocalList],
                    fetchMissing: @escaping @Sendable (Profile) async -> Void) {
            self.local = local
            self.fetchMissing = fetchMissing
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
    /// When the user turned the VPN on: kept across reconnects, cleared when
    /// it is turned off.
    private var sessionSince: Date?
    private var lastError: String?
    private var attempts = 0
    private var wantConnected = false
    private var recovery: Task<Void, Never>?
    private var watchers: [UUID: AsyncStream<Status>.Continuation] = [:]
    private var api: (port: UInt16, secret: String)?
    /// Last measured round trip per server (nil inside: not answering).
    private var latency: [UUID: Int?] = [:]
    /// Where each route's selector points now.
    private var via: [UUID: RouteState.Via] = [:]
    /// Servers counted as answering, and each one's failed checks in a row.
    private var alive: Set<UUID> = []
    private var strikes: [UUID: Int] = [:]
    /// The session log's ear: told when a session begins and ends and what
    /// happens in between. Set by the daemon; nil in most tests.
    private var sessionHook: (@Sendable (SessionEvent) -> Void)?
    private var inSession = false

    public func setSessionHook(_ hook: @escaping @Sendable (SessionEvent) -> Void) {
        sessionHook = hook
    }

    private func session(_ e: SessionEvent) {
        switch e {
        case .began: inSession = true
        case .ended: guard inSession else { return }; inSession = false
        case .note: guard inSession else { return }
        }
        sessionHook?(e)
    }

    /// The network wants a login; the login-page proxy is open meanwhile.
    private var captive = false
    /// That proxy's address and password for the running sing-box.
    private var captiveProxy: SingBoxConfig.LocalProxy?
    /// The addresses macOS sends direct for the running sing-box: taken with
    /// its config, so the TUN's routes and the kill switch always agree,
    /// even when a list is updated meanwhile.
    private var direct: [IPNetwork] = []

    /// When the servers stopped answering, while they still don't.
    private var downSince: Date?
    /// The quick checks after a network change; one at a time.
    private var probing: Task<Void, Never>?

    public init(profile: Profile, options: Options, pf: PacketFilter, engine: Engine, network: NetworkInspector,
                store: StateStore, clock: Clock) {
        self.profile = profile
        self.options = options
        self.pf = pf
        self.engine = engine
        self.network = network
        self.store = store
        self.clock = clock
        // Read before anything can write: every transition saves the state,
        // and loading the owner's profile at start-up (before
        // `reconcileOnLaunch`) is one. Read later, the previous helper's
        // "the VPN was on" would already be overwritten — and the VPN would
        // not come back after an update.
        savedAtLaunch = store.load()
    }

    /// What the previous helper left, as it was when this one started.
    private let savedAtLaunch: PersistedState?
    /// sing-box answers DNS on this Mac's port 53 too (see SystemDNS): set
    /// per attempt, when the port is free and the guard keeping it to this
    /// Mac is in place.
    private var localDNS = false
    /// sing-box's log level for the session: set before it begins, kept
    /// through its reconnects (one log file, one level).
    private var logLevel: String?

    public func setLogLevel(_ level: String) { logLevel = level }

    // MARK: - Status

    public var status: Status {
        Status(phase: phase, connectedSince: connectedSince, sessionSince: sessionSince,
               killSwitchOn: pfToken != nil, lastError: lastError, reconnectAttempts: attempts,
               servers: phase == .connected ? latency.keys.sorted { $0.uuidString < $1.uuidString }
                   .map { ServerState(id: $0, latencyMs: latency[$0] ?? nil) } : [],
               routes: phase == .connected ? profile.serverRoutes.compactMap { r in via[r.id].map { RouteState(id: r.id, via: $0) } } : [],
               captivePortal: captive && phase == .reconnecting)
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
                                  bootTime: clock.bootTime(), bootSession: clock.bootSession()))
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
        session(.began(profile: profile.name, resumed: false))
        set(.connecting)
        do {
            try await connect(epoch: my, keepBlockingOnFailure: false)
        } catch let e as CommandError {
            if epoch == my {
                wantConnected = false
                await liftFailedStart()
                set(.off, error: e.description)
                session(.ended(reason: "could not connect — \(e.description)"))
            }
            throw e
        } catch {
            if epoch == my {
                wantConnected = false
                await liftFailedStart()
                set(.off, error: error.localizedDescription)
                session(.ended(reason: "could not connect — \(error.localizedDescription)"))
            }
            throw .failed(error.localizedDescription)
        }
    }

    /// A first start failed: sing-box goes, and the block it was proven
    /// behind is lifted ("Always" keeps it), so the network is as before.
    private func liftFailedStart() async {
        if let pid = enginePID { await killEngine(pid) }
        await network.releaseLocalDNS()
        localDNS = false
        guard pfToken != nil || profile.protectionMode == .always else { return }
        await teardown()
    }

    public func stop() async {
        epoch += 1
        wantConnected = false
        recovery?.cancel()
        recovery = nil
        set(.stopping)
        await teardown()
        await engineSettled()
        lastError = nil
        set(.off)
        session(.ended(reason: "turned off"))
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
        if let pid { await stopEngine(pid) }
        await network.restoreRouting()
        await network.restoreDNS()
        await network.releaseLocalDNS()
        localDNS = false
        await engineSettled()
        session(.ended(reason: "Emergency Restore"))
        via = [:]
        latency = [:]
        alive = []
        strikes = [:]
        api = nil
        connectedSince = nil
        sessionSince = nil
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
            // The new profile must make a config — no errors, its lists on
            // disk — before anything is switched over.
            var env = options.configEnvironment
            if let lists = options.ruleLists {
                await lists.fetchMissing(new)
                env.lists = await lists.local(RuleLists.urls(new))
            }
            do { _ = try SingBoxConfig.generate(new, env: env) } catch { throw .failed(error.description) }
        }
        guard phase == .connected || phase == .reconnecting || phase == .off else { throw .busy(phase) }
        let guarded = profile.protectionMode != .off || new.protectionMode != .off
        if running {
            session(.note(new.id == profile.id ? "profile edited; applying the changes" : "profile switched to “\(new.name)”"))
        }
        profile = new
        guard running else { publish(); return }
        epoch += 1
        let my = epoch
        if guarded { await holdBlocking(epoch: my) }
        guard epoch == my else { return }
        if let pid = enginePID { enginePID = nil; await stopEngine(pid) }
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
        // DHCP may have rewritten the DNS (a new Wi-Fi): point it back.
        await network.overrideDNS(server: SingBoxConfig.tunDNS, local: localDNS)
        guard epoch == my, phase == .connected else { return }
        let anyUp = await checkServers(epoch: my)
        guard epoch == my, phase == .connected else { return }
        await judge(anyUp: anyUp, epoch: my)
    }

    /// Fallbacks handle single servers. No server answering at all, for
    /// longer than `restartAfterSeconds`, means sing-box or the network under
    /// it is stuck (sleep, a network change): restart it behind the kill
    /// switch. Shorter outages are waited out, so connections survive them.
    private func judge(anyUp: Bool, epoch my: Int) async {
        guard !anyUp else { downSince = nil; return }
        let now = clock.now()
        guard let since = downSince else { downSince = now; return }
        guard now.timeIntervalSince(since) >= options.restartAfterSeconds else { return }
        downSince = nil
        epoch += 1
        if let pid = enginePID { enginePID = nil; await stopEngine(pid) }
        beginRecovery(epoch: epoch, reason: "no exit answers")
    }

    private func describe(_ v: RouteState.Via) -> String {
        switch v {
        case .server(let id): "now through “\(profile.tunnels.first { $0.id == id }?.name ?? "a server")”"
        case .direct: "no server answers; going direct"
        case .blocked: "no server answers; blocked by its kill switch"
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
        // A server that was answering stays in use until it has failed
        // `failAfterChecks` checks in a row; one that was not needs one
        // answer. (Right after a start nothing was answering yet: the first
        // check decides at once.)
        var stillAlive: Set<UUID> = []
        for id in ids {
            if (measured[id] ?? nil) != nil {
                strikes[id] = 0
                stillAlive.insert(id)
            } else {
                strikes[id, default: 0] += 1
                if alive.contains(id), strikes[id, default: 0] < options.failAfterChecks { stillAlive.insert(id) }
            }
        }
        alive = stillAlive
        for r in routes {
            let chain = profile.chain(of: r)
            let up = chain.first { alive.contains($0) }
            let next: RouteState.Via = up.map { .server($0) } ?? (r.killSwitch ? .blocked : .direct)
            guard via[r.id] != next else { continue }
            // Blocked: its first (dead) server, which fails every connection.
            // A route with no server at all cannot run (validation refuses
            // it); never "direct" in its place, which would open it.
            let member: String
            switch next {
            case .server(let id): member = SingBoxConfig.tag(id)
            case .direct: member = SingBoxConfig.direct
            case .blocked:
                guard let first = chain.first else { continue }
                member = SingBoxConfig.tag(first)
            }
            do {
                try await engine.select(SingBoxConfig.routeTag(r.id), member: member)
                guard epoch == my else { return false }
                if via[r.id] != nil { session(.note("route “\(r.name)”: \(describe(next))")) }
                via[r.id] = next
            } catch {
                // Left as it was; the next check tries again.
            }
        }
        publish()
        return measured.values.contains { $0 != nil }
    }

    /// After sleep or a network change: look every couple of seconds until
    /// the servers answer again, instead of waiting for the next tick. The
    /// system reports changes in bursts (our own TUN coming up is one), so
    /// one round of checks covers them all.
    public func networkChanged() async {
        guard phase == .connected, probing == nil else { return }
        // In the log: the errors sing-box prints right now (connections cut
        // by the change) have a cause a reader can see.
        session(.note("the network changed; checking the servers"))
        let my = epoch
        probing = Task { [weak self] in await self?.probe(epoch: my) }
    }

    private func probe(epoch my: Int) async {
        let rounds = Int((options.restartAfterSeconds / options.probeIntervalSeconds).rounded(.up)) + 1
        for _ in 0..<rounds {
            do { try await clock.sleep(seconds: options.probeIntervalSeconds) } catch { break }
            guard epoch == my, phase == .connected else { break }
            let anyUp = await checkServers(epoch: my)
            guard epoch == my, phase == .connected else { break }
            await judge(anyUp: anyUp, epoch: my)
            if anyUp {
                await network.overrideDNS(server: SingBoxConfig.tunDNS, local: localDNS)
                break
            }
        }
        probing = nil
    }

    // MARK: - Helper start-up

    /// Reconcile with reality when the helper (re)starts: after a crash of the
    /// helper, after a reboot, or on first install.
    public func reconcileOnLaunch() async {
        let saved = savedAtLaunch
        let rebooted = saved.map { $0.isFromAnotherBoot(bootTime: clock.bootTime(), bootSession: clock.bootSession()) } ?? true

        // An orphaned sing-box from a crashed helper: we can no longer observe
        // it, so it goes. pf (if it was on) keeps blocking meanwhile.
        if !rebooted, let pid = saved?.enginePID, await engine.isRunning(pid: pid) {
            await stopEngine(pid)
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
                session(.began(profile: profile.name, resumed: true))
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
        // A helper that crashed while connected left macOS's DNS pointing
        // into a tunnel that is gone, and maybe the local DNS guard: put
        // both back.
        await network.restoreDNS()
        await network.releaseLocalDNS()
        wantConnected = false
        set(.off)
    }

    // MARK: - Internals

    private func rules(tun: String?) throws -> String {
        try PFRules.generate(.init(tunInterface: tun, singBoxGroup: options.singBoxGroup, lan: profile.lan, direct: direct))
    }

    private func makeConfig(lists: [String: SingBoxConfig.LocalList]?) throws -> Data {
        var env = options.configEnvironment
        if let lists { env.lists = lists }
        env.clashAPISecret = Secret.random()
        env.localDNS = localDNS
        if let logLevel { env.logLevel = logLevel }
        env.captive = nil
        if let localPorts = options.localPorts {
            guard let ports = localPorts(2), ports.count == 2 else {
                throw CommandError.failed("No free local port for sing-box")
            }
            env.captive = .init(port: ports[0], username: "silentroute", password: Secret.random())
            env.clashAPIPort = ports[1]
        }
        let data = try SingBoxConfig.generate(profile, env: env).encoded()
        direct = SingBoxConfig.directAddresses(profile, env: env)
        api = (env.clashAPIPort, env.clashAPISecret)
        captiveProxy = env.captive
        return data
    }

    /// The Wi-Fi login proxy, while a network wants a login: for the
    /// owner's app, which opens the login page through it.
    public var currentCaptiveProxy: SingBoxConfig.LocalProxy? { captive ? captiveProxy : nil }

    /// The running sing-box's clash API, for the app's live stats.
    public var currentAPI: (port: UInt16, secret: String)? { phase == .connected ? api : nil }

    /// launchd is stopping the helper: an update, a shutdown or a restart.
    ///
    /// With the VPN on and a kill switch on any route, everything outside the
    /// tunnel stays blocked: an update must not let traffic out while one
    /// helper replaces the other, and the next helper resumes the VPN behind
    /// the same block. sing-box and the DNS change go; pf alone stays. A
    /// restart of the Mac clears pf, so the network after a reboot is
    /// pristine all the same, and the installer lifts the block itself if no
    /// helper comes back.
    ///
    /// With the VPN off, or a profile without any kill switch, nothing is
    /// blocked: the network is left as macOS has it.
    public func shutdownForExit() async {
        epoch += 1
        recovery?.cancel()
        recovery = nil
        let wanted = wantConnected
        if wanted, profile.protectionMode != .off, let blocked = try? rules(tun: nil) {
            via = [:]
            latency = [:]
            captive = false
            await network.restoreDNS()
            do {
                // Blocked before sing-box goes: no moment of open network.
                try await pfTry { try await $0.load(blocked) }
                if pfToken == nil { pfToken = try await pfTry { try await $0.enable() } }
                if let pid = enginePID {
                    enginePID = nil
                    await stopEngine(pid)
                }
                await network.releaseLocalDNS()
                localDNS = false
                connectedSince = nil
                api = nil
                session(.ended(reason: "the helper stopped (an update or a shutdown); the network stays blocked until the VPN is back"))
                phase = .off
                publish()
                return
            } catch {
                // Could not block: better a clean network than a broken one.
            }
        }
        await teardown()
        session(.ended(reason: wanted ? "the helper stopped (an update or a shutdown)" : "the helper stopped"))
        wantConnected = wanted
        phase = .off
        publish()
    }

    /// One connection attempt. With `keepBlockingOnFailure` (recovery), a
    /// failure leaves pf as it is. On a first start with a kill switch on
    /// any active route, everything outside sing-box is blocked once the
    /// checks pass and before sing-box starts, so nothing goes out past the
    /// tunnel while its servers are being proven; `start` lifts the block if
    /// the attempt fails. Without a kill switch the network is not touched.
    private func connect(epoch my: Int, keepBlockingOnFailure: Bool) async throws {
        // Routes a killed sing-box left would lead into nothing, and look
        // like another VPN's to the check below.
        await network.removeStaleTunnelRoutes()
        if !keepBlockingOnFailure, let other = await network.foreignTunnel() {
            throw CommandError.failed("Another VPN is active (\(other)). Turn it off first.")
        }
        try Task.checkCancellation()
        guard epoch == my else { return }

        // The profile's lists that are not on disk yet (saving the profile
        // fetched them already): fetched now, also behind the kill switch,
        // which lets the helper's downloads out as it does sing-box.
        var localLists: [String: SingBoxConfig.LocalList]?
        if let lists = options.ruleLists {
            await lists.fetchMissing(profile)
            guard epoch == my else { return }
            localLists = await lists.local(RuleLists.urls(profile))
            guard epoch == my else { return }
        }

        let config: Data
        let blocked: String
        localDNS = await network.prepareLocalDNS()
        guard epoch == my else { return }
        do {
            config = try makeConfig(lists: localLists)
            blocked = try rules(tun: nil)
        } catch {
            throw CommandError.failed("\(error)")
        }
        // Validate both before touching anything.
        try await engine.check(config: config)
        try await pf.validate(blocked)
        guard epoch == my else { return }
        if !keepBlockingOnFailure, profile.protectionMode != .off {
            await holdBlocking(epoch: my)
            guard epoch == my else { return }
        }

        // Started and, if a newer command took over meanwhile, stopped again
        // as one engine operation: turning off waits for it.
        let launched: Int32? = try await engineOperation {
            let pid = try await engine.launch(config: config) { [weak self] pid in
                Task { await self?.engineExited(pid: pid) }
            }
            guard epoch == my else { await engine.terminate(pid: pid); return nil }
            enginePID = pid
            return pid
        }
        guard let pid = launched else { return }
        publish()

        // Wait for sing-box to finish starting: its interface, then its API.
        // The interface comes first, its routes after it (tens of thousands
        // when macOS sends a country's addresses direct, seconds of work);
        // the API opens last. Asked before that, every server looks dead.
        var tun: String?
        var ready = false
        let deadline = clock.now().addingTimeInterval(options.startWaitSeconds)
        while tun == nil || !ready {
            guard epoch == my else { return }
            guard enginePID == pid, await engine.isRunning(pid: pid) else {
                enginePID = nil
                throw CommandError.failed("sing-box exited during start")
            }
            if tun == nil { tun = await network.tunInterface() }
            if tun != nil { ready = await engine.isReady() }
            if tun == nil || !ready {
                guard clock.now() < deadline else {
                    await killEngine(pid)
                    throw CommandError.failed(tun == nil ? "sing-box did not bring up its interface in time"
                                                         : "sing-box did not finish starting in time")
                }
                try await clock.sleep(seconds: 0.25)
            }
        }
        guard epoch == my else { return }

        // Prove the servers carry traffic before locking anything down:
        // "Everything else" must reach one of its servers; any other route
        // using servers must reach at least one too, or there is no VPN.
        via = [:]
        alive = []
        strikes = [:]
        await checkServers(epoch: my)
        guard epoch == my else { return }
        if let failure = proofFailure() {
            // Reconnecting behind the kill switch on a network that wants a
            // login (a hotel, a café): keep sing-box, open the login-page
            // proxy, and wait for the servers instead of starting over.
            if keepBlockingOnFailure, let proxy = captiveProxy, await network.captivePortal(via: proxy), epoch == my {
                try await waitForLogin(epoch: my, pid: pid, proxy: proxy)
            } else {
                if epoch == my { await killEngine(pid) }
                throw CommandError.failed(await network.foreignFirewall() ? "\(failure) — \(ForeignFirewall.hint)" : failure)
            }
        }
        guard epoch == my, let tun else { return }
        downSince = nil

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
            sessionSince = sessionSince ?? connectedSince
            attempts = 0
            lastError = nil
            set(.connected)
            session(.note("connected"))
            await network.overrideDNS(server: SingBoxConfig.tunDNS, local: localDNS)
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
        sessionSince = sessionSince ?? connectedSince
        attempts = 0
        lastError = nil
        set(.connected)
        session(.note("connected"))
        // macOS's resolver into the tunnel: no name is asked of the router.
        await network.overrideDNS(server: SingBoxConfig.tunDNS, local: localDNS)
    }

    /// Why the servers are not proven to carry traffic, or nil if they are:
    /// "Everything else" must reach one of its servers; any other route
    /// using servers must reach at least one too, or there is no VPN.
    private func proofFailure() -> String? {
        let def = profile.defaultRoute
        if case .servers = def.target {
            if case .server = via[def.id] { return nil }
            return "No server of “\(def.name)” answers — check the servers"
        }
        if !profile.serverRoutes.isEmpty, !latency.values.contains(where: { $0 != nil }) {
            return "No server answers — check the servers"
        }
        return nil
    }

    /// The network wants a login. sing-box keeps running (behind the kill
    /// switch: nothing else gets out) with the login-page proxy open, until
    /// the servers answer — the user has logged in — or the network turns
    /// out not to want a login after all.
    private func waitForLogin(epoch my: Int, pid: Int32, proxy: SingBoxConfig.LocalProxy) async throws {
        captive = true
        session(.note("this network wants a login (a hotel or café Wi-Fi); everything else stays blocked meanwhile"))
        publish()
        defer { captive = false }
        var round = 0
        while epoch == my {
            try await clock.sleep(seconds: options.captiveCheckSeconds)
            guard epoch == my else { return }
            guard enginePID == pid, await engine.isRunning(pid: pid) else {
                throw CommandError.failed("sing-box exited while waiting for the Wi-Fi login")
            }
            await checkServers(epoch: my)
            guard epoch == my else { return }
            if proofFailure() == nil {
                session(.note("logged in to the network; the servers answer"))
                return
            }
            round += 1
            // Now and then: still a login page? If not, this is a plain
            // outage; start over the usual way.
            if round % 5 == 0, !(await network.captivePortal(via: proxy)) {
                if epoch == my { await killEngine(pid) }
                throw CommandError.failed("No server answers — check the servers")
            }
        }
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
        await stopEngine(pid)
    }

    // MARK: Engine operations

    /// sing-box starts and stops under way. Turning off waits for them, so
    /// "off" never has a sing-box still coming or going (a switch of
    /// profiles, a reconnect, racing with the user's Turn Off).
    private var engineOperations = 0
    private var engineIdle: [CheckedContinuation<Void, Never>] = []

    private func engineOperation<T>(_ body: () async throws -> T) async rethrows -> T {
        engineOperations += 1
        defer {
            engineOperations -= 1
            if engineOperations == 0 {
                let waiting = engineIdle
                engineIdle = []
                for w in waiting { w.resume() }
            }
        }
        return try await body()
    }

    private func stopEngine(_ pid: Int32) async {
        await engineOperation { await engine.terminate(pid: pid) }
    }

    /// Returns once no sing-box is starting or stopping.
    private func engineSettled() async {
        guard engineOperations > 0 else { return }
        await withCheckedContinuation { engineIdle.append($0) }
    }

    /// Reconnect loop with exponential backoff. pf keeps blocking throughout.
    private func beginRecovery(epoch my: Int, reason: String?) {
        recovery?.cancel()
        if let reason { lastError = reason }
        session(.note(reason.map { "reconnecting: \($0)" } ?? "reconnecting"))
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
        } else {
            // No kill switch: traffic goes direct while the tunnel is down,
            // so names must resolve without it too.
            await network.restoreDNS()
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
                session(.note("attempt \(attempts) failed: \(error)"))
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
        alive = []
        strikes = [:]
        await network.restoreDNS()
        await network.releaseLocalDNS()
        localDNS = false
        if let pid = enginePID {
            enginePID = nil
            await stopEngine(pid)
        }
        connectedSince = nil
        sessionSince = nil
        api = nil
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
