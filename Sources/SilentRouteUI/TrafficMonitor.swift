import AppKit
import Foundation
import Observation
import VPNCore
import VPNIPC

/// Live connections from sing-box's clash API: one snapshot of /connections
/// a second, only while someone looks at it. Rates come from the byte
/// counters' change between two snapshots. (The speed chart's history is
/// kept by the app for the whole session: `SpeedHistory`.)
@MainActor @Observable
final class TrafficMonitor {
    struct Connection: Identifiable, Equatable {
        var id: String
        var app: AppRef
        var host: String
        var port: String
        var network: String
        /// The route it belongs to and the server carrying it now (or
        /// Direct), and whether that is not the route's first server.
        var route: String
        var exit: String
        var viaFallback: Bool
        var start: Date
        var download: Int64
        var upload: Int64
        var downRate: Int64 = 0
        var upRate: Int64 = 0
    }

    struct AppRef: Hashable {
        var name: String
        /// The .app bundle, for the icon; nil for command-line tools.
        var bundlePath: String?
        var executable: String
    }

    struct AppTraffic: Identifiable, Equatable {
        var id: String { app.executable }
        var app: AppRef
        var connections: Int
        var downRate: Int64
        var upRate: Int64
        var download: Int64
        var upload: Int64
        var exits: [String]
    }

    private(set) var connections: [Connection] = []
    private(set) var downloadTotal: Int64 = 0
    private(set) var uploadTotal: Int64 = 0
    private(set) var problem: String?

    var apps: [AppTraffic] {
        Dictionary(grouping: connections, by: \.app).map { app, cs in
            AppTraffic(app: app, connections: cs.count,
                       downRate: cs.reduce(0) { $0 + $1.downRate }, upRate: cs.reduce(0) { $0 + $1.upRate },
                       download: cs.reduce(0) { $0 + $1.download }, upload: cs.reduce(0) { $0 + $1.upload },
                       exits: Array(Set(cs.map(\.exit))).sorted())
        }
        .sorted { ($0.downRate + $0.upRate, $0.download) > ($1.downRate + $1.upRate, $1.download) }
    }

    private var task: Task<Void, Never>?
    private var api: IPC.APICredentials?
    private var names: [String: String] = [:]
    /// route selector tag → (route name, tag of its first server)
    private var routes: [String: (name: String, first: String?)] = [:]
    private var defaultRouteName = "Everything else"
    private var last: (time: Date, down: Int64, up: Int64, perConn: [String: (Int64, Int64)])?

    init() {}

    /// For the snapshot tool.
    init(preview connections: [Connection]) {
        self.connections = connections
    }

    /// Exit names for the tags sing-box reports, from the running profile.
    func setProfile(_ p: Profile?) {
        names = ["direct": "Direct"]
        routes = [:]
        guard let p else { return }
        for t in p.tunnels { names[SingBoxConfig.tag(t.id)] = t.name }
        for r in p.allRoutes {
            routes[SingBoxConfig.routeTag(r.id)] = (r.name, p.chain(of: r).first.map(SingBoxConfig.tag))
        }
        defaultRouteName = p.defaultRoute.name
    }

    func start(credentials: @escaping @Sendable () async -> IPC.APICredentials?) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.api == nil { self.api = await credentials() }
                if let api = self.api {
                    do {
                        try await self.poll(api)
                        self.problem = nil
                    } catch {
                        self.problem = "No traffic data: \(error.localizedDescription)"
                        self.api = nil      // credentials change on every connect
                    }
                } else {
                    self.problem = nil
                    self.connections = []
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        last = nil
    }

    func close(_ id: String) {
        guard let api else { return }
        Task {
            _ = try? await Self.request(api, "DELETE", "/connections/\(id)")
            connections.removeAll { $0.id == id }
        }
    }

    // MARK: Polling

    private func poll(_ api: IPC.APICredentials) async throws {
        let data = try await Self.request(api, "GET", "/connections")
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let now = Date()
        let down = (obj["downloadTotal"] as? NSNumber)?.int64Value ?? 0
        let up = (obj["uploadTotal"] as? NSNumber)?.int64Value ?? 0
        let raw = obj["connections"] as? [[String: Any]] ?? []

        var perConn: [String: (Int64, Int64)] = [:]
        var list: [Connection] = []
        list.reserveCapacity(raw.count)
        let dt = last.map { max(0.2, now.timeIntervalSince($0.time)) } ?? 1
        for c in raw {
            guard let id = c["id"] as? String else { continue }
            let meta = c["metadata"] as? [String: Any] ?? [:]
            let d = (c["download"] as? NSNumber)?.int64Value ?? 0
            let u = (c["upload"] as? NSNumber)?.int64Value ?? 0
            perConn[id] = (d, u)
            // chains: [what carried it, …, what the rule chose]
            let chains = c["chains"] as? [String] ?? []
            let actual = chains.first ?? "direct"
            let chosen = chains.last ?? actual
            let route = routes[chosen]
            let host = (meta["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (meta["destinationIP"] as? String ?? "?")
            var conn = Connection(
                id: id, app: Self.app(meta["processPath"] as? String ?? ""), host: host,
                port: meta["destinationPort"] as? String ?? "", network: (meta["network"] as? String ?? "").uppercased(),
                route: route?.name ?? Self.routeName(c["rule"] as? String ?? "", chosen: chosen, fallback: defaultRouteName),
                exit: names[actual] ?? actual,
                viaFallback: route.map { $0.first != nil && $0.first != actual } ?? false,
                start: Self.date(c["start"] as? String) ?? now, download: d, upload: u)
            if let prev = last?.perConn[id] {
                conn.downRate = Int64(Double(max(0, d - prev.0)) / dt)
                conn.upRate = Int64(Double(max(0, u - prev.1)) / dt)
            }
            list.append(conn)
        }
        last = (now, down, up, perConn)
        downloadTotal = down
        uploadTotal = up
        connections = list
    }

    nonisolated static func request(_ api: IPC.APICredentials, _ method: String, _ path: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(api.port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 3
        req.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: Decoding sing-box's fields

    /// "/Applications/Telegram.app/Contents/MacOS/Telegram (user)" →
    /// Telegram, with its bundle for the icon.
    nonisolated static func app(_ processPath: String) -> AppRef {
        var path = processPath
        if let r = path.range(of: #" \([^()]*\)$"#, options: .regularExpression) { path.removeSubrange(r) }
        guard !path.isEmpty else { return AppRef(name: "System", bundlePath: nil, executable: "") }
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            // The outermost app: helpers live in nested bundles
            // (…/Google Chrome.app/…/Google Chrome Helper.app/…).
            return AppRef(name: URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent,
                          bundlePath: bundle, executable: path)
        }
        return AppRef(name: URL(fileURLWithPath: path).lastPathComponent, bundlePath: nil, executable: path)
    }

    /// For connections that did not go through a route selector: the LAN
    /// shortcut, a direct or blocking route.
    nonisolated static func routeName(_ rule: String, chosen: String, fallback: String) -> String {
        if rule.contains("ip_is_private") { return "Local network" }
        if rule == "final" || rule.isEmpty { return fallback }
        return chosen == "direct" ? "Direct route" : rule
    }

    nonisolated static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // sing-box prints a variable number of fraction digits.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: trimmed)
    }
}
