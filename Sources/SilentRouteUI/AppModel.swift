import AppKit
import Foundation
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import VPNCore
import VPNIPC
import VPNRuntime

/// How the app reaches the helper. The real one is XPC; the snapshot tool
/// and previews use a fake.
public protocol HelperBackend: Sendable {
    func send(_ request: IPC.Request) async throws -> IPC.Response
    /// The helper's files are on disk (it may still not be running).
    var isInstalled: Bool { get }
    /// The build of the installed helper, read from its files.
    var installedVersion: String? { get }
}

extension HelperBackend {
    public var installedVersion: String? { nil }
}

public struct XPCBackend: HelperBackend {
    let client = HelperClient()
    public init() {}
    public func send(_ request: IPC.Request) async throws -> IPC.Response { try await client.send(request, timeout: 30) }
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Application Support/Silent Route/bin/SilentRouteHelper")
    }
    public var installedVersion: String? {
        (try? String(contentsOfFile: "/Library/Application Support/Silent Route/bin/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Live speed, bytes per second.
public struct Speed: Equatable, Sendable {
    public var down: Int64
    public var up: Int64
    public init(down: Int64, up: Int64) { self.down = down; self.up = up }
}

/// Everything the menu bar and the window show, and every action they take.
@MainActor @Observable
public final class AppModel {
    public enum HelperState: Equatable {
        case unknown
        case notInstalled
        /// Installed but not answering, or a different version.
        case broken(String)
        case ready
    }

    public private(set) var helper: HelperState = .unknown
    public private(set) var status = VPNStatus(phase: .off)
    public private(set) var activeProfile: IPC.ProfileRef?
    /// The VPN is on, turned on by another user of this Mac: we see only
    /// that, may turn it off, and change nothing of what it runs.
    public private(set) var otherUsersVPN = false
    public private(set) var library = ProfileLibrary()
    public private(set) var speed: Speed?
    /// Bytes since the uptime's start (`uptimeSince`). sing-box counts from
    /// its own start, so when counting the whole session, what earlier
    /// sing-box runs carried is added on (`sessionCarry`).
    public private(set) var sessionBytes: Speed?
    private var sessionCarry = Speed(down: 0, up: 0)
    private var sessionKey: Date?

    /// Where the uptime counts from, as chosen in Settings: this connection,
    /// or the whole session since the VPN was turned on.
    public var uptimeSince: Date? {
        Preferences.sessionCounter == .session ? (status.sessionSince ?? status.connectedSince) : status.connectedSince
    }
    /// The installed helper's build, from its last answer.
    public private(set) var helperVersion: String?

    /// The helper came from another build of the app: offer to update it.
    public var helperOutdated: Bool {
        if helper == .broken(Self.otherVersion) { return true }
        guard helper == .ready, let h = helperVersion, let mine = Self.appVersion else { return false }
        return h != mine
    }

    static let otherVersion = "The installed helper is from another version of Silent Route. Update it to continue — your profiles are kept."

    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    /// A command is in flight (toggle, switch, save…): controls disable.
    public private(set) var busy = false
    /// The last thing that went wrong on a user action, shown until the next one.
    public var notice: Notice?

    public struct Notice: Equatable, Identifiable {
        public var id = UUID()
        public var text: String
        public var isError: Bool
        public init(_ text: String, isError: Bool) { self.text = text; self.isError = isError }
    }

    let backend: HelperBackend
    private var libraryRevision: Int?
    private var polling: Task<Void, Never>?
    private var traffic: Task<Void, Never>?

    public init(backend: HelperBackend) {
        self.backend = backend
    }

    /// For the snapshot tool: a model frozen in a given state.
    public init(preview backend: HelperBackend, helper: HelperState, status: VPNStatus, library: ProfileLibrary,
                speed: Speed? = nil, session: Speed? = nil, notice: Notice? = nil) {
        self.backend = backend
        self.helper = helper
        self.status = status
        self.library = library
        self.activeProfile = library.active.map { IPC.ProfileRef(id: $0.id, name: $0.name) }
        self.speed = speed
        self.sessionBytes = session
        self.notice = notice
    }

    // MARK: - Polling

    public func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Quicker while something is changing.
                let fast = [.connecting, .reconnecting, .stopping].contains(self.status.phase) || self.busy
                try? await Task.sleep(for: .milliseconds(fast ? 400 : 1500))
            }
        }
    }

    public func refresh() async {
        do {
            apply(try await backend.send(.status))
            if helper != .ready { helper = .ready }
        } catch {
            if backend.isInstalled, let v = backend.installedVersion, let mine = Self.appVersion, v != mine {
                // A helper from another build (this app was just updated, or
                // came from another download): it does not accept this
                // app's signature. Updating it is the way forward.
                helper = .broken(Self.otherVersion)
            } else {
                helper = backend.isInstalled ? .broken(error.localizedDescription) : .notInstalled
            }
            status = VPNStatus(phase: .off)
            stopTraffic()
        }
    }

    private func apply(_ r: IPC.Response) {
        if let s = r.status {
            RouteNotifier.shared.update(from: status, to: s, profile: library.active)
            status = s
        }
        if let v = r.helperVersion { helperVersion = v }
        otherUsersVPN = r.otherUsersVPN ?? false
        activeProfile = r.activeProfile
        if let lib = r.library {
            library = lib
            libraryRevision = r.libraryRevision
        } else if let rev = r.libraryRevision, rev != libraryRevision {
            Task { await self.reloadLibrary() }
        }
        if status.phase == .connected { startTraffic() } else { stopTraffic() }
    }

    func reloadLibrary() async {
        if let r = try? await backend.send(.getLibrary) { apply(r) }
    }

    // MARK: - Commands

    /// Runs a helper command with the busy flag and error reporting.
    @discardableResult
    func run(_ request: IPC.Request, success: String? = nil) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            apply(try await backend.send(request))
            if let success { notice = Notice(success, isError: false) }
            return true
        } catch {
            notice = Notice(error.localizedDescription, isError: true)
            await refresh()
            return false
        }
    }

    public var isOn: Bool { [.connecting, .connected, .reconnecting].contains(status.phase) }

    public func setOn(_ on: Bool) async {
        notice = nil
        await run(on ? .start : .stop)
    }

    public func activate(_ id: Profile.ID) async {
        guard id != library.activeID else { return }
        notice = nil
        await run(.activateProfile(id))
    }

    public func panic() async {
        await run(.panic, success: "Network restored: the VPN is off and nothing is blocked")
    }

    /// Saves and returns nil, or returns why not.
    public func save(_ p: Profile) async -> String? {
        busy = true
        defer { busy = false }
        do {
            apply(try await backend.send(.saveProfile(p)))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func delete(_ id: Profile.ID) async {
        await run(.deleteProfile(id))
    }

    static let defaultProfileName = "New Profile"

    /// "New Profile", "New Profile 3": a name nobody chose.
    static func isDefaultName(_ name: String) -> Bool {
        name.range(of: #"^New Profile( \d+)?$"#, options: .regularExpression) != nil
    }

    public func newProfile() async -> Profile.ID? {
        let p = Profile.blank(name: library.freeName(Self.defaultProfileName))
        return await save(p) == nil ? p.id : nil
    }

    public func duplicate(_ p: Profile) async -> Profile.ID? {
        var copy = library.prepareImport(p)
        copy.name = library.freeName(p.name + " Copy")
        return await save(copy) == nil ? copy.id : nil
    }

    // MARK: - Traffic

    private func startTraffic() {
        guard traffic == nil else { return }
        traffic = Task { [weak self] in
            guard let self, let r = try? await self.backend.send(.apiCredentials), let api = r.api else { return }
            // The same count as the uptime: a new one, or a new sing-box run
            // of the same session.
            if self.uptimeSince != self.sessionKey {
                self.sessionKey = self.uptimeSince
                self.sessionCarry = Speed(down: 0, up: 0)
            } else if let s = self.sessionBytes {
                self.sessionCarry = s
            }
            // The totals so far once, then each second's bytes added on.
            var total = self.sessionCarry
            if let d = try? await TrafficMonitor.request(api, "GET", "/connections"),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                total.down += (obj["downloadTotal"] as? NSNumber)?.int64Value ?? 0
                total.up += (obj["uploadTotal"] as? NSNumber)?.int64Value ?? 0
            }
            self.sessionBytes = total
            await TrafficStream.run(port: api.port, secret: api.secret) { [weak self] s in
                await MainActor.run {
                    guard let self else { return }
                    self.speed = s
                    if let s, var t = self.sessionBytes {
                        t.down += s.down
                        t.up += s.up
                        self.sessionBytes = t
                    }
                }
            }
            await MainActor.run { self.traffic = nil }
        }
    }

    private func stopTraffic() {
        traffic?.cancel()
        traffic = nil
        speed = nil
        if status.phase == .off {
            sessionBytes = nil
            sessionCarry = Speed(down: 0, up: 0)
            sessionKey = nil
        }
    }

    // MARK: - Helper installation

    public enum PrivilegedResult: Equatable, Sendable {
        case done
        case cancelled
        case failed(String)
    }

    /// Runs the bundled installer as root through the standard administrator
    /// password prompt — macOS's own dialog; the app never sees the password.
    func runInstaller(_ args: [String]) async -> PrivilegedResult {
        guard let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else {
            return .failed("The installer is missing from the app bundle — rebuild the app")
        }
        return await Task.detached { () -> PrivilegedResult in
            func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let command = ([script.path] + args).map(q).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
            guard let error else { return .done }
            // -128: the user cancelled the password prompt.
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
            return .failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
        }.value
    }

    /// Install and update are the same operation; profiles are kept.
    public func installHelper() async {
        let updating = helper == .ready
        busy = true
        defer { busy = false }
        // Who installs: an earlier version's shared profiles become theirs.
        switch await runInstaller(["install", "--user", NSUserName()]) {
        case .done: notice = Notice(updating ? "Helper updated" : "Helper installed", isError: false)
        case .cancelled: break
        case .failed(let m): notice = Notice("Installation failed: \(m)", isError: true)
        }
        await refresh()
        await reloadLibrary()
    }

    /// Removes everything, then moves the app to the Trash and quits.
    /// - Parameter keepProfiles: each user's profiles are copied to their home first.
    public func uninstallEverything(keepProfiles: Bool, keepLogs: Bool = false) async {
        busy = true
        defer { busy = false }
        var args = ["uninstall", "--yes", "--user", NSUserName()]
        if keepProfiles { args.append("--keep-profiles") }
        if keepLogs { args.append("--keep-logs") }
        switch await runInstaller(args) {
        case .cancelled:
            return
        case .failed(let m):
            notice = Notice("Uninstall did not finish: \(m)", isError: true)
            return
        case .done:
            try? await SMAppService.mainApp.unregister()
            _ = try? await NSWorkspace.shared.recycle([Bundle.main.bundleURL])
            NSApp.terminate(nil)
        }
    }

    // MARK: - Import

    /// A .srprofile (or its JSON) chosen, dropped, pasted or opened from
    /// Finder. Only whole profiles: links are added in the Add Exit sheet.
    public func importFile(_ url: URL) async -> Profile.ID? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            notice = Notice("Could not read \(url.lastPathComponent)", isError: true)
            return nil
        }
        guard let p = try? JSONDecoder().decode(Profile.self, from: data) else {
            notice = Notice("\(url.lastPathComponent) is not a Silent Route profile", isError: true)
            return nil
        }
        return await importProfile(p)
    }

    /// A profile's JSON pasted as text.
    public func importProfileText(_ text: String) async -> Profile.ID? {
        guard let p = try? JSONDecoder().decode(Profile.self, from: Data(text.utf8)) else {
            notice = Notice("The clipboard holds no Silent Route profile. To add a tunnel or proxy by its link, use Add Exit in a profile.",
                            isError: true)
            return nil
        }
        return await importProfile(p)
    }

    func importProfile(_ p: Profile) async -> Profile.ID? {
        let new = library.prepareImport(p)
        if let err = await save(new) {
            notice = Notice("Profile not imported: \(err)", isError: true)
            return nil
        }
        notice = Notice("Imported the profile “\(new.name)”", isError: false)
        return new.id
    }

    /// For the Monitor page; nil while not connected.
    public func apiCredentials() async -> IPC.APICredentials? {
        try? await backend.send(.apiCredentials).api
    }
}

/// The clash API's /traffic endpoint: one JSON line a second,
/// {"up": bytes/s, "down": bytes/s}.
enum TrafficStream {
    static func run(port: Int, secret: String, update: @escaping @Sendable (Speed?) async -> Void) async {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/traffic")!)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 3600
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        guard let (bytes, _) = try? await session.bytes(for: req) else { return }
        do {
            for try await line in bytes.lines {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let up = (obj["up"] as? NSNumber)?.int64Value ?? 0
                let down = (obj["down"] as? NSNumber)?.int64Value ?? 0
                await update(Speed(down: down, up: up))
            }
        } catch {}
        await update(nil)
    }
}

extension UTType {
    /// A Silent Route profile file (.srprofile): the profile as JSON.
    public static let silentRouteProfile = UTType(exportedAs: "org.silentroute.app.profile", conformingTo: .json)
}
