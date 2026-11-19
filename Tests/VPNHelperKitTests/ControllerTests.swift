import Foundation
import Testing
@testable import VPNCore
@testable import VPNHelperKit

/// The state machine against a scripted system. The two properties that
/// matter most are checked throughout:
///   1. a start that fails leaves the network as it was before;
///   2. once the kill switch is on, nothing but stop/panic turns it off.
@Suite struct ControllerTests {

    // MARK: start

    /// With a kill switch on any active route, everything outside sing-box
    /// is blocked from the moment the switch is turned on — once the checks
    /// pass, before sing-box runs — and the tunnel is proven behind it.
    @Test func startBlocksBeforeSingBoxRuns() async throws {
        let h = Harness()
        try await h.controller.start()
        let s = await h.controller.status
        #expect(s.phase == .connected)
        #expect(s.killSwitchOn)
        #expect(await h.world.blocking)
        let log = await h.world.log
        let check = log.firstIndex(of: "engine.check")!
        let validate = log.firstIndex(of: "pf.validate")!
        let blocked = log.firstIndex(of: "pf.load(blocked)")!
        let enable = log.firstIndex(of: "pf.enable")!
        let launch = log.firstIndex { $0.hasPrefix("engine.launch") }!
        let health = log.firstIndex(of: "engine.health")!
        let connected = log.firstIndex(of: "pf.load(connected)")!
        // Validated before anything is touched; blocked before sing-box runs;
        // the tunnel let through once proven.
        #expect(check < blocked && validate < blocked)
        #expect(blocked < enable && enable < launch)
        #expect(launch < health && health < connected)
        #expect(log.filter { $0 == "pf.enable" }.count == 1)
    }

    /// No kill switch anywhere: the network is never blocked, not even
    /// while the servers are being proven.
    @Test func startWithoutKillSwitchNeverBlocks() async throws {
        let h = Harness(killSwitch: .off)
        try await h.controller.start()
        #expect(await h.controller.status.phase == .connected)
        let log = await h.world.log
        #expect(!log.contains { $0.hasPrefix("pf.load") || $0 == "pf.enable" }, "\(log)")
    }

    /// Only active routes count: a kill switch on a route that is turned
    /// off does not block anything.
    @Test func killSwitchOnADisabledRouteDoesNotCount() async throws {
        let h = Harness(killSwitch: .off)
        var p = await h.controller.profile
        p.routes.append(Route(name: "Off", enabled: false, conditions: Conditions(destinations: [.domain("example.org")]),
                              target: .servers([Harness.h2.id]), killSwitch: true))
        #expect(p.protectionMode == .off)
        try await h.controller.update(profile: p)
        try await h.controller.start()
        #expect(!(await h.world.log.contains { $0.hasPrefix("pf.load") || $0 == "pf.enable" }))
        p.routes[p.routes.count - 1].enabled = true
        #expect(p.protectionMode == .whileConnected)
    }

    /// A failed start ends with the network as it was: checks that fail
    /// before anything runs never touch pf; a failure behind the block
    /// lifts it again.
    @Test(arguments: ["check", "launch", "dies", "noTun", "unhealthy", "foreign"])
    func failedStartLeavesTheNetworkAsItWas(failure: String) async {
        let h = Harness()
        await h.world.set { w in
            switch failure {
            case "check": w.checkFails = true
            case "launch": w.launchFails = true
            case "dies": w.dieRightAfterLaunch = true
            case "noTun": w.tunAppears = false
            case "unhealthy": w.healthy = false
            default: w.foreign = "utun3 (other VPN)"
            }
        }
        await #expect(throws: Controller.CommandError.self) { try await h.controller.start() }
        let s = await h.controller.status
        #expect(s.phase == .off)
        #expect(!s.killSwitchOn)
        #expect(s.lastError != nil)
        #expect(!(await h.world.blocking), "still blocking after a failed start")
        #expect(await h.world.anchorRules == nil)
        #expect(await h.world.tokens.isEmpty, "pf reference leaked")
        let log = await h.world.log
        if failure == "check" || failure == "foreign" {
            #expect(!log.contains { $0.hasPrefix("pf.load") || $0 == "pf.enable" }, "pf touched before the checks passed: \(log)")
        }
        #expect(await h.world.running.isEmpty, "sing-box left running")
        #expect(h.store.load()?.wantConnected == false)
    }

    @Test func secondStartIsRefused() async throws {
        let h = Harness()
        try await h.controller.start()
        await #expect(throws: Controller.CommandError.busy(.connected)) { try await h.controller.start() }
    }

