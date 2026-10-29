import AppKit
import CryptoKit
import Foundation
import Observation

/// Updates from the project's GitHub releases.
///
/// Where the information comes from: the app (never the helper) asks
/// GitHub's public API for the releases of the repository named in
/// Info.plist (`SRUpdateRepository`, set when the app is built). A release
/// carries `Silent-Route-<version>.dmg` and its `.sha256`. Pre-releases
/// (alpha, beta) are offered only to someone already running one.
///
/// Installing: download, check the sha256, mount the image, check that it is a
/// properly signed Silent Route bundle, update the helper from it (macOS
/// asks for the administrator password right then), swap the app in place
/// of this one and relaunch. Profiles stay where they are, in the helper's
/// own directory, and are backed up by the installer first.
///
/// With the VPN on and a kill switch, everything outside the tunnel stays
/// blocked while one helper replaces the other, and the new helper brings
/// the VPN back by itself. Until then the update can be stopped: the VPN is
/// turned off and the network goes back to normal.
@MainActor @Observable
public final class Updater {
    public static let shared = Updater()

    public struct Release: Equatable, Sendable {
        public var version: String
        public var page: URL
        var image: URL
        var checksum: URL
    }

    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var lastChecked: Date?
    /// Set while quitting into a new version: the quit must not turn the
    /// VPN off (the new app reconnects it after updating the helper).
    public private(set) var relaunching = false
    /// How much of the download is done (0…1) while downloading.
    public private(set) var fraction: Double?
    /// The step under way while installing, for the progress window.
    public private(set) var stage: Stage?
    /// Stop was asked for while the helper was being replaced: the VPN is
    /// turned off as soon as a helper answers.
    public private(set) var stopping = false
    private var installTask: Task<Void, Never>?
    /// The helper could not be updated: a small window says so and offers
    /// to restore the network.
    public private(set) var helperFailure: HelperFailure?
    /// Restoring the network after such a failure.
    public private(set) var restoring = false
    /// Relaunched into the new version while the VPN reconnects: the
    /// update's window stays until it is back (or turned off).
    public var resuming = false

    public struct HelperFailure: Equatable, Sendable {
        public var message: String
        /// A helper answers: the previous one was put back.
        public var helperRunning: Bool
    }

    public enum Stage: Equatable, Sendable {
        /// Downloading and checking: stopping changes nothing.
        case preparing
        /// The password prompt and the helper's replacement.
        case helper
        /// Swapping the app and relaunching.
        case relaunching
    }

    /// "owner/repo", or nil for a build without an update source.
    public let repository: String?
    public let currentVersion: String

    /// Remembered across the relaunch: the new app should update the helper.
    public static let pendingHelperUpdateKey = "pendingHelperUpdate"

    private var automatic: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        let repo = (bundle.object(forInfoDictionaryKey: "SRUpdateRepository") as? String)?
            .trimmingCharacters(in: .whitespaces)
        repository = repo.flatMap { $0.split(separator: "/").count == 2 ? $0 : nil }
        currentVersion = bundle.object(forInfoDictionaryKey: "SRVersion") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    public var available: Release? {
        if case .available(let r) = state { r } else { nil }
    }

