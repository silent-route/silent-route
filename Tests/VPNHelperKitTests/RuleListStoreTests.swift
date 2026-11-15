import Foundation
import Testing
@testable import VPNHelperKit
import VPNCore

@Suite struct RuleListStoreTests {
    static let binary = Data("SRS\u{3}one".utf8)
    static let newer = Data("SRS\u{3}two".utf8)
    static let a = "https://lists.example/a.srs"
    static let text = "https://lists.example/sites.txt"

    final class Server: @unchecked Sendable {
        let lock = NSLock()
        var answers: [String: (Int, Data)] = [:]
        var requests: [String] = []
        func fetch(_ url: URL) async throws -> (status: Int, data: Data) {
            try await Task.sleep(for: .milliseconds(5))
            return lock.withLock {
                requests.append(url.absoluteString)
                return answers[url.absoluteString] ?? (404, Data())
            }
        }
    }

    /// sing-box's rule-set tool, played: decompile writes a source, compile
    /// writes a binary, each from the other; `broken` refuses everything.
    static func tool(broken: Bool = false) -> RuleListStore.RuleSetTool {
        { args in
            if broken { return "read rule[0]: unexpected EOF" }
            guard args.count == 4, let input = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else { return "bad call" }
            let out = URL(fileURLWithPath: args[3])
            switch args[0] {
            case "decompile": try? Data(#"{"version":3,"rules":[{"domain_suffix":["a.example"]}]}"#.utf8).write(to: out)
            case "compile": try? (Data("SRS\u{3}".utf8) + input).write(to: out)
            default: return "unknown"
            }
            return nil
        }
    }

    func make(_ server: Server, broken: Bool = false) throws -> (RuleListStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (RuleListStore(dir: dir, fetch: { try await server.fetch($0) }, tool: Self.tool(broken: broken)), dir)
    }

    func file(_ dir: URL, _ url: String) -> URL { dir.appendingPathComponent(RuleLists.fileKey(url) + ".srs") }

    @Test func downloadsWhatIsMissing() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        let (store, dir) = try make(server)
        let nope = "https://lists.example/nope.srs"
        await store.update([Self.a, nope], olderThan: .infinity)
        #expect(try Data(contentsOf: file(dir, Self.a)) == Self.binary)
        let local = await store.local([Self.a, nope])
        #expect(local.keys.sorted() == [Self.a])
        #expect(local[Self.a]?.matchesNames == true)
        let info = await store.info([Self.a, nope])
        #expect(info[0].bytes == Self.binary.count && info[0].updated != nil && info[0].error == nil)
        #expect(info[1].bytes == nil && info[1].error == "nothing at this address (HTTP 404)")
        // Present and fresh: not fetched again.
        await store.update([Self.a], olderThan: 60)
        #expect(server.requests.filter { $0 == Self.a }.count == 1)
    }

    /// Plain text is turned into a rule-set and compiled.
    @Test func textIsCompiled() async throws {
        let server = Server()
        server.answers[Self.text] = (200, Data("10.0.0.0/8\n# note\n".utf8))
        let (store, dir) = try make(server)
        await store.update([Self.text], olderThan: 0)
        let compiled = try Data(contentsOf: file(dir, Self.text))
        #expect(compiled.prefix(3) == Data("SRS".utf8))
        // Addresses only: it plays no part in choosing a DNS server.
        #expect(await store.local([Self.text])[Self.text]?.matchesNames == false)
    }

