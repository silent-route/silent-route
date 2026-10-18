import Foundation
import VPNCore

/// What the controller reports about a VPN session, for its log.
public enum SessionEvent: Sendable, Equatable {
    /// The user turned the VPN on (or a restarted helper resumed it).
    case began(profile: String, resumed: Bool)
    /// Something worth a line: a profile switch, a reconnect and why.
    case note(String)
    /// Turned off, restored, failed to start, or the helper stopped.
    case ended(reason: String)
}

/// One log file per VPN session, from turning it on to turning it off: the
/// helper's own lines and everything sing-box prints (warnings and errors).
///
/// A session belongs to the macOS user who turned the VPN on and is written
/// into their own home (`SessionLogFormat`), owned by them: they open it in
/// Finder or Console, and other users of the Mac cannot read it.
///
/// The helper is root and the folder is the user's, so nothing is opened by
/// a path the user could have swapped: each folder on the way is opened
/// without following symbolic links and must belong to the user, the file
/// is always created new (`O_EXCL`), and every later write goes through the
/// descriptors opened then. The last `keep` sessions are kept; a file that
/// grows past `maxBytes` keeps its first `headBytes` and then only what
/// comes after.
public final class SessionLog: @unchecked Sendable {
    /// The user's home folder and group, by uid.
    public typealias HomeLookup = @Sendable (uid_t) -> (path: String, gid: gid_t)?

    let system: URL
    let home: HomeLookup
    let keep: Int
    let maxBytes: Int
    let headBytes: Int

    private let lock = NSLock()
    /// The current session's folder and file.
    private var dirFD: Int32 = -1
    private var fileFD: Int32 = -1
    /// Who turned the VPN on, given just before the session begins.
    private var pendingOwner: uid_t?

    /// - Parameter system: root's own folder (`/Library/Logs/Silent Route`),
    ///   where only the owner of the last session is remembered.
    public init(system: URL, home: @escaping HomeLookup = SessionLog.passwdHome,
                keep: Int = 30, maxBytes: Int = 5_000_000, headBytes: Int = 1_000_000) {
        self.system = system
        self.home = home
        self.keep = keep
        self.maxBytes = maxBytes
        self.headBytes = headBytes
    }

    public static let passwdHome: HomeLookup = { uid in
        guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
        return (String(cString: dir), pw.pointee.pw_gid)
    }

    // MARK: Writing

    /// The user turning the VPN on now; their uid comes with their request.
    public func setOwner(_ uid: uid_t) {
        lock.withLock { pendingOwner = uid }
    }

    public func handle(_ event: SessionEvent, at date: Date = Date()) {
        lock.withLock {
            switch event {
            case .began(let profile, let resumed):
                closeLocked(reason: "a new session began", at: date)
                openLocked(profile: profile, resumed: resumed, at: date)
            case .note(let text):
                appendLocked(text, at: date)
            case .ended(let reason):
                closeLocked(reason: reason, at: date)
            }
        }
    }

    /// A line from the helper, into the current session (if any).
    public func write(_ text: String, at date: Date = Date()) {
        lock.withLock { appendLocked(text, at: date) }
    }

    /// Where a sing-box process writes its output: the current session's
    /// file (a duplicate of its descriptor, appending). Nil outside a session.
    public func engineOutput() -> FileHandle? {
        lock.withLock {
            guard fileFD >= 0 else { return nil }
            let fd = dup(fileFD)
            return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        }
    }

    /// Called now and then: keeps the current file under `maxBytes`.
    public func enforceLimit() {
        lock.withLock {
            guard fileFD >= 0 else { return }
            var st = stat()
            guard fstat(fileFD, &st) == 0, Int(st.st_size) > maxBytes else { return }
            // Writers append (O_APPEND), so cutting the file back to its
            // head is safe: their next line lands right after the marker.
            guard ftruncate(fileFD, off_t(headBytes)) == 0 else { return }
            raw("\n… \((Int(st.st_size) - headBytes) / 1000) KB of log left out to keep the file small …\n")
        }
    }

    // MARK: Session files

    /// The owner of a resumed session: whoever turned it on before the
    /// helper restarted, remembered in root's folder.
    private var lastOwnerFile: URL { system.appendingPathComponent("last-owner") }

