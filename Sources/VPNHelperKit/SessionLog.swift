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
/// descriptors opened then. The last `keep` sessions are kept (each user
/// chooses how many; 0: none are written); a file that grows past
/// `maxBytes` keeps its first `headBytes` and then only what comes after.
///
/// While a session is written its file is append-only (`UF_APPEND`, the
/// macOS `chattr +a`): a cleaning app cannot cut it short or delete it from
/// under the writers. Its owner can still lift the flag on purpose
/// (`chflags nouappnd`). It is lifted when the session ends, and from files
/// a stopped helper left flagged. Files emptied from outside (a cleaning
/// app cuts the ones it may) are removed.
public final class SessionLog: @unchecked Sendable {
    /// The user's home folder and group, by uid.
    public typealias HomeLookup = @Sendable (uid_t) -> (path: String, gid: gid_t)?

    let home: HomeLookup
    /// For an owner who has not chosen.
    let defaultKeep: Int
    let maxBytes: Int
    let headBytes: Int

    private let lock = NSLock()
    /// The current session's folder and file.
    private var dirFD: Int32 = -1
    private var fileFD: Int32 = -1
    /// Who turned the VPN on, given just before the session begins — for a
    /// session resumed after a helper restart, the owner the helper keeps in
    /// its own root-only folder (`ProfileManager.owner`).
    private var pendingOwner: (uid: uid_t, keep: Int)?
    /// Whose session is being written, and how many of theirs to keep.
    private var owner: (uid: uid_t, keep: Int)?
    private var fileName: String?
    /// A session whose owner keeps none: sing-box's output goes nowhere.
    private var discarding = false
    private var ticks = 0

    public init(home: @escaping HomeLookup = SessionLog.passwdHome,
                keep: Int = SessionLogFormat.defaultKept, maxBytes: Int = 4_000_000, headBytes: Int = 1_000_000) {
        self.home = home
        self.defaultKeep = keep
        self.maxBytes = maxBytes
        self.headBytes = headBytes
    }

    public static let passwdHome: HomeLookup = { uid in
        guard let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { return nil }
        return (String(cString: dir), pw.pointee.pw_gid)
    }

    // MARK: Writing

    /// The user turning the VPN on now (their uid comes with their request),
    /// or the owner of a session about to resume.
    public func setOwner(_ uid: uid_t, keep: Int? = nil) {
        lock.withLock { pendingOwner = (uid, keep ?? defaultKeep) }
    }

    /// The file this user's running session is written to, if any.
    public func currentFile(of uid: uid_t) -> String? {
        lock.withLock { owner?.uid == uid ? fileName : nil }
    }

