import Foundation
import Testing
@testable import SilentRouteUI
@testable import VPNCore

@Suite struct LogStoreTests {
    @Test func readsSessionsAndAppliesTheUsersChoices() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ls-\(UUID().uuidString)/Silent Route")
        defer { try? fm.removeItem(at: base.deletingLastPathComponent()) }
        let store = LogStore(base: base)

        // Defaults: out of backups, out of Spotlight.
        store.apply(includeInBackups: false, indexable: false)
        let unindexed = base.appendingPathComponent(SessionLogFormat.unindexed)
        #expect(fm.fileExists(atPath: unindexed.path))
        #expect(try base.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try "# Silent Route session · profile: Home\nx [helper] session ended: turned off\n"
            .write(to: unindexed.appendingPathComponent(SessionLogFormat.fileName(for: t0)), atomically: true, encoding: .utf8)
        try "# Silent Route session · profile: Work\nx [helper] connected\n"
            .write(to: unindexed.appendingPathComponent(SessionLogFormat.fileName(for: t0.addingTimeInterval(60))), atomically: true, encoding: .utf8)
        try "not ours".write(to: unindexed.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let sessions = store.sessions()
        #expect(sessions.map(\.profile) == ["Work", "Home"])
        #expect(sessions[0].ended == nil, "still going")
        #expect(sessions[1].ended != nil)
        #expect(store.text(of: sessions[1].id)?.contains("turned off") == true)
        #expect(store.text(of: "../notes.txt") == nil)

        // A large one: the page gets its two ends, a saved copy all of it.
        let big = "# Silent Route session · profile: Home\n" + (0..<20000).map { "line \($0)\n" }.joined()
        try big.write(to: unindexed.appendingPathComponent(SessionLogFormat.fileName(for: t0.addingTimeInterval(-60))),
                      atomically: true, encoding: .utf8)
        let id = try #require(store.sessions().last?.id)
        let shown = try #require(store.text(of: id, tail: 1000))
        #expect(shown.contains("not shown") && !shown.contains("line 15000\n"))
        #expect(store.text(of: id, tail: .max) == big)

        // Switching both on: the folder is renamed (sessions kept), backups allowed.
        store.apply(includeInBackups: true, indexable: true)
        #expect(!fm.fileExists(atPath: unindexed.path))
        #expect(store.folder?.lastPathComponent == SessionLogFormat.indexed)
        #expect(store.sessions().count == 3)
        #expect(try base.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
    }
}
