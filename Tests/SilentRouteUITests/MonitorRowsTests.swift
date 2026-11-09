import Foundation
import Testing
@testable import SilentRouteUI

@MainActor @Suite struct MonitorRowsTests {
    typealias AppRef = TrafficMonitor.AppRef
    let safari = TrafficMonitor.app("/Applications/Safari.app/Contents/MacOS/Safari (user)")
    let curl = TrafficMonitor.app("/usr/bin/curl (user)")
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func conn(_ id: String, _ app: AppRef, _ host: String, down: Int64 = 0, age: Double = 10) -> TrafficMonitor.Connection {
        TrafficMonitor.Connection(id: id, app: app, host: host, port: "443", network: "TCP", route: "R", exit: "S",
                                  viaFallback: false, start: t0.addingTimeInterval(-age), download: down, upload: 0,
                                  downRate: down, upRate: 0)
    }

    @Test func pinListKeepsTheUsersOrder() {
        var p = PinList<AppRef>()
        p.pin(safari)
        p.pin(curl)
        p.pin(safari)                       // once is enough
        #expect(p.items.map(\.id) == [safari.id, curl.id])
        p.move(curl.id, by: -1)
        #expect(p.items.map(\.id) == [curl.id, safari.id])
        p.move(curl.id, by: -1)             // already first
        #expect(p.items.map(\.id) == [curl.id, safari.id])
        p.unpin(curl.id)
        #expect(p.items.map(\.id) == [safari.id])
    }

    @Test func pinsSurviveARelaunch() throws {
        let defaults = try #require(UserDefaults(suiteName: "MonitorRowsTests-\(UUID())"))
        var pins = MonitorPins()
        pins.apps.pin(curl)
        pins.destinations.pin(.init(app: safari, host: "example.com"))
        pins.save(defaults)
        #expect(MonitorPins.load(defaults) == pins)
    }

    /// A browser's helpers are the browser: one row, one pin, one rule.
    @Test func helpersCountAsTheirApp() {
        let helper = TrafficMonitor.app("/Applications/Safari.app/Contents/XPCServices/WebContent.xpc/Contents/MacOS/WebContent (user)")
        let m = TrafficMonitor(preview: [conn("1", safari, "a.com", down: 5), conn("2", helper, "b.com", down: 7)])
        #expect(m.apps.count == 1)
        #expect(m.apps.first?.connections == 2 && m.apps.first?.downRate == 12)
    }

    /// Pinned first, in pin order, whatever the column; the rest by it.
    @Test func pinnedRowsStayOnTop() {
        let live = [conn("1", safari, "a.com", down: 100), conn("2", curl, "b.com", down: 1), conn("3", safari, "c.com", down: 50)]
        var pins = PinList<MonitorPins.Destination>()
        pins.pin(.init(app: curl, host: "b.com"))
        pins.pin(.init(app: curl, host: "gone.example"))
        let rows = MonitorOrder.arranged(ConnectionRow.rows(live, pins: pins), pin: \.pin,
                                         by: [KeyPathComparator(\.downRate, order: .reverse)],
                                         tieBreak: [KeyPathComparator(\.id)])
        #expect(rows.map(\.id) == ["2", "pin:" + MonitorPins.Destination.id(app: curl, host: "gone.example"), "1", "3"])
        #expect(rows[1].isLive == false && rows[1].destination == "gone.example")
        let ascending = MonitorOrder.arranged(ConnectionRow.rows(live, pins: pins), pin: \.pin,
                                              by: [KeyPathComparator(\.downRate)], tieBreak: [KeyPathComparator(\.id)])
        #expect(ascending.map(\.id).suffix(2) == ["3", "1"])
        #expect(ascending.first?.id == "2")
    }

    /// Every open connection to a pinned site is under its pin.
    @Test func onePinCoversEveryConnectionToTheSite() {
        let live = [conn("1", safari, "a.com"), conn("2", safari, "a.com"), conn("3", safari, "b.com")]
        var pins = PinList<MonitorPins.Destination>()
        pins.pin(.init(app: safari, host: "a.com"))
        let rows = ConnectionRow.rows(live, pins: pins)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.pin == 0 }.map(\.id).sorted() == ["1", "2"])
    }

    @Test func absentPinnedAppIsShownFaded() {
        var pins = PinList<AppRef>()
        pins.pin(curl)
        let m = TrafficMonitor(preview: [conn("1", safari, "a.com", down: 3)])
        let rows = AppRow.rows(m.apps, pins: pins)
        #expect(rows.count == 2)
        let c = rows.first { $0.id == curl.id }
        #expect(c?.isLive == false && c?.pin == 0)
        #expect(rows.first { $0.id == safari.id }?.pin == nil)
    }
}
