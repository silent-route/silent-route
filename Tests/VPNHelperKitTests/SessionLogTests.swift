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
        var sessions: URL { home.appendingPathComponent("Library/Logs/Silent Route/\(SessionLogFormat.unindexed)") }
        let me = getuid()
        init() { try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        func log(keep: Int = 30, maxBytes: Int = 5_000_000, headBytes: Int = 1_000_000,
                 asked: Asked? = nil) -> SessionLog {
            let h = home.path, g = getgid()
            return SessionLog(home: { uid in asked?.add(uid); return (h, g) },
                              keep: keep, maxBytes: maxBytes, headBytes: headBytes)
        }
        func files() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: sessions.path)) ?? []).sorted()
        }
        func text(_ name: String) -> String { (try? String(contentsOf: sessions.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        func cleanup() {
            // A failed test may leave a file append-only.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
            p.arguments = ["-R", "nouappnd", root.path]
            try? p.run()
            p.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        func flags(_ name: String) -> UInt32 {
            var st = stat()
            return lstat(sessions.appendingPathComponent(name).path, &st) == 0 ? st.st_flags : 0
        }
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

    @Test func theRunningFileIsAppendOnlyUntilItsSessionEnds() throws {
        let env = Env()
        defer { env.cleanup() }
        let log = env.log()
        log.setOwner(env.me)
        log.handle(.began(profile: "Home", resumed: false))
        let name = try #require(env.files().first)
        #expect(log.currentFile(of: env.me) == name)
        #expect(log.currentFile(of: env.me + 1) == nil, "only its owner is told")
        #expect(env.flags(name) & UInt32(UF_APPEND) != 0)
        let path = env.sessions.appendingPathComponent(name).path
        // What a cleaning app does: cut it, or delete it.
        #expect(truncate(path, 0) != 0 && errno == EPERM)
        #expect(unlink(path) != 0 && errno == EPERM)
        log.write("still written")
        log.handle(.ended(reason: "turned off"))
        #expect(env.flags(name) & UInt32(UF_APPEND) == 0)
        #expect(log.currentFile(of: env.me) == nil)
        #expect(env.text(name).hasPrefix("# Silent Route session") && env.text(name).contains("still written"))
    }

    @Test func emptiedFilesGoAndLeftoverFlagsAreLifted() throws {
        let env = Env()
        defer { env.cleanup() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = env.log()
        first.setOwner(env.me)
        first.handle(.began(profile: "A", resumed: false), at: t0)
        first.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(10))
        // A helper that stopped mid-session: its file stays append-only.
        let crashed = env.log()
        crashed.setOwner(env.me)
        crashed.handle(.began(profile: "B", resumed: false), at: t0.addingTimeInterval(100))
        let left = SessionLogFormat.fileName(for: t0.addingTimeInterval(100))
        // A cleaning app emptied an old one.
        let emptied = SessionLogFormat.fileName(for: t0.addingTimeInterval(-100))
        try Data().write(to: env.sessions.appendingPathComponent(emptied))

        let next = env.log()
        next.setOwner(env.me)
        next.handle(.began(profile: "C", resumed: true), at: t0.addingTimeInterval(200))
        #expect(!env.files().contains(emptied))
        #expect(env.files().count == 3)
        #expect(env.flags(left) & UInt32(UF_APPEND) == 0, "lifted, so the user can delete it")
        next.handle(.ended(reason: "turned off"))
        _ = crashed
    }

    @Test func theUsersNumberIsKeptAndZeroWritesNothing() throws {
        let env = Env()
        defer { env.cleanup() }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let log = env.log()
        for i in 0..<5 {
            log.setOwner(env.me, keep: 10)
            log.handle(.began(profile: "P\(i)", resumed: false), at: t0.addingTimeInterval(Double(i) * 100))
            log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(Double(i) * 100 + 10))
        }
        #expect(env.files().count == 5)
        // Fewer chosen with the VPN off: older ones go at once.
        log.setKeep(2, for: env.me)
        #expect(env.files().count == 2)
        // While a session runs it counts, and stays.
        log.setOwner(env.me, keep: 2)
        log.handle(.began(profile: "Now", resumed: false), at: t0.addingTimeInterval(1000))
        log.setKeep(1, for: env.me)
        #expect(env.files() == [SessionLogFormat.fileName(for: t0.addingTimeInterval(1000))])
        log.handle(.ended(reason: "turned off"))
        // None: nothing written, sing-box's output discarded, the rest gone.
        log.setOwner(env.me, keep: 0)
        log.handle(.began(profile: "Off", resumed: false), at: t0.addingTimeInterval(2000))
        let out = try #require(log.engineOutput())
        out.write(Data("discarded\n".utf8))
        #expect(env.files().isEmpty)
        #expect(log.currentFile(of: env.me) == nil)
        log.handle(.ended(reason: "turned off"))
        #expect(log.engineOutput() == nil)
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

    /// A session resumed after a helper restart is logged for the owner the
    /// helper passes on (it keeps the owner in its own root-only folder);
    /// with no owner given, nothing is written anywhere.
    @Test func aResumedSessionIsLoggedForTheOwnerGiven() {
        let env = Env()
        defer { env.cleanup() }
        let asked = Asked()
        let restarted = env.log(asked: asked)              // a new helper process
        restarted.handle(.began(profile: "X", resumed: true))
        #expect(restarted.engineOutput() == nil, "no owner, no file")
        restarted.setOwner(env.me)
        restarted.handle(.began(profile: "X", resumed: true))
        restarted.handle(.ended(reason: "turned off"))
        #expect(asked.all == [env.me])
        #expect(env.files().count == 1)
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

/// The uninstaller's removal of a user's logs (as root, in a folder the
/// user controls).
@Suite struct SafeRemoveTests {
    @Test func removesTheLogsAndNothingElse() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let logs = home.appendingPathComponent("Library/Logs/Silent Route/Sessions.noindex")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: logs.appendingPathComponent("a.log"))
        // A link inside points elsewhere: the link goes, its target stays.
        let elsewhere = root.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("keep.txt"))
        try fm.createSymbolicLink(at: logs.appendingPathComponent("link"), withDestinationURL: elsewhere)
        SafeRemove.userLogs(home: home.path, uid: getuid())
        #expect(!fm.fileExists(atPath: home.appendingPathComponent("Library/Logs/Silent Route").path))
        #expect(fm.fileExists(atPath: home.appendingPathComponent("Library/Logs").path))
        #expect(fm.fileExists(atPath: elsewhere.appendingPathComponent("keep.txt").path))
    }

    /// ~/Library/Logs swapped for a link: nothing is removed through it.
    @Test func aLinkOnTheWayIsNotFollowed() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let target = root.appendingPathComponent("target")
        try fm.createDirectory(at: target.appendingPathComponent("Silent Route"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Logs"), withDestinationURL: target)
        SafeRemove.userLogs(home: home.path, uid: getuid())
        #expect(fm.fileExists(atPath: target.appendingPathComponent("Silent Route").path))
    }
}
