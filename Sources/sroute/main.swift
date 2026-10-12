import Foundation
import VPNCore
import VPNHelperKit
import VPNIPC
import VPNRuntime

// sroute — the Silent Route command line. Works without the app (over SSH too);
// everything that changes the network goes through the root helper.

let usage = """
usage: sroute <command>

  status                  connection state and active profile
  up | down               connect / disconnect
  profiles                list profiles (● = active)
  use <profile>           make a profile active (switches over if connected)
  export <profile> <file> save a profile to a file (contains passwords!)
  import <file>           add a profile from a file
  delete <profile>        delete a profile
  panic                   emergency reset: kill switch off, sing-box killed,
                          routing and DNS repaired
  servers                 tunnels and proxies of the active profile
  routes                  routes of the active profile, live while connected
  add <link|->            add a tunnel or proxy to the active profile
                          ("-" reads stdin); routes are edited in the app
  remove <name>           delete a server from the active profile
  probe <link|->          check a server through a temporary local proxy;
                          the current connection is not touched
  parse <link|->          show what a link turns into (secrets masked)
  diag                    local checks: interfaces, routes, other VPNs

If the helper itself is unreachable, the manual reset is:
  sudo pfctl -a \(PFRules.anchor) -F all
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("✗ " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func readArgument(_ a: String) -> String {
    a == "-" ? (readLine(strippingNewline: true) ?? "") : a
}

func mask(_ s: String) -> String {
    s.count <= 4 ? "****" : String(s.prefix(2)) + String(repeating: "*", count: min(8, s.count - 2))
}

func describe(_ t: Tunnel) -> String {
    var lines = ["name:      \(t.name)", "server:    \(t.server.host):\(t.server.port)", "protocol:  \(t.proto.displayName)"]
    switch t.proto {
    case .hysteria2(let h):
        lines.append("password:  \(mask(h.password))")
        if h.obfsPassword != nil { lines.append("obfs:      salamander") }
        if let sni = h.tls.serverName { lines.append("sni:       \(sni)") }
    case .vless(let v):
        lines.append("uuid:      \(mask(v.uuid.uuidString))")
        if let f = v.flow { lines.append("flow:      \(f)") }
        if let sni = v.tls?.serverName { lines.append("sni:       \(sni)") }
        lines.append("transport: \(v.transport)")
    case .trojan(let t):
        lines.append("password:  \(mask(t.password))")
        lines.append("transport: \(t.transport)")
    case .shadowsocks(let s):
        lines.append("method:    \(s.method)")
        lines.append("password:  \(mask(s.password))")
    case .vmess(let v):
        lines.append("uuid:      \(mask(v.uuid.uuidString))")
        lines.append("transport: \(v.transport)")
    case .proxy(let p):
        if let u = p.username { lines.append("user:      \(u)") }
        if let pw = p.password { lines.append("password:  \(mask(pw))") }
    }
    return lines.joined(separator: "\n")
}

func parseOrFail(_ link: String) -> LinkParser.Result {
    do { return try LinkParser.parse(link) } catch { fail("\(error)") }
}

func singBoxPath() -> String {
    let candidates: [String?] = [ProcessInfo.processInfo.environment["SING_BOX"], Paths().singBox.path,
                      "/usr/local/bin/sing-box", "/opt/homebrew/bin/sing-box"]
    guard let p = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        fail("sing-box not found; set SING_BOX=/path/to/sing-box")
    }
    return p
}

let client = HelperClient()

func send(_ r: IPC.Request) async -> IPC.Response {
    do { return try await client.send(r) } catch { fail(error.localizedDescription) }
}

func printStatus(_ r: IPC.Response) {
    guard let s = r.status else { return }
    let profile = r.activeProfile.map { " — profile “\($0.name)”" } ?? ""
    switch s.phase {
    case .connected:
        print("● Connected\(profile)")
        if let since = s.connectedSince {
            print("  since \(since.formatted(date: .omitted, time: .shortened))")
        }
    case .connecting: print("◌ Connecting…\(profile)")
    case .reconnecting: print("◌ Reconnecting (attempt \(s.reconnectAttempts)) — traffic is blocked meanwhile")
    case .stopping: print("◌ Disconnecting…")
    case .off: print("○ Off\(profile)")
    }
    print("  kill switch: \(s.killSwitchOn ? "on — nothing leaves outside the tunnel" : "off")")
    if let e = s.lastError { print("  last error: \(e)") }
}

func libraryOrFail() async -> ProfileLibrary {
    guard let l = await send(.getLibrary).library else { fail("the helper returned no profiles") }
    return l
}

func profileOrFail() async -> Profile {
    guard let p = await libraryOrFail().active else { fail("no active profile — create one in the app, or: sroute import <file>") }
    return p
}

func findProfile(_ lib: ProfileLibrary, _ name: String) -> Profile {
    let matches = lib.profiles.filter { $0.name.lowercased() == name.lowercased() || $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
    guard matches.count == 1 else { fail(matches.isEmpty ? "no profile \"\(name)\"" : "\"\(name)\" is ambiguous") }
    return matches[0]
}

func findTunnel(_ p: Profile, _ name: String) -> Tunnel {
    let matches = p.tunnels.filter { $0.name.lowercased() == name.lowercased() || $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }
    guard matches.count == 1 else { fail(matches.isEmpty ? "no tunnel \"\(name)\"" : "\"\(name)\" is ambiguous") }
    return matches[0]
}

let args = Array(CommandLine.arguments.dropFirst())
switch (args.first, args.count) {
case ("status", 1), (nil, 0):
    printStatus(await send(.status))

case ("up", 1):
    print("Connecting…")
    printStatus(await send(.start))

case ("profiles", 1):
    let lib = await libraryOrFail()
    if lib.profiles.isEmpty { print("No profiles. Create one in the app, or: sroute import <file>") }
    for p in lib.profiles {
        let mark = p.id == lib.activeID ? "●" : " "
        print("\(mark) \(p.name)  —  \(p.tunnels.count) server(s), \(p.routes.count + 1) route(s)")
    }

case ("use", 2):
    let p = findProfile(await libraryOrFail(), args[1])
    printStatus(await send(.activateProfile(p.id)))

case ("delete", 2):
    let p = findProfile(await libraryOrFail(), args[1])
    _ = await send(.deleteProfile(p.id))
    print("Deleted profile \(p.name)")

case ("export", 3):
    let p = findProfile(await libraryOrFail(), args[1])
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let url = URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
    guard let data = try? enc.encode(p),
          FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
        fail("cannot write \(url.path)")
    }
    print("Saved \(p.name) to \(url.path) — it contains passwords, share it carefully")

case ("import", 2):
    let url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    guard let data = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
    guard let p = try? JSONDecoder().decode(Profile.self, from: data) else { fail("\(url.lastPathComponent) is not a Silent Route profile") }
    let new = await libraryOrFail().prepareImport(p)
    _ = await send(.saveProfile(new))
    print("Imported profile \(new.name)")

case ("down", 1):
    _ = await send(.stop)
    print("○ Off. The network is as it was before.")

case ("panic", 1):
    _ = await send(.panic)
    print("Reset done: kill switch off, sing-box stopped, routing and DNS repaired.")

case ("servers", 1), ("tunnels", 1):
    let p = await profileOrFail()
    if p.tunnels.isEmpty { print("No servers. Add one: sroute add <link>") }
    for t in p.tunnels {
        let used = p.allRoutes.filter { $0.servers.contains(t.id) }.map(\.name)
        print("\(t.name)  —  \(t.proto.displayName), \(t.server.host):\(t.server.port)\(used.isEmpty ? "" : "  (" + used.joined(separator: ", ") + ")")")
    }

case ("routes", 1):
    let r = await send(.getLibrary)
    guard let p = r.library?.active else { fail("no active profile") }
    let live = Dictionary(uniqueKeysWithValues: (r.status?.routes ?? []).map { ($0.id, $0.via) })
    let ms = Dictionary(uniqueKeysWithValues: (r.status?.servers ?? []).map { ($0.id, $0.latencyMs) })
    for route in p.allRoutes where route.enabled || route.id == p.defaultRoute.id {
        var to: String
        switch route.target {
        case .direct: to = "direct"
        case .block: to = "block"
        case .servers:
            to = p.chain(of: route).map { id in
                let name = p.tunnel(id)?.name ?? "?"
                guard let m = ms[id] else { return name }
                return name + (m.map { " (\($0) ms)" } ?? " (down)")
            }.joined(separator: " → ") + (route.killSwitch ? " → block" : " → direct")
        }
        var now = ""
        switch live[route.id] {
        case .server(let id)?: now = "  [now: \(p.tunnel(id)?.name ?? "?")]"
        case .direct?: now = "  [now: DIRECT]"
        case .blocked?: now = "  [now: BLOCKED]"
        case nil: break
        }
        print("\(route.name): \(to)\(now)")
    }

case ("add", 2):
    let r = parseOrFail(readArgument(args[1]))
    for w in r.warnings { print("⚠️  \(w)") }
    var p = await profileOrFail()
    p.tunnels.append(r.tunnel)
    _ = await send(.saveProfile(p))
    print("Added \(r.tunnel.name)")

case ("remove", 2):
    var p = await profileOrFail()
    let t = findTunnel(p, args[1])
    p.tunnels.removeAll { $0.id == t.id }
    func drop(_ r: inout Route) {
        if case .servers(let ids) = r.target { r.target = .servers(ids.filter { $0 != t.id }) }
        if case .servers(let ids) = r.target, ids.isEmpty { r.target = .direct }
    }
    for i in p.routes.indices { drop(&p.routes[i]) }
    drop(&p.defaultRoute)
    _ = await send(.saveProfile(p))
    print("Removed \(t.name)")

case ("parse", 2):
    let r = parseOrFail(readArgument(args[1]))
    print(describe(r.tunnel))
    for w in r.warnings { print("⚠️  \(w)") }

case ("probe", 2):
    let r = parseOrFail(readArgument(args[1]))
    for w in r.warnings { print("⚠️  \(w)") }
    print("Checking \(r.tunnel.name) through a temporary local proxy…")
    do {
        let rep = try await Probe.run(r.tunnel, singBox: singBoxPath())
        print("✅ Exit: \(rep.ip) — \([rep.city, rep.country].compactMap { $0 }.joined(separator: ", "))")
        if let org = rep.org { print("   Network: \(org)") }
        print("   Answer in \(rep.latencyMs) ms")
        for w in rep.warnings { print("⚠️  \(w)") }
    } catch {
        fail("\(error)")
    }

case ("diag", 1):
    let net = SystemNetwork()
    print("route to the internet: \(await SystemNetwork.routeInterface(for: "1.1.1.1") ?? "none")")
    print("other VPN: \(await net.foreignTunnel() ?? "none")")
    print("Silent Route TUN: \(await net.tunInterface() ?? "none")")
    print("group \(Paths.groupName): \(getgrnam(Paths.groupName).map { "gid \($0.pointee.gr_gid)" } ?? "missing (helper not installed)")")
    print("helper: \(FileManager.default.fileExists(atPath: Paths().helper.path) ? "installed" : "not installed")")

default:
    print(usage)
    exit(args.isEmpty ? 0 : 2)
}
