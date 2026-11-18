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

    static let me: uid_t = 501
    static let other: uid_t = 502

    static func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sb-users-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A library that cannot be written (here: its folder is a file) is
    /// not reported as saved, and nothing changes in memory either.
    @Test func aSaveThatCannotBeWrittenIsAnError() async throws {
        let h = Harness()
        let dir = Self.tempDir()
        let users = dir.appendingPathComponent("users")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        try Data().write(to: users.appendingPathComponent(String(Self.other)))
        let m = ProfileManager(controller: h.controller, usersDir: users, ownerFile: dir.appendingPathComponent("owner"))
        await #expect(throws: ProfileManager.Failure.self) { try await m.save(Profile(name: "X"), by: Self.other) }
        #expect(await m.library(of: Self.other).profiles.isEmpty)
        #expect(await m.revision(of: Self.other) == 0)
    }

    /// User 501 has "Home" (active) and a second, valid "Work"; 501 turned
    /// the VPN on as the daemon would (prepareStart, then start).
    static func setUp(start: Bool = false) async throws -> (Harness, ProfileManager, home: Profile, work: Profile) {
        let h = Harness()
        var home = await h.controller.profile
        home.name = "Home"
        var work = Profile.example(name: "Work", tunnels: [Harness.h2b])
        work.killSwitch = .whileConnected
        let dir = tempDir()
        let lib = ProfileLibrary(profiles: [home, work], activeID: home.id)
        try ProfileManager.store(in: dir.appendingPathComponent("users"), for: me).save(lib)
        let m = ProfileManager(controller: h.controller, usersDir: dir.appendingPathComponent("users"),
                               ownerFile: dir.appendingPathComponent("owner"))
        if start {
            try await m.prepareStart(by: me)
            try await h.controller.start()
        }
        return (h, m, home, work)
    }

    @Test func activatingWhileConnectedSwitchesUnderTheKillSwitch() async throws {
        let (h, m, _, work) = try await Self.setUp(start: true)
        try await m.activate(work.id, by: Self.me)
        #expect(await h.wait(for: .connected))
        #expect(await h.controller.profile.id == work.id)
        #expect(await m.library(of: Self.me).activeID == work.id)
        let log = await h.world.log
        // Never unblocked during the swap.
        #expect(!log.contains("pf.release") && !log.contains("pf.flush"))
        #expect(log.filter { $0.hasPrefix("engine.launch") }.count == 2)
    }

    @Test func theProfileInUseCannotBeDeleted() async throws {
        let (h, m, home, work) = try await Self.setUp(start: true)
        await #expect(throws: ProfileManager.Failure.self) { try await m.delete(home.id, by: Self.me) }
        try await m.delete(work.id, by: Self.me)
        #expect(await m.library(of: Self.me).profiles.map(\.id) == [home.id])
        await h.controller.stop()
        try await m.delete(home.id, by: Self.me)
        #expect(await m.library(of: Self.me).profiles.isEmpty)
        #expect(await m.library(of: Self.me).activeID == nil)
    }

    @Test func anInvalidEditOfTheRunningProfileIsRefusedAndNothingChanges() async throws {
        let (h, m, home, _) = try await Self.setUp(start: true)
        var bad = home
        bad.routes.append(Route(name: "empty", conditions: Conditions(), target: .direct))
        await #expect(throws: ProfileManager.Failure.self) { try await m.save(bad, by: Self.me) }
        #expect(await m.library(of: Self.me).profile(home.id) == home)
        #expect(await h.controller.profile == home)
        // While off the same draft is kept: it is being edited.
        await h.controller.stop()
        try await m.save(bad, by: Self.me)
        #expect(await m.library(of: Self.me).profile(home.id) == bad)
    }

    @Test func editsOfOtherProfilesDoNotTouchTheConnection() async throws {
        let (h, m, _, work) = try await Self.setUp(start: true)
        var w = work
        w.name = "Office"
        try await m.save(w, by: Self.me)
        #expect(await h.world.log.filter { $0.hasPrefix("engine.launch") }.count == 1)
        #expect(await m.library(of: Self.me).profile(work.id)?.name == "Office")
    }

    @Test func concurrentEditsAreNotLost() async throws {
        let (_, m, _, _) = try await Self.setUp()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask { try? await m.save(Profile(name: "P\(i)"), by: Self.me) }
            }
        }
        #expect(await m.library(of: Self.me).profiles.count == 22)
    }

    // MARK: Each user's own

    /// A user sees and changes only their own library; nothing they do
    /// touches the VPN another user turned on.
    @Test func librariesArePerUser() async throws {
        let (h, m, home, _) = try await Self.setUp(start: true)
        #expect(await m.library(of: Self.other).profiles.isEmpty, "the other user sees none of these")
        let theirs = Profile.example(name: "Theirs", tunnels: [Harness.h2])
        try await m.save(theirs, by: Self.other)
        try await m.activate(theirs.id, by: Self.other)
        #expect(await m.library(of: Self.me).profile(theirs.id) == nil)
        #expect(await h.controller.profile.id == home.id, "the running VPN is untouched")
        #expect(await h.world.log.filter { $0.hasPrefix("engine.launch") }.count == 1)
        #expect(!(await m.controls(Self.other)))
        #expect(await m.controls(Self.me))
        #expect(await m.controls(0), "root sees everything")
        // Once it is off, the other user may turn it on with their own profile.
        await h.controller.stop()
        #expect(await m.controls(Self.other))
        try await m.prepareStart(by: Self.other)
        #expect(await h.controller.profile.id == theirs.id)
        #expect(await m.owner == Self.other)
    }

    /// Two users turning it on at the same moment: one wins, with their own
    /// profile, and is the owner.
    @Test func simultaneousStartsDoNotMixUsers() async throws {
        let (h, m, home, _) = try await Self.setUp()
        let theirs = Profile.example(name: "Theirs", tunnels: [Harness.h2])
        try await m.save(theirs, by: Self.other)
        try await m.activate(theirs.id, by: Self.other)
        async let a: Void? = try? m.start(by: Self.me)
        async let b: Void? = try? m.start(by: Self.other)
        _ = await (a, b)
        #expect(await h.wait(for: .connected))
        let owner = try #require(await m.owner)
        #expect(await h.controller.profile.id == (owner == Self.me ? home.id : theirs.id))
    }

    @Test func theOwnerIsRememberedAcrossRestarts() async throws {
        let (h, m, home, _) = try await Self.setUp(start: true)
        #expect(await m.owner == Self.me)
        // A new helper process reads the same files.
        let again = ProfileManager(controller: h.controller, usersDir: m.usersDir, ownerFile: m.ownerFile)
        #expect(await again.owner == Self.me)
        #expect(await again.ownerProfile()?.id == home.id)
    }

    @Test func librariesAreStoredPrivately() async throws {
        let (_, m, _, _) = try await Self.setUp()
        try await m.save(Profile(name: "X"), by: Self.other)
        let url = ProfileManager.store(in: m.usersDir, for: Self.other).url
        let fm = FileManager.default
        #expect(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        #expect(try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    }

    /// The shared library of an earlier version goes to one user only.
    @Test func theSharedLibraryMovesToOneUser() throws {
        let dir = Self.tempDir()
        let shared = LibraryStore(url: dir.appendingPathComponent("profiles.json"))
        var lib = ProfileLibrary()
        try lib.upsert(Profile(name: "Old"))
        try? shared.save(lib)
        let users = dir.appendingPathComponent("users")
        ProfileManager.migrateShared(from: shared, to: users, uid: Self.me)
        #expect(ProfileManager.store(in: users, for: Self.me).load().profiles.map(\.name) == ["Old"])
        #expect(!FileManager.default.fileExists(atPath: shared.url.path), "no shared copy is left")
        #expect(!FileManager.default.fileExists(atPath: shared.url.appendingPathExtension("prev").path))
        #expect(ProfileManager.store(in: users, for: Self.other).load().profiles.isEmpty)
        #expect(!ProfileManager.migrateShared(from: shared, to: users, uid: Self.me), "only once")
    }

    /// After an update from a version with one shared library, the VPN that
    /// was on resumes with the updating user's profile — not an empty one.
    @Test func aResumedVPNKeepsItsProfileAfterTheMove() async throws {
        let dir = Self.tempDir()
        let shared = LibraryStore(url: dir.appendingPathComponent("profiles.json"))
        let h = Harness()
        var home = await h.controller.profile
        home.name = "Home"
        try? shared.save(ProfileLibrary(profiles: [home], activeID: home.id))
        let users = dir.appendingPathComponent("users")
        let ownerFile = dir.appendingPathComponent("owner")
        // As the daemon does: move, then make the mover the owner.
        #expect(ProfileManager.migrateShared(from: shared, to: users, uid: Self.me))
        try Data(String(Self.me).utf8).write(to: ownerFile)
        let m = ProfileManager(controller: h.controller, usersDir: users, ownerFile: ownerFile)
        #expect(await m.owner == Self.me)
        #expect(await m.ownerProfile()?.id == home.id)
    }

    @Test func savedAndReloaded() async throws {
        let store = Self.tempStore()
        var lib = ProfileLibrary()
        try lib.upsert(Profile.example(name: "Home", tunnels: [Harness.h2]))
        try store.save(lib)
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
        try store.save(fresh)
        #expect(try Data(contentsOf: kept) == junk)
    }

    @Test func eachSaveKeepsThePreviousVersion() throws {
        let store = Self.tempStore()
        var lib = ProfileLibrary()
        try lib.upsert(Profile(name: "One"))
        try store.save(lib)
        try lib.upsert(Profile(name: "Two"))
        try store.save(lib)
        let prev = try JSONDecoder().decode(ProfileLibrary.self, from: Data(contentsOf: store.url.appendingPathExtension("prev")))
        #expect(prev.profiles.map(\.name) == ["One"])
        #expect(store.load().profiles.map(\.name) == ["One", "Two"])
    }

    /// Detailed logs: off by default; once chosen, kept by the helper for
    /// that user, and used from their next session — a session keeps the
    /// level it began with.
    @Test func detailedLogsApplyFromTheNextSession() async throws {
        let (h, m, _, work) = try await Self.setUp()
        #expect(await m.detailedLogs(of: Self.me) == false)
        try await m.start(by: Self.me)
        #expect(await h.world.logLevel == "warn")

        await m.setDetailedLogs(true, by: Self.me)
        // The running session keeps its level, also across a switch.
        try await m.activate(work.id, by: Self.me)
        #expect(await h.wait(for: .connected))
        #expect(await h.world.logLevel == "warn")

        await h.controller.stop()
        try await m.start(by: Self.me)
        #expect(await h.world.logLevel == "info")

        // Kept across a helper restart.
        let again = ProfileManager(controller: h.controller, usersDir: m.usersDir, ownerFile: m.ownerFile)
        #expect(await again.detailedLogs(of: Self.me))
        #expect(await again.detailedLogs(of: 502) == false, "another user's choice is their own")
    }
}

