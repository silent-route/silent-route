import Foundation
import VPNCore

/// pf through pfctl, confined to `PFRules.anchor`. Never `pfctl -f` on the
/// main ruleset, never `pfctl -d`: other users of pf keep working.
public struct SystemPacketFilter: PacketFilter {
    let pfctl = "/sbin/pfctl"
    let anchor: String

    public init(anchor: String = PFRules.anchor) {
        self.anchor = anchor
    }

    public func validate(_ rules: String) async throws {
        let r = await Command.run(pfctl, ["-a", anchor, "-n", "-f", "-"], input: rules)
        guard r.ok else { throw Command.Failed(tool: "pfctl -n", output: r.text) }
    }

    public func load(_ rules: String) async throws {
        // Loading an anchor replaces its rules in one step: there is no
        // moment with the old rules gone and the new ones not yet in.
        let r = await Command.run(pfctl, ["-a", anchor, "-f", "-"], input: rules)
        guard r.ok else { throw Command.Failed(tool: "pfctl -f", output: r.text) }
    }

    public func flush() async {
        await Command.run(pfctl, ["-a", anchor, "-F", "all"])
    }

    public func enable() async throws -> String {
        let r = await Command.run(pfctl, ["-E"])
        // "Token : 12345678901234567890"
        guard let line = r.text.split(separator: "\n").first(where: { $0.contains("Token") }),
              let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              !token.isEmpty, token.allSatisfy(\.isNumber) else {
            throw Command.Failed(tool: "pfctl -E", output: r.text)
        }
        return token
    }

    public func release(token: String) async {
        guard token.allSatisfy(\.isNumber) else { return }
        await Command.run(pfctl, ["-X", token])
    }

    public func isLoaded() async -> Bool {
        let r = await Command.run(pfctl, ["-a", anchor, "-s", "rules"])
        return r.ok && r.text.contains("block drop out quick all")
    }
}
