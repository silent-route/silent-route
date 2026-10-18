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
    /// removes them. Only that exact path: if any folder on the way is a
    /// symbolic link, only a link itself is removed, never its target.
    static func removeUserLogs() async {
        let r = await Command.run("/usr/bin/dscl", [".", "-list", "/Users", "NFSHomeDirectory"])
        let fm = FileManager.default
        for line in r.text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, !parts[0].hasPrefix("_") else { continue }
            let home = parts[1].trimmingCharacters(in: .whitespaces)
            var path = home
            var safe = true
            for component in SessionLogFormat.base {
                path += "/" + component
                if (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                    if component == SessionLogFormat.base.last { try? fm.removeItem(atPath: path) }
                    safe = false
                    break
                }
            }
            if safe { try? fm.removeItem(atPath: path) }
        }
    }
}
