import Foundation
import Testing
@testable import VPNCore

/// singbox.pin is the single source of truth for the engine; the constants
/// compiled into the helper must agree with it.
@Suite struct PinTests {
    static let pin: [String: String] = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("singbox.pin")
        let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }()

    @Test func versionMatchesPin() {
        #expect(Self.pin["version"] == VPNCore.singBoxVersion)
    }

    @Test func hashesMatchPin() {
        #expect(Self.pin["darwin-arm64"] == VPNCore.singBoxSHA256["arm64"])
        #expect(Self.pin["darwin-amd64"] == VPNCore.singBoxSHA256["x86_64"])
    }
}
