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

/// Safari loads its pages through a system process outside its bundle.
@Suite struct SafariTests {
    /// Safari is Safari: Apple's shared web content is a choice of its own.
    @Test func addingSafariAddsSafariAlone() throws {
        let safari = TrafficMonitor.app("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari (user)")
        let m = try #require(RouteAddition.matcher(for: safari))
        #expect(m.isSafari)
        let p = try #require(RouteAddition.apply(.app(m), to: .new(name: "Safari", target: .direct), in: Profile(name: "P")))
        #expect(p.routes[0].conditions.apps == [m])
        let both = try #require(RouteAddition.apply(.app(.webKitNetworking), to: .existing(p.routes[0].id), in: p))
        #expect(both.routes[0].conditions.apps == [m, .webKitNetworking])
        #expect(Validation.check(both).isEmpty)
    }

    /// Apple's web content is its own setting: nothing comes with it.
    @Test func appleWebContentIsItsOwnSetting() throws {
        let p = try #require(RouteAddition.apply(.app(.webKitNetworking), to: .new(name: "Apple", target: .direct), in: Profile(name: "P")))
        #expect(p.routes[0].conditions.apps == [.webKitNetworking])
    }

    /// The process shows under a name people recognise, and is matched by
    /// name: its folder differs between macOS versions.
    @Test func webKitNetworkingIsMatchedByName() throws {
        for path in ["/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
                     "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"] {
            let app = TrafficMonitor.app(path + " (user)")
            #expect(app.name == "Apple web content (WebKit)")
            #expect(RouteAddition.matcher(for: app) == .webKitNetworking)
        }
    }

    /// A route made before: Safari alone gets a hint, not an error.
    @Test func safariWithoutItsPagesIsPointedOut() {
        let r = Route(name: "S", conditions: Conditions(apps: [.bundle(path: "/Applications/Safari.app")]), target: .direct)
        let issues = Validation.check(Profile(name: "P", routes: [r]))
        #expect(issues.contains { $0.severity == .warning && $0.message.contains("Apple web content") })
        #expect(!issues.contains { $0.severity == .error })
    }
}

@Suite struct AppleWebContentFromMonitorTests {
    /// Monitor does not add Apple's web content: it is set in the route.
    @Test func notOfferedFromMonitor() {
        let webKit = TrafficMonitor.app("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking (user)")
        #expect(!RouteAddition.canAdd(webKit))
        #expect(RouteAddition.canAdd(TrafficMonitor.app("/Applications/Telegram.app/Contents/MacOS/Telegram (user)")))
        #expect(!RouteAddition.canAdd(TrafficMonitor.app("")))
    }
}
