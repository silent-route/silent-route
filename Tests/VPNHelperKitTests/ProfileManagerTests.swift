import Foundation
import Testing
@testable import VPNCore
@testable import VPNHelperKit

@Suite struct ProfileManagerTests {
    static func tempStore() -> LibraryStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sb-lib-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LibraryStore(url: dir.appendingPathComponent("profiles.json"),
                            legacyURL: dir.appendingPathComponent("profile.json"))
    }

    /// The harness's profile as "Home" plus a second, valid "Work".
    static func setUp() async throws -> (Harness, ProfileManager, home: Profile, work: Profile) {
        let h = Harness()
        var home = await h.controller.profile
        home.name = "Home"
        try await h.controller.update(profile: home)   // as the daemon starts it: from the library
        var work = Profile.example(name: "Work", tunnels: [Harness.h2b])
        work.killSwitch = .whileConnected
        let lib = ProfileLibrary(profiles: [home, work], activeID: home.id)
        let m = ProfileManager(controller: h.controller, store: tempStore(), library: lib)
        return (h, m, home, work)
    }

    @Test func activatingWhileConnectedSwitchesUnderTheKillSwitch() async throws {
        let (h, m, _, work) = try await Self.setUp()
        try await h.controller.start()
        try await m.activate(work.id)
        #expect(await h.wait(for: .connected))
        #expect(await h.controller.profile.id == work.id)
        #expect(await m.library.activeID == work.id)
        let log = await h.world.log
        // Never unblocked during the swap.
        #expect(!log.contains("pf.release") && !log.contains("pf.flush"))
        #expect(log.filter { $0.hasPrefix("engine.launch") }.count == 2)
    }

    @Test func theProfileInUseCannotBeDeleted() async throws {
        let (h, m, home, work) = try await Self.setUp()
        try await h.controller.start()
        await #expect(throws: ProfileManager.Failure.self) { try await m.delete(home.id) }
        try await m.delete(work.id)
        #expect(await m.library.profiles.map(\.id) == [home.id])
        await h.controller.stop()
        try await m.delete(home.id)
        #expect(await m.library.profiles.isEmpty)
        #expect(await m.library.activeID == nil)
    }

    @Test func anInvalidEditOfTheRunningProfileIsRefusedAndNothingChanges() async throws {
        let (h, m, home, _) = try await Self.setUp()
        try await h.controller.start()
        var bad = home
        bad.routes.append(Route(name: "empty", conditions: Conditions(), target: .direct))
        await #expect(throws: ProfileManager.Failure.self) { try await m.save(bad) }
        #expect(await m.library.profile(home.id) == home)
        #expect(await h.controller.profile == home)
        // While off the same draft is kept: it is being edited.
        await h.controller.stop()
        try await m.save(bad)
        #expect(await m.library.profile(home.id) == bad)
    }

    @Test func editsOfOtherProfilesDoNotTouchTheConnection() async throws {
        let (h, m, _, work) = try await Self.setUp()
        try await h.controller.start()
        var w = work
        w.name = "Office"
        try await m.save(w)
        #expect(await h.world.log.filter { $0.hasPrefix("engine.launch") }.count == 1)
        #expect(await m.library.profile(work.id)?.name == "Office")
    }

    @Test func concurrentEditsAreNotLost() async throws {
        let (_, m, _, _) = try await Self.setUp()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask { try? await m.save(Profile(name: "P\(i)")) }
            }
        }
        #expect(await m.library.profiles.count == 22)
    }

    @Test func savedAndReloaded() async throws {
        let store = Self.tempStore()
        var lib = ProfileLibrary()
        try lib.upsert(Profile.example(name: "Home", tunnels: [Harness.h2]))
        store.save(lib)
        #expect(store.load() == lib)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func theOldSingleProfileIsMigrated() throws {
        let store = Self.tempStore()
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Profile.example(tunnels: [Harness.h2]))) as! [String: Any]
        old["id"] = nil
        old["name"] = nil
        try JSONSerialization.data(withJSONObject: old).write(to: store.legacyURL!)
        let lib = store.load()
        #expect(lib.profiles.count == 1)
        #expect(lib.profiles[0].name == "Main")
        #expect(lib.activeID == lib.profiles[0].id)
        #expect(!FileManager.default.fileExists(atPath: store.legacyURL!.path))
        #expect(store.load() == lib)   // and the id is stable from now on
    }

    /// A file this version cannot read (damaged, or from a newer version) is
    /// kept aside and never overwritten.
    @Test func anUnreadableLibraryIsSetAsideNotLost() throws {
        let store = Self.tempStore()
        let junk = Data("{\"profiles\": \"from the future\"}".utf8)
        try junk.write(to: store.url)
        let (lib, aside) = store.loadReporting()
        #expect(lib.profiles.isEmpty)
        let kept = try #require(aside)
        #expect(try Data(contentsOf: kept) == junk)
        // Saving afterwards does not touch the set-aside file.
        var fresh = ProfileLibrary()
        try fresh.upsert(Profile(name: "New"))
        store.save(fresh)
        #expect(try Data(contentsOf: kept) == junk)
    }

    @Test func eachSaveKeepsThePreviousVersion() throws {
        let store = Self.tempStore()
        var lib = ProfileLibrary()
        try lib.upsert(Profile(name: "One"))
        store.save(lib)
        try lib.upsert(Profile(name: "Two"))
        store.save(lib)
        let prev = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: store.url.appendingPathExtension("prev")))
        #expect(prev.profiles.map(\.name) == ["One"])
        #expect(store.load().profiles.map(\.name) == ["One", "Two"])
    }
}
