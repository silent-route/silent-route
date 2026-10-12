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
