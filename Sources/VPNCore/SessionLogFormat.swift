import Foundation

/// Where and how session logs are written; shared by the helper (which
/// writes them) and the app (which reads them).
///
/// Each user's logs live in their own home:
/// `~/Library/Logs/Silent Route/Sessions.noindex/` — or `Sessions/` when the
/// user lets Spotlight index them (folders ending in `.noindex` are skipped
/// by Spotlight). One file per session: `2026-10-14_12-03-09.log`.
public enum SessionLogFormat {
    /// Relative to the home folder.
    public static let base = ["Library", "Logs", "Silent Route"]
    public static let unindexed = "Sessions.noindex"
    public static let indexed = "Sessions"
    /// Written last in a file when its session ends.
    public static let endMarker = "session ended:"
    /// How many sessions a user may keep, the running one included: none
    /// (no logs) to a thousand, each at most 4 MB.
    public static let keptRange = 0...1000
    public static let defaultKept = 30

    /// `2026-10-14_12-03-09.log`, or `…_2.log` for a second one that second.
    public static func fileName(for date: Date, suffix: Int? = nil) -> String {
        fileStamp.string(from: date) + (suffix.map { "_\($0)" } ?? "") + ".log"
    }

    public static func isSessionFile(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}(_\d+)?\.log$"#, options: .regularExpression) != nil
    }

    public static func date(fromFileName name: String) -> Date? {
        fileStamp.date(from: String(name.prefix(19)))
    }

    /// The first line names the profile: `# Silent Route session · profile: Home`.
    public static func header(profile: String) -> String { "# Silent Route session · profile: \(profile)\n" }

    public static func profile(fromHeader first: String) -> String? {
        guard first.hasPrefix("#"), let r = first.range(of: "profile: ") else { return nil }
        return String(first[r.upperBound...]).trimmingCharacters(in: .newlines)
    }

    public static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    public static let lineStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