    @Test func pfEnableFailureRollsBack() async {
        let h = Harness()
        await h.world.set { $0.pfEnableFails = true }
        await #expect(throws: Controller.CommandError.self) { try await h.controller.start() }
        #expect(await h.world.anchorRules == nil)
        #expect(await h.world.running.isEmpty)
        #expect(await h.controller.status.phase == .off)
    }

    // MARK: stop and panic

    @Test func stopRestoresEverything() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.controller.stop()
        #expect(await h.controller.status == Controller.Status(phase: .off, connectedSince: nil,
                                                               killSwitchOn: false, lastError: nil, reconnectAttempts: 0))
        #expect(await h.world.anchorRules == nil)
        #expect(await h.world.tokens.isEmpty)
        #expect(await h.world.running.isEmpty)
        #expect(h.store.load() == PersistedState(wantConnected: false, bootTime: h.clock.boot))
    }

    /// Integration run, 2026-10-12: sing-box's exit, reported while panic
    /// waited for it, started a reconnect that put the kill switch back.
    @Test func panicFromConnectedLeavesNothingBlocked() async throws {
        for _ in 0..<20 {
            let h = Harness()
            try await h.controller.start()
            await h.controller.panic()
            try await Task.sleep(for: .milliseconds(20))
            #expect(await h.controller.status.phase == .off)
            #expect(await h.world.anchorRules == nil)
            #expect(await h.world.tokens.isEmpty)
            #expect(await h.world.running.isEmpty)
        }
    }

    @Test func panicFromReconnecting() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.set { $0.launchFails = true }
        await h.world.crashAll()
        #expect(await h.wait(for: .reconnecting))
        await h.controller.panic()
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.anchorRules == nil)
        #expect(await h.world.tokens.isEmpty)
        #expect(await h.world.routingRestored == 1)
        // The cancelled recovery must not come back to life.
        for _ in 0..<50 { await Task.yield() }
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.running.isEmpty)
    }

    /// stop arriving while start is waiting for the interface: start must not
    /// resurrect anything afterwards.
    @Test func stopDuringStart() async throws {
        let h = Harness()
        await h.world.set { $0.tunAppears = false }
        h.clock.realDelay = .milliseconds(20)       // start now waits ~1 s for the interface
        let starting = Task { try? await h.controller.start() }
        #expect(await h.waitWorld { $0.log.contains { $0.hasPrefix("engine.launch") } })
        await h.controller.stop()
        await h.world.set { $0.tunAppears = true }
        await starting.value
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.running.isEmpty)
        #expect(await h.world.anchorRules == nil)
        #expect(await h.world.tokens.isEmpty)
    }

    // MARK: failures while connected

    /// Two clocks: the connection restarts with a reconnect, the session
    /// lasts from turning on to turning off.
    @Test func sessionStartSurvivesReconnects() async throws {
        let h = Harness()
        try await h.controller.start()
        let first = try #require(await h.controller.status.connectedSince)
        #expect(await h.controller.status.sessionSince == first)
        try await h.clock.sleep(seconds: 300)
        await h.world.crashAll()
        #expect(await h.waitWorld { $0.log.contains("engine.launch(101)") })
        #expect(await h.wait(for: .connected))
        #expect(await h.controller.status.sessionSince == first)
        #expect(await h.controller.status.connectedSince != first)
        await h.controller.stop()
        #expect(await h.controller.status.sessionSince == nil)
        try await h.clock.sleep(seconds: 60)
        try await h.controller.start()
        #expect(await h.controller.status.sessionSince != first)
    }

    /// The session log hears when a session begins and ends, and why.
    @Test func sessionEventsGoToTheLog() async throws {
        let h = Harness()
        let events = Events()
        await h.controller.setSessionHook { e in events.add(e) }
        try await h.controller.start()
        await h.world.crashAll()
        #expect(await h.waitWorld { $0.log.contains("engine.launch(101)") })
        #expect(await h.wait(for: .connected))
        await h.controller.stop()
        await h.controller.stop()                   // no second "ended"
        let got = events.all
        #expect(got.first == .began(profile: await h.controller.profile.name, resumed: false))
        #expect(got.contains(.note("connected")))
        #expect(got.contains { if case .note(let t) = $0 { t.hasPrefix("reconnecting") } else { false } })
        #expect(got.last == .ended(reason: "turned off"))
        #expect(got.filter { if case .ended = $0 { true } else { false } }.count == 1)
    }

    @Test func aFailedStartEndsItsSession() async {
        let h = Harness()
        let events = Events()
        await h.controller.setSessionHook { e in events.add(e) }
        await h.world.set { $0.launchFails = true }
        try? await h.controller.start()
        #expect(events.all.count == 2)
        if case .ended(let reason) = events.all.last { #expect(reason.hasPrefix("could not connect")) } else { Issue.record("not ended") }
    }

    // MARK: DNS

    /// macOS's resolver points into the tunnel only once it is proven, and
    /// goes back whenever the VPN goes off.
    @Test func dnsIsOverriddenWhileConnectedAndRestoredAfter() async throws {
        let h = Harness()
        try await h.controller.start()
        let log = await h.world.log
        let lock = try #require(log.firstIndex(of: "pf.enable"))
        let dns = try #require(log.firstIndex { $0.hasPrefix("dns.override") })
        #expect(lock < dns, "after the tunnel is proven and locked")
        #expect(await h.world.dnsOverridden)
        await h.controller.stop()
        #expect(!(await h.world.dnsOverridden))
        try await h.controller.start()
        await h.controller.panic()
        #expect(!(await h.world.dnsOverridden), "Emergency Restore puts it back too")
    }

    @Test func aFailedStartLeavesDNSAlone() async {
        let h = Harness()
        await h.world.set { $0.launchFails = true }
        try? await h.controller.start()
        #expect(!(await h.world.log.contains { $0.hasPrefix("dns.override") }))
        #expect(!(await h.world.dnsGuard), "local DNS guard left after a failed start")
    }

    /// sing-box answers DNS on the Mac's port 53 and macOS is pointed at
    /// each interface's own address, so queries macOS scopes to an
    /// interface are answered too. The guard keeping that port to the Mac
    /// goes up before sing-box starts, and down with the VPN.
    @Test func localDNSIsGuardedFromBeforeStartToStop() async throws {
        let h = Harness()
        try await h.controller.start()
        let log = await h.world.log
        let guarded = try #require(log.firstIndex(of: "dns.guard"))
        let launch = try #require(log.firstIndex { $0.hasPrefix("engine.launch") })
        #expect(guarded < launch)
        #expect(log.contains("dns.override(local)"))
        #expect(await h.world.dnsLocal)
        #expect(await h.world.dnsGuard)
        await h.controller.stop()
        #expect(!(await h.world.dnsGuard))
        try await h.controller.start()
        await h.controller.panic()
        #expect(!(await h.world.dnsGuard), "Emergency Restore lifts the guard too")
        try await h.controller.start()
        await h.controller.shutdownForExit()
        #expect(!(await h.world.dnsGuard), "a helper stop lifts it (sing-box is gone)")
    }

    /// Port 53 already in use (a local DNS server): the tunnel address as
    /// before, no guard, and the VPN still connects.
    @Test func portTakenFallsBackToTheTunnelAddress() async throws {
        let h = Harness()
        await h.world.set { $0.port53Taken = true }
        try await h.controller.start()
        #expect(await h.controller.status.phase == .connected)
        #expect(await h.world.log.contains("dns.override"))
        #expect(!(await h.world.dnsLocal))
        #expect(!(await h.world.dnsGuard))
    }

    @Test func aHelperRestartPutsLeftoverDNSBack() async {
        let h = Harness()
        await h.controller.reconcileOnLaunch()
        #expect(await h.world.log.contains("dns.restore"))
    }

    // MARK: Wi-Fi login

    /// The café: the tunnel drops, the network wants a login. Blocking holds,
    /// sing-box stays (its login-page proxy open), and once the user has
    /// logged in the same sing-box carries on — no restart, no gap.
    @Test func aNetworkWantingALoginKeepsBlockingUntilTheServersAnswer() async throws {
        let h = Harness(captivePort: 28_123)
        try await h.controller.start()
        h.clock.realDelay = .milliseconds(5)
        await h.world.set { $0.healthy = false; $0.captive = true }
        await h.world.crashAll()                                   // the tunnel goes with the old network
        #expect(await h.wait(for: .reconnecting) { $0.captivePortal })
        #expect(await h.world.blocking)
        #expect(await h.controller.currentCaptiveProxy?.port == 28_123)
        let launches = await h.world.log.filter { $0.hasPrefix("engine.launch") }.count
        // Logged in: the servers answer.
        await h.world.set { $0.healthy = true; $0.captive = false }
        #expect(await h.wait(for: .connected))
        #expect(await h.world.log.filter { $0.hasPrefix("engine.launch") }.count == launches, "the same sing-box carries on")
        #expect(await h.world.blocking)
        #expect(await h.controller.currentCaptiveProxy == nil, "the way out closes")
        let log = await h.world.log
        let crash = try #require(log.firstIndex { $0.hasPrefix("engine.crash") })
        #expect(!log[crash...].contains("pf.flush") && !log[crash...].contains("pf.release"))
        h.clock.realDelay = nil
        await h.controller.stop()
    }

    /// No login page: an ordinary outage, handled the usual way.
    @Test func withoutALoginPageItIsAnOrdinaryOutage() async throws {
        let h = Harness(captivePort: 28_123)
        try await h.controller.start()
        await h.world.set { $0.healthy = false; $0.captive = false }
        await h.world.crashAll()
        #expect(await h.waitWorld { $0.log.filter { $0.hasPrefix("engine.launch") }.count >= 3 })
        #expect(!(await h.controller.status.captivePortal))
        #expect(await h.world.blocking)
        await h.controller.stop()
    }

    @Test func turningItOnInACafeDoesNotOpenAWayOut() async {
        let h = Harness(captivePort: 28_123)
        await h.world.set { $0.healthy = false; $0.captive = true }
        try? await h.controller.start()
        #expect(await h.controller.status.phase == .off)
        #expect(!(await h.world.blocking), "a failed start changes nothing")
        #expect(!(await h.world.log.contains("net.captive?")))
    }

    @Test func crashKeepsBlockingAndReconnects() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.crashAll()
        // Reconnected: a second sing-box is up and the controller says so.
        #expect(await h.waitWorld { $0.log.contains("engine.launch(101)") })
        #expect(await h.wait(for: .connected))
        #expect(await h.world.blocking)
        let log = await h.world.log
        let crash = log.firstIndex { $0.hasPrefix("engine.crash") }!
        // From the crash on, pf was never flushed or released.
        #expect(!log[crash...].contains("pf.flush") && !log[crash...].contains("pf.release"))
        #expect(log[crash...].contains("pf.load(blocked)"))
        #expect(await h.world.running.count == 1)
    }

    @Test func persistentFailureBacksOffAndKeepsBlocking() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.set { $0.launchFails = true }
        await h.world.crashAll()
        #expect(await h.wait(for: .reconnecting) { $0.reconnectAttempts >= 7 })
        #expect(await h.world.blocking, "the network opened while the tunnel was down")
        let sleeps = h.clock.recordedSleeps.filter { $0 >= 1 }
        #expect(Array(sleeps.prefix(6)) == [1, 2, 4, 8, 16, 30])
        // The server comes back.
        await h.world.set { $0.launchFails = false }
        #expect(await h.wait(for: .connected))
        #expect(await h.controller.status.reconnectAttempts == 0)
        await h.controller.stop()
    }

    @Test func unhealthyTunnelIsRestarted() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.set { $0.healthy = false }
        // Checks in quick succession are not enough: only silence for
        // longer than restartAfterSeconds (12 s) restarts sing-box.
        await h.controller.healthTick()
        await h.controller.healthTick()
        #expect(await h.controller.status.phase == .connected)
        try await h.clock.sleep(seconds: 10)
        await h.controller.healthTick()
        #expect(await h.controller.status.phase == .connected)
        try await h.clock.sleep(seconds: 10)
        await h.controller.healthTick()
        #expect(await h.controller.status.phase == .reconnecting)
        #expect(await h.world.blocking)
        await h.world.set { $0.healthy = true }
        #expect(await h.wait(for: .connected))
        await h.controller.stop()
    }

    /// A network change that heals within a few seconds keeps sing-box and
    /// every connection through it (a call survives a Wi-Fi switch).
    @Test func shortOutageAfterNetworkChangeKeepsTheEngine() async throws {
        let h = Harness()
        try await h.controller.start()
        // Real time per quick check, so the test can step in between them.
        h.clock.realDelay = .milliseconds(30)
        func rounds() -> Int { h.clock.recordedSleeps.filter { $0 == 2 }.count }
        await h.world.set { $0.healthy = false }
        // A burst of change reports starts one round of quick checks.
        await h.controller.networkChanged()
        await h.controller.networkChanged()
        await h.controller.networkChanged()
        #expect(await Self.until { rounds() >= 2 })        // 4 s without an answer
        await h.world.set { $0.healthy = true }             // the new network is up
        // The checks stop as soon as the servers answer: one more round at
        // most, and one round of checks for the whole burst of reports.
        try await Task.sleep(for: .milliseconds(300))
        #expect((2...3).contains(rounds()))
        #expect(await h.controller.status.phase == .connected)
        #expect(await h.world.log.filter { $0.hasPrefix("engine.launch") }.count == 1, "sing-box was not restarted")
        h.clock.realDelay = nil
        await h.controller.stop()
    }

    /// Polls a condition for up to two seconds of real time.
    static func until(_ cond: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func longOutageAfterNetworkChangeRestarts() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.set { $0.healthy = false }
        await h.controller.networkChanged()
        // Quick checks every 2 s; after 12 s of silence sing-box restarts
        // behind the kill switch.
        #expect(await h.wait(for: .reconnecting) { _ in true })
        #expect(await h.world.blocking)
        let sleeps = h.clock.recordedSleeps.filter { $0 == 2 }
        #expect(sleeps.count >= 6)
        await h.world.set { $0.healthy = true }
        #expect(await h.wait(for: .connected))
        await h.controller.stop()
    }

    // MARK: route server lists

    static func via(_ h: Harness, _ route: UUID) async -> RouteState.Via? {
        await h.controller.status.routes.first { $0.id == route }?.via
    }

    @Test func theNextServerTakesOverAndHandsBack() async throws {
        let h = Harness()                         // Everything else: [A, B]
        try await h.controller.start()
        let a = Harness.h2.id, b = Harness.h2b.id
        let def = await h.controller.profile.defaultRoute.id
        #expect(await Self.via(h, def) == .server(a))

        await h.world.set { $0.deadTags = [SingBoxConfig.tag(a)] }
        await h.controller.healthTick()
        #expect(await Self.via(h, def) == .server(a), "one lost check does not move the route")
        await h.controller.healthTick()
        #expect(await Self.via(h, def) == .server(b))
        #expect(await h.world.selections[SingBoxConfig.routeTag(def)] == SingBoxConfig.tag(b))
        #expect(await h.controller.status.phase == .connected, "moving to the next server is not a reconnect")
        #expect(await h.controller.status.servers.first { $0.id == a }?.latencyMs == nil)

        await h.world.set { $0.deadTags = [] }
        await h.controller.healthTick()
        #expect(await Self.via(h, def) == .server(a), "the first server gets its traffic back when it answers again")
        #expect(await h.world.selections[SingBoxConfig.routeTag(def)] == SingBoxConfig.tag(a))
    }

    @Test(arguments: [true, false])
    func aRouteWithNoServerLeftIsBlockedOrDirect(killSwitch: Bool) async throws {
        let h = Harness()
        var p = await h.controller.profile
        let route = Route(name: "B only", conditions: Conditions(destinations: [.domainSuffix("b.example")]),
                          target: .servers([Harness.h2b.id]), killSwitch: killSwitch)
        p.routes.append(route)
        try await h.controller.update(profile: p)
        try await h.controller.start()
        await h.world.set { $0.deadTags = [SingBoxConfig.tag(Harness.h2b.id)] }
        await h.controller.healthTick()
        #expect(await Self.via(h, route.id) == .server(Harness.h2b.id), "one lost check blocks nothing")
        await h.controller.healthTick()
        #expect(await Self.via(h, route.id) == (killSwitch ? .blocked : .direct))
        #expect(await h.world.selections[SingBoxConfig.routeTag(route.id)]
                == (killSwitch ? SingBoxConfig.tag(Harness.h2b.id) : "direct"))
        #expect(await h.controller.status.phase == .connected)
    }

    /// A server that misses one check and answers the next keeps its
    /// routes all along: no block, no move, nothing in the log.
    @Test func aSingleLostCheckChangesNothing() async throws {
        let h = Harness()
        try await h.controller.start()
        let def = await h.controller.profile.defaultRoute.id
        let selects = await h.world.log.filter { $0 == "engine.select" }.count
        await h.world.set { $0.deadTags = [SingBoxConfig.tag(Harness.h2.id), SingBoxConfig.tag(Harness.h2b.id)] }
        await h.controller.healthTick()
        await h.world.set { $0.deadTags = [] }
        await h.controller.healthTick()
        #expect(await Self.via(h, def) == .server(Harness.h2.id))
        #expect(await h.world.log.filter { $0 == "engine.select" }.count == selects)
        #expect(await h.controller.status.phase == .connected)
    }

    @Test func startFailsCleanlyWhenEverythingElseHasNoServer() async throws {
        let h = Harness()
        var p = await h.controller.profile
        p.defaultRoute.target = .servers([Harness.h2.id])
        p.defaultRoute.killSwitch = false         // even without kill switch: "on" must mean "through the VPN"
        try await h.controller.update(profile: p)
        await h.world.set { $0.deadTags = [SingBoxConfig.tag(Harness.h2.id)] }
        await #expect(throws: Controller.CommandError.self) { try await h.controller.start() }
        #expect(await h.controller.status.phase == .off)
        #expect(!(await h.world.blocking))
        #expect(await h.world.running.isEmpty)
    }

    @Test func flushedAnchorIsRestored() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.world.set { $0.anchorRules = nil }      // someone ran pfctl -f elsewhere
        await h.controller.healthTick()
        #expect(await h.world.anchorRules?.contains("utun9") == true)
    }

    // MARK: profile changes

    @Test func profileUpdateRestartsEngineUnderBlock() async throws {
        let h = Harness()
        try await h.controller.start()
        var p = await h.controller.profile
        p.routes.append(Route(name: "x", conditions: Conditions(destinations: [.domainSuffix("example.org")]), target: .direct))
        try await h.controller.update(profile: p)
        #expect(await h.wait(for: .connected))
        let log = await h.world.log
        #expect(!log.contains("pf.release") && !log.contains("pf.flush"))
        #expect(log.filter { $0.hasPrefix("engine.launch") }.count == 2)
        await #expect(throws: Controller.CommandError.self) {
            var bad = p
            bad.routes.append(Route(name: "bad", conditions: Conditions(), target: .direct))
            try await h.controller.update(profile: bad)
        }
    }

    /// Either profile having a kill switch is enough: blocking goes on before
    /// the old sing-box stops, and lifts only once the new one is proven.
    @Test func switchToProfileWithoutKillSwitchBlocksDuringSwap() async throws {
        let h = Harness()
        try await h.controller.start()
        var p = await h.controller.profile
        p.defaultRoute.killSwitch = false
        for i in p.routes.indices { p.routes[i].killSwitch = false }
        p.killSwitch = .whileConnected
        await h.world.set { $0.log = [] }
        try await h.controller.update(profile: p)
        #expect(await h.wait(for: .connected) { !$0.killSwitchOn })
        let log = await h.world.log
        let block = log.firstIndex(of: "pf.load(blocked)")!
        let stop = log.firstIndex { $0.hasPrefix("engine.terminate") }!
        let launch = log.firstIndex { $0.hasPrefix("engine.launch") }!
        let release = log.firstIndex(of: "pf.release")!
        let health = log.lastIndex(of: "engine.health")!
        #expect(block < stop && stop < launch && health < release)
        #expect(!(await h.world.blocking))
    }

    @Test func switchFromProfileWithoutKillSwitchBlocksDuringSwap() async throws {
        let h = Harness(killSwitch: .off)
        try await h.controller.start()
        #expect(!(await h.world.blocking))
        var p = await h.controller.profile
        p.defaultRoute.killSwitch = true
        await h.world.set { $0.log = [] }
        try await h.controller.update(profile: p)
        #expect(await h.wait(for: .connected) { $0.killSwitchOn })
        let log = await h.world.log
        let block = log.firstIndex(of: "pf.load(blocked)")!
        let enable = log.firstIndex(of: "pf.enable")!
        let stop = log.firstIndex { $0.hasPrefix("engine.terminate") }!
        #expect(block < stop && enable < stop)
        #expect(await h.world.blocking)
    }

    // MARK: kill switch modes

    @Test func killSwitchOffNeverTouchesPF() async throws {
        let h = Harness(killSwitch: .off)
        try await h.controller.start()
        await h.world.crashAll()
        #expect(await h.wait(for: .connected) { _ in true })
        await h.controller.stop()
        #expect(!(await h.world.log.contains { $0.hasPrefix("pf.load") || $0 == "pf.enable" }))
    }

    @Test func alwaysModeBlocksAfterStop() async throws {
        let h = Harness(killSwitch: .always)
        try await h.controller.start()
        await h.controller.stop()
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.blocking)
        #expect(await h.world.anchorRules?.contains("utun") == false)
        // Panic is the way out.
        await h.controller.panic()
        #expect(!(await h.world.blocking))
    }

    // MARK: helper start-up

    @Test func afterRebootNetworkIsClean() async {
        // The user had the VPN on, then rebooted: whileConnected means a clean network.
        let h = Harness(saved: PersistedState(wantConnected: true, enginePID: 55, pfToken: "OLD",
                                              bootTime: Date(timeIntervalSince1970: 1)))
        await h.controller.reconcileOnLaunch()
        #expect(await h.controller.status.phase == .off)
        #expect(!(await h.world.blocking))
        #expect(!(await h.world.log.contains { $0.hasPrefix("engine.launch") || $0.hasPrefix("pf.load") }))
        #expect(h.store.load()?.wantConnected == false)
    }

    /// The user's rule: after a reboot the network is pristine — in every
    /// mode, with any saved state.
    @Test(arguments: KillSwitchMode.allCases, [false, true])
    func afterRebootTheNetworkIsPristine(mode: KillSwitchMode, wanted: Bool) async {
        let h = Harness(killSwitch: mode, saved: PersistedState(wantConnected: wanted, enginePID: 100, pfToken: "T1",
                                                               bootTime: Date(timeIntervalSince1970: 1)))
        await h.controller.reconcileOnLaunch()
        for _ in 0..<50 { await Task.yield() }
        #expect(await h.controller.status.phase == .off)
        #expect(!(await h.world.blocking))
        #expect(await h.world.anchorRules == nil)
        #expect(!(await h.world.log.contains { $0.hasPrefix("engine.launch") || $0.hasPrefix("pf.load") }))
        #expect(h.store.load()?.wantConnected == false)
    }

    /// "Always" still blocks across a helper restart within one boot.
    @Test func alwaysModeBlocksAfterHelperRestartWithinABoot() async {
        let boot = Date(timeIntervalSince1970: 500_000)
        let h = Harness(killSwitch: .always, saved: PersistedState(bootTime: boot), boot: boot)
        await h.controller.reconcileOnLaunch()
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.blocking)
    }

    @Test func afterHelperCrashBlocksThenReconnects() async {
        let boot = Date(timeIntervalSince1970: 500_000)
        let h = Harness(saved: PersistedState(wantConnected: true, enginePID: 100, pfToken: "T9", bootTime: boot), boot: boot)
        // The orphaned sing-box from the dead helper is still running.
        await h.world.set { w in w.running.insert(100); w.nextPID = 200; w.tokens.insert("T9") }
        await h.controller.reconcileOnLaunch()
        #expect(await h.wait(for: .connected))
        let log = await h.world.log
        #expect(log.first == "engine.terminate(100)")
        #expect(log.firstIndex(of: "pf.load(blocked)")! < log.firstIndex { $0.hasPrefix("engine.launch") }!)
        #expect(await h.world.tokens == ["T9"], "the surviving token should be reused, not leaked")
        await h.controller.stop()
        #expect(await h.world.tokens.isEmpty)
    }

    /// The boot time macOS reports moves when the clock is corrected: a few
    /// seconds of drift is still the same boot, and the VPN comes back.
    @Test func bootTimeDriftIsNotAReboot() async {
        let boot = Date(timeIntervalSince1970: 500_000)
        let h = Harness(saved: PersistedState(wantConnected: true, pfToken: "T9", bootTime: boot.addingTimeInterval(-3)), boot: boot)
        await h.world.set { $0.tokens.insert("T9") }
        await h.controller.reconcileOnLaunch()
        #expect(await h.wait(for: .connected))
    }

    /// With boot sessions on both sides, they alone decide.
    @Test func bootSessionDecides() async {
        let boot = Date(timeIntervalSince1970: 500_000)
        let other = Harness(saved: PersistedState(wantConnected: true, bootTime: boot, bootSession: "A"), boot: boot)
        other.clock.session = "B"
        await other.controller.reconcileOnLaunch()
        #expect(await other.controller.status.phase == .off)
        #expect(!(await other.world.blocking))

        let same = Harness(saved: PersistedState(wantConnected: true, bootTime: boot.addingTimeInterval(-600), bootSession: "A"),
                           boot: boot)
        same.clock.session = "A"
        await same.controller.reconcileOnLaunch()
        #expect(await same.wait(for: .connected))
    }

    /// An update stops the helper with the VPN on: the network stays blocked
    /// until the next helper resumes the VPN — never open in between.
    @Test func helperStopWithVPNOnKeepsBlocking() async throws {
        let h = Harness()
        try await h.controller.start()
        await h.controller.shutdownForExit()
        #expect(await h.world.blocking)
        #expect(await h.world.anchorRules?.contains("utun") == false)
        #expect(await h.world.running.isEmpty)
        let saved = h.store.load()
        #expect(saved?.wantConnected == true)
        #expect(saved?.pfToken != nil)
        #expect(!(await h.world.log.suffix(4).contains("pf.flush")))

        // The next helper picks up the same block and reconnects.
        let next = Harness(saved: saved, boot: h.clock.boot)
        await next.world.set { w in w.tokens = [saved!.pfToken!]; w.anchorRules = "blocked" }
        await next.controller.reconcileOnLaunch()
        #expect(await next.wait(for: .connected))
        #expect(await next.world.tokens == [saved!.pfToken!])
    }

    /// The helper loads its owner's profile before reconciling, and that
    /// saves the state: the previous helper's "the VPN was on" must still
    /// decide (found when an update did not bring the VPN back).
    @Test func profileLoadedBeforeReconcileStillResumes() async throws {
        let boot = Date(timeIntervalSince1970: 500_000)
        let h = Harness(saved: PersistedState(wantConnected: true, pfToken: "T9", bootTime: boot), boot: boot)
        await h.world.set { w in w.tokens = ["T9"]; w.anchorRules = "blocked" }
        try await h.controller.update(profile: await h.controller.profile)
        await h.controller.reconcileOnLaunch()
        #expect(await h.wait(for: .connected))
        #expect(await h.world.tokens == ["T9"])
    }

    /// With the VPN off, a helper stop (an update) leaves the network alone.
    @Test func helperStopWithVPNOffLeavesTheNetwork() async {
        let h = Harness()
        await h.controller.shutdownForExit()
        #expect(!(await h.world.blocking))
        #expect(!(await h.world.log.contains { $0.hasPrefix("pf.load") || $0 == "pf.enable" }))
        #expect(h.store.load()?.wantConnected == false)
    }

    /// No kill switch in the profile: nothing is blocked during an update.
    @Test func helperStopWithoutKillSwitchDoesNotBlock() async throws {
        let h = Harness(killSwitch: .off)
        try await h.controller.start()
        await h.controller.shutdownForExit()
        #expect(!(await h.world.blocking))
        #expect(h.store.load()?.wantConnected == true)
    }

    @Test func firstLaunchIsClean() async {
        let h = Harness(saved: nil)
        await h.controller.reconcileOnLaunch()
        #expect(await h.controller.status.phase == .off)
        #expect(!(await h.world.blocking))
    }

    /// Turned off while sing-box is still starting: "off" comes only once
    /// that sing-box is gone again (found by the random sequences on CI).
    @Test func offWaitsForAStartingEngine() async throws {
        let h = Harness()
        await h.world.set { $0.holdLaunch = true }
        let starting = Task { try? await h.controller.start() }
        #expect(await h.waitWorld { !$0.running.isEmpty })
        let stopping = Task { await h.controller.stop() }
        for _ in 0..<20 { await Task.yield() }
        // Still starting: not off yet, whatever stop has done so far.
        #expect(await h.controller.status.phase != .off)
        await h.world.set { $0.holdLaunch = false }
        await stopping.value
        await starting.value
        #expect(await h.controller.status.phase == .off)
        #expect(await h.world.running.isEmpty)
        #expect(!(await h.world.blocking))
    }

    // MARK: random sequences

    /// Random commands and failures. After every step: if the user wants the
    /// VPN and it is not connected, pf must be blocking (or never have been
    /// on, during a first start); after stop/panic, nothing of ours remains.
    @Test func randomSequencesKeepInvariants() async throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<30 {
            let h = Harness()
            // The same profile with and without kill switches, to switch between.
            let guardedProfile = await h.controller.profile
            var openProfile = guardedProfile
            openProfile.defaultRoute.killSwitch = false
            for i in openProfile.routes.indices { openProfile.routes[i].killSwitch = false }
            var everConnected = false
            for _ in 0..<25 {
                switch Int.random(in: 0..<11, using: &rng) {
                case 0, 1: try? await h.controller.start()
                case 2: await h.controller.stop()
                case 3: await h.world.crashAll()
                case 4: await h.world.set { $0.launchFails.toggle() }
                case 5: await h.world.set { $0.healthy.toggle() }
                case 6: await h.controller.healthTick()
                case 7: await h.world.set { $0.deadTags = Bool.random() ? [SingBoxConfig.tag(Harness.h2.id)] : [] }
                case 8: try? await h.controller.update(profile: Bool.random() ? guardedProfile : openProfile)
                case 9:
                    // A switch racing with the way out.
                    let p = Bool.random() ? guardedProfile : openProfile
                    async let switched: Void = { try? await h.controller.update(profile: p) }()
                    if Bool.random() { await h.controller.panic() } else { await h.controller.stop() }
                    await switched
                default: await h.controller.panic()
                }
                for _ in 0..<5 { await Task.yield() }
                let s = await h.controller.status
                if s.phase == .connected { everConnected = true }
                if s.phase == .off {
                    #expect(!(await h.world.blocking), "off but still blocking")
                    #expect(await h.world.running.isEmpty, "off but sing-box running")
                    everConnected = false
                }
                let guarded = await h.controller.profile.protectionMode != .off
                if s.phase == .reconnecting && everConnected && guarded {
                    #expect(await h.world.blocking, "reconnecting without the kill switch")
                }
            }
            await h.controller.stop()
            #expect(await h.world.tokens.isEmpty)
            #expect(await h.world.running.isEmpty)
        }
    }
}

final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SessionEvent] = []
    func add(_ e: SessionEvent) { lock.withLock { list.append(e) } }
    var all: [SessionEvent] { lock.withLock { list } }
}
