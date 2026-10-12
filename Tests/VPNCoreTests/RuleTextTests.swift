import Testing
@testable import VPNCore

@Suite struct RuleTextTests {
    @Test func everyFormRoundTrips() {
        let text = """
        # comment
        youtube.com
        =exact.example.org
        keyword:tube
        geoip:cn
        geosite:geolocation-cn
        10.0.0.0/8
        2001:db8::/32
        1.2.3.4
        """
        let (ds, errors) = RuleText.destinations(text)
        #expect(errors.isEmpty)
        #expect(ds == [.domainSuffix("youtube.com"), .domain("exact.example.org"), .domainKeyword("tube"), .geoIP("cn"), .geoSite("geolocation-cn"),
                       .cidr(IPNetwork("10.0.0.0/8")!), .cidr(IPNetwork("2001:db8::/32")!), .cidr(IPNetwork("1.2.3.4/32")!)])
        #expect(RuleText.destinations(RuleText.text(ds)).values == ds)
    }

    @Test func forgivingWhereItIsUnambiguous() {
        let (ds, errors) = RuleText.destinations("*.Example.COM\n.example.net\nhttps://www.youtube.com/watch?v=1\n\n  spaced.org  \nexample.net")
        #expect(errors.isEmpty)
        #expect(ds == [.domainSuffix("example.com"), .domainSuffix("example.net"), .domainSuffix("www.youtube.com"),
                       .domainSuffix("spaced.org")])
    }

    @Test func everyBadLineIsReported() {
        let (ds, errors) = RuleText.destinations("good.org\n300.1.1.1\n10.0.0.0/33\ngeoip:china\nkeyword:\nbad domain\nexa_mple.com")
        #expect(ds == [.domainSuffix("good.org")])
        #expect(errors.map(\.line) == ["300.1.1.1", "10.0.0.0/33", "geoip:china", "keyword:", "bad domain", "exa_mple.com"])
    }

    @Test func ports() {
        #expect(RuleText.ports("443, 8000-8100 53").values == [PortRange(443), PortRange(8000, 8100), PortRange(53)])
        #expect(RuleText.text([PortRange(443), PortRange(8000, 8100)]) == "443, 8000-8100")
        #expect(RuleText.ports("0, 70000, 9-3, a, 5-").errors.map(\.line) == ["0", "70000", "9-3", "a", "5-"])
    }
}
