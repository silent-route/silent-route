import Foundation
import Testing
@testable import VPNCore
@testable import VPNHelperKit

/// The helper writes into a user's home; here the "user" is whoever runs
/// the tests, with a temporary folder as their home.
@Suite struct SessionLogTests {
    struct Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        var home: URL { root.appendingPathComponent("home") }
        var system: URL { root.appendingPathComponent("system") }
        var sessions: URL { home.appendingPathComponent("Library/Logs/Silent Route/\(SessionLogFormat.unindexed)") }
        let me = getuid()
        init() { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        func log(keep: Int = 30, maxBytes: Int = 5_000_000, headBytes: Int = 1_000_000,
                 asked: Asked? = nil) -> SessionLog {
            let h = home.path, g = getgid()
            return SessionLog(system: system, home: { uid in asked?.add(uid); return (h, g) },
                              keep: keep, maxBytes: maxBytes, headBytes: headBytes)
        }
        func files() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).sorted()
        }
        func text(_ name: String) -> String { (try? String(contentsOf: sessions.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var uids: [uid_t] = []
        func add(_ u: uid_t) { lock.withLock { uids.append(u) } }
        var all: [uid_t] { lock.withLock { uids } }
    }

    @Test func aSessionIsOneFileInTheUsersOwnFolder() throws {
        let env = Env()
        defer { env.cleanup() }
        let log = env.log()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.setOwner(env.me)
        log.handle(.began(profile: "Home", resumed: false), at: t0)
        log.write("the Mac woke from sleep", at: t0.addingTimeInterval(5))
        let out = try #require(log.engineOutput())
        out.write(Data("WARN sing-box says something\n".utf8))
        try out.close()
        log.handle(.note("connected"), at: t0.addingTimeInterval(6))
        log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(60))
        log.write("ignored")
        #expect(log.engineOutput() == nil, "outside a session nothing is written")

        let files = env.files()
        #expect(files == [SessionLogFormat.fileName(for: t0)])
        let text = env.text(files[0])
        for line in ["profile: Home", "VPN turned on", "woke from sleep", "sing-box says something", "connected",
                     "session ended: turned off"] {
            #expect(text.contains(line), "missing \(line)")
        }
        #expect(!text.contains("ignored"))
        // Private to the user.
        let fm = FileManager.default
        let base = env.home.appendingPathComponent("Library/Logs/Silent Route")
        #expect(try fm.attributesOfItem(atPath: base.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: env.sessions.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: env.sessions.appendingPathComponent(files[0]).path)[.posixPermissions] as? Int == 0o600)
        // And the app reads it back the same way.
        let store = LogStoreReader(base: base)
        #expect(store.sessionNames() == files)
    }

    @Test func onlyTheLastSessionsAreKept() {
        let env = Env()
        defer { env.cleanup() }
        let log = env.log(keep: 3)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 {
            log.setOwner(env.me)
            log.handle(.began(profile: "P\(i)", resumed: false), at: t0.addingTimeInterval(Double(i) * 100))
            log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(Double(i) * 100 + 10))
        }
        #expect(env.files().count == 3)
        #expect(env.files().map(env.text).allSatisfy { !$0.contains("P0") && !$0.contains("P1") })
    }

    @Test func aGrowingFileKeepsItsStartAndItsLatestLines() throws {
        let env = Env()
        defer { env.cleanup() }
        let log = env.log(maxBytes: 20_000, headBytes: 4_000)
        log.setOwner(env.me)
        log.handle(.began(profile: "Big", resumed: false))
        let out = try #require(log.engineOutput())
        for i in 0..<1000 { out.write(Data("line \(i) \(String(repeating: "x", count: 40))\n".utf8)) }
        log.enforceLimit()
        out.write(Data("the latest line\n".utf8))
        try out.close()
        let text = env.text(env.files()[0])
        #expect(text.utf8.count < 6_000)
        #expect(text.hasPrefix("# Silent Route session · profile: Big"))
        #expect(text.contains("left out to keep the file small"))
        #expect(text.hasSuffix("the latest line\n"), "writers append after the cut, with no gap")
    }

    /// The folder is the user's; a symbolic link anywhere on the way must not
    /// lead the helper (root) to write somewhere else.
    @Test(arguments: ["Library", "Library/Logs", "Library/Logs/Silent Route", "Library/Logs/Silent Route/Sessions.noindex"])
    func aLinkOnTheWayIsNotFollowed(_ linked: String) throws {
        let env = Env()
        defer { env.cleanup() }
        let fm = FileManager.default
        let elsewhere = env.root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = env.home.appendingPathComponent(linked)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: elsewhere)
        let log = env.log()
        log.setOwner(env.me)
        log.handle(.began(profile: "X", resumed: false))
        #expect(log.engineOutput() == nil, "no session file anywhere")
        let leaked = fm.enumerator(atPath: elsewhere.path)?.allObjects ?? []
        #expect(leaked.isEmpty, "nothing written through the link: \(leaked)")
    }

    @Test func theUsersChoiceOfFolderNameIsKept() {
        let env = Env()
        defer { env.cleanup() }
        let indexed = env.home.appendingPathComponent("Library/Logs/Silent Route/\(SessionLogFormat.indexed)")
        try? FileManager.default.createDirectory(at: indexed, withIntermediateDirectories: true)
        let log = env.log()
        log.setOwner(env.me)
        log.handle(.began(profile: "X", resumed: false))
        log.handle(.ended(reason: "turned off"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: indexed.path)) ?? []).count == 1)
        #expect(!FileManager.default.fileExists(atPath: env.sessions.path))
    }

    /// A session resumed after a helper restart stays with whoever began it.
    @Test func aResumedSessionKeepsItsOwner() {
        let env = Env()
        defer { env.cleanup() }
        let asked = Asked()
        let log = env.log(asked: asked)
        log.setOwner(env.me)
        log.handle(.began(profile: "X", resumed: false))
        log.handle(.ended(reason: "the helper stopped"))
        let restarted = env.log(asked: asked)              // a new helper process
        restarted.handle(.began(profile: "X", resumed: true))
        restarted.handle(.ended(reason: "turned off"))
        #expect(asked.all == [env.me, env.me])
    }

    @Test func fileNames() {
        #expect(SessionLogFormat.isSessionFile("2026-10-14_12-00-00.log"))
        #expect(SessionLogFormat.isSessionFile("2026-10-14_12-00-00_2.log"))
        for bad in ["../x.log", "2026-10-14_12-00-00.log/../x", "notes.txt", ""] {
            #expect(!SessionLogFormat.isSessionFile(bad))
        }
    }
}

/// A minimal reader, as the app's LogStore lists files (the app module is
/// not a dependency of these tests).
struct LogStoreReader {
    let base: URL
    func sessionNames() -> [String] {
        let dir = base.appendingPathComponent(SessionLogFormat.unindexed)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter(SessionLogFormat.isSessionFile).sorted()
    }
}
