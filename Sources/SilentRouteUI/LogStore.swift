import Foundation
import VPNCore

/// This user's session logs, read straight from their own folder (the
/// helper writes them there, owned by the user; see `SessionLogFormat`).
public struct LogStore: Sendable {
    /// `~/Library/Logs/Silent Route`.
    public let base: URL

    public init(base: URL) { self.base = base }

    public static var currentUser: LogStore {
        LogStore(base: SessionLogFormat.base.reduce(FileManager.default.homeDirectoryForCurrentUser) {
            $0.appendingPathComponent($1, isDirectory: true)
        })
    }

    /// The sessions folder, under whichever name it has now.
    public var folder: URL? {
        for name in [SessionLogFormat.unindexed, SessionLogFormat.indexed] {
            let u = base.appendingPathComponent(name, isDirectory: true)
            var dir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), dir.boolValue { return u }
        }
        return nil
    }

    /// Newest first. `current` is the running session's file, as the helper
    /// says: only that one is still going. A file left empty from outside
    /// (a cleaning app) is not listed; the helper removes it.
    public func sessions(current: String? = nil) -> [LogSession] {
        guard let folder else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name -> LogSession? in
            guard SessionLogFormat.isSessionFile(name), let started = SessionLogFormat.date(fromFileName: name) else { return nil }
            let url = folder.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard bytes > 0 || name == current else { return nil }
            let (first, last) = Self.ends(of: url)
            let running = name == current
            return LogSession(id: name, started: started,
                              ended: running ? nil : attrs?[.modificationDate] as? Date,
                              interrupted: !running && !last.contains(SessionLogFormat.endMarker),
                              profile: first.flatMap(SessionLogFormat.profile(fromHeader:)) ?? "",
                              bytes: bytes)
        }
        .sorted { $0.started > $1.started }
    }

    public func url(of id: String) -> URL? {
        guard SessionLogFormat.isSessionFile(id), let folder else { return nil }
        return folder.appendingPathComponent(id)
    }

    /// Moves a session's file to the Trash (it can be put back from there).
    /// Not the running one: it is append-only while written, and a file a
    /// stopped helper left so is released first.
    @discardableResult
    public func moveToTrash(_ id: String) -> Bool {
        guard let url = url(of: id) else { return false }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd >= 0 {
            var st = stat()
            if fstat(fd, &st) == 0, st.st_flags & UInt32(UF_APPEND) != 0 { _ = fchflags(fd, st.st_flags & ~UInt32(UF_APPEND)) }
            close(fd)
        }
        return (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// A session's text; for a file larger than `tail` bytes, its head and
    /// its last `tail` bytes (`.max`: all of it).
    public func text(of id: String, tail: Int = 2_000_000) -> String? {
        guard let url = url(of: id), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = Int((try? h.seekToEnd()) ?? 0)
        try? h.seek(toOffset: 0)
        if size <= tail {
            return String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        }
        let head = (try? h.read(upToCount: 64_000)) ?? Data()
        try? h.seek(toOffset: UInt64(size - tail))
        let rest = (try? h.readToEnd()) ?? Data()
        return String(decoding: head, as: UTF8.self)
            + "\n… \((size - tail - head.count) / 1000) KB not shown …\n"
            + String(decoding: rest, as: UTF8.self)
    }

    /// The first line and the last few hundred bytes.
    static func ends(of url: URL) -> (first: String?, last: String) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return (nil, "") }
        defer { try? h.close() }
        let head = String(decoding: (try? h.read(upToCount: 300)) ?? Data(), as: UTF8.self)
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 400 ? size - 400 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return (head.split(separator: "\n").first.map(String.init), tail)
    }

    // MARK: Backups and Spotlight

    /// Applies the user's choices: whether Time Machine backs the logs up,
    /// and whether Spotlight indexes them (by the folder's name: Spotlight
    /// skips folders ending in `.noindex`). Both are off by default.
    public func apply(includeInBackups: Bool, indexable: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let want = base.appendingPathComponent(indexable ? SessionLogFormat.indexed : SessionLogFormat.unindexed)
        let other = base.appendingPathComponent(indexable ? SessionLogFormat.unindexed : SessionLogFormat.indexed)
        if fm.fileExists(atPath: other.path), !fm.fileExists(atPath: want.path) {
            try? fm.moveItem(at: other, to: want)
        } else if !fm.fileExists(atPath: want.path) {
            try? fm.createDirectory(at: want, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var b = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = !includeInBackups
        try? b.setResourceValues(values)
    }
}