    /// The project's documentation (its README).
    public var helpPage: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)#readme") }
    }

    public var releasesPage: URL? {
        repository.flatMap { URL(string: "https://github.com/\($0)/releases") }
    }

    // MARK: Checking

    /// Once a day while the setting is on; the first check soon after launch.
    public func startAutomaticChecks() {
        guard automatic == nil, repository != nil else { return }
        automatic = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self else { return }
                if Preferences.checkForUpdates { await self.check() }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    public func check() async {
        guard let repository else { state = .failed("This build has no update source"); return }
        switch state {
        case .checking, .installing: return
        default: break
        }
        state = .checking
        do {
            let release = try await Self.newest(repository, includePrereleases: Self.isPrerelease(currentVersion))
            lastChecked = Date()
            if let release, Self.isNewer(release.version, than: currentVersion) {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed("Could not check for updates: \(error.localizedDescription)")
        }
    }

    /// The newest published release that has a disk image.
    nonisolated static func newest(_ repository: String, includePrereleases: Bool) async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub did not answer") }
        return try pick(from: data, includePrereleases: includePrereleases)
    }

    /// From GitHub's list of releases: the newest published one that has a
    /// disk image and its checksum.
    nonisolated static func pick(from data: Data, includePrereleases: Bool) throws -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Item: Decodable { let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool; let assets: [Asset] }
        let releases = try JSONDecoder().decode([Item].self, from: data).compactMap { r -> Release? in
            guard !r.draft, includePrereleases || !r.prerelease,
                  let image = r.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                  let sum = r.assets.first(where: { $0.name == image.name + ".sha256" })
            else { return nil }
            return Release(version: normalized(r.tag_name), page: r.html_url,
                           image: image.browser_download_url, checksum: sum.browser_download_url)
        }
        return releases.max { isNewer($1.version, than: $0.version) }
    }

    nonisolated static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    nonisolated static func isPrerelease(_ v: String) -> Bool { normalized(v).contains("-") }

    /// Semantic versions: 1.10.0 > 1.9.2, 1.0.0 > 1.0.0-beta.1 > 1.0.0-alpha.2
    /// > 0.1.0-alpha.1. A missing number counts as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func split(_ s: String) -> (core: [Int], pre: [String]) {
            let parts = normalized(s).split(separator: "-", maxSplits: 1)
            let core = parts.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
            return (core, pre)
        }
        let x = split(a), y = split(b)
        for i in 0..<max(x.core.count, y.core.count) {
            let l = i < x.core.count ? x.core[i] : 0, r = i < y.core.count ? y.core[i] : 0
            if l != r { return l > r }
        }
        // Same numbers: a release beats any pre-release of it.
        if x.pre.isEmpty || y.pre.isEmpty { return x.pre.isEmpty && !y.pre.isEmpty }
        for (l, r) in zip(x.pre, y.pre) where l != r {
            if let li = Int(l), let ri = Int(r) { return li > ri }
            return l > r
        }
        return x.pre.count > y.pre.count
    }

    // MARK: Installing

    public func install() async {
        guard installTask == nil else { return }
        let task = Task { await performInstall() }
        installTask = task
        await task.value
        installTask = nil
        stage = nil
        stopping = false
    }

    /// Stops the update. While downloading, nothing has changed yet. While
    /// the helper is being replaced the installer cannot be interrupted (it
    /// runs as root, and stopping it halfway could leave no helper at all):
    /// it finishes, and then the VPN is turned off, so the network goes back
    /// to normal.
    public func cancel() {
        switch stage {
        case .preparing: installTask?.cancel()
        case .helper:
            stopping = true
            state = .installing("Stopping — the VPN turns off as soon as the helper is back…")
        case .relaunching, nil: break
        }
    }

    private func performInstall() async {
        guard let remembered = available, let repository else { return }
        stage = .preparing
        // What was found earlier may have been withdrawn or superseded since:
        // install what is published now.
        state = .installing("Checking for the newest version…")
        let release: Release
        do {
            guard let fresh = try await Self.newest(repository, includePrereleases: Self.isPrerelease(currentVersion)),
                  Self.isNewer(fresh.version, than: currentVersion) else {
                lastChecked = Date()
                state = Task.isCancelled ? .available(remembered) : .upToDate
                return
            }
            release = fresh
        } catch {
            if Task.isCancelled { state = .available(remembered); return }
            // GitHub did not answer: try what was found before.
            release = remembered
        }
        let target = Bundle.main.bundleURL
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path),
              fm.isWritableFile(atPath: target.path) else {
            state = .failed("Silent Route can’t replace itself in \(target.deletingLastPathComponent().path). Download the release from GitHub instead.")
            return
        }
        // On the same volume as the app, so the swap is a rename.
        guard let work = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: target, create: true) else {
            state = .failed("Update failed: no room to unpack it next to the app")
            return
        }
        defer { try? fm.removeItem(at: work) }
        let app: URL
        do {
            state = .installing("Downloading \(release.version)…")
            app = try await download(release, into: work, named: target.lastPathComponent)
        } catch {
            state = Task.isCancelled ? .available(release) : .failed("Update failed: \(error.localizedDescription)")
            return
        }
        guard !Task.isCancelled else { state = .available(release); return }

        // The helper, from the new version, now: the password is asked while
        // the user is here, not after the relaunch.
        if fm.fileExists(atPath: Self.installedHelper) {
            stage = .helper
            state = .installing("Updating the helper — enter your password if macOS asks…")
            let script = app.appendingPathComponent("Contents/Resources/install-helper.sh")
            let result = await AppModel.runInstaller(script, ["install", "--user", NSUserName()])
            if stopping {
                // Whichever helper is there now — the new one, or the old
                // one put back — its own command line turns the VPN off.
                _ = await AppModel.runInstalledCLI(["down"])
            }
            switch result {
            case .done: break
            case .cancelled:
                state = stopping ? .failed("Update stopped. The VPN is off and the network is back to normal.") : .available(release)
                return
            case .failed(let m):
                state = .failed("The helper could not be updated, so nothing was changed\(stopping ? " (the VPN is off)" : ""): \(m)")
                await reportHelperFailure(m)
                return
            }
        }

        stage = .relaunching
        state = .installing("Installing…")
        do {
            _ = try fm.replaceItemAt(target, withItemAt: app)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
            return
        }
        // If the helper could not be updated above (none was installed),
        // the new app offers it.
        UserDefaults.standard.set(true, forKey: Self.pendingHelperUpdateKey)
        relaunch(target)
    }

    /// Shows the failure window. Whether a helper answers decides what it says.
    public func reportHelperFailure(_ message: String) async {
        let running = await AppModel.runInstalledCLIStatus(["status"]) == 0
        helperFailure = HelperFailure(message: message, helperRunning: running)
    }

    public func dismissHelperFailure() { helperFailure = nil }

    /// For the snapshot tool: an updater frozen in a given state.
    public static func preview(stage: Stage? = nil, step: String = "", failure: String? = nil,
                               helperRunning: Bool = false, resuming: Bool = false) -> Updater {
        let u = Updater()
        u.stage = stage
        if stage != nil { u.state = .installing(step) }
        u.helperFailure = failure.map { HelperFailure(message: $0, helperRunning: helperRunning) }
        u.resuming = resuming
        return u
    }

    /// The VPN off and nothing blocked. Through the installed helper when
    /// one answers; otherwise as root (macOS asks for the password), which
    /// lifts what a stopped helper left behind.
    public func restoreNetwork() async {
        restoring = true
        defer { restoring = false }
        if await AppModel.runInstalledCLIStatus(["panic"]) == 0 {
            helperFailure = nil
            return
        }
        guard let script = Bundle.main.url(forResource: "install-helper", withExtension: "sh") else { return }
        switch await AppModel.runInstaller(script, ["restore-network"]) {
        case .done: helperFailure = nil
        case .cancelled: break
        case .failed(let m):
            helperFailure?.message = "The network could not be restored: \(m). Restarting the Mac restores it."
        }
    }

    nonisolated static let installedHelper = "/Library/Application Support/Silent Route/bin/SilentRouteHelper"

    /// Downloads and checks a release; returns the app, unpacked into `work`.
    private func download(_ release: Release, into work: URL, named name: String) async throws -> URL {
        let fm = FileManager.default
        let image = work.appendingPathComponent(release.image.lastPathComponent)
        fraction = 0
        defer { fraction = nil }
        try await Download.run(release.image, to: image) { f in
            Task { @MainActor in if self.fraction != nil { self.fraction = f } }
        }
        let (sumData, _) = try await URLSession.shared.data(from: release.checksum)
        let want = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let got = try await Task.detached { try Self.sha256(of: image) }.value
        guard let want, want == got else { throw Failure("the download is damaged (checksum mismatch)") }
        try Task.checkCancellation()

        state = .installing("Checking the new version…")
        let mount = work.appendingPathComponent("mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                "-mountpoint", mount.path, image.path])
        let app = work.appendingPathComponent(name)
        var copyError: Error?
        do {
            try await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("Silent Route.app").path, app.path])
        } catch {
            copyError = error
        }
        try? await Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
        if let copyError { throw copyError }
        guard let new = Bundle(url: app), new.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw Failure("the download does not contain Silent Route")
        }
        try await Self.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        // Downloaded by the app, not a browser — but clear it anyway so
        // the relaunch never stops at a Gatekeeper prompt.
        try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// Waits for this process to end, then opens the new app.
    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        relaunching = true
        NSApp.terminate(nil)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func run(_ tool: String, _ args: [String]) async throws {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw Failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed (\(p.terminationStatus))")
            }
        }.value
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}

/// One file, with its progress reported as it arrives.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let d = Download(destination: destination, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone once this returns: move it now.
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            moveError = Updater.Failure("the download failed")
            return
        }
        do { try FileManager.default.moveItem(at: location, to: destination) } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error ?? moveError { continuation?.resume(throwing: e) } else { continuation?.resume() }
        continuation = nil
    }
}
