import Foundation
import Testing
@testable import SilentRouteUI
import VPNCore
import VPNIPC

/// A helper that keeps one library and records what it was asked.
private final class FakeHelper: HelperBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var lib: ProfileLibrary
    private var revision = 1
    private var log: [String] = []
    var failSaves = false

    init(_ lib: ProfileLibrary) { self.lib = lib }

    var isInstalled: Bool { true }
    var requests: [String] { lock.withLock { log } }

    struct Refused: Error, LocalizedError { var errorDescription: String? { "the disk is full" } }

    func send(_ request: IPC.Request) async throws -> IPC.Response {
        try lock.withLock {
            var withLibrary = false
            switch request {
            case .status: break
            case .getLibrary: withLibrary = true
            case .saveProfile(let p):
                log.append("save \(p.name)")
                if failSaves { throw Refused() }
                try lib.upsert(p)
                revision += 1
                withLibrary = true
            case .activateProfile(let id):
                log.append("activate \(lib.profile(id)?.name ?? "?")")
                lib.activeID = id
                revision += 1
            case .start: log.append("start")
            case .deleteProfile(let id):
                try lib.remove(id)
                revision += 1
                withLibrary = true
            default: break
            }
            return IPC.Response(status: VPNStatus(phase: .off),
                                activeProfile: lib.active.map { IPC.ProfileRef(id: $0.id, name: $0.name) },
                                libraryRevision: revision, library: withLibrary ? lib : nil)
        }
    }
}

@MainActor
@Suite struct DraftsTests {
    let home = Profile(name: "Home")
    let work = Profile(name: "Work")

    private func setUp(asking choice: UnsavedChoice = .cancel) async -> (AppModel, FakeHelper, Asked) {
        let helper = FakeHelper(ProfileLibrary(profiles: [home, work], activeID: home.id))
        let model = AppModel(backend: helper)
        let asked = Asked()
        model.askAboutUnsaved = { profiles, reason in
            asked.calls.append((profiles.map(\.name), reason))
            return choice
        }
        await model.refresh()
        await model.reloadLibrary()
        return (model, helper, asked)
    }

    final class Asked {
        var calls: [([String], UnsavedReason)] = []
    }

    private func renamed(_ p: Profile, _ name: String) -> Profile {
        var p = p
        p.name = name
        return p
    }

    @Test func anEditStaysUnsavedUntilItIsUndoneOrSaved() async {
        let (model, helper, _) = await setUp()
        model.edit(renamed(work, "Office"))
        #expect(model.hasUnsavedChanges(work.id))
        #expect(model.edited(work.id)?.name == "Office")
        #expect(model.library.profile(work.id)?.name == "Work")

        model.edit(work)
        #expect(!model.hasUnsavedChanges(work.id))

        model.edit(renamed(work, "Office"))
        #expect(await model.saveDraft(work.id))
        #expect(!model.hasUnsavedChanges(work.id))
        #expect(model.library.profile(work.id)?.name == "Office")
        #expect(helper.requests == ["save Office"])
    }

    @Test func aFailedSaveKeepsTheChangesAndSaysWhy() async {
        let (model, helper, _) = await setUp()
        helper.failSaves = true
        model.edit(renamed(work, "Office"))
        #expect(await model.saveDraft(work.id) == false)
        #expect(model.hasUnsavedChanges(work.id))
        #expect(model.saveErrors[work.id] == "the disk is full")
    }

    @Test func activatingAProfileWithUnsavedChangesAsksFirst() async {
        let (model, helper, asked) = await setUp(asking: .cancel)
        model.edit(renamed(work, "Office"))
        await model.activate(work.id)
        #expect(asked.calls.count == 1)
        #expect(asked.calls.first?.0 == ["Office"])
        #expect(asked.calls.first?.1 == .activate)
        #expect(helper.requests.isEmpty)
        #expect(model.hasUnsavedChanges(work.id))
    }

    @Test func saveThenActivate() async {
        let (model, helper, _) = await setUp(asking: .save)
        model.edit(renamed(work, "Office"))
        await model.activate(work.id)
        #expect(helper.requests == ["save Office", "activate Office"])
        #expect(!model.hasUnsavedChanges(work.id))
    }

    @Test func discardThenActivateTheSavedProfile() async {
        let (model, helper, _) = await setUp(asking: .discard)
        model.edit(renamed(work, "Office"))
        await model.activate(work.id)
        #expect(helper.requests == ["activate Work"])
        #expect(!model.hasUnsavedChanges(work.id))
    }

    @Test func aFailedSaveStopsTheActivation() async {
        let (model, helper, _) = await setUp(asking: .save)
        helper.failSaves = true
        model.edit(renamed(work, "Office"))
        await model.activate(work.id)
        #expect(helper.requests == ["save Office"])
        #expect(model.notice?.isError == true)
        #expect(model.hasUnsavedChanges(work.id))
    }

    @Test func connectingAsksOnlyAboutTheActiveProfile() async {
        let (model, helper, asked) = await setUp(asking: .cancel)
        model.edit(renamed(work, "Office"))
        await model.setOn(true)
        #expect(asked.calls.isEmpty)
        #expect(helper.requests == ["start"])

        model.edit(renamed(home, "House"))
        await model.setOn(true)
        #expect(asked.calls.map(\.1) == [.connect])
        #expect(helper.requests == ["start"])
    }

    @Test func quittingAsksAboutAllOfThem() async {
        let (model, _, asked) = await setUp(asking: .discard)
        model.edit(renamed(home, "House"))
        model.edit(renamed(work, "Office"))
        #expect(await model.resolveAllUnsaved(.quit))
        #expect(asked.calls.first?.0 == ["House", "Office"])
        #expect(model.unsavedProfiles.isEmpty)
    }

    @Test func aDeletedProfileTakesItsChangesWithIt() async {
        let (model, _, _) = await setUp()
        model.edit(renamed(work, "Office"))
        await model.delete(work.id)
        #expect(!model.hasUnsavedChanges(work.id))
        #expect(model.unsavedProfiles.isEmpty)
    }
}
