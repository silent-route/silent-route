import Testing
@testable import VPNHelperKit

/// panic must never rebuild routes under another, working VPN.
@Suite struct RouteRepairTests {
    @Test func leavesOtherVPNAlone() {
        #expect(!SystemNetwork.needsRouteRepair(routeInterface: "utun6", interfaceExists: true, isOurTUN: false))
    }

    @Test func leavesPhysicalRouteAlone() {
        #expect(!SystemNetwork.needsRouteRepair(routeInterface: "en0", interfaceExists: true, isOurTUN: false))
    }

    @Test func repairsOurOwnOrDeadTunnelOrNoRoute() {
        #expect(SystemNetwork.needsRouteRepair(routeInterface: "utun9", interfaceExists: true, isOurTUN: true))
        #expect(SystemNetwork.needsRouteRepair(routeInterface: "utun9", interfaceExists: false, isOurTUN: false))
        #expect(SystemNetwork.needsRouteRepair(routeInterface: nil, interfaceExists: false, isOurTUN: false))
    }
}
