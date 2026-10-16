import Foundation
import Testing
@testable import VPNCore
@testable import VPNHelperKit

@Suite struct SessionLogTests {
    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sessionlog-\(UUID().uuidString)")
        return d
    }

    @Test func aSessionIsOneFileFromOnToOff() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(dir: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.setOwner(501)
        log.handle(.began(profile: "Home", resumed: false), at: t0)
        log.write("the Mac woke from sleep", at: t0.addingTimeInterval(5))
        let out = try #require(log.engineOutput())
        out.write(Data("WARN sing-box says something\n".utf8))
        try out.close()
        log.handle(.note("connected"), at: t0.addingTimeInterval(6))
        #expect(log.sessions(of: 501).first?.ended == nil, "still going")
        log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(60))
        // Outside a session nothing is written anywhere.
        log.write("ignored")
        #expect(log.engineOutput() == nil)

        let sessions = log.sessions(of: 501)
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.profile == "Home")
        #expect(s.started == t0)
        #expect(s.ended != nil)
        let text = try #require(log.text(of: s.id, for: 501))
        for line in ["profile: Home", "VPN turned on", "woke from sleep", "sing-box says something", "connected",
                     "session ended: turned off"] {
            #expect(text.contains(line), "missing \(line)")
        }
        #expect(!text.contains("ignored"))
        // Root only.
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        let filePerms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("501").appendingPathComponent(s.id).path)[.posixPermissions] as? Int
        #expect(dirPerms == 0o700 && filePerms == 0o600)
    }

    @Test func onlyTheLastSessionsAreKept() {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(dir: dir, keep: 3)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 {
            log.setOwner(501)
            log.handle(.began(profile: "P\(i)", resumed: false), at: t0.addingTimeInterval(Double(i) * 100))
            log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(Double(i) * 100 + 10))
        }
        #expect(log.sessions(of: 501).map(\.profile) == ["P4", "P3", "P2"])
    }

    @Test func aGrowingFileKeepsItsStartAndItsLatestLines() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(dir: dir, maxBytes: 20_000, headBytes: 4_000)
        log.setOwner(501)
        log.handle(.began(profile: "Big", resumed: false))
        let out = try #require(log.engineOutput())
        for i in 0..<1000 { out.write(Data("line \(i) \(String(repeating: "x", count: 40))\n".utf8)) }
        log.enforceLimit()
        out.write(Data("the latest line\n".utf8))
        try out.close()
        let id = try #require(log.sessions(of: 501).first?.id)
        let text = try #require(log.text(of: id, for: 501))
        #expect(text.utf8.count < 6_000)
        #expect(text.hasPrefix("# Silent Route session · profile: Big"))
        #expect(text.contains("left out to keep the file small"))
        #expect(text.hasSuffix("the latest line\n"), "writers append after the cut, with no gap")
    }

    /// Each user sees their own sessions only, even knowing another's name.
    @Test func sessionsBelongToWhoeverTurnedTheVPNOn() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SessionLog(dir: dir)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        log.setOwner(501)
        log.handle(.began(profile: "Mine", resumed: false), at: t0)
        log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(10))
        log.setOwner(502)
        log.handle(.began(profile: "Theirs", resumed: false), at: t0.addingTimeInterval(100))
        // The helper restarts mid-session: the session stays with its owner.
        log.handle(.ended(reason: "the helper stopped"), at: t0.addingTimeInterval(110))
        log.handle(.began(profile: "Theirs", resumed: true), at: t0.addingTimeInterval(120))
        log.handle(.ended(reason: "turned off"), at: t0.addingTimeInterval(130))

        #expect(log.sessions(of: 501).map(\.profile) == ["Mine"])
        #expect(log.sessions(of: 502).map(\.profile) == ["Theirs", "Theirs"])
        #expect(log.sessions(of: 503).isEmpty)
        let mine = try #require(log.sessions(of: 501).first?.id)
        #expect(log.text(of: mine, for: 501) != nil)
        #expect(log.text(of: mine, for: 502) == nil, "another user cannot read it")
    }

    @Test func onlyOurOwnFileNamesCanBeRead() {
        let log = SessionLog(dir: Self.tempDir())
        for bad in ["../../etc/passwd", "/etc/passwd", "state.json", "2026-10-14_12-00-00.log/../x", ""] {
            #expect(log.text(of: bad, for: 501) == nil, "\(bad)")
        }
        #expect(SessionLog.isSessionFile("2026-10-14_12-00-00.log"))
        #expect(SessionLog.isSessionFile("2026-10-14_12-00-00_2.log"))
    }
}
