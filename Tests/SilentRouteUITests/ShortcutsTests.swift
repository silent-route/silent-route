import Testing
@testable import SilentRouteUI

@Suite struct ShortcutsTests {
    @Test func readsAndWritesItsText() {
        let s = KeyShortcut("shift+cmd+s")
        #expect(s?.shift == true && s?.command == true && s?.key == "s")
        #expect(s?.text == "shift+cmd+s")
        #expect(s?.symbols == "⇧⌘S")
        // Modifiers in any order come out in the menus' order.
        #expect(KeyShortcut("cmd+ctrl+opt+1")?.symbols == "⌃⌥⌘1")
    }

    @Test func refusesWhatWouldBeTyped() {
        #expect(KeyShortcut("s") == nil)
        #expect(KeyShortcut("shift+s") == nil)
        #expect(KeyShortcut("opt+s") == nil)
        #expect(KeyShortcut("cmd+") == nil)
        #expect(KeyShortcut("cmd+ss") == nil)
        #expect(KeyShortcut("cmd+S") != nil)
        #expect(KeyShortcut("cmd+σ") == nil)
        #expect(KeyShortcut("hyper+s") == nil)
    }

    @Test func storedChoices() {
        #expect(ShortcutAction.shortcut(from: nil, for: .saveProfile) == ShortcutAction.saveProfile.defaultShortcut)
        #expect(ShortcutAction.shortcut(from: "", for: .saveProfile) == nil)
        #expect(ShortcutAction.shortcut(from: "garbage", for: .saveProfile) == ShortcutAction.saveProfile.defaultShortcut)
        #expect(ShortcutAction.shortcut(from: "ctrl+cmd+k", for: .revertProfile)?.symbols == "⌃⌘K")
    }

    @Test func defaultsAreFreeAndDiffer() {
        for a in ShortcutAction.allCases {
            #expect(ShortcutAction.taken[a.defaultShortcut.text] == nil)
        }
        #expect(ShortcutAction.saveProfile.defaultShortcut != ShortcutAction.revertProfile.defaultShortcut)
    }
}