    private func openLocked(profile: String, resumed: Bool, at date: Date) {
        let saved = (try? String(contentsOf: lastOwnerFile, encoding: .utf8))
            .flatMap { uid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let owner = (resumed ? saved : pendingOwner) ?? pendingOwner ?? saved ?? 0
        pendingOwner = nil
        try? FileManager.default.createDirectory(at: system, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data(String(owner).utf8).write(to: lastOwnerFile)

        guard let (homePath, gid) = home(owner),
              let dir = Self.openSessionsFolder(home: homePath, uid: owner, gid: gid) else { return }
        var name = SessionLogFormat.fileName(for: date)
        var n = 2
        var fd: Int32 = -1
        while true {
            fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_APPEND | O_CLOEXEC, 0o600)
            if fd >= 0 || errno != EEXIST || n > 50 { break }
            name = SessionLogFormat.fileName(for: date, suffix: n)
            n += 1
        }
        guard fd >= 0, fchown(fd, owner, gid) == 0 || geteuid() != 0 else {
            if fd >= 0 { close(fd); unlinkat(dir, name, 0) }
            close(dir)
            return
        }
        dirFD = dir
        fileFD = fd
        raw(SessionLogFormat.header(profile: profile))
        appendLocked(resumed ? "VPN on again after the helper restarted" : "VPN turned on", at: date)
        pruneLocked()
    }

    private func closeLocked(reason: String, at date: Date) {
        guard fileFD >= 0 else { return }
        appendLocked("\(SessionLogFormat.endMarker) \(reason)", at: date)
        close(fileFD)
        close(dirFD)
        fileFD = -1
        dirFD = -1
    }

    private func appendLocked(_ text: String, at date: Date) {
        guard fileFD >= 0 else { return }
        raw("\(SessionLogFormat.lineStamp.string(from: date)) [helper] \(text)\n")
    }

    private func raw(_ s: String) {
        let data = Data(s.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fileFD, $0.baseAddress, data.count) }
    }

    /// Oldest sessions beyond `keep` go. Only our own file names, and
    /// unlinkat never follows a link.
    private func pruneLocked() {
        let copy = dup(dirFD)
        guard copy >= 0 else { return }
        guard let d = fdopendir(copy) else { close(copy); return }
        defer { closedir(d) }
        var names: [String] = []
        while let e = readdir(d) {
            let len = Int(e.pointee.d_namlen)
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(len), as: UTF8.self) }
            if SessionLogFormat.isSessionFile(name) { names.append(name) }
        }
        for old in names.sorted(by: >).dropFirst(keep) { unlinkat(dirFD, old, 0) }
    }

    // MARK: The user's folder, safely

    /// Opens (creating as needed) `~/Library/Logs/Silent Route/Sessions…`
    /// one folder at a time: never through a symbolic link, and every folder
    /// must be the user's own. Folders it creates are given to the user.
    /// Returns the sessions folder's descriptor, or nil if anything is off.
    static func openSessionsFolder(home: String, uid: uid_t, gid: gid_t) -> Int32? {
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard owned(fd, by: uid) else { close(fd); return nil }
        let base = SessionLogFormat.base
        for (i, component) in base.enumerated() {
            // ~/Library and ~/Library/Logs exist in every home; ours is
            // private (0700).
            let mode: mode_t = i == base.count - 1 ? 0o700 : 0o755
            guard let next = openOrCreate(fd, component, uid: uid, gid: gid, mode: mode) else { close(fd); return nil }
            close(fd)
            fd = next
        }
        // Whichever the user chose; unindexed when there is none yet.
        if let existing = openOrCreate(fd, SessionLogFormat.unindexed, uid: uid, gid: gid, mode: 0o700, create: false)
            ?? openOrCreate(fd, SessionLogFormat.indexed, uid: uid, gid: gid, mode: 0o700, create: false) {
            close(fd)
            return existing
        }
        let made = openOrCreate(fd, SessionLogFormat.unindexed, uid: uid, gid: gid, mode: 0o700)
        close(fd)
        return made
    }

    private static func openOrCreate(_ parent: Int32, _ name: String, uid: uid_t, gid: gid_t, mode: mode_t,
                                     create: Bool = true) -> Int32? {
        var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT, create {
            guard mkdirat(parent, name, mode) == 0 || errno == EEXIST else { return nil }
            fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            // Made by us: give it to the user (by descriptor, never by path).
            if geteuid() == 0, uid != 0 { _ = fchown(fd, uid, gid) }
            _ = fchmod(fd, mode)
        }
        guard fd >= 0 else { return nil }
        guard owned(fd, by: uid) else { close(fd); return nil }
        return fd
    }

    private static func owned(_ fd: Int32, by uid: uid_t) -> Bool {
        var st = stat()
        return fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == uid
    }
}
