import Foundation

/// All profiles and which one is active. The helper owns the only copy; the
/// app and the CLI edit it through requests.
public struct ProfileLibrary: Codable, Hashable, Sendable {
    public var profiles: [Profile]
    /// The profile `start` connects with and the menu bar shows.
    public var activeID: Profile.ID?

    public init(profiles: [Profile] = [], activeID: Profile.ID? = nil) {
        self.profiles = profiles
        self.activeID = activeID
    }

    public var active: Profile? { activeID.flatMap(profile) }

    public func profile(_ id: Profile.ID) -> Profile? { profiles.first { $0.id == id } }

    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case noSuchProfile
        case emptyName
        case duplicateName(String)

        public var description: String {
            switch self {
            case .noSuchProfile: "No such profile"
            case .emptyName: "A profile needs a name"
            case .duplicateName(let n): "There is already a profile called “\(n)”"
            }
        }
    }

    /// Adds a new profile or replaces the one with the same id. The first
    /// profile becomes active.
    public mutating func upsert(_ p: Profile) throws(Failure) {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        if profiles.contains(where: { $0.id != p.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw .duplicateName(name)
        }
        var p = p
        p.name = name
        if let i = profiles.firstIndex(where: { $0.id == p.id }) {
            profiles[i] = p
        } else {
            profiles.append(p)
        }
        if activeID == nil { activeID = p.id }
    }

    /// Removes a profile. If it was active, the first remaining one becomes
    /// active (or none).
    public mutating func remove(_ id: Profile.ID) throws(Failure) {
        guard profiles.contains(where: { $0.id == id }) else { throw .noSuchProfile }
        profiles.removeAll { $0.id == id }
        if activeID == id { activeID = profiles.first?.id }
    }

    /// A name not taken yet: "Home", "Home 2", "Home 3"…
    public func freeName(_ base: String) -> String {
        let taken = Set(profiles.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    /// A profile from a file someone gave us: fresh ids (its own and its
    /// tunnels' and rules', so two imports never collide) and a free name.
    public func prepareImport(_ p: Profile) -> Profile {
        var p = p
        p.id = UUID()
        p.name = freeName(p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported" : p.name)
        var map: [Tunnel.ID: Tunnel.ID] = [:]
        for i in p.tunnels.indices {
            let new = UUID()
            map[p.tunnels[i].id] = new
            p.tunnels[i].id = new
        }
        func remap(_ r: Route) -> Route {
            var r = r
            r.id = UUID()
            if case .servers(let ids) = r.target { r.target = .servers(ids.compactMap { map[$0] }) }
            return r
        }
        p.routes = p.routes.map(remap)
        p.defaultRoute = remap(p.defaultRoute)
        return p
    }
}
