import Foundation

/// Where the helper keeps things. All under root-owned directories that a
/// normal user (even an admin, without a password) cannot change.
public struct Paths: Sendable {
    public var root: URL

    public init(root: URL = URL(fileURLWithPath: "/Library/Application Support/Silent Route")) {
        self.root = root
    }

    public var bin: URL { root.appendingPathComponent("bin") }
    public var singBox: URL { bin.appendingPathComponent("sing-box") }
    public var helper: URL { bin.appendingPathComponent("SilentRouteHelper") }
    /// Written by the installer: the app build this helper came from.
    public var version: URL { bin.appendingPathComponent("VERSION") }
    public static let launchDaemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/org.silentroute.app.helper.plist")
    public var rules: URL { root.appendingPathComponent("rules") }
    /// Working directory of sing-box: config (0600) and cache.
    public var run: URL { root.appendingPathComponent("run") }
    public var config: URL { run.appendingPathComponent("config.json") }
    public var cache: URL { run.appendingPathComponent("cache.db") }
    /// Before profiles: the one profile. Migrated into `library` on start.
    public var legacyProfile: URL { root.appendingPathComponent("profile.json") }
    public var library: URL { root.appendingPathComponent("profiles.json") }
    public var state: URL { root.appendingPathComponent("state.json") }
    public var logs: URL { URL(fileURLWithPath: "/Library/Logs/Silent Route") }
    public var singBoxLog: URL { logs.appendingPathComponent("sing-box.log") }
    /// One file per VPN session (root only).
    public var sessionLogs: URL { logs.appendingPathComponent("sessions") }

    public static let bundleID = "org.silentroute.app"
    public static let machService = "org.silentroute.app.helper"
    public static let groupName = "_silentroute"
}
