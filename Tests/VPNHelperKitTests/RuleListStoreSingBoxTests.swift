import Foundation
import Testing
@testable import VPNHelperKit
import VPNCore

/// The list store with the real sing-box as its rule-set tool, as the
/// helper runs it: what sing-box writes back (a decompiled list says
/// `"domain_suffix": "a.example"`, not a list of them) must come out right.
/// Skipped without the pinned binary (scripts/fetch-sing-box.sh).
@Suite(.enabled(if: PinnedSingBox.path != nil, "sing-box binary not found"))
struct RuleListStoreSingBoxTests {
    static func run(_ args: [String]) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: PinnedSingBox.path!)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (false, "cannot run") }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus == 0, out)
    }

    static let tool: RuleListStore.RuleSetTool = { args in
        let r = run(["rule-set"] + args + ["--disable-color"])
        return r.ok ? nil : r.out
    }

    /// What a compiled list holds, read back by sing-box.
    func source(_ file: URL) throws -> String {
        let out = file.deletingPathExtension().appendingPathExtension("check.json")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(Self.run(["rule-set", "decompile", file.path, "-o", out.path]).ok)
        return try String(contentsOf: out, encoding: .utf8)
    }

    @Test func mixedListsKeepTheirNamesApart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rules-sb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "https://lists.example/mixed.txt", binary = "https://lists.example/mixed.srs"

        // A compiled list, as a publisher gives it.
        let src = dir.appendingPathComponent("pub.json"), pub = dir.appendingPathComponent("pub.srs")
        try Data(#"{"version":3,"rules":[{"domain_suffix":["b.example"],"ip_cidr":["198.51.100.0/24"]}]}"#.utf8).write(to: src)
        #expect(Self.run(["rule-set", "compile", src.path, "-o", pub.path]).ok)
        let compiled = try Data(contentsOf: pub)
        try FileManager.default.removeItem(at: src)
        try FileManager.default.removeItem(at: pub)

        let answers = [text: Data("a.example\n203.0.113.0/24\n".utf8), binary: compiled]
        let store = RuleListStore(dir: dir, fetch: { (200, answers[$0.absoluteString] ?? Data()) }, tool: Self.tool)
        await store.update([text, binary], olderThan: 0)
        let local = await store.local([text, binary])
        for (url, site, net) in [(text, "a.example", "203.0.113"), (binary, "b.example", "198.51.100")] {
            #expect(await store.info([url])[0].error == nil)
            let names = try #require(local[url]?.namesPath)
            #expect(names.hasSuffix(".names.srs"))
            let kept = try source(URL(fileURLWithPath: names))
            #expect(kept.contains(site) && !kept.contains(net), "\(kept)")
            #expect(try source(URL(fileURLWithPath: try #require(local[url]?.path))).contains(net))
            // Its address apart, for macOS's routes and the kill switch.
            #expect(local[url]?.addresses == [IPNetwork(net + ".0/24")!])
        }

        // The same lists as an earlier helper left them: upgraded from disk.
        let key = RuleLists.fileKey(text)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(key + ".names.srs"))
        try Data(#"{"url":"\#(text)","matchesNames":true}"#.utf8).write(to: dir.appendingPathComponent(key + ".json"))
        #expect(await store.local([text])[text]?.namesPath == nil)
        await store.upgrade()
        let upgraded = try #require(await store.local([text])[text]?.namesPath)
        let kept = try source(URL(fileURLWithPath: upgraded))
        #expect(kept.contains("a.example") && !kept.contains("203.0.113"))
        #expect(await store.local([text])[text]?.addresses == [IPNetwork("203.0.113.0/24")!])
        // Nothing left over but the lists.
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        #expect(files.count == 8, "\(files)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".") })
    }
}

enum PinnedSingBox {
    static let path: String? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let arch = SingBoxEngine.machineArch == "arm64" ? "arm64" : "amd64"
        let p = root.appendingPathComponent("Resources/sing-box/sing-box-darwin-\(arch)").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()
}
