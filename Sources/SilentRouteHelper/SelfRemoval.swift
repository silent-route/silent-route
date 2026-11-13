import Foundation
import VPNCore
import VPNHelperKit

/// The helper's files were deleted while it ran (an app cleaner, or by hand).
/// Leave nothing behind that could block or change the network: disconnect,
/// lift the kill switch, remove what is left of the installation, and
/// unregister from launchd so nothing restarts.
enum SelfRemoval {
    static func run(controller: Controller, paths: Paths) async -> Never {
        fputs("installation removed — disconnecting and cleaning up\n", stderr)
        // panic: stops sing-box, flushes our pf anchor, releases our pf
        // reference, repairs routing only if it points into our own TUN.
        await controller.panic()

        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: "/usr/local/bin/sroute")) == paths.bin.appendingPathComponent("sroute").path {
            try? fm.removeItem(atPath: "/usr/local/bin/sroute")
        }
        try? fm.removeItem(at: Paths.launchDaemonPlist)
        try? fm.removeItem(at: paths.root)
        try? fm.removeItem(at: paths.logs)
        await removeUserLogs()
        _ = await Command.run("/usr/bin/dscl", [".", "-delete", "/Groups/\(Paths.groupName)"])
        // Last: this ends the process (launchd sends SIGTERM, then kills).
        _ = await Command.run("/bin/launchctl", ["bootout", "system/\(Paths.machService)"])
        exit(0)
    }

    /// Every local user's ~/Library/Logs/Silent Route, as the uninstaller
    /// removes them. Everything is done through descriptors opened without
    /// following links, each folder checked to be the user's: a link, or a
    /// folder swapped for one meanwhile, is never followed to delete
    /// something else.
    static func removeUserLogs() async {
        let r = await Command.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"])
        for line in r.text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, !parts[0].hasPrefix("_"), let uid = uid_t(parts[1]), uid == 0 || uid >= 500,
                  let pw = getpwuid(uid), let dir = pw.pointee.pw_dir else { continue }
            SafeRemove.userLogs(home: String(cString: dir), uid: uid)
        }
    }
}
