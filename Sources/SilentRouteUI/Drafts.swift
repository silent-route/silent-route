import AppKit
import VPNCore

/// What is about to happen to profiles with unsaved changes.
public enum UnsavedReason: Sendable {
    case activate, connect, quit, update
}

public enum UnsavedChoice: Sendable {
    case save, discard, cancel
}

/// Unsaved changes. A profile is edited as a draft that stays in the model,
/// not in its page: the user can look at other pages and profiles and come
/// back to save or revert it. Nothing reaches the helper until Save, and
/// the VPN never takes a profile with unsaved changes without asking.
extension AppModel {
    /// The profile as the editor shows it: with its unsaved changes.
    public func edited(_ id: Profile.ID) -> Profile? { drafts[id] ?? library.profile(id) }

    public func hasUnsavedChanges(_ id: Profile.ID) -> Bool { drafts[id] != nil }

    /// Profiles with unsaved changes, in the sidebar's order.
    public var unsavedProfiles: [Profile] { library.profiles.compactMap { drafts[$0.id] } }

    /// An edit. Edited back to how it is saved: nothing is unsaved.
    public func edit(_ p: Profile) {
        guard let saved = library.profile(p.id) else { return }
        guard p != saved else { return discardDraft(p.id) }
        drafts[p.id] = p
    }

    /// The running profile must stay valid; others may be saved half-done.
    public func mustBeValid(_ id: Profile.ID) -> Bool {
        id == library.activeID && status.phase != .off && !otherUsersVPN
    }

    /// Its unsaved changes have errors, and it is in use: they cannot be saved.
    public func saveBlocked(_ id: Profile.ID) -> Bool {
        guard let d = drafts[id], mustBeValid(id) else { return false }
        return Validation.check(d).contains { $0.severity == .error }
    }

    /// Saves its unsaved changes. False when they could not be, with the
    /// reason in `saveErrors`.
    @discardableResult
    public func saveDraft(_ id: Profile.ID) async -> Bool {
        guard let draft = drafts[id] else { return true }
        guard !saveBlocked(id) else {
            saveErrors[id] = "This profile is in use: it can only be saved without errors."
            return false
        }
        if let e = await save(draft) {
            saveErrors[id] = e
            return false
        }
        saveErrors[id] = nil
        // Edited on while it was saving: that is still unsaved.
        if drafts[id] == draft { drafts[id] = nil }
        return true
    }

    public func discardDraft(_ id: Profile.ID) {
        drafts[id] = nil
        saveErrors[id] = nil
    }

    /// Before the VPN uses these profiles, an update or quitting: their
    /// unsaved changes are saved or discarded, as the user chooses. False:
    /// the user cancelled, or a save failed (the reason is shown).
    public func resolveUnsaved(_ ids: [Profile.ID], _ reason: UnsavedReason) async -> Bool {
        let unsaved = unsavedProfiles.filter { ids.contains($0.id) }
        guard !unsaved.isEmpty else { return true }
        switch askAboutUnsaved(unsaved, reason) {
        case .cancel:
            return false
        case .discard:
            for p in unsaved { discardDraft(p.id) }
            return true
        case .save:
            for p in unsaved {
                guard await saveDraft(p.id) else {
                    notice = Notice("“\(p.name)” was not saved: \(saveErrors[p.id] ?? "unknown error")", isError: true)
                    return false
                }
            }
            return true
        }
    }

    /// All of them: before an update or quitting.
    public func resolveAllUnsaved(_ reason: UnsavedReason) async -> Bool {
        await resolveUnsaved(unsavedProfiles.map(\.id), reason)
    }

    /// The library changed: a deleted profile's draft goes, and one that
    /// matches what is saved now has nothing unsaved left.
    func pruneDrafts() {
        for (id, d) in drafts {
            if let saved = library.profile(id) {
                if d == saved { drafts[id] = nil }
            } else {
                discardDraft(id)
            }
        }
        for id in saveErrors.keys where library.profile(id) == nil { saveErrors[id] = nil }
    }
}

/// macOS's question about unsaved changes: Save, Discard Changes, Cancel.
@MainActor
enum UnsavedAlert {
    static func ask(_ profiles: [Profile], _ reason: UnsavedReason) -> UnsavedChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        let what = profiles.count == 1 ? "“\(profiles[0].name)”" : "\(profiles.count) profiles"
        alert.messageText = switch reason {
        case .activate: "Save the changes to \(what) before switching to it?"
        case .connect: "Save the changes to \(what) before connecting?"
        case .quit: "Save the changes to \(what) before quitting?"
        case .update: "Save the changes to \(what) before updating?"
        }
        var info: [String] = []
        if profiles.count > 1 { info.append("Unsaved: " + profiles.map { "“\($0.name)”" }.joined(separator: ", ") + ".") }
        switch reason {
        case .activate, .connect: info.append("The VPN uses a profile as it was last saved.")
        case .update: info.append("Silent Route relaunches to update.")
        case .quit: break
        }
        info.append("Changes you discard are lost.")
        alert.informativeText = info.joined(separator: " ")
        alert.addButton(withTitle: profiles.count == 1 ? "Save" : "Save All")
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
}
