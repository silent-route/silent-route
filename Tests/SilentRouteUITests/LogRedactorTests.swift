import Testing
@testable import SilentRouteUI

@Suite struct LogRedactorTests {
    @Test func addressesNamesAndHostsGo() {
        let log = """
        # Silent Route session · profile: Home Office
        2026-10-14 12:03:09 [helper] route “Streaming”: now through “nl-1 backup”
        +0000 2026-10-14 12:03:10 ERROR connection: open connection to 203.0.113.7:443 using outbound/hysteria2[t-00000000-0000-4000-8000-0000000000a1]: lookup vpn.example.org: timeout
        dial [2001:db8::1]:443 and fe80::1%en0 and 2001:db8:0:0:0:0:0:2
        """
        let r = LogRedactor.redact(log)
        for secret in ["Home Office", "Streaming", "nl-1 backup", "203.0.113.7", "vpn.example.org", "2001:db8", "fe80::1"] {
            #expect(!r.contains(secret), "\(secret) left in")
        }
        // What makes a log useful stays.
        for kept in ["2026-10-14 12:03:09", "12:03:10", "ERROR connection", ":443", "hysteria2", "lookup", "timeout",
                     "t-00000000-0000-4000-8000-0000000000a1"] {
            #expect(r.contains(kept), "\(kept) lost")
        }
    }

    /// Paths of apps in sing-box's messages carry the account name.
    @Test func accountNameInPathsGoes() {
        let r = LogRedactor.redact("process /Users/jane.doe/Applications/Tool.app/Contents/MacOS/Tool (user)")
        #expect(!r.contains("jane.doe"))
        #expect(r.contains("/Users/‹user›/Applications/"))
    }
}
