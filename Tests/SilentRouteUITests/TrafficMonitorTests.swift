import Foundation
import Testing
@testable import SilentRouteUI

@Suite struct TrafficMonitorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let labels = TrafficMonitor.Labels(names: ["direct": "Direct", "t-a": "Server A"],
                                       routes: ["r-x": (name: "Route X", first: "t-a")])

    func json(_ conns: [(id: String, path: String, down: Int, chains: [String])]) -> Data {
        let list: [[String: Any]] = conns.map { c in
            ["id": c.id, "download": c.down, "upload": 0, "chains": c.chains, "rule": "final",
             "start": "2026-10-24T10:40:09.123456+02:00",
             "metadata": ["processPath": c.path, "host": "", "destinationIP": "192.0.2.1",
                          "destinationPort": "443", "network": "udp"]]
        }
        return try! JSONSerialization.data(withJSONObject: ["connections": list, "downloadTotal": 500, "uploadTotal": 7])
    }

    @Test func ratesComeFromTheChangeBetweenTwoSnapshots() throws {
        let torrent = "/Applications/qbittorrent.app/Contents/MacOS/qbittorrent (user)"
        let first = try TrafficMonitor.snapshot(json([("1", torrent, 100, ["t-a", "r-x"])]), at: t0, labels: labels, last: nil)
        let c = try #require(first.connections.first)
        #expect(c.app.name == "qbittorrent" && c.route == "Route X" && c.exit == "Server A" && c.network == "UDP")
        // The formatter keeps milliseconds.
        #expect(abs(c.start.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-10-24T08:40:09Z")!) - 0.123) < 0.001)
        #expect(first.download == 500 && first.upload == 7)

        let second = try TrafficMonitor.snapshot(
            json([("1", torrent, 300, ["direct", "r-x"]), ("2", "/usr/bin/curl (user)", 0, ["direct"])]),
            at: t0.addingTimeInterval(2), labels: labels, last: first)
        let again = try #require(second.connections.first { $0.id == "1" })
        #expect(again.downRate == 100)
        #expect(again.download == 300)
        #expect(again.start == c.start)
        // The route moved it to another exit: shown at once.
        #expect(again.exit == "Direct" && again.viaFallback)
        #expect(second.apps.count == 2)
        #expect(second.apps.first { $0.app.name == "qbittorrent" }?.connections == 1)
    }

    /// A torrent client can hold thousands: decoded off the main thread, in
    /// one pass, apps grouped once.
    @Test func thousandsOfConnections() throws {
        let many = (0..<5000).map { (id: "\($0)", path: "/Applications/qbittorrent.app/Contents/MacOS/qbittorrent (user)",
                                      down: $0, chains: ["t-a", "r-x"]) }
        let snap = try TrafficMonitor.snapshot(json(many), at: t0, labels: labels, last: nil)
        #expect(snap.connections.count == 5000)
        #expect(snap.apps.count == 1 && snap.apps[0].connections == 5000)
    }
}
