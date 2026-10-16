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
/// A session belongs to the macOS user who turned the VPN on, and only
/// they see it: each user's sessions are in their own folder
/// (`sessions/<uid>/`), and the helper hands a user nothing but their
/// own. The files can name sites and servers, so they are root's on disk
/// (folders 0700, files 0600); the app reads them through the helper.
/// The last `keep` sessions of each user are kept. A file that grows past `maxBytes`
/// keeps its first `headBytes` and then only what comes after: the start
/// of a session and its latest events are what one looks for.
public final class SessionLog: @unchecked Sendable {
    let dir: URL
    let keep: Int
    let maxBytes: Int
    let headBytes: Int

    private let lock = NSLock()
    private var current: URL?
    /// Who turned the VPN on, given just before the session begins.
    private var pendingOwner: uid_t?

    public init(dir: URL, keep: Int = 30, maxBytes: Int = 5_000_000, headBytes: Int = 1_000_000) {
        self.dir = dir
        self.keep = keep
        self.maxBytes = maxBytes
        self.headBytes = headBytes
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
    /// file, opened for appending (so trimming it never leaves a gap).
    /// Nil outside a session.
    public func engineOutput() -> FileHandle? {
        lock.withLock {
            guard let url = current else { return nil }
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            guard fd >= 0 else { return nil }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    /// Called now and then: keeps the current file under `maxBytes`.
    public func enforceLimit() {
        lock.withLock {
            guard let url = current, let size = Self.size(url), size > maxBytes else { return }
            // Writers append (O_APPEND), so cutting the file back to its
            // head is safe: their next line lands right after the marker.
            let fd = open(url.path, O_WRONLY)
            guard fd >= 0 else { return }
            defer { close(fd) }
            guard ftruncate(fd, off_t(headBytes)) == 0 else { return }
            let marker = "\n… \((size - headBytes) / 1000) KB of log left out to keep the file small …\n"
            appendRaw(marker, to: url)
        }
    }

    // MARK: Reading

    /// One user's sessions, newest first.
    public func sessions(of uid: uid_t) -> [LogSession] {
        lock.withLock {
            let dir = userDir(uid)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.compactMap { name -> LogSession? in
                guard Self.isSessionFile(name), let started = Self.date(fromFileName: name) else { return nil }
                let url = dir.appendingPathComponent(name)
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                let live = url == current
                return LogSession(id: name, started: started,
                                  ended: live ? nil : attrs?[.modificationDate] as? Date,
                                  profile: Self.profile(in: url) ?? "",
                                  bytes: (attrs?[.size] as? NSNumber)?.intValue ?? 0)
            }
            .sorted { $0.started > $1.started }
        }
    }

    /// A session's text; for a large file its head and its last `tail`
    /// bytes. Nil for a name that is not one of our files.
    public func text(of id: String, for uid: uid_t, tail: Int = 2_000_000) -> String? {
        guard Self.isSessionFile(id) else { return nil }
        let url = userDir(uid).appendingPathComponent(id)
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = Int((try? h.seekToEnd()) ?? 0)
        if size <= tail {
            try? h.seek(toOffset: 0)
            return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        }
        try? h.seek(toOffset: 0)
        let head = (try? h.read(upToCount: 64_000)) ?? Data()
        try? h.seek(toOffset: UInt64(size - tail))
        let rest = (try? h.readToEnd()) ?? Data()
        return String(decoding: head, as: UTF8.self)
            + "\n… \((size - tail - head.count) / 1000) KB not shown …\n"
            + String(decoding: rest, as: UTF8.self)
    }

    // MARK: Files

    private func userDir(_ uid: uid_t) -> URL { dir.appendingPathComponent(String(uid)) }

    /// The owner of a resumed session: whoever turned it on before the
    /// helper restarted, remembered on disk.
    private var lastOwnerFile: URL { dir.appendingPathComponent("last-owner") }

    private func openLocked(profile: String, resumed: Bool, at date: Date) {
        let fm = FileManager.default
        let saved = (try? String(contentsOf: lastOwnerFile, encoding: .utf8)).flatMap { uid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let owner = (resumed ? saved : pendingOwner) ?? pendingOwner ?? saved ?? 0
        pendingOwner = nil
        for d in [dir, userDir(owner)] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        }
        try? Data(String(owner).utf8).write(to: lastOwnerFile)
        let dir = userDir(owner)
        var name = Self.fileName(for: date)
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = Self.fileName(for: date, suffix: n)
            n += 1
        }
        let url = dir.appendingPathComponent(name)
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        current = url
        appendRaw("# Silent Route session · profile: \(profile)\n", to: url)
        appendLocked(resumed ? "VPN on again after the helper restarted" : "VPN turned on", at: date)
        pruneLocked(dir)
    }

    private func closeLocked(reason: String, at date: Date) {
        guard current != nil else { return }
        appendLocked("session ended: \(reason)", at: date)
        current = nil
    }

    private func appendLocked(_ text: String, at date: Date) {
        guard let url = current else { return }
        appendRaw("\(Self.stamp.string(from: date)) [helper] \(text)\n", to: url)
    }

    private func appendRaw(_ s: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Data(s.utf8)
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
    }

    private func pruneLocked(_ dir: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter(Self.isSessionFile).sorted(by: >)
        for old in names.dropFirst(keep) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old))
        }
    }

    // MARK: Names

    /// `2026-10-14_12-03-09.log`, or `…_2.log` for a second one that second.
    static func fileName(for date: Date, suffix: Int? = nil) -> String {
        fileStamp.string(from: date) + (suffix.map { "_\($0)" } ?? "") + ".log"
    }

    static func isSessionFile(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(_\d+)?\.log$"#, options: .regularExpression) != nil
    }

    static func date(fromFileName name: String) -> Date? {
        fileStamp.date(from: String(name.prefix(19)))
    }

    static func profile(in url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let first = String(decoding: (try? h.read(upToCount: 300)) ?? Data(), as: UTF8.self)
            .split(separator: "\n").first.map(String.init) ?? ""
        guard let r = first.range(of: "profile: ") else { return nil }
        return String(first[r.upperBound...])
    }

    static func size(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