@Suite struct ServerLibraryTests {
    static let socks = Tunnel(name: "proxy", server: Endpoint(host: "198.51.100.9", port: 1080), proto: .proxy(Proxy(kind: .socks5)))

    /// Libraries from before have no servers; each user's are their own.
    @Test func savedPerUser() async throws {
        let dir = ProfileManagerTests.tempDir()
        let m = ProfileManager(controller: Harness().controller, usersDir: dir, ownerFile: dir.appendingPathComponent("owner"))
        try await m.saveServers([Self.socks], by: ProfileManagerTests.me)
        #expect(await m.library(of: ProfileManagerTests.me).servers == [Self.socks])
        #expect(await m.library(of: ProfileManagerTests.other).servers.isEmpty)
        let again = ProfileManager(controller: Harness().controller, usersDir: dir, ownerFile: dir.appendingPathComponent("owner"))
        #expect(await again.library(of: ProfileManagerTests.me).servers == [Self.socks])
    }

    /// A server that could not run is not kept: profiles take it as it is.
    @Test func unusableServersAreRefused() async throws {
        let dir = ProfileManagerTests.tempDir()
        let m = ProfileManager(controller: Harness().controller, usersDir: dir, ownerFile: dir.appendingPathComponent("owner"))
        var bad = Self.socks
        bad.server.host = ""
        await #expect(throws: ProfileManager.Failure.self) { try await m.saveServers([bad], by: ProfileManagerTests.me) }
        await #expect(throws: ProfileManager.Failure.self) { try await m.saveServers([Self.socks, Self.socks], by: ProfileManagerTests.me) }
        #expect(await m.library(of: ProfileManagerTests.me).servers.isEmpty)
    }

    @Test func olderLibrariesHaveNoServers() throws {
        let old = #"{"profiles": [], "activeID": null}"#
        #expect(try JSONDecoder().decode(ProfileLibrary.self, from: Data(old.utf8)).servers.isEmpty)
    }
}
