import Foundation
import VPNCore

// Everything the controller does to the system goes through these protocols.
// Production implementations run pfctl, spawn sing-box and read interfaces;
// tests substitute scripted fakes and drive every failure path.

/// pf, restricted to Silent Route's own anchor.
public protocol PacketFilter: Sendable {
    /// Parse only (`pfctl -n`); nothing is loaded.
    func validate(_ rules: String) async throws
    /// Replace the anchor's rules atomically.
    func load(_ rules: String) async throws
    /// Empty the anchor. Never touches other anchors or the main ruleset.
    func flush() async
    /// Take a reference on pf being enabled (`pfctl -E`); returns its token.
    func enable() async throws -> String
    /// Drop our reference (`pfctl -X`). pf stays on if others hold one.
    func release(token: String) async
    /// True if the anchor currently has rules.
    func isLoaded() async -> Bool
}

/// The sing-box process.
public protocol Engine: Sendable {
    /// `sing-box check` on a config.
    func check(config: Data) async throws
    /// Start sing-box with this config. `onExit` is called once, from any
    /// thread, when that process ends.
    func launch(config: Data, onExit: @escaping @Sendable (_ pid: Int32) -> Void) async throws -> Int32
    /// SIGTERM, then SIGKILL after a grace period; returns when it is gone.
    func terminate(pid: Int32) async
    func isRunning(pid: Int32) async -> Bool
    /// Point a selector at one of its members (clash API).
    func select(_ selector: String, member: String) async throws
    /// Round trip of a test request through one outbound, in milliseconds;
    /// nil if it does not answer (or the API itself is unreachable).
    func delay(_ tag: String) async -> Int?
}

public protocol NetworkInspector: Sendable {
    /// The TUN interface sing-box created, if it exists.
    func tunInterface() async -> String?
    /// A description of another VPN that already owns the default route.
    func foreignTunnel() async -> String?
    /// Panic cleanup: put the default route back on a physical gateway if it
    /// still points at a dead tunnel, and flush the DNS cache.
    func restoreRouting() async
    /// While connected: macOS's resolver points at `server` (inside the
    /// tunnel). Harmless to repeat; re-applied after network changes.
    func overrideDNS(server: String) async
    /// Puts macOS's own DNS settings back (also after a crash).
    func restoreDNS() async
    /// Whether the network wants a login before anything gets through,
    /// asked through the login-page proxy (which goes direct).
    func captivePortal(via proxy: SingBoxConfig.LocalProxy) async -> Bool
}

public protocol StateStore: Sendable {
    func load() -> PersistedState?
    func save(_ state: PersistedState)
}

public protocol Clock: Sendable {
    func sleep(seconds: Double) async throws
    func now() -> Date
    /// Kernel boot time; changes only across a reboot.
    func bootTime() -> Date
}

/// What survives a helper restart. Written on every transition.
public struct PersistedState: Codable, Equatable, Sendable {
    /// The user wants the VPN on.
    public var wantConnected: Bool
    public var enginePID: Int32?
    public var pfToken: String?
    public var bootTime: Date

    public init(wantConnected: Bool = false, enginePID: Int32? = nil, pfToken: String? = nil, bootTime: Date) {
        self.wantConnected = wantConnected
        self.enginePID = enginePID
        self.pfToken = pfToken
        self.bootTime = bootTime
    }
}
