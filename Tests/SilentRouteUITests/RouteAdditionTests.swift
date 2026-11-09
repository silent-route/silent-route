import Foundation
import Testing
import VPNCore
@testable import SilentRouteUI

@Suite struct RouteAdditionTests {
    let telegram = TrafficMonitor.app("/Applications/Telegram.app/Contents/MacOS/Telegram (user)")

    @Test func appBecomesItsBundleOrProgram() {
        #expect(RouteAddition.matcher(for: telegram) == .bundle(path: "/Applications/Telegram.app"))
        #expect(RouteAddition.matcher(for: TrafficMonitor.app("/usr/bin/curl")) == .executable(path: "/usr/bin/curl"))
        #expect(RouteAddition.matcher(for: TrafficMonitor.app("")) == nil)
    }

    @Test func hostChoices() {
        #expect(RouteAddition.destinations(forHost: "rr1.googlevideo.com") ==
                [.domainSuffix("rr1.googlevideo.com"), .domainSuffix("googlevideo.com"), .domain("rr1.googlevideo.com")])
        // A country's company zone is not offered on its own.
        #expect(RouteAddition.destinations(forHost: "www.bbc.co.uk") ==
                [.domainSuffix("www.bbc.co.uk"), .domainSuffix("bbc.co.uk"), .domain("www.bbc.co.uk")])
        #expect(RouteAddition.destinations(forHost: "149.154.167.51") == [.cidr(IPNetwork("149.154.167.51/32")!)])
        #expect(RouteAddition.destinations(forHost: "?").isEmpty)
        #expect(RouteAddition.suggested(RouteAddition.destinations(forHost: "rr1.googlevideo.com")) == .domainSuffix("googlevideo.com"))
    }

    @Test func newRouteGoesFirst() throws {
        let p = Profile(name: "P", routes: [Route(name: "Old", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)])
        let item = RouteAddition.Item.app(.bundle(path: "/Applications/Telegram.app"))
        let out = try #require(RouteAddition.apply(item, to: .new(name: "Telegram", target: .block), in: p))
        #expect(out.routes.map(\.name) == ["Telegram", "Old"])
        #expect(out.routes[0].conditions.apps == [.bundle(path: "/Applications/Telegram.app")])
        #expect(out.routes[0].target == .block)
    }

    @Test func addingToAnExistingRoute() throws {
        let r = Route(name: "Sites", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)
        let p = Profile(name: "P", routes: [r])
        let site = RouteAddition.Item.destination(.domainSuffix("b.com"))
        let out = try #require(RouteAddition.apply(site, to: .existing(r.id), in: p))
        #expect(out.routes[0].conditions.destinations == [.domainSuffix("a.com"), .domainSuffix("b.com")])
        #expect(RouteAddition.contains(out.routes[0], site))
        #expect(!RouteAddition.narrows(r, site))
        // "Everything else" and gone routes take nothing.
        #expect(RouteAddition.apply(site, to: .existing(p.defaultRoute.id), in: p) == nil)
        #expect(RouteAddition.apply(site, to: .existing(UUID()), in: p) == nil)
    }

    /// The first app in a route of sites makes it "this app to these
    /// sites": said before adding.
    @Test func narrowingIsNoticed() {
        let sites = Route(name: "Sites", conditions: Conditions(destinations: [.domainSuffix("a.com")]), target: .direct)
        let app = RouteAddition.Item.app(.executable(path: "/usr/bin/curl"))
        #expect(RouteAddition.narrows(sites, app))
        var both = sites
        both.conditions.apps = [.processName("ssh")]
        #expect(!RouteAddition.narrows(both, app))
        #expect(!RouteAddition.narrows(Route(name: "Empty", target: .direct), app))
    }
}
