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

    struct AppRef: Hashable, Codable, Identifiable {
        var name: String
        /// The .app bundle, for the icon; nil for command-line tools.
        var bundlePath: String?
        var executable: String

        /// One app, whichever of its processes: the bundle (a browser's
        /// helpers are part of it), or the program itself; "" for traffic
        /// sing-box could not attribute.
        var id: String { bundlePath ?? executable }
        /// Where it is on disk, for a tooltip.
        var path: String { bundlePath ?? executable }
        var isSafari: Bool { bundlePath.map { AppMatcher.bundle(path: $0).isSafari } ?? false }
    }

    struct AppTraffic: Identifiable, Equatable {
        var id: String { app.id }
        var app: AppRef
        var connections: Int
        var downRate: Int64
        var upRate: Int64
        var download: Int64
        var upload: Int64
        var exits: [String]
    }

    private(set) var connections: [Connection] = []
    /// The connections by app, worked out once per snapshot.
    private(set) var apps: [AppTraffic] = []
    private(set) var downloadTotal: Int64 = 0
    private(set) var uploadTotal: Int64 = 0
    private(set) var problem: String?

    private var task: Task<Void, Never>?
    private var api: IPC.APICredentials?
    private var labels = Labels()
    private var last: Snapshot?

    init() {}

    /// For the snapshot tool.
    init(preview connections: [Connection]) {
        self.connections = connections
        apps = Self.byApp(connections)
    }

    /// How sing-box's tags read, from the running profile.
    struct Labels: Sendable {
        var names: [String: String] = ["direct": "Direct"]
        /// route selector tag → (route name, tag of its first server)
        var routes: [String: (name: String, first: String?)] = [:]
        var defaultRouteName = "Everything else"
    }

    /// Exit names for the tags sing-box reports, from the running profile.
    func setProfile(_ p: Profile?) {
        labels = Labels()
        guard let p else { return }
        for t in p.tunnels { labels.names[SingBoxConfig.tag(t.id)] = t.name }
        for r in p.allRoutes {
            labels.routes[SingBoxConfig.routeTag(r.id)] = (r.name, p.chain(of: r).first.map(SingBoxConfig.tag))
        }
        labels.defaultRouteName = p.defaultRoute.name
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

    /// One answer of /connections, decoded.
    struct Snapshot: Sendable {
        var time: Date
        var connections: [Connection]
        var apps: [AppTraffic]
        var download: Int64
        var upload: Int64
    }

    private func poll(_ api: IPC.APICredentials) async throws {
        let data = try await Self.request(api, "GET", "/connections")
        // Off the main thread: a torrent client alone can hold thousands of
        // connections, and the window must stay responsive whatever comes.
        let labels = labels, previous = last
        let snap = try await Task.detached(priority: .userInitiated) {
            try Self.snapshot(data, at: Date(), labels: labels, last: previous)
        }.value
        guard task != nil else { return }
        last = snap
        downloadTotal = snap.download
        uploadTotal = snap.upload
        connections = snap.connections
        apps = snap.apps
    }

    /// Decodes /connections. What never changes for a connection (its app,
    /// when it started) is taken from the previous snapshot rather than
    /// worked out again every second.
    nonisolated static func snapshot(_ data: Data, at now: Date, labels: Labels, last: Snapshot?) throws -> Snapshot {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let raw = obj["connections"] as? [[String: Any]] ?? []
        var previous: [String: Connection] = [:]
        if let last {
            previous.reserveCapacity(last.connections.count)
            for c in last.connections { previous[c.id] = c }
        }
        let dt = last.map { max(0.2, now.timeIntervalSince($0.time)) } ?? 1
        var appsByPath: [String: AppRef] = [:]
        let dates = DateParser()
        var list: [Connection] = []
        list.reserveCapacity(raw.count)
        for c in raw {
            guard let id = c["id"] as? String else { continue }
            let d = (c["download"] as? NSNumber)?.int64Value ?? 0
            let u = (c["upload"] as? NSNumber)?.int64Value ?? 0
            // chains: [what carried it, …, what the rule chose]
            let chains = c["chains"] as? [String] ?? []
            let actual = chains.first ?? "direct"
            let chosen = chains.last ?? actual
            let route = labels.routes[chosen]
            var conn: Connection
            if var p = previous[id] {
                p.route = route?.name ?? p.route
                p.exit = labels.names[actual] ?? actual
                p.viaFallback = route.map { $0.first != nil && $0.first != actual } ?? false
                p.downRate = Int64(Double(max(0, d - p.download)) / dt)
                p.upRate = Int64(Double(max(0, u - p.upload)) / dt)
                conn = p
            } else {
                let meta = c["metadata"] as? [String: Any] ?? [:]
                let path = meta["processPath"] as? String ?? ""
                let app = appsByPath[path] ?? Self.app(path)
                appsByPath[path] = app
                let host = (meta["host"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (meta["destinationIP"] as? String ?? "?")
                conn = Connection(
                    id: id, app: app, host: host,
                    port: meta["destinationPort"] as? String ?? "", network: (meta["network"] as? String ?? "").uppercased(),
                    route: route?.name ?? Self.routeName(c["rule"] as? String ?? "", chosen: chosen, fallback: labels.defaultRouteName),
                    exit: labels.names[actual] ?? actual,
                    viaFallback: route.map { $0.first != nil && $0.first != actual } ?? false,
                    start: dates.date(c["start"] as? String) ?? now, download: d, upload: u)
            }
            conn.download = d
            conn.upload = u
            list.append(conn)
        }
        return Snapshot(time: now, connections: list, apps: byApp(list),
                        download: (obj["downloadTotal"] as? NSNumber)?.int64Value ?? 0,
                        upload: (obj["uploadTotal"] as? NSNumber)?.int64Value ?? 0)
    }

    nonisolated static func byApp(_ connections: [Connection]) -> [AppTraffic] {
        Dictionary(grouping: connections, by: \.app.id).map { _, cs in
            AppTraffic(app: cs[0].app, connections: cs.count,
                       downRate: cs.reduce(0) { $0 + $1.downRate }, upRate: cs.reduce(0) { $0 + $1.upRate },
                       download: cs.reduce(0) { $0 + $1.download }, upload: cs.reduce(0) { $0 + $1.upload },
                       exits: Array(Set(cs.map(\.exit))).sorted())
        }
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
        // Apple's shared web content process (Safari, Mail, the App Store…):
        // named for what it is, not after any one app.
        if (path as NSString).lastPathComponent == AppMatcher.webKitNetworkingName {
            return AppRef(name: "Apple web content (WebKit)", bundlePath: nil, executable: path)
        }
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

    /// sing-box's start times. Formatters are costly to make: one per
    /// snapshot, not one per connection.
    struct DateParser {
        private let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        private let whole = ISO8601DateFormatter()

        func date(_ s: String?) -> Date? {
            guard let s else { return nil }
            if let d = fractional.date(from: s) { return d }
            // sing-box prints a variable number of fraction digits.
            return whole.date(from: s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
        }
    }
}
