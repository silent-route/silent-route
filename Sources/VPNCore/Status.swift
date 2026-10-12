import Foundation

/// The helper's state as the app and CLI see it.
public enum VPNPhase: String, Codable, Sendable {
    case off, connecting, connected, reconnecting, stopping
}

public struct VPNStatus: Codable, Equatable, Sendable {
    public var phase: VPNPhase
    public var connectedSince: Date?
    /// pf is blocking everything that bypasses sing-box.
    public var killSwitchOn: Bool
    public var lastError: String?
    public var reconnectAttempts: Int
    /// While connected: whether each server answers…
    public var servers: [ServerState]
    /// …and where each route's traffic goes right now.
    public var routes: [RouteState]

    public init(phase: VPNPhase, connectedSince: Date? = nil, killSwitchOn: Bool = false,
                lastError: String? = nil, reconnectAttempts: Int = 0,
                servers: [ServerState] = [], routes: [RouteState] = []) {
        self.servers = servers
        self.routes = routes
        self.phase = phase
        self.connectedSince = connectedSince
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
