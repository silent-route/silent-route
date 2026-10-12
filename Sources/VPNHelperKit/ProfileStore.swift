import Foundation
import VPNCore

/// The profile library on disk: root-owned, 0600 (it holds tunnel passwords).
public struct LibraryStore: Sendable {
    public let url: URL
    /// The single profile.json of helpers before profiles had names.
    public let legacyURL: URL?

    public init(url: URL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    /// Never loses data: a file that exists but cannot be read (damaged, or
    /// written by a newer version) is moved aside, not overwritten later.
    public func load() -> ProfileLibrary { loadReporting().library }

    /// `setAside`: where an unreadable library file was moved, if it was.
    public func loadReporting() -> (library: ProfileLibrary, setAside: URL?) {
        if let d = try? Data(contentsOf: url) {
            if let lib = try? JSONDecoder().decode(ProfileLibrary.self, from: d) { return (lib, nil) }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            return (migrateLegacy() ?? ProfileLibrary(), aside)
        }
        return (migrateLegacy() ?? ProfileLibrary(), nil)
    }

    private func migrateLegacy() -> ProfileLibrary? {
        guard let legacyURL, let d = try? Data(contentsOf: legacyURL),
              var p = try? JSONDecoder().decode(Profile.self, from: d) else { return nil }
        if p.name == "Profile" { p.name = "Main" }
        let lib = ProfileLibrary(profiles: [p], activeID: p.id)
        save(lib)
        try? FileManager.default.removeItem(at: legacyURL)
        return lib
    }

    public func save(_ lib: ProfileLibrary) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(lib) else { return }
        let fm = FileManager.default
        // The previous version stays next to it: one bad save is recoverable.
        let prev = url.appendingPathExtension("prev")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: prev)
            try? fm.copyItem(at: url, to: prev)
        }
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        _ = try? fm.replaceItemAt(url, withItemAt: tmp)
    }
}

/// Owns the library and keeps the controller's profile in step with the
/// active one. Every change is saved before it returns.
public actor ProfileManager {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    let controller: Controller
    let store: LibraryStore
    public private(set) var library: ProfileLibrary
    /// Bumped on every change, so clients polling status know to refetch.
    public private(set) var revision = 0

    public init(controller: Controller, store: LibraryStore, library: ProfileLibrary) {
        self.controller = controller
        self.store = store
        self.library = library
    }

    /// Changes are re-applied to the library as it is after the controller
    /// call: actor methods interleave at `await`, and a change made by a
    /// concurrent request in the meantime must not be lost.
    private func commit(_ change: (inout ProfileLibrary) throws(ProfileLibrary.Failure) -> Void) {
        var lib = library
        do { try change(&lib) } catch { return }
        library = lib
        revision += 1
        store.save(lib)
    }

    /// Create or edit. Editing the active profile while connected applies it
    /// at once (sing-box restarts behind the kill switch); an invalid edit is
    /// refused then and nothing changes.
    public func save(_ p: Profile) async throws(Failure) {
        var lib = library
        do { try lib.upsert(p) } catch { throw Failure(error.description) }
        if lib.activeID == p.id, let saved = lib.active {
            do { try await controller.update(profile: saved) } catch { throw Failure(error.description) }
        }
        commit { lib throws(ProfileLibrary.Failure) in try lib.upsert(p) }
    }

    public func delete(_ id: Profile.ID) async throws(Failure) {
        var lib = library
        let wasActive = lib.activeID == id
        if wasActive, await controller.status.phase != .off {
            throw Failure("This profile is in use. Disconnect or switch to another profile first.")
        }
        do { try lib.remove(id) } catch { throw Failure(error.description) }
        if wasActive {
            do { try await controller.update(profile: lib.active ?? Profile()) } catch { throw Failure(error.description) }
        }
        let next = lib.activeID
        commit { lib throws(ProfileLibrary.Failure) in
            try lib.remove(id)
            if wasActive { lib.activeID = next }
        }
    }

    /// Make another profile active. Connected: switches over right away,
    /// traffic blocked during the swap.
    public func activate(_ id: Profile.ID) async throws(Failure) {
        guard let p = library.profile(id) else { throw Failure("No such profile") }
        guard library.activeID != id else { return }
        do { try await controller.update(profile: p) } catch { throw Failure(error.description) }
        commit { lib in lib.activeID = id }
    }
}
