import Foundation

/// The helper's state as the app and CLI see it.
public enum VPNPhase: String, Codable, Sendable {
    case off, connecting, connected, reconnecting, stopping
}

public struct VPNStatus: Codable, Equatable, Sendable {
    public var phase: VPNPhase
    /// When the current connection came up; a reconnect starts it anew.
    public var connectedSince: Date?
    /// When the VPN was turned on; reconnects and profile switches keep it.
    public var sessionSince: Date?
    /// pf is blocking everything that bypasses sing-box.
    public var killSwitchOn: Bool
    public var lastError: String?
    public var reconnectAttempts: Int
    /// While connected: whether each server answers…
    public var servers: [ServerState]
    /// …and where each route's traffic goes right now.
    public var routes: [RouteState]
    /// Reconnecting on a Wi-Fi that wants a login (a hotel, a café): the
    /// owner's app offers its login page; everything else stays blocked.
    public var captivePortal: Bool

    public init(phase: VPNPhase, connectedSince: Date? = nil, sessionSince: Date? = nil, killSwitchOn: Bool = false,
                lastError: String? = nil, reconnectAttempts: Int = 0,
                servers: [ServerState] = [], routes: [RouteState] = [], captivePortal: Bool = false) {
        self.captivePortal = captivePortal
        self.servers = servers
        self.routes = routes
        self.phase = phase
        self.connectedSince = connectedSince
        self.sessionSince = sessionSince
        self.killSwitchOn = killSwitchOn
        self.lastError = lastError
        self.reconnectAttempts = reconnectAttempts
    }
}

public struct ServerState: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Round trip of the last check through this server; nil = not answering.
    public var latencyMs: Int?

    public init(id: UUID, latencyMs: Int?) {
        self.id = id
        self.latencyMs = latencyMs
    }
}

public struct RouteState: Codable, Equatable, Sendable, Identifiable {
    public enum Via: Codable, Equatable, Sendable {
        /// Through this server of the route's list.
        case server(UUID)
        /// No server in the list answers; kill switch off.
        case direct
        /// No server in the list answers; kill switch on.
        case blocked
    }

    public var id: UUID
    public var via: Via

    public init(id: UUID, via: Via) {
        self.id = id
        self.via = via
    }
}

/// One VPN session's log, as the app lists it.
public struct LogSession: Codable, Equatable, Sendable, Identifiable {
    /// The file name; also how the app asks for its text.
    public var id: String
    public var started: Date
    /// Nil while the session is still going.
    public var ended: Date?
    public var profile: String
    public var bytes: Int

    public init(id: String, started: Date, ended: Date?, profile: String, bytes: Int) {
        self.id = id
        self.started = started
        self.ended = ended
        self.profile = profile
        self.bytes = bytes
    }
}