    /// The user chose to keep `keep` sessions: older ones go now, also
    /// while the VPN is off.
    public func setKeep(_ keep: Int, for uid: uid_t) {
        lock.withLock { keepLocked(keep, for: uid) }
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
            if discarding { return FileHandle.nullDevice }
            guard fileFD >= 0 else { return nil }
            let fd = dup(fileFD)
            return fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        }
    }

    /// Called every few seconds: keeps the current file under `maxBytes`,
    /// and once a minute clears out files emptied from outside.
    public func enforceLimit() {
        lock.withLock {
            guard fileFD >= 0 else { return }
            ticks += 1
            if ticks % 6 == 0 { pruneLocked() }
            var st = stat()
            guard fstat(fileFD, &st) == 0, Int(st.st_size) > maxBytes else { return }
            // Writers append (O_APPEND), so cutting the file back to its
            // head is safe: their next line lands right after the marker.
            // Append-only forbids the cut, so the flag is lifted for it.
            _ = fchflags(fileFD, st.st_flags & ~UInt32(UF_APPEND))
            defer { _ = fchflags(fileFD, st.st_flags | UInt32(UF_APPEND)) }
            guard ftruncate(fileFD, off_t(headBytes)) == 0 else { return }
            raw("\n… \((Int(st.st_size) - headBytes) / 1000) KB of log left out to keep the file small …\n")
        }
    }

    // MARK: Session files

    /// Nothing is remembered here: the helper knows the owner and says so
    /// before a session begins. (Earlier builds kept it in
    /// /Library/Logs/Silent Route, written by path; that folder is not the
    /// helper's own to trust.) Without an owner, no session file: sing-box's
    /// output then goes to the helper's own folder.
    private func openLocked(profile: String, resumed: Bool, at date: Date) {
        guard let pending = pendingOwner else { return }
        pendingOwner = nil
        let owner = pending.uid
        guard pending.keep > 0 else {
            // Keeps none: nothing written, and the ones kept before go.
            discarding = true
            keepLocked(0, for: owner)
            return
        }
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
        fileName = name
        self.owner = pending
        var st = stat()
        if fstat(fd, &st) == 0 { _ = fchflags(fd, st.st_flags | UInt32(UF_APPEND)) }
        raw(SessionLogFormat.header(profile: profile))
        appendLocked(resumed ? "VPN on again after the helper restarted" : "VPN turned on", at: date)
        pruneLocked()
    }

    private func closeLocked(reason: String, at date: Date) {
        discarding = false
        guard fileFD >= 0 else { return }
        appendLocked("\(SessionLogFormat.endMarker) \(reason)", at: date)
        Self.unflag(fileFD)
        owner = nil
        fileName = nil
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

    private func pruneLocked() {
        guard dirFD >= 0, let owner else { return }
        Self.prune(dirFD, keep: owner.keep, current: fileName)
    }

    /// The running session stays whatever the number: it is still being
    /// written.
    private func keepLocked(_ keep: Int, for uid: uid_t) {
        if owner?.uid == uid, dirFD >= 0 {
            owner?.keep = keep
            pruneLocked()
            return
        }
        guard let (homePath, gid) = home(uid),
              let dir = Self.openSessionsFolder(home: homePath, uid: uid, gid: gid, create: false) else { return }
        defer { close(dir) }
        Self.prune(dir, keep: keep, current: nil)
    }

    /// In the sessions folder `dir`: files emptied from outside go, then
    /// the oldest beyond `keep` (the current one counts and always stays).
    /// Other files are never append-only: a stopped helper may have left
    /// one so. Only our own file names; nothing here follows a link.
    static func prune(_ dir: Int32, keep: Int, current: String?) {
        let copy = dup(dir)
        guard copy >= 0 else { return }
        guard let d = fdopendir(copy) else { close(copy); return }
        // A duplicate shares its position: read from the start, not from
        // where the last listing stopped.
        rewinddir(d)
        var names: [String] = []
        while let e = readdir(d) {
            let len = Int(e.pointee.d_namlen)
            let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix(len), as: UTF8.self) }
            if SessionLogFormat.isSessionFile(name), name != current { names.append(name) }
        }
        closedir(d)
        var kept = current == nil ? 0 : 1
        for name in names.sorted(by: >) {
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            var st = stat()
            let ok = fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            if ok { unflag(fd) }
            close(fd)
            guard ok else { continue }
            if st.st_size > 0 && kept < keep {
                kept += 1
            } else {
                unlinkat(dir, name, 0)
            }
        }
    }

    /// Lifts append-only, if set.
    static func unflag(_ fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_flags & UInt32(UF_APPEND) != 0 else { return }
        _ = fchflags(fd, st.st_flags & ~UInt32(UF_APPEND))
    }

    // MARK: The user's folder, safely

    /// Opens (creating as needed) `~/Library/Logs/Silent Route/Sessions…`
    /// one folder at a time: never through a symbolic link, and every folder
    /// must be the user's own. Folders it creates are given to the user.
    /// Returns the sessions folder's descriptor, or nil if anything is off.
    /// With `create` false, nil when the sessions folder is not there yet.
    static func openSessionsFolder(home: String, uid: uid_t, gid: gid_t, create: Bool = true) -> Int32? {
        var fd = open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard SafeRemove.owned(fd, by: uid) else { close(fd); return nil }
        let base = SessionLogFormat.base
        for (i, component) in base.enumerated() {
            // ~/Library and ~/Library/Logs exist in every home; ours is
            // private (0700).
            let mode: mode_t = i == base.count - 1 ? 0o700 : 0o755
            guard let next = openOrCreate(fd, component, uid: uid, gid: gid, mode: mode, create: create) else { close(fd); return nil }
            close(fd)
            fd = next
        }
        // Whichever the user chose; unindexed when there is none yet.
        if let existing = openOrCreate(fd, SessionLogFormat.unindexed, uid: uid, gid: gid, mode: 0o700, create: false)
            ?? openOrCreate(fd, SessionLogFormat.indexed, uid: uid, gid: gid, mode: 0o700, create: false) {
            close(fd)
            return existing
        }
        let made = create ? openOrCreate(fd, SessionLogFormat.unindexed, uid: uid, gid: gid, mode: 0o700) : nil
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
        guard SafeRemove.owned(fd, by: uid) else { close(fd); return nil }
        return fd
    }

}
