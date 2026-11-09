import Foundation

/// Things kept in order: Monitor's pinned rows. The order is the user's —
/// pinning adds at the end, Move Up and Move Down change it.
struct PinList<Item: Codable & Hashable & Identifiable>: Codable, Hashable where Item.ID == String {
    private(set) var items: [Item] = []

    init(_ items: [Item] = []) { self.items = items }

    func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
    func contains(_ id: String) -> Bool { index(of: id) != nil }

    mutating func pin(_ item: Item) {
        if !contains(item.id) { items.append(item) }
    }

    mutating func unpin(_ id: String) { items.removeAll { $0.id == id } }

    /// Up (−1) or down (+1) among the pinned; nothing past either end.
    mutating func move(_ id: String, by offset: Int) {
        guard let i = index(of: id), items.indices.contains(i + offset) else { return }
        items.swapAt(i, i + offset)
    }
}

/// What Monitor keeps at the top of its lists: apps, and an app's traffic
/// to one site (a single connection lives seconds; what it connects to is
/// what is worth watching). Kept across launches; app settings, not part of
/// any profile.
struct MonitorPins: Codable, Hashable {
    struct Destination: Codable, Hashable, Identifiable {
        var app: TrafficMonitor.AppRef
        var host: String
        var id: String { Self.id(app: app, host: host) }
        static func id(app: TrafficMonitor.AppRef, host: String) -> String { app.id + "\u{1F}" + host }
    }

    var apps = PinList<TrafficMonitor.AppRef>()
    var destinations = PinList<Destination>()

    static let defaultsKey = "monitorPins"

    static func load(_ defaults: UserDefaults = .standard) -> MonitorPins {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(MonitorPins.self, from: $0) } ?? MonitorPins()
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Self.defaultsKey) }
    }
}

/// A row of Monitor's app list: an app with traffic now, or a pinned app
/// without any (drawn dimmed). Fields are flat so that every column sorts.
struct AppRow: Identifiable, Equatable {
    var id: String { app.id }
    var app: TrafficMonitor.AppRef
    /// Its place among the pinned rows.
    var pin: Int?
    var isLive: Bool
    var name: String
    var via: String
    var connections: Int
    var downRate: Int64
    var upRate: Int64
    var download: Int64
    var upload: Int64

    init(_ t: TrafficMonitor.AppTraffic, pin: Int?) {
        app = t.app
        self.pin = pin
        isLive = true
        name = t.app.name
        via = t.exits.joined(separator: ", ")
        connections = t.connections
        downRate = t.downRate
        upRate = t.upRate
        download = t.download
        upload = t.upload
    }

    init(absent app: TrafficMonitor.AppRef, pin: Int) {
        self.app = app
        self.pin = pin
        isLive = false
        name = app.name
        via = ""
        connections = 0
        downRate = 0; upRate = 0; download = 0; upload = 0
    }

    static func rows(_ live: [TrafficMonitor.AppTraffic], pins: PinList<TrafficMonitor.AppRef>) -> [AppRow] {
        var rows = live.map { AppRow($0, pin: pins.index(of: $0.id)) }
        let present = Set(live.map(\.id))
        for (i, p) in pins.items.enumerated() where !present.contains(p.id) {
            rows.append(AppRow(absent: p, pin: i))
        }
        return rows
    }
}

/// A row of Monitor's connection list: a live connection, or a pinned
/// destination with none open now (drawn dimmed).
struct ConnectionRow: Identifiable, Equatable {
    /// sing-box's connection id; for an absent pinned destination, its pin.
    var id: String
    var app: TrafficMonitor.AppRef
    var host: String
    var pinID: String { MonitorPins.Destination.id(app: app, host: host) }
    var pin: Int?
    var live: TrafficMonitor.Connection?
    var isLive: Bool { live != nil }
    var appName: String
    var destination: String
    var route: String
    var exit: String
    var downRate: Int64
    var upRate: Int64
    /// Absent rows sort as the newest: they have no age.
    var start: Date

    init(_ c: TrafficMonitor.Connection, pin: Int?) {
        id = c.id
        app = c.app
        host = c.host
        self.pin = pin
        live = c
        appName = c.app.name
        destination = c.port.isEmpty ? c.host : "\(c.host):\(c.port)"
        route = c.route
        exit = c.exit
        downRate = c.downRate
        upRate = c.upRate
        start = c.start
    }

    init(absent d: MonitorPins.Destination, pin: Int) {
        id = "pin:" + d.id
        app = d.app
        host = d.host
        self.pin = pin
        appName = d.app.name
        destination = d.host
        route = ""
        exit = ""
        downRate = 0; upRate = 0
        start = .distantFuture
    }

    static func rows(_ live: [TrafficMonitor.Connection], pins: PinList<MonitorPins.Destination>) -> [ConnectionRow] {
        var present = Set<String>()
        var rows = live.map { c in
            let id = MonitorPins.Destination.id(app: c.app, host: c.host)
            let pin = pins.index(of: id)
            if pin != nil { present.insert(id) }
            return ConnectionRow(c, pin: pin)
        }
        for (i, p) in pins.items.enumerated() where !present.contains(p.id) {
            rows.append(ConnectionRow(absent: p, pin: i))
        }
        return rows
    }
}

enum MonitorOrder {
    /// The pinned rows first, in the user's order (several connections
    /// under one pin by the chosen column); then the rest by the chosen
    /// column. `tieBreak` keeps equal rows — idle ones, most of the time —
    /// from swapping places every second.
    static func arranged<Row>(_ rows: [Row], pin: (Row) -> Int?, by order: [KeyPathComparator<Row>],
                              tieBreak: [KeyPathComparator<Row>]) -> [Row] {
        let comparators = order + tieBreak
        return rows.sorted { a, b in
            switch (pin(a), pin(b)) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                for c in comparators {
                    switch c.compare(a, b) {
                    case .orderedAscending: return true
                    case .orderedDescending: return false
                    case .orderedSame: continue
                    }
                }
                return false
            }
        }
    }
}
