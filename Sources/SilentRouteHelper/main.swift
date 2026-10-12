import Foundation

// The root LaunchDaemon. Two modes:
//
//   SilentRouteHelper exec-engine <gid> <sing-box> <args…>
//       Trampoline: switch to the Silent Route group, then exec sing-box. It
//       runs before anything else in this process, while it is still
//       single-threaded, so changing credentials here is safe. sing-box keeps
//       uid 0 (TUN and routes need it) but its sockets carry the group pf
//       lets out — and nothing else on the system has that group.
//
//   SilentRouteHelper
//       The daemon (see Daemon.swift).

let arguments = CommandLine.arguments
if arguments.count >= 4, arguments[1] == "exec-engine" {
    guard let gid = gid_t(arguments[2]), gid > 0 else {
        fputs("exec-engine: bad group\n", stderr)
        exit(2)
    }
    var groups = [gid]
    guard setgroups(1, &groups) == 0, setgid(gid) == 0, getegid() == gid else {
        fputs("exec-engine: cannot switch to group \(gid): \(String(cString: strerror(errno)))\n", stderr)
        exit(2)
    }
    let argv = Array(arguments[3...])
    var cArgs = argv.map { strdup($0) } + [nil]
    execv(argv[0], &cArgs)
    fputs("exec-engine: exec \(argv[0]) failed: \(String(cString: strerror(errno)))\n", stderr)
    exit(2)
}

Daemon.run()
