import Foundation
import Testing
@testable import SilentRouteUI

@Suite struct SpeedHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func history(seconds: Int, from start: Int = 0) -> SpeedHistory {
        var h = SpeedHistory()
        for i in start..<(start + seconds) {
            h.add(Speed(down: Int64(i), up: 1), at: t0.addingTimeInterval(Double(i)))
        }
        return h
    }

    /// A short span shows every second, as it came.
    @Test func shortSpanIsKeptAsIs() {
        let h = history(seconds: 100)
        let p = h.points(within: 120)
        #expect(p.count == 100)
        #expect(p.first?.down == 0 && p.last?.down == 99)
    }

    /// A fixed span shows only its own end of the session.
    @Test func spanCutsFromTheEnd() {
        let h = history(seconds: 1000)
        let p = h.points(within: 120)
        #expect(p.count == 121)
        #expect(p.first?.time == t0.addingTimeInterval(879))
    }

    /// Hours are averaged into at most `maxPoints`, keeping the level.
    @Test func longSessionIsAveraged() {
        var h = SpeedHistory()
        for i in 0..<7200 { h.add(Speed(down: 1000, up: 10), at: t0.addingTimeInterval(Double(i))) }
        let p = h.points(within: nil, maxPoints: 600)
        #expect(p.count <= 600 && p.count > 500)
        #expect(p.allSatisfy { $0.down == 1000 && $0.up == 10 })
        #expect(p.first?.time == t0)
    }

    /// A reconnect: the line drops to zero across the gap instead of a
    /// made-up slope from before it to after it.
    @Test func gapDropsToZero() {
        var h = SpeedHistory()
        h.add(Speed(down: 500, up: 50), at: t0)
        h.pause(at: t0.addingTimeInterval(1))
        h.pause(at: t0.addingTimeInterval(2))           // repeated: once is enough
        h.add(Speed(down: 700, up: 70), at: t0.addingTimeInterval(30))
        let p = h.points(within: nil)
        #expect(p.map(\.down) == [500, 0, 0, 700])
        #expect(p[1].time == t0.addingTimeInterval(1))
        #expect(p[2].time == t0.addingTimeInterval(29))
    }

    @Test func emptyHasNoPoints() {
        #expect(SpeedHistory().points(within: 120).isEmpty)
    }
}
