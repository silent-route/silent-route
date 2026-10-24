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
