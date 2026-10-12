import Foundation
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
        _ = await Command.run("/usr/bin/dscl", [".", "-delete", "/Groups/\(Paths.groupName)"])
        // Last: this ends the process (launchd sends SIGTERM, then kills).
        _ = await Command.run("/bin/launchctl", ["bootout", "system/\(Paths.machService)"])
        exit(0)
    }
}
