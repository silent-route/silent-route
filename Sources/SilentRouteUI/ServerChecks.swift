import Foundation
import Observation
import SwiftUI
import VPNCore
import VPNIPC
import VPNRuntime

/// Server checks, for every list of servers in the app. Each check is a
/// sing-box of its own, so a few run at once and the rest wait their turn:
/// any number can be asked for, one by one or all together. A result says
/// when it was found, and stays for an hour unless the server changes,
/// wherever the user goes in the meantime: older, it says little about now.
@MainActor @Observable
public final class ServerChecks {
    public typealias Check = @Sendable (Tunnel) async throws -> Probe.Report

    public enum State: Equatable, Sendable {
        case waiting
        case running
        case ok(String)
        case failed(String)

        public var isPending: Bool { self == .waiting || self == .running }
    }

    private struct Entry {
        /// The server as it was checked.
        var tunnel: Tunnel
        var state: State
        /// When the check ended; nil while it waits or runs.
        var finished: Date?
    }

    /// How long a result is shown.
    public static let keptFor: TimeInterval = 3600

    private var entries: [Tunnel.ID: Entry] = [:]
    @ObservationIgnored private var line: [(tunnel: Tunnel, check: Check)] = []
    @ObservationIgnored private var running = 0
    public let atOnce: Int

    public init(atOnce: Int = IPC.serverChecksAtOnce) {
        self.atOnce = max(1, atOnce)
    }

    /// The last check of this server; nil when there is none, it is older
    /// than `keptFor`, or the server has changed since (another address,
    /// password, protocol…).
    public func state(of t: Tunnel, now: Date = Date()) -> State? {
        guard let e = entries[t.id], Self.sameServer(e.tunnel, t) else { return nil }
        if let f = e.finished, now.timeIntervalSince(f) > Self.keptFor { return nil }
        return e.state
    }

    /// When the shown result was found.
    public func finished(_ t: Tunnel) -> Date? {
        guard let e = entries[t.id], Self.sameServer(e.tunnel, t) else { return nil }
        return e.finished
    }

    /// "just now", "5 minutes ago".
    public static func age(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    public func isPending(_ t: Tunnel) -> Bool { entries[t.id]?.state.isPending ?? false }

    /// In line behind the others; nothing if it is already waiting or running.
    public func check(_ t: Tunnel, using check: @escaping Check) {
        guard !isPending(t) else { return }
        entries[t.id] = Entry(tunnel: t, state: .waiting)
        line.append((t, check))
        startNext()
    }

    public func checkAll(_ servers: [Tunnel], using check: @escaping Check) {
        for t in servers { self.check(t, using: check) }
    }

    private func startNext() {
        while running < atOnce, !line.isEmpty {
            let (t, check) = line.removeFirst()
            running += 1
            entries[t.id]?.state = .running
            Task {
                let result = await Self.run(check, t)
                running -= 1
                entries[t.id] = Entry(tunnel: t, state: result, finished: Date())
                startNext()
            }
        }
    }

    private nonisolated static func run(_ check: Check, _ t: Tunnel) async -> State {
        do {
            let r = try await check(t)
            var text = "Exit: \([r.city, r.country].compactMap { $0 }.joined(separator: ", ")) · \(r.ip) · \(r.latencyMs) ms"
            if !r.warnings.isEmpty { text += " · " + r.warnings.joined(separator: "; ") }
            return .ok(text)
        } catch {
            return .failed(Text.sentence("\(error)"))
        }
    }

    /// The same server, whatever it is called: a new name keeps the result.
    static func sameServer(_ a: Tunnel, _ b: Tunnel) -> Bool {
        var a = a
        a.name = b.name
        return a == b
    }
}
