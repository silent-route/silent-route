import Foundation
import Testing
@testable import VPNCore

@Suite struct IPNetworkTests {
    @Test(arguments: [
        ("1.2.3.4", "1.2.3.4/32"),
        ("10.1.2.3/8", "10.0.0.0/8"),
        ("0.0.0.0/0", "0.0.0.0/0"),
        ("  192.168.1.0/24 ", "192.168.1.0/24"),
        ("::1", "::1/128"),
        ("fe80::/10", "fe80::/10"),
        ("2001:DB8:0:0:1:0:0:1", "2001:db8::1:0:0:1/128"),
        ("2001:db8::", "2001:db8::/128"),
        ("::ffff:1.2.3.4", "::ffff:102:304/128"),
        ("fdfe:dcba:9876::1/126", "fdfe:dcba:9876::/126"),
    ])
    func parses(input: String, expected: String) {
        #expect(IPNetwork(input)?.description == expected)
    }

    @Test(arguments: [
        "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.4/33", "1.2.3.4/",
        "1.2.3.4/-1", "1.2.3.4/8/8", "::1/129", ":::1", "1::2::3", "12345::", "g::1",
        "1.2.3.4; pass all", "example.com", "1:2:3:4:5:6:7:8:9",
    ])
    func rejects(input: String) {
        #expect(IPNetwork(input) == nil)
    }

    @Test func contains() {
        let net = IPNetwork("9.9.0.0/18")!
        #expect(net.contains(IPNetwork("9.9.9.9")!))
        #expect(!net.contains(IPNetwork("9.9.64.1")!))
        #expect(!net.contains(IPNetwork("::1")!))
    }

    @Test func codableAsString() throws {
        let data = try JSONEncoder().encode([IPNetwork("10.0.0.0/8")!])
        #expect(String(data: data, encoding: .utf8) == #"["10.0.0.0\/8"]"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([IPNetwork].self, from: Data(#"["nope"]"#.utf8)) }
    }
}
