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
/// properly signed Silent Route bundle, swap it in place of this one and
/// relaunch. The new app then updates the helper (macOS asks for the
/// administrator password) — profiles stay where they are, in the helper's
/// own directory, and are backed up by the installer first.
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
        guard let remembered = available, let repository else { return }
        // What was found earlier may have been withdrawn or superseded since:
        // install what is published now.
        state = .installing("Checking for the newest version…")
        let release: Release
        do {
            guard let fresh = try await Self.newest(repository, includePrereleases: Self.isPrerelease(currentVersion)),
                  Self.isNewer(fresh.version, than: currentVersion) else {
                lastChecked = Date()
                state = .upToDate
                return
            }
            release = fresh
        } catch {
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
        do {
            state = .installing("Downloading \(release.version)…")
            // On the same volume as the app, so the swap is a rename.
            let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: target, create: true)
            defer { try? fm.removeItem(at: work) }
            let image = work.appendingPathComponent(release.image.lastPathComponent)
            let (tmp, resp) = try await URLSession.shared.download(from: release.image)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download failed") }
            try fm.moveItem(at: tmp, to: image)
            let (sumData, _) = try await URLSession.shared.data(from: release.checksum)
            let want = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let got = try await Task.detached { try Self.sha256(of: image) }.value
            guard let want, want == got else { throw Failure("the download is damaged (checksum mismatch)") }

            state = .installing("Checking the new version…")
            let mount = work.appendingPathComponent("mount")
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                    "-mountpoint", mount.path, image.path])
            let app = work.appendingPathComponent(target.lastPathComponent)
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

            state = .installing("Installing…")
            _ = try fm.replaceItemAt(target, withItemAt: app)
            UserDefaults.standard.set(true, forKey: Self.pendingHelperUpdateKey)
            relaunch(target)
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
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
