/// At most `limit` at once. Up to `waiting` more wait for their turn, in
/// the order they came; any beyond that are refused.
public actor Gate {
    public let limit: Int
    public let waiting: Int
    private var inside = 0
    private var line: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int, waiting: Int) {
        self.limit = max(1, limit)
        self.waiting = max(0, waiting)
    }

    /// False: refused, the line is full. True: inside, and `leave()` must follow.
    public func enter() async -> Bool {
        if inside < limit {
            inside += 1
            return true
        }
        guard line.count < waiting else { return false }
        // The place is handed over by `leave()`: `inside` stays as it is.
        await withCheckedContinuation { line.append($0) }
        return true
    }

    public func leave() {
        if line.isEmpty {
            inside = max(0, inside - 1)
        } else {
            line.removeFirst().resume()
        }
    }

    /// Inside now, and waiting.
    public var counts: (inside: Int, waiting: Int) { (inside, line.count) }
}
