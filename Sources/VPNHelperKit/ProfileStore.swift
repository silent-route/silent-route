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
        // The old file goes only once the new one is written.
        guard (try? save(lib)) != nil else { return lib }
        try? FileManager.default.removeItem(at: legacyURL)
        return lib
    }

    public struct SaveError: Error, CustomStringConvertible {
        public var description: String
    }

    /// Written in full or not at all; throws when it could not be written
    /// (a full disk), so nobody is told a change was saved when it was not.
    public func save(_ lib: ProfileLibrary) throws(SaveError) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(lib) else { throw SaveError(description: "the profiles could not be encoded") }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // The previous version stays next to it: one bad save is recoverable.
        let prev = url.appendingPathExtension("prev")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: prev)
            try? fm.copyItem(at: url, to: prev)
        }
        let tmp = url.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
            throw SaveError(description: "the profiles could not be written (is the disk full?)")
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw SaveError(description: "the profiles could not be saved: \(error.localizedDescription)")
        }
    }
}

/// Every user's own profile library, and whose profile the VPN runs.
///
/// Profiles hold server passwords: each macOS user has their own library
/// (`users/<uid>/profiles.json`, root only), and a request sees and changes
/// only the library of the user who sent it. The VPN itself is one for the
/// whole Mac; its owner is the user who turned it on, and only the owner's
/// requests touch the running configuration. Every change is saved before
/// it returns.
public actor ProfileManager {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ d: String) { description = d }
    }

    let controller: Controller
    nonisolated let usersDir: URL
    nonisolated let ownerFile: URL
    private var libraries: [uid_t: ProfileLibrary] = [:]
    private var revisions: [uid_t: Int] = [:]
    /// The user whose profile the VPN runs; remembered across helper
    /// restarts. Nil before anyone turned it on.
    public private(set) var owner: uid_t?
    /// A start is under way: a second one, from anyone, waits its turn.
    private var starting = false

    public init(controller: Controller, usersDir: URL, ownerFile: URL) {
        self.controller = controller
        self.usersDir = usersDir
        self.ownerFile = ownerFile
        owner = (try? String(contentsOf: ownerFile, encoding: .utf8))
            .flatMap { uid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    public static func store(in usersDir: URL, for uid: uid_t) -> LibraryStore {
        LibraryStore(url: usersDir.appendingPathComponent(String(uid)).appendingPathComponent("profiles.json"))
    }

    /// One user's library (loaded on first use).
    public func library(of uid: uid_t) -> ProfileLibrary {
        if let lib = libraries[uid] { return lib }
        let (lib, setAside) = Self.store(in: usersDir, for: uid).loadReporting()
        if let setAside {
            fputs("profiles of user \(uid) could not be read; kept as \(setAside.lastPathComponent)\n", stderr)
        }
        libraries[uid] = lib
        return lib
    }

    /// The lists any user's profiles use.
    public func listsInUse() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: usersDir.path)) ?? []
        var urls: Set<String> = []
        for uid in names.compactMap(uid_t.init) {
            for p in library(of: uid).profiles { urls.formUnion(RuleLists.urls(p)) }
        }
        return urls
    }

    /// Bumped on every change of a user's library, so their clients refetch.
    public func revision(of uid: uid_t) -> Int { revisions[uid, default: 0] }

    /// The profile the VPN should run now: the owner's active one.
    public func ownerProfile() -> Profile? {
        owner.flatMap { library(of: $0).active }
    }

    /// Whether this user's requests may see and steer the running VPN: its
    /// owner, root, or anyone while it is off.
    public func controls(_ uid: uid_t) async -> Bool {
        if uid == 0 || owner == uid { return true }
        return await controller.status.phase == .off
    }

    /// Whether a change to this user's active profile must reach the
    /// running VPN.
    private func drives(_ uid: uid_t) async -> Bool {
        guard owner == uid else { return false }
        return await controller.status.phase != .off
    }

    private func setOwner(_ uid: uid_t) {
        owner = uid
        try? FileManager.default.createDirectory(at: ownerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(uid).utf8).write(to: ownerFile)
    }

    /// Changes are re-applied to the library as it is after the controller
    /// call: actor methods interleave at `await`, and a change made by a
    /// concurrent request in the meantime must not be lost.
    /// Saved to disk first: if that fails, nothing changes and the request
    /// says why.
    private func commit(_ uid: uid_t, _ change: (inout ProfileLibrary) throws(ProfileLibrary.Failure) -> Void) throws(Failure) {
        var lib = library(of: uid)
        // Checked before the await, but the library may have changed since.
        do { try change(&lib) } catch { throw Failure(error.description) }
        let store = Self.store(in: usersDir, for: uid)
        try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do { try store.save(lib) } catch { throw Failure(error.description) }
        libraries[uid] = lib
        revisions[uid, default: 0] += 1
    }

    // MARK: Per-user settings the helper applies

    /// Each user's log settings, as read from their settings.json.
    private var settings: [uid_t: LogSettings] = [:]

    struct LogSettings: Codable {
        var detailedLogs: Bool?
        var keptSessions: Int?
    }

    private nonisolated func settingsURL(_ uid: uid_t) -> URL {
        usersDir.appendingPathComponent(String(uid)).appendingPathComponent("settings.json")
    }

    private func logSettings(of uid: uid_t) -> LogSettings {
        if let s = settings[uid] { return s }
        let s = (try? Data(contentsOf: settingsURL(uid))).flatMap { try? JSONDecoder().decode(LogSettings.self, from: $0) }
            ?? LogSettings()
        settings[uid] = s
        return s
    }

    private func save(_ s: LogSettings, of uid: uid_t) {
        settings[uid] = s
        let url = settingsURL(uid)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// Whether this user's sessions log every connection.
    public func detailedLogs(of uid: uid_t) -> Bool { logSettings(of: uid).detailedLogs ?? false }

    /// Takes effect from this user's next session: a session keeps the
    /// level it began with, so one log file has one level.
    public func setDetailedLogs(_ on: Bool, by uid: uid_t) {
        var s = logSettings(of: uid)
        s.detailedLogs = on
        save(s, of: uid)
    }

    /// How many of this user's sessions are kept, the running one included.
    public func keptSessions(of uid: uid_t) -> Int {
        logSettings(of: uid).keptSessions.map(Self.clampKept) ?? SessionLogFormat.defaultKept
    }

    /// Returns the number kept, within `keptSessionsRange`.
    @discardableResult
    public func setKeptSessions(_ n: Int, by uid: uid_t) -> Int {
        var s = logSettings(of: uid)
        s.keptSessions = Self.clampKept(n)
        save(s, of: uid)
        return s.keptSessions!
    }

    static func clampKept(_ n: Int) -> Int { min(max(n, SessionLogFormat.keptRange.lowerBound), SessionLogFormat.keptRange.upperBound) }

    /// The session's sing-box log level: every connection, or problems only.
    public func logLevel(of uid: uid_t) -> String { detailedLogs(of: uid) ? "info" : "warn" }

    /// Turns the VPN on with this user's active profile, making them its
    /// owner. One start at a time: two users starting at the same moment
    /// cannot end up with one's profile and the other's ownership.
    public func start(by uid: uid_t, beforeStart: @Sendable () -> Void = {}) async throws(Failure) {
        guard !starting else { throw Failure("The VPN is being turned on") }
        starting = true
        defer { starting = false }
        guard await controller.status.phase == .off else { throw Failure("The VPN is already on") }
        try await prepareStart(by: uid)
        await controller.setLogLevel(logLevel(of: uid))
        beforeStart()
        do { try await controller.start() } catch { throw Failure(error.description) }
    }

    /// Before this user turns the VPN on: their active profile becomes the
    /// one it runs, and they its owner.
    public func prepareStart(by uid: uid_t) async throws(Failure) {
        guard let p = library(of: uid).active else { throw Failure("No active profile — create one first") }
        do { try await controller.update(profile: p) } catch { throw Failure(error.description) }
        setOwner(uid)
    }

    /// Create or edit. Editing the owner's active profile while connected
    /// applies it at once (sing-box restarts behind the kill switch); an
    /// invalid edit is refused then and nothing changes.
    public func save(_ p: Profile, by uid: uid_t) async throws(Failure) {
        var lib = library(of: uid)
        do { try lib.upsert(p) } catch { throw Failure(error.description) }
        let live = await drives(uid)
        if live, lib.activeID == p.id, let saved = lib.active {
            do { try await controller.update(profile: saved) } catch { throw Failure(error.description) }
        }
        try commit(uid) { lib throws(ProfileLibrary.Failure) in try lib.upsert(p) }
    }

    /// The user's server library, replaced whole. Each server must be
    /// usable as it is: it is copied into profiles as it stands.
    public func saveServers(_ servers: [Tunnel], by uid: uid_t) throws(Failure) {
        guard Set(servers.map(\.id)).count == servers.count else { throw Failure("Two servers share an id") }
        let probe = Profile(name: "Library", tunnels: servers)
        let errors = Validation.check(probe).filter { $0.severity == .error && $0.tunnel != nil }
        guard errors.isEmpty else { throw Failure(errors.map(\.message).joined(separator: "; ")) }
        try commit(uid) { lib in lib.servers = servers }
    }

    public func delete(_ id: Profile.ID, by uid: uid_t) async throws(Failure) {
        var lib = library(of: uid)
        let live = await drives(uid)
        if live, lib.activeID == id {
            throw Failure("This profile is in use. Disconnect or switch to another profile first.")
        }
        do { try lib.remove(id) } catch { throw Failure(error.description) }
        let wasActive = library(of: uid).activeID == id
        let next = lib.activeID
        try commit(uid) { lib throws(ProfileLibrary.Failure) in
            try lib.remove(id)
            if wasActive { lib.activeID = next }
        }
    }

    /// Make another profile active. The owner, connected: switches over
    /// right away, traffic blocked during the swap.
    public func activate(_ id: Profile.ID, by uid: uid_t) async throws(Failure) {
        let lib = library(of: uid)
        guard let p = lib.profile(id) else { throw Failure("No such profile") }
        guard lib.activeID != id else { return }
        if await drives(uid) {
            do { try await controller.update(profile: p) } catch { throw Failure(error.description) }
        }
        try commit(uid) { lib in lib.activeID = id }
    }

    /// The library of helpers before profiles were per user: it goes to
    /// `uid` (the user who updated), unless they already have one.
    /// Returns whether there was one to move.
    @discardableResult
    public static func migrateShared(from shared: LibraryStore, to usersDir: URL, uid: uid_t) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: shared.url.path) || shared.legacyURL.map({ fm.fileExists(atPath: $0.path) }) == true else { return false }
        let target = store(in: usersDir, for: uid)
        try? fm.createDirectory(at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if !fm.fileExists(atPath: target.url.path) {
            // Not written: the shared file stays, and the next start tries again.
            guard (try? target.save(shared.load())) != nil else { return false }
        }
        for u in [shared.url, shared.url.appendingPathExtension("prev")] + (shared.legacyURL.map { [$0] } ?? []) {
            try? fm.removeItem(at: u)
        }
        return true
    }
}
