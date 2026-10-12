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

        let libraryStore = LibraryStore(url: paths.library, legacyURL: paths.legacyProfile)
        let (library, setAside) = libraryStore.loadReporting()
        if let setAside {
            fputs("profiles.json could not be read; kept as \(setAside.lastPathComponent), starting with no profiles\n", stderr)
        }
        let version = (try? String(contentsOf: paths.version, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "dev"
        let profile = library.active ?? Profile()
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

        let engine = SingBoxEngine(paths: paths, group: group, trampoline: paths.helper.path)
        let controller = Controller(
            profile: profile, options: .init(singBoxGroup: group, configEnvironment: env),
            pf: SystemPacketFilter(), engine: engine, network: SystemNetwork(),
            store: FileStateStore(url: paths.state), clock: SystemClock())
        let profiles = ProfileManager(controller: controller, store: libraryStore, library: library)
        let service = Service(controller: controller, profiles: profiles, apiPort: env.clashAPIPort, version: version)

        Task {
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
                if now.timeIntervalSince(last) > 30 { log.info("wake detected") }
                last = now
                await controller.healthTick()
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

    init(controller: Controller, profiles: ProfileManager, apiPort: UInt16, version: String) {
        self.controller = controller
        self.profiles = profiles
        self.apiPort = apiPort
        self.version = version
    }

    func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task {
            let response = await handle(request)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    /// Every answer carries the state, the active profile and the library
    /// revision, so a client never needs a second round trip to refresh.
    func respond(error: String? = nil, library: Bool = false, api: IPC.APICredentials? = nil) async -> IPC.Response {
        let lib = await profiles.library
        return IPC.Response(error: error, status: await controller.status,
                            activeProfile: lib.active.map { IPC.ProfileRef(id: $0.id, name: $0.name) },
                            libraryRevision: await profiles.revision,
                            library: library ? lib : nil, api: api, helperVersion: version)
    }

    func handle(_ data: Data) async -> IPC.Response {
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
                try await controller.start()
            case .stop:
                await controller.stop()
            case .panic:
                await controller.panic()
            case .getLibrary:
                return await respond(library: true)
            case .saveProfile(let p):
                try await profiles.save(p)
                return await respond(library: true)
            case .deleteProfile(let id):
                try await profiles.delete(id)
                return await respond(library: true)
            case .activateProfile(let id):
                try await profiles.activate(id)
            case .apiCredentials:
                guard let secret = await controller.currentAPISecret else {
                    return await respond(error: "Not connected")
                }
                return await respond(api: .init(port: Int(apiPort), secret: secret))
            }
        } catch {
            return await respond(error: "\(error)")
        }
        return await respond()
    }
}
