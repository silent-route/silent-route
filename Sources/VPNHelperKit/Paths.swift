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
    /// Before profiles were per user: the one shared library. Migrated into
    /// `users` on start.
    public var library: URL { root.appendingPathComponent("profiles.json") }
    /// Each user's own library: `users/<uid>/profiles.json` (root only).
    public var users: URL { root.appendingPathComponent("users") }
    /// The uid of the user whose profile the VPN runs.
    public var owner: URL { root.appendingPathComponent("owner") }
    /// Written by the installer: the user who updated, who gets the shared
    /// library of an earlier version.
    public var migrateOwner: URL { root.appendingPathComponent("migrate-owner") }
    public var state: URL { root.appendingPathComponent("state.json") }
    public var logs: URL { URL(fileURLWithPath: "/Library/Logs/Silent Route") }
    public var singBoxLog: URL { logs.appendingPathComponent("sing-box.log") }

    public static let bundleID = "org.silentroute.app"
    public static let machService = "org.silentroute.app.helper"
    public static let groupName = "_silentroute"
}
