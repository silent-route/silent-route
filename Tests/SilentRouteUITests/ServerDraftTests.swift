import Foundation
import Testing
import VPNCore
@testable import SilentRouteUI

@Suite struct ServerDraftTests {
    /// What a link sets, the server added from it through the form keeps,
    /// fields the form does not show included.
    @Test(arguments: [
        "ss://YWVzLTI1Ni1nY206c2VjcmV0@203.0.113.5:8388?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dexample.com#SS",
        "hysteria2://pass@example.com:443?sni=example.com&upmbps=50&downmbps=200#HY",
        "vmess://" + Data(#"{"v":"2","ps":"VM","add":"example.com","port":"443","id":"1b2c3d4e-0000-4000-8000-123456789abc","aid":"64","net":"ws","path":"/ws","tls":"tls"}"#.utf8).base64EncodedString(),
    ])
    func linkSurvivesTheForm(_ link: String) throws {
        let t = try LinkParser.parse(link).tunnel
        let built = try ServerDraft(t).build()
        #expect(built.proto == t.proto)
        #expect(built.origin == t.origin)
    }

    /// The fields for them: a plugin turned off takes its options along;
    /// a speed or an alter ID that is not a number is refused, not dropped.
    @Test func linkOnlyFieldsAreEditable() throws {
        var d = ServerDraft(try LinkParser.parse(
            "ss://YWVzLTI1Ni1nY206c2VjcmV0@203.0.113.5:8388?plugin=obfs-local%3Bobfs%3Dhttp#SS").tunnel)
        #expect(d.ssPlugin == "obfs-local" && d.ssPluginOptions == "obfs=http")
        d.ssPlugin = ""
        guard case .shadowsocks(let s) = try d.build().proto else { Issue.record("not Shadowsocks"); return }
        #expect(s.plugin == nil && s.pluginOptions == nil)

        d.proto = .hysteria2
        d.password = "p"
        d.upMbps = "fast"
        #expect(throws: ServerDraft.Problem.self) { try d.build() }
        d.upMbps = " 50 "
        guard case .hysteria2(let h) = try d.build().proto else { Issue.record("not Hysteria2"); return }
        #expect(h.upMbps == 50 && h.downMbps == nil)

        d.proto = .vmess
        d.uuid = "1b2c3d4e-0000-4000-8000-123456789abc"
        d.vmessAlterID = "-1"
        #expect(throws: ServerDraft.Problem.self) { try d.build() }
    }

    /// Reality chosen for VLESS, then another protocol picked: no Reality.
    @Test func realityStaysWithVLESS() throws {
        var d = ServerDraft()
        d.host = "example.com"
        d.uuid = "1b2c3d4e-0000-4000-8000-123456789abc"
        d.security = .reality
        d.realityKey = "key"
        d.proto = .trojan
        d.password = "p"
        guard case .trojan(let tr) = try d.build().proto else { Issue.record("not Trojan"); return }
        #expect(tr.tls?.reality == nil)
        d.proto = .hysteria2
        guard case .hysteria2(let h) = try d.build().proto else { Issue.record("not Hysteria2"); return }
        #expect(h.tls.reality == nil)
    }
}
