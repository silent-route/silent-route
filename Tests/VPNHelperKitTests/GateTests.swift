import Testing
@testable import VPNHelperKit

@Suite struct GateTests {
    @Test func letsInUpToTheLimitThenQueuesInOrder() async {
        let gate = Gate(limit: 2, waiting: 2)
        #expect(await gate.enter())
        #expect(await gate.enter())
        let order = Order()
        let a = Task { let ok = await gate.enter(); await order.add("a"); return ok }
        while await gate.counts.waiting < 1 { await Task.yield() }
        let b = Task { let ok = await gate.enter(); await order.add("b"); return ok }
        while await gate.counts.waiting < 2 { await Task.yield() }
        // The line is full: refused, not queued.
        #expect(await gate.enter() == false)

        await gate.leave()
        #expect(await a.value)
        await gate.leave()
        #expect(await b.value)
        #expect(await order.items == ["a", "b"])
        // Places were handed over, never more than the limit inside.
        #expect(await gate.counts.inside == 2)
        await gate.leave()
        await gate.leave()
        #expect(await gate.counts.inside == 0)
        #expect(await gate.enter())
    }

    @Test func leavingMoreThanEnteredDoesNotGoBelowZero() async {
        let gate = Gate(limit: 1, waiting: 0)
        await gate.leave()
        #expect(await gate.counts.inside == 0)
        #expect(await gate.enter())
        #expect(await gate.enter() == false)
    }

    private actor Order {
        var items: [String] = []
        func add(_ s: String) { items.append(s) }
    }
}
