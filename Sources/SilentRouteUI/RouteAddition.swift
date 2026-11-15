import Foundation
import VPNCore

/// Adding what Monitor shows — an app, or the site a connection goes to —
/// to a profile's route. The rules of it, apart from the sheet.
enum RouteAddition {
    /// One condition to add.
    enum Item: Hashable {
        case app(AppMatcher)
        case destination(Destination)
    }

    /// Where it goes.
    enum Target: Hashable {
        case existing(Route.ID)
        /// A new route of its own, placed first so that it decides before
        /// the routes already there.
        case new(name: String, target: Route.Target)
    }

    /// The whole app, helpers included, when it is an app bundle; the
    /// program otherwise — by name for a part of macOS, whose folder moves
    /// between versions (/System/Library or a cryptex). Traffic sing-box
    /// could not attribute has none.
    static func matcher(for app: TrafficMonitor.AppRef) -> AppMatcher? {
        if let b = app.bundlePath { return .bundle(path: b) }
        guard !app.executable.isEmpty else { return nil }
        if app.executable.hasPrefix("/System/") { return .processName((app.executable as NSString).lastPathComponent) }
        return .executable(path: app.executable)
    }


    /// What a host can become, narrowest first: an address as itself; a
    /// name with its subdomains at each level down to the site
    /// (rr1.googlevideo.com, googlevideo.com), then the exact name alone.
    static func destinations(forHost host: String) -> [Destination] {
        let parsed = RuleText.destinations(host)
        guard parsed.errors.isEmpty, let first = parsed.values.first, parsed.values.count == 1 else { return [] }
        guard case .domainSuffix(let name) = first else { return [first] }
        let labels = name.split(separator: ".").map(String.init)
        var out: [Destination] = []
        // Not the zone alone ("com"), nor a country's second level
        // ("co.uk"): those are whole swaths of the internet.
        for start in 0..<max(1, labels.count - 1) {
            let suffix = labels[start...]
            if suffix.count == 2, isSecondLevelZone(suffix.first!, tld: suffix.last!), labels.count > 2 { continue }
            out.append(.domainSuffix(suffix.joined(separator: ".")))
        }
        if labels.count > 1 { out.append(.domain(name)) }
        return out
    }

    /// co.uk, com.au, ne.jp and the like: a country's own zones for
    /// companies, networks, organisations.
    static func isSecondLevelZone(_ label: String, tld: String) -> Bool {
        tld.count == 2 && ["co", "com", "net", "org", "gov", "edu", "ac", "or", "ne", "go", "gob", "mil"].contains(label)
    }

    /// The suggested choice among `destinations(forHost:)`: the site itself,
    /// with every subdomain — what a site's traffic usually spreads over.
    static func suggested(_ choices: [Destination]) -> Destination? {
        choices.last { if case .domainSuffix = $0 { true } else { false } } ?? choices.first
    }

    /// Whether Monitor offers the app itself for a route: not Apple's web
    /// content, which is a route setting of its own, set in the route.
    static func canAdd(_ app: TrafficMonitor.AppRef) -> Bool {
        guard let m = matcher(for: app) else { return false }
        return m != .webKitNetworking
    }

    static func contains(_ route: Route, _ item: Item) -> Bool {
        switch item {
        case .app(let m): route.conditions.apps.contains(m)
        case .destination(let d): route.conditions.destinations.contains(d)
        }
    }

    /// Ports or a protocol narrow whatever the route matches: an app or a
    /// site added to such a route takes only that part of its traffic.
    static func narrows(_ route: Route, _ item: Item) -> Bool {
        !route.conditions.ports.isEmpty || route.conditions.network != nil
    }

    /// The profile with the item added; nil when the route is gone or is
    /// "Everything else" (which matches by being last, not by conditions).
    static func apply(_ item: Item, to target: Target, in profile: Profile) -> Profile? {
        var p = profile
        switch target {
        case .existing(let id):
            guard let i = p.routes.firstIndex(where: { $0.id == id }) else { return nil }
            add(item, to: &p.routes[i].conditions)
        case .new(let name, let to):
            var r = Route(name: name, target: to)
            add(item, to: &r.conditions)
            p.routes.insert(r, at: 0)
        }
        return p
    }

    private static func add(_ item: Item, to c: inout Conditions) {
        switch item {
        case .app(let m): if !c.apps.contains(m) { c.apps.append(m) }
        case .destination(let d): if !c.destinations.contains(d) { c.destinations.append(d) }
        }
    }

    /// For the sheet's menu: "googlevideo.com and subdomains".
    static func describe(_ d: Destination) -> String {
        switch d {
        case .domainSuffix(let s): "\(s) and subdomains"
        case .domain(let s): "Only \(s)"
        default: RuleText.text(d)
        }
    }

    /// A route's name from what it was made for.
    static func suggestedName(_ item: Item?) -> String {
        switch item {
        case .app(let m)?: RouteSummary.appName(m)
        case .destination(.domainSuffix(let s))?, .destination(.domain(let s))?: s
        case .destination(let d)?: RuleText.text(d)
        case nil: "New Route"
        }
    }
}
