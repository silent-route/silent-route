import Foundation
import Testing
@testable import SilentRouteUI

@Suite struct UpdaterTests {
    @Test(arguments: [
        ("0.1.0", "0.0.9"),
        ("1.10.0", "1.9.2"),
        ("v0.2.0", "0.1.9"),
        ("1.0.0", "1.0.0-alpha.3"),
        ("1.0.0-beta.1", "1.0.0-alpha.9"),
        ("1.0.0-alpha.10", "1.0.0-alpha.9"),
        ("1.0.0-alpha.2", "1.0.0-alpha.1"),
        ("1.0.0-alpha.1.1", "1.0.0-alpha.1"),
    ])
    func newer(_ pair: (String, String)) {
        #expect(Updater.isNewer(pair.0, than: pair.1))
        #expect(!Updater.isNewer(pair.1, than: pair.0))
    }

    static func release(_ tag: String, pre: Bool = true, draft: Bool = false, dmg: Bool = true) -> String {
        let name = "Silent-Route-\(tag.dropFirst()).dmg"
        let assets = dmg ? """
            [{"name": "\(name)", "browser_download_url": "https://example.org/\(name)"},
             {"name": "\(name).sha256", "browser_download_url": "https://example.org/\(name).sha256"}]
            """ : "[]"
        return """
        {"tag_name": "\(tag)", "html_url": "https://example.org/\(tag)", "draft": \(draft), "prerelease": \(pre), "assets": \(assets)}
        """
    }

    /// What is published now decides: a withdrawn release is simply absent,
    /// and the newest of the rest wins, whatever order GitHub lists them in.
    @Test func theNewestPublishedReleaseIsPicked() throws {
        let list = "[" + [Self.release("v1.0.1-beta"), Self.release("v1.2.1-beta"), Self.release("v1.1.3-beta"),
                          Self.release("v1.3.0-beta", draft: true), Self.release("v1.2.5-beta", dmg: false)].joined(separator: ",") + "]"
        let r = try Updater.pick(from: Data(list.utf8), includePrereleases: true)
        #expect(r?.version == "1.2.1-beta")
        #expect(r?.image.lastPathComponent == "Silent-Route-1.2.1-beta.dmg")
    }

    @Test func preReleasesOnlyForThoseRunningOne() throws {
        let list = "[" + [Self.release("v1.2.1-beta"), Self.release("v1.0.0", pre: false)].joined(separator: ",") + "]"
        #expect(try Updater.pick(from: Data(list.utf8), includePrereleases: false)?.version == "1.0.0")
        #expect(try Updater.pick(from: Data(list.utf8), includePrereleases: true)?.version == "1.2.1-beta")
        #expect(try Updater.pick(from: Data("[]".utf8), includePrereleases: true) == nil)
    }

    /// An older helper's state, read from its own command line, so the VPN
    /// can still be turned off from an app of another version.
    @Test func olderHelperStateIsRead() {
        #expect(AppModel.legacyPhase("● Connected — profile “x”\n  since 13:20\n  kill switch: on — nothing leaves") == (.connected, true))
        #expect(AppModel.legacyPhase("○ Off\n  kill switch: off") == (.off, false))
        #expect(AppModel.legacyPhase("◌ Reconnecting (attempt 2) — traffic is blocked meanwhile\n  kill switch: on").0 == .reconnecting)
        #expect(AppModel.legacyPhase("").0 == .off)
    }

    @Test func sameVersionIsNotNewer() {
        #expect(!Updater.isNewer("1.0.0-alpha.1", than: "v1.0.0-alpha.1"))
        #expect(!Updater.isNewer("1.0", than: "1.0.0"))
    }

    @Test func prereleases() {
        #expect(Updater.isPrerelease("1.0.0-alpha.1"))
        #expect(!Updater.isPrerelease("v1.0.0"))
    }

    @MainActor @Test func defaultProfileNames() {
        #expect(AppModel.isDefaultName("New Profile"))
        #expect(AppModel.isDefaultName("New Profile 12"))
        #expect(!AppModel.isDefaultName("New Profile Copy"))
        #expect(!AppModel.isDefaultName("Home"))
    }
}

/// GitHub stand-in: answers 200 with an ETag, then 304 when asked with it.
final class FakeGitHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var asked: [String?] = []
    nonisolated(unsafe) static var body = Data("[]".utf8)
    static let etag = #"W/"abc""#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let condition = request.value(forHTTPHeaderField: "If-None-Match")
        Self.asked.append(condition)
        let notModified = condition == Self.etag
        let resp = HTTPURLResponse(url: request.url!, statusCode: notModified ? 304 : 200, httpVersion: nil,
                                   headerFields: ["ETag": Self.etag])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !notModified { client?.urlProtocol(self, didLoad: Self.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ReleaseListTests {
    @Test func asksAgainWithTheETagAndUsesTheKeptCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("releases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeGitHub.self]
        let list = ReleaseList(cache: dir, session: URLSession(configuration: cfg))
        FakeGitHub.asked = []
        FakeGitHub.body = Data("[\(UpdaterTests.release("v9.9.9"))]".utf8)

        let first = try await list.fetch("owner/repo")
        let second = try await list.fetch("owner/repo")
        #expect(FakeGitHub.asked == [nil, FakeGitHub.etag])
        #expect(first == second)
        #expect(try Updater.pick(from: second, includePrereleases: true)?.version == "9.9.9")

        // Nothing kept: no condition is sent.
        let fresh = ReleaseList(cache: nil, session: URLSession(configuration: cfg))
        _ = try await fresh.fetch("owner/repo")
        #expect(FakeGitHub.asked.last == .some(nil))
    }

    @MainActor @Test func intervalsAreTheOffered() {
        let key = Preferences.updateIntervalKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.set(5, forKey: key)
        #expect(Preferences.updateCheckHours == Preferences.defaultUpdateInterval)
        UserDefaults.standard.set(36, forKey: key)
        #expect(Preferences.updateCheckHours == 36)
    }
}

extension ReleaseListTests {
    @Test func aDamagedKeptCopyIsDroppedAndAskedAnew() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("releases-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FakeGitHub.self]
        let list = ReleaseList(cache: dir, session: URLSession(configuration: cfg))
        FakeGitHub.body = Data("[]".utf8)
        _ = try await list.fetch("owner/repo")
        try Data("not json".utf8).write(to: dir.appendingPathComponent("releases.json"))
        FakeGitHub.asked = []
        // Not modified: the damaged copy comes back and does not read…
        let damaged = try await list.fetch("owner/repo")
        #expect(throws: DecodingError.self) { try Updater.pick(from: damaged, includePrereleases: true) }
        // …so it is forgotten, and the next ask is unconditional.
        list.forget()
        _ = try await list.fetch("owner/repo")
        #expect(FakeGitHub.asked == [FakeGitHub.etag, nil])
    }
}
