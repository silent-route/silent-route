import Foundation
import Testing
@testable import SilentRouteUI
import VPNCore
import VPNRuntime

@MainActor
@Suite struct ServerChecksTests {
    private func server(_ name: String) -> Tunnel {
        Tunnel(name: name, server: Endpoint(host: "\(name.lowercased()).example.org", port: 443),
               proto: .proxy(Proxy(kind: .socks5)))
    }

    /// Checks that end when told to, counting how many run at once.
    final class Gatekeeper: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
        private(set) var started: [String] = []
        private var now = 0
        private(set) var most = 0

        func check(_ t: Tunnel) async throws -> Probe.Report {
            await withCheckedContinuation { c in
                lock.withLock {
                    started.append(t.name)
                    now += 1
                    most = max(most, now)
                    waiting[t.name] = c
                }
            }
            lock.withLock { now -= 1 }
            if t.name.hasPrefix("Bad") { throw CheckFailed() }
            return try JSONDecoder().decode(Probe.Report.self, from: Data(#"{"ip":"198.51.100.1","country":"NL","latencyMs":42,"warnings":[]}"#.utf8))
        }

        func finish(_ name: String) { lock.withLock { waiting.removeValue(forKey: name) }?.resume() }
        var startedNames: [String] { lock.withLock { started } }
        var mostAtOnce: Int { lock.withLock { most } }

        struct CheckFailed: Error, CustomStringConvertible { var description: String { "no answer" } }
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    @Test func runsAFewAtOnceAndTheRestInOrder() async {
        let checks = ServerChecks(atOnce: 2)
        let gate = Gatekeeper()
        let servers = ["A", "B", "C", "Bad D"].map(server)
        checks.checkAll(servers, using: gate.check)
        await settle()
        #expect(gate.startedNames == ["A", "B"])
        #expect(checks.state(of: servers[0]) == .running)
        #expect(checks.state(of: servers[2]) == .waiting)
        #expect(checks.isPending(servers[3]))

        gate.finish("B")
        await settle()
        #expect(gate.startedNames == ["A", "B", "C"])
        #expect(checks.state(of: servers[1]) == .ok("Exit: NL · 198.51.100.1 · 42 ms"))

        for name in ["A", "C", "Bad D"] {
            while !gate.startedNames.contains(name) { await settle() }
            gate.finish(name)
        }
        while servers.contains(where: checks.isPending) { await settle() }
        #expect(gate.mostAtOnce == 2)
        #expect(checks.state(of: servers[3]) == .failed("No answer"))
    }

    @Test func askingAgainWhileItRunsChangesNothing() async {
        let checks = ServerChecks(atOnce: 1)
        let gate = Gatekeeper()
        let a = server("A")
        checks.check(a, using: gate.check)
        checks.check(a, using: gate.check)
        await settle()
        gate.finish("A")
        while checks.isPending(a) { await settle() }
        #expect(gate.startedNames == ["A"])
    }

    @Test func aResultHoldsOnlyForTheServerAsCheckedAndForAnHour() async throws {
        let checks = ServerChecks(atOnce: 1)
        let gate = Gatekeeper()
        var a = server("A")
        checks.check(a, using: gate.check)
        await settle()
        gate.finish("A")
        while checks.isPending(a) { await settle() }

        a.name = "Renamed"
        #expect(checks.state(of: a) != nil)
        // Says when, and goes after an hour.
        let found = try #require(checks.finished(a))
        #expect(ServerChecks.age(found, now: found.addingTimeInterval(20)) == "just now")
        #expect(checks.state(of: a, now: found.addingTimeInterval(ServerChecks.keptFor - 1)) != nil)
        #expect(checks.state(of: a, now: found.addingTimeInterval(ServerChecks.keptFor + 1)) == nil)
        a.server.port = 8443
        #expect(checks.state(of: a) == nil)
    }
}
