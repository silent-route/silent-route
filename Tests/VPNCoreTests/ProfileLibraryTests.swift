import Foundation
import Testing
@testable import VPNCore

@Suite struct ProfileLibraryTests {
    static let t = Tunnel(name: "A", server: Endpoint(host: "a.example.org", port: 443),
                          proto: .hysteria2(Hysteria2(password: "p", tls: TLS())))

    @Test func firstProfileBecomesActive() throws {
        var lib = ProfileLibrary()
        let home = Profile.example(name: "Home")
        try lib.upsert(home)
        try lib.upsert(Profile.example(name: "Work"))
        #expect(lib.activeID == home.id)
        #expect(lib.profiles.map(\.name) == ["Home", "Work"])
    }

    @Test func namesAreTrimmedUniqueAndRequired() throws {
        var lib = ProfileLibrary()
        try lib.upsert(Profile(name: "  Home "))
        #expect(lib.profiles[0].name == "Home")
        #expect(throws: ProfileLibrary.Failure.duplicateName("home")) { try lib.upsert(Profile(name: "home")) }
        #expect(throws: ProfileLibrary.Failure.emptyName) { try lib.upsert(Profile(name: "  ")) }
        // Renaming a profile to its own name is fine.
        var same = lib.profiles[0]
        same.killSwitch = .always
        try lib.upsert(same)
        #expect(lib.profiles.count == 1 && lib.profiles[0].killSwitch == .always)
    }

    @Test func removingTheActiveOneActivatesAnother() throws {
        var lib = ProfileLibrary()
        let a = Profile(name: "A"), b = Profile(name: "B")
        try lib.upsert(a)
        try lib.upsert(b)
        try lib.remove(a.id)
        #expect(lib.activeID == b.id)
        try lib.remove(b.id)
        #expect(lib.activeID == nil)
        #expect(throws: ProfileLibrary.Failure.noSuchProfile) { try lib.remove(b.id) }
    }

    @Test func importGetsFreshIdsAndKeepsRoutesPointingRight() throws {
        var lib = ProfileLibrary()
        var p = Profile.example(name: "Home", tunnels: [Self.t])
        p.routes.append(Route(name: "via A", conditions: Conditions(destinations: [.domainSuffix("x.example")]),
                              target: .servers([Self.t.id])))
        try lib.upsert(p)
        let imported = lib.prepareImport(p)
        #expect(imported.id != p.id)
        #expect(imported.name == "Home 2")
        #expect(imported.tunnels[0].id != Self.t.id)
        #expect(imported.defaultRoute.target == .servers([imported.tunnels[0].id]))
        #expect(imported.routes.last?.target == .servers([imported.tunnels[0].id]))
        #expect(imported.defaultRoute.id != p.defaultRoute.id)
        try lib.upsert(imported)
        #expect(lib.profiles.count == 2)
    }

    /// A schema 1 profile (rules, a main tunnel, per-tunnel fallbacks and
    /// kill switch) becomes routes with the same meaning.
    @Test func schemaOneBecomesRoutes() throws {
        let a = UUID(), b = UUID(), r1 = UUID(), r2 = UUID()
        func tunnel(_ id: UUID, _ fallbacks: [UUID], ks: Bool) -> [String: Any] {
            ["id": id.uuidString, "name": "T", "server": ["host": "a.example.org", "port": 443],
             "proto": ["hysteria2": ["_0": ["password": "p", "tls": ["alpn": [], "insecure": false], "serverPorts": []]]],
             "origin": ["manual": [:]], "fallbacks": fallbacks.map(\.uuidString), "killSwitch": ks]
        }
        let old: [String: Any] = [
            "schemaVersion": 1, "id": UUID().uuidString, "name": "Old",
            "tunnels": [tunnel(a, [b], ks: true), tunnel(b, [], ks: false)],
            "mainTunnel": a.uuidString,
            "rules": [
                ["id": r1.uuidString, "name": "B only", "enabled": true,
                 "conditions": ["destinations": [["domainSuffix": ["_0": "b.example"]]], "apps": [], "ports": []],
                 "action": ["tunnel": ["_0": b.uuidString]]],
                ["id": r2.uuidString, "name": "Domestic", "enabled": true,
                 "conditions": ["destinations": [["geoIP": ["_0": "cn"]]], "apps": [], "ports": []],
                 "action": ["direct": [:]]],
            ],
            "dns": try JSONSerialization.jsonObject(with: JSONEncoder().encode(DNSSettings.default)),
            "lan": "allow", "killSwitch": "whileConnected",
        ]
        let p = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(p.schemaVersion == Profile.currentSchema)
        #expect(p.defaultRoute.target == .servers([a, b]))
        #expect(p.defaultRoute.killSwitch)
        #expect(p.routes.map(\.id) == [r1, r2])
        #expect(p.routes[0].target == .servers([b]))
        #expect(!p.routes[0].killSwitch)
        #expect(p.routes[1].target == .direct)
        // And it saves as schema 2.
        let again = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(p))
        #expect(again == p)
    }

    /// profile.json from before profiles had names still loads.
    @Test func legacyProfileDecodes() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile.example(tunnels: [Self.t]))) as! [String: Any]
        old["id"] = nil
        old["name"] = nil
        let p = try JSONDecoder().decode(Profile.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(p.name == "Profile")
        #expect(p.tunnels == [Self.t])
    }
}
