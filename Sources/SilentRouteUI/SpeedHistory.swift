import Foundation

/// The VPN's speed, a sample a second, for Monitor's chart: kept from where
/// the uptime counts (this connection, or turning the VPN on, as chosen in
/// Settings), whether or not anyone looks, so the chart can show what happened before
/// Monitor was opened. It comes from the stream the app reads anyway while
/// connected; nothing extra is asked of sing-box.
public struct SpeedHistory: Equatable, Sendable {
    public struct Sample: Identifiable, Equatable, Sendable {
        public var id: Date { time }
        public var time: Date
        public var down: Int64
        public var up: Int64
        public init(time: Date, down: Int64, up: Int64) { self.time = time; self.down = down; self.up = up }
    }

    public init() {}

    /// Two days of seconds at most; older ones go first.
    static let capacity = 2 * 24 * 3600

    private(set) var samples: [Sample] = []
    /// Set while no data arrives (a reconnect): the line drops to zero
    /// there rather than bridging the gap with a made-up slope.
    private var paused = false

    var isEmpty: Bool { samples.isEmpty }

    public mutating func add(_ speed: Speed, at time: Date) {
        if paused, let last = samples.last, time.timeIntervalSince(last.time) > 1 {
            samples.append(Sample(time: time.addingTimeInterval(-1), down: 0, up: 0))
        }
        paused = false
        samples.append(Sample(time: time, down: speed.down, up: speed.up))
        // Trimmed an hour at a time, not every second.
        if samples.count > Self.capacity + 3600 { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The stream stopped (sing-box restarting, the VPN off).
    public mutating func pause(at time: Date) {
        guard !paused, let last = samples.last else { return }
        paused = true
        if last.down != 0 || last.up != 0 {
            samples.append(Sample(time: max(time, last.time.addingTimeInterval(0.001)), down: 0, up: 0))
        }
    }

    /// The samples within `range` of the last one, averaged into at most
    /// `maxPoints` (a chart of hours does not need every second, and drawing
    /// them all would be slow).
    func points(within range: TimeInterval?, maxPoints: Int = 600) -> [Sample] {
        guard let end = samples.last?.time else { return [] }
        let start = range.map { end.addingTimeInterval(-$0) } ?? samples[0].time
        let first = samples.firstIndex { $0.time >= start } ?? samples.count
        let slice = samples[first...]
        guard slice.count > maxPoints, maxPoints > 0 else { return Array(slice) }
        let width = end.timeIntervalSince(start) / Double(maxPoints)
        guard width > 0 else { return Array(slice) }
        var out: [Sample] = []
        var bucket = -1
        var sumDown: Int64 = 0, sumUp: Int64 = 0, n: Int64 = 0, time = start
        func flush() {
            if n > 0 { out.append(Sample(time: time, down: sumDown / n, up: sumUp / n)) }
        }
        for s in slice {
            let b = min(maxPoints - 1, Int(s.time.timeIntervalSince(start) / width))
            if b != bucket {
                flush()
                bucket = b
                sumDown = 0; sumUp = 0; n = 0
                time = s.time
            }
            sumDown += s.down; sumUp += s.up; n += 1
        }
        flush()
        return out
    }
}
