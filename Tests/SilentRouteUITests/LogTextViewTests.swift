import Testing
@testable import SilentRouteUI

@Suite struct LogTextViewTests {
    /// Connections that ended normally, though sing-box calls it an error.
    @Test(arguments: [
        "+0000 2026-10-20 12:15:54 ERROR [2323960577 20m1s] connection: connection upload closed: stream 3852 canceled by remote with error code 0",
        "+0000 2026-10-20 12:28:45 ERROR [1091400810 86ms] connection: connection download closed: close tcp 172.19.0.5:63571->203.0.113.50:443: endpoint not connected",
    ])
    func harmlessCloses(_ line: String) {
        #expect(LogTextView.isHarmlessClose(Substring(line)))
    }

    @Test(arguments: [
        "+0000 2026-10-20 12:15:54 ERROR [1 5s] connection: connection upload closed: stream 3852 canceled by remote with error code 257",
        "+0000 2026-10-14 13:10:45 ERROR connection: open connection to 198.51.100.7:8000 using outbound/socks: i/o timeout",
        "+0000 2026-10-20 12:28:45 ERROR [1 86ms] connection: connection download closed: read tcp 172.19.0.5:1->203.0.113.50:443: connection reset by peer",
        "+0000 2026-10-20 12:28:45 ERROR dns: exchange failed for example.com: endpoint not connected",
    ])
    func realErrors(_ line: String) {
        #expect(!LogTextView.isHarmlessClose(Substring(line)))
    }
}
