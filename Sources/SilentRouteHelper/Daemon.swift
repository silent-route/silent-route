import Foundation
import Network
import os
import VPNCore
import VPNHelperKit
import VPNIPC

let log = Logger(subsystem: IPC.helperIdentifier, category: "helper")

enum Daemon {
    static func run() -> Never {
        guard getuid() == 0 else {
            fputs("SilentRouteHelper must run as root (it is started by launchd)\n", stderr)
            exit(1)
        }
        let paths = Paths()
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        umask(0o077)

        let group = getgrnam(Paths.groupName).map { $0.pointee.gr_gid } ?? 0
        if group == 0 { log.error("group \(Paths.groupName, privacy: .public) is missing; connections will be refused") }

        // Profiles are per user. The shared library of earlier versions goes
        // to the user who installed the update (or, run by hand, to whoever
        // is at the Mac).
        try? fm.createDirectory(at: paths.users, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let installer = (try? String(contentsOf: paths.migrateOwner, encoding: .utf8))
            .flatMap { uid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let console = (try? fm.attributesOfItem(atPath: "/dev/console")[.ownerAccountID] as? NSNumber)?.uint32Value
        ProfileManager.migrateShared(from: LibraryStore(url: paths.library, legacyURL: paths.legacyProfile),
                                     to: paths.users, uid: installer ?? console ?? 0)
        try? fm.removeItem(at: paths.migrateOwner)
        let version = (try? String(contentsOf: paths.version, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
        let countries = Set((try? fm.contentsOfDirectory(atPath: paths.rules.path))?.compactMap { name -> String? in
            guard name.hasPrefix("geoip-"), name.hasSuffix(".srs") else { return nil }
            return String(name.dropFirst(6).dropLast(4))
        } ?? [])
        let siteLists = Set((try? fm.contentsOfDirectory(atPath: paths.rules.path))?.compactMap { name -> String? in
            guard name.hasPrefix("geosite-"), name.hasSuffix(".srs") else { return nil }
            return String(name.dropFirst(8).dropLast(4))
        } ?? [])
        let env = SingBoxConfig.Environment(
            ruleSetDirectory: paths.rules.path, cacheFile: paths.cache.path,
            clashAPIPort: freePort(), clashAPISecret: "",
            geoIPCountries: countries, siteLists: siteLists)

        // Session logs go into the home of whoever turned the VPN on. Earlier
        // builds kept a shared sing-box.log (readable by every user) and
        // root's own session folders: both go.
        let sessionLog = SessionLog(system: paths.logs)
        try? fm.removeItem(at: paths.singBoxLog)
        try? fm.removeItem(at: paths.singBoxLog.appendingPathExtension("1"))
        try? fm.removeItem(at: paths.logs.appendingPathComponent("sessions"))
        let engine = SingBoxEngine(paths: paths, group: group, trampoline: paths.helper.path,
                                   output: { sessionLog.engineOutput() })
        let controller = Controller(
            profile: Profile(), options: .init(singBoxGroup: group, configEnvironment: env),
            pf: SystemPacketFilter(), engine: engine, network: SystemNetwork(),
            store: FileStateStore(url: paths.state), clock: SystemClock())
        let profiles = ProfileManager(controller: controller, usersDir: paths.users, ownerFile: paths.owner)
        let service = Service(controller: controller, profiles: profiles, apiPort: env.clashAPIPort, version: version,
                              sessionLog: sessionLog)

        Task {
            // Before anything can begin a session.
            await controller.setSessionHook { sessionLog.handle($0) }
            // The VPN runs its owner's profile (it may resume below).
            if let p = await profiles.ownerProfile() { try? await controller.update(profile: p) }
            await controller.reconcileOnLaunch()
            log.info("helper ready")
        }

        // Every state change, with its reason, into helper.log (launchd sends
        // stderr there) — the first place to look when something went wrong.
        Task {
            var last: VPNStatus?
            for await s in await controller.updates() {
                defer { last = s }
                guard s.phase != last?.phase || s.lastError != last?.lastError
                        || s.killSwitchOn != last?.killSwitchOn else { continue }
                var line = "\(Date().formatted(.iso8601)) \(s.phase.rawValue)"
                line += s.killSwitchOn ? ", kill switch on" : ", kill switch off"
                if s.reconnectAttempts > 0 { line += ", attempt \(s.reconnectAttempts)" }
                if let e = s.lastError { line += " — \(e)" }
                fputs(line + "\n", stderr)
            }
        }

        // XPC: only our own app and CLI, signed by the same certificate.
        let listener = NSXPCListener(machServiceName: IPC.machService)
        if let leaf = IPC.ownLeafCertificateHash() {
            listener.setConnectionCodeSigningRequirement(IPC.requirement(identifiers: IPC.clientIdentifiers, leafHash: leaf))
        } else {
            log.fault("helper is not signed with a certificate; refusing all clients")
        }
        let delegate = ListenerDelegate(service: service, enabled: IPC.ownLeafCertificateHash() != nil)
        listener.delegate = delegate
        listener.resume()

        // Health checks. A gap much longer than the interval means the Mac
        // slept: check at once instead of trusting a tunnel from before.
        Task {
            var last = Date()
            while true {
                try? await Task.sleep(for: .seconds(10))
                let now = Date()
                if now.timeIntervalSince(last) > 30 {
                    log.info("wake detected")
                    sessionLog.write("the Mac woke from sleep")
                }
                last = now
                await controller.healthTick()
                sessionLog.enforceLimit()
            }
        }

        // Removed behind our back (AppCleaner, or files deleted by hand):
        // nothing may stay blocked or running. Checked twice, 5 s apart, so
        // a moment in the middle of an install never counts.
        Task {
            var missingBefore = false
            while true {
                try? await Task.sleep(for: .seconds(5))
                let fm = FileManager.default
                let missing = !fm.fileExists(atPath: Paths.launchDaemonPlist.path) || !fm.fileExists(atPath: paths.helper.path)
                if missing && missingBefore {
                    await SelfRemoval.run(controller: controller, paths: paths)
                }
                missingBefore = missing
            }
        }

        // Network changes (Wi-Fi → Ethernet → hotspot): re-check right away.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { _ in Task { await controller.networkChanged() } }
        monitor.start(queue: DispatchQueue(label: "path"))

        // launchd sends SIGTERM on shutdown and on unload. Stop cleanly so the
        // network is left as macOS expects it.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler {
            Task {
                await controller.shutdownForExit()
                exit(0)
            }
        }
        term.resume()

        withExtendedLifetime((listener, delegate, monitor, term)) {
            dispatchMain()
        }
    }

    /// A free localhost port for the clash API, chosen once per helper run.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return ok ? UInt16(bigEndian: addr.sin_port) : 19090
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service: Service
    let enabled: Bool

    init(service: Service, enabled: Bool) {
        self.service = service
        self.enabled = enabled
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard enabled else { return false }
        c.exportedInterface = NSXPCInterface(with: HelperXPCProtocol.self)
        c.exportedObject = service
        c.resume()
        return true
    }
}

/// Decodes requests and calls the controller and the profile manager.
final class Service: NSObject, HelperXPCProtocol, @unchecked Sendable {
    let controller: Controller
    let profiles: ProfileManager
    let apiPort: UInt16
    let version: String
    let sessionLog: SessionLog

    init(controller: Controller, profiles: ProfileManager, apiPort: UInt16, version: String, sessionLog: SessionLog) {
        self.sessionLog = sessionLog
        self.controller = controller
        self.profiles = profiles
        self.apiPort = apiPort
        self.version = version
    }

    func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        // Who is asking: macOS vouches for the connection's user. Logs are
        // per user, so this decides whose sessions a request can see.
        let uid = NSXPCConnection.current()?.effectiveUserIdentifier ?? 0
        Task {
            let response = await handle(request, uid: uid)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    /// Every answer carries the state, the active profile and the library
    /// revision, so a client never needs a second round trip to refresh.
    func respond(_ uid: uid_t, error: String? = nil, library: Bool = false, api: IPC.APICredentials? = nil) async -> IPC.Response {
        let lib = await profiles.library(of: uid)
        var status = await controller.status
        let mine = await profiles.controls(uid)
        if !mine {
            // Another user's VPN: that it is on, nothing of what it runs.
            status = VPNStatus(phase: status.phase, connectedSince: status.connectedSince,
                               killSwitchOn: status.killSwitchOn, reconnectAttempts: status.reconnectAttempts)
        }
        var r = IPC.Response(error: error, status: status,
                             activeProfile: lib.active.map { IPC.ProfileRef(id: $0.id, name: $0.name) },
                             libraryRevision: await profiles.revision(of: uid),
                             library: library ? lib : nil, api: api, helperVersion: version)
        r.otherUsersVPN = mine ? nil : true
        return r
    }

    func handle(_ data: Data, uid: uid_t) async -> IPC.Response {
        guard let env = try? JSONDecoder().decode(IPC.Envelope.self, from: data) else {
            return IPC.Response(error: "Malformed request")
        }
        guard env.version == IPC.protocolVersion else {
            return IPC.Response(error: "Version mismatch between app and helper; reinstall the helper")
        }
        do {
            switch env.request {
            case .status:
                break
            case .start:
                // The user turning it on owns it: their active profile runs.
                let log = sessionLog
                try await profiles.start(by: uid, beforeStart: { log.setOwner(uid) })
            case .stop:
                // Anyone at the Mac may turn it off: their traffic goes through it too.
                await controller.stop()
            case .panic:
                await controller.panic()
            case .getLibrary:
                return await respond(uid, library: true)
            case .saveProfile(let p):
                try await profiles.save(p, by: uid)
                return await respond(uid, library: true)
            case .deleteProfile(let id):
                try await profiles.delete(id, by: uid)
                return await respond(uid, library: true)
            case .activateProfile(let id):
                try await profiles.activate(id, by: uid)
            case .apiCredentials:
                // Live connections show what the owner is doing: theirs alone.
                let owner = await profiles.owner
                guard uid == 0 || owner == uid, let secret = await controller.currentAPISecret else {
                    return await respond(uid, error: "Not connected")
                }
                return await respond(uid, api: .init(port: Int(apiPort), secret: secret))
            }
        } catch {
            return await respond(uid, error: "\(error)")
        }
        return await respond(uid)
    }
}