    /// A bad download never replaces a good list.
    @Test func keepsTheLastGoodCopy() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        let (store, dir) = try make(server)
        await store.update([Self.a], olderThan: 0)
        for (status, body) in [(200, Data("<html>blocked</html>".utf8)), (500, Data()), (200, Data(count: RuleLists.maxBytes + 1))] {
            server.answers[Self.a] = (status, body)
            await store.update([Self.a], olderThan: 0)
            #expect(try Data(contentsOf: file(dir, Self.a)) == Self.binary)
            #expect(await store.info([Self.a])[0].error != nil)
        }
        server.answers[Self.a] = (200, Self.newer)
        await store.update([Self.a], olderThan: 0)
        #expect(try Data(contentsOf: file(dir, Self.a)) == Self.newer)
        #expect(await store.info([Self.a])[0].error == nil)
        // The list and its note, nothing left over.
        let key = RuleLists.fileKey(Self.a)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == [key + ".json", key + ".srs"])
    }

    @Test func refusesWhatSingBoxCannotRead() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        let (store, dir) = try make(server, broken: true)
        await store.update([Self.a], olderThan: 0)
        #expect(await store.local([Self.a]).isEmpty)
        #expect(await store.info([Self.a])[0].error?.contains("unexpected EOF") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    @Test func concurrentRequestsShareADownload() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        let (store, _) = try make(server)
        async let x: Void = store.update([Self.a], olderThan: 0)
        async let y: Void = store.update([Self.a], olderThan: 0)
        _ = await (x, y)
        #expect(server.requests == [Self.a])
    }

    /// Only web addresses over HTTPS are ever fetched.
    @Test func badAddressesAreIgnored() async throws {
        let server = Server()
        let (store, _) = try make(server)
        await store.update(["file:///etc/master.passwd", "http://lists.example/a", "https://u:p@lists.example/a"], olderThan: 0)
        #expect(server.requests.isEmpty)
        #expect(await store.info(["file:///etc/master.passwd"]).isEmpty)
    }

    /// The daily check finds every list on disk by its note.
    @Test func refreshFindsListsOnDisk() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        var clock = Date()
        let box = ClockBox(clock)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RuleListStore(dir: dir, fetch: { try await server.fetch($0) }, tool: Self.tool(), now: { box.now })
        await store.update([Self.a], olderThan: 0)
        await store.refreshStale()
        #expect(server.requests.count == 1)
        clock.addTimeInterval(RuleListStore.maxAge + 60)
        box.now = clock
        await store.refreshStale()
        #expect(server.requests.count == 2)
    }

    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }

    /// Earlier builds kept lists by name, and in folders per source.
    @Test func removesLegacyFiles() async throws {
        let server = Server()
        server.answers[Self.a] = (200, Self.binary)
        let (store, dir) = try make(server)
        await store.update([Self.a], olderThan: 0)
        try Self.binary.write(to: dir.appendingPathComponent("geoip-de.srs"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sagernet"), withIntermediateDirectories: true)
        try Self.binary.write(to: dir.appendingPathComponent("sagernet/geoip-cn.srs"))
        await store.removeLegacy()
        let key = RuleLists.fileKey(Self.a)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == [key + ".json", key + ".srs"])
    }
}

@Suite struct ControllerRuleListTests {
    actor Calls {
        var fetched = 0
        func add() { fetched += 1 }
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    /// A start fetches the profile's lists while the network is open,
    /// before anything is blocked, and reads them from disk.
    @Test func startFetchesFirst() async throws {
        let calls = Calls()
        let world = Box<World?>(nil)
        let local = Dictionary(uniqueKeysWithValues: Profile.domesticLists.map { ($0.url, SingBoxConfig.LocalList(path: "/r/\($0.name).srs", matchesNames: false)) })
        let h = Harness(ruleLists: .init(local: { _ in local }, fetchMissing: { _ in
            await calls.add()
            if let w = world.value { await w.set { $0.log.append("lists.fetch") } }
        }))
        world.value = h.world
        try await h.controller.start()
        let log = await h.world.log
        let fetch = try #require(log.firstIndex(of: "lists.fetch"))
        #expect(fetch < log.firstIndex(of: "pf.load(blocked)")!)
        let config = String(decoding: try #require(await h.world.lastConfig), as: UTF8.self)
        #expect(config.contains("/r/geoip-cn.srs"))
        #expect(await calls.fetched == 1)
    }

    /// A running VPN does not switch to a profile whose list is not there.
    @Test func noSwitchWithoutTheLists() async throws {
        let h = Harness(ruleLists: .init(local: { _ in [:] }, fetchMissing: { _ in }))
        var p = await h.controller.profile
        // Started without lists in use, then a profile that needs one.
        let saved = p.routes
        p.routes = []
        try await h.controller.update(profile: p)
        try await h.controller.start()
        p.routes = saved
        await #expect(throws: Controller.CommandError.self) { try await h.controller.update(profile: p) }
        #expect(await h.controller.status.phase == .connected)
    }
}
