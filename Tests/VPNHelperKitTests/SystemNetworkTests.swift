import Foundation
import Testing
@testable import VPNCore
@testable import VPNHelperKit

@Suite struct SystemNetworkTests {
    /// The login-page proxy's password is the one way past the kill switch:
    /// it must never be on a command line, which every user of the Mac can
    /// read with `ps`.
    @Test func captiveCheckKeepsThePasswordOffTheCommandLine() {
        let proxy = SingBoxConfig.LocalProxy(port: 40123, username: "silentroute", password: "s3cr3t\"\\x")
        let (args, config) = SystemNetwork.captiveCheck(proxy)
        #expect(!args.joined(separator: " ").contains("s3cr3t"))
        #expect(args.contains("-K") && args.contains("-"))
        #expect(args.contains("socks5h://127.0.0.1:40123"))
        // curl's config syntax: a quoted value with \ and " escaped.
        #expect(config == "proxy-user = \"silentroute:s3cr3t\\\"\\\\x\"\n")
    }
}
