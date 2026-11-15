import Foundation
import VPNCore

/// The lists profiles use, kept on disk and up to date. Each one, by its
/// address, is `rules/<key>.srs` (compiled, what sing-box reads) with
/// `rules/<key>.json` (its address and kind), root's alone.
///
/// A list is fetched when a profile using it is saved or started, when
/// someone asks (Update Now), and again once it is a day old. A rule-set
/// (binary or source) or plain text is taken; whatever comes, sing-box must
/// read it whole before it replaces the file in use, by a rename, so a
/// running sing-box (which reloads a changed list on its own) only ever
/// sees the old file or the new one. A list that cannot be fetched keeps its
/// last copy.
public actor RuleListStore {
    /// Fetches a URL's body.
    public typealias Fetch = @Sendable (URL) async throws -> (status: Int, data: Data)
    /// Runs `sing-box rule-set <arguments>`: nil on success, else why not.
    public typealias RuleSetTool = @Sendable ([String]) async -> String?

    let dir: URL
    let fetch: Fetch
    let tool: RuleSetTool
    let now: @Sendable () -> Date

    /// Why the last attempt for a list failed, by address.
    private var errors: [String: String] = [:]
    /// Downloads under way, by address: a second request waits for it.
    private var inflight: [String: Task<Void, Never>] = [:]

    /// A list is checked again once it is this old.
    public static let maxAge: TimeInterval = 24 * 3600

    public init(dir: URL, fetch: @escaping Fetch = RuleListStore.download, tool: @escaping RuleSetTool,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.dir = dir
        self.fetch = fetch
        self.tool = tool
        self.now = now
    }

    struct Meta: Codable {
        var url: String
        var matchesNames: Bool
    }

    // MARK: Reading

    /// The lists on disk among these addresses, for sing-box's config.
    public func local(_ urls: [String]) -> [String: SingBoxConfig.LocalList] {
        var out: [String: SingBoxConfig.LocalList] = [:]
        for url in urls where RuleLists.isValidURL(url) {
            guard isFile(srs(url)), let m = meta(url) else { continue }
            out[url] = .init(path: srs(url).path, matchesNames: m.matchesNames)
        }
        return out
    }

    public func info(_ urls: [String]) -> [RuleListInfo] {
        urls.filter(RuleLists.isValidURL).map { url in
            var st = stat()
            let on = lstat(srs(url).path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
            return RuleListInfo(url: url, bytes: on ? Int(st.st_size) : nil,
                                updated: on ? Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)) : nil,
                                error: errors[url])
        }
    }

    // MARK: Updating

    /// Fetches each list that is missing or at least `olderThan` old (0:
    /// every one), and waits for all of them.
    public func update(_ urls: [String], olderThan age: TimeInterval) async {
        var tasks: [Task<Void, Never>] = []
        for url in Set(urls) where RuleLists.isValidURL(url) {
            if let running = inflight[url] { tasks.append(running); continue }
            if let updated = info([url]).first?.updated, now().timeIntervalSince(updated) < age { continue }
            let t = Task { await self.fetchOne(url) }
            inflight[url] = t
            tasks.append(t)
        }
        for t in tasks { await t.value }
    }

    /// Every list on disk that is a day old.
    public func refreshStale() async {
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { n -> String? in
            guard n.hasSuffix(".json"), !n.hasPrefix("."),
                  let d = try? Data(contentsOf: dir.appendingPathComponent(n)) else { return nil }
            return (try? JSONDecoder().decode(Meta.self, from: d))?.url
        }
        await update(urls, olderThan: Self.maxAge)
    }

    /// What earlier builds kept here (lists by their tag, folders per
    /// source) goes: profiles name their lists by address now, and fetch
    /// them again.
    public func removeLegacy() {
        guard ensureFolder() else { return }
        let fm = FileManager.default
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let isOurs = n.range(of: #"^[0-9a-f]{24}\.(srs|json)$"#, options: .regularExpression) != nil
            if isOurs || n.hasPrefix(".") { continue }
            let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return }
            SafeRemove.tree(in: fd, n)
            close(fd)
        }
    }

    private func fetchOne(_ url: String) async {
        defer { inflight[url] = nil }
        do {
            try await install(url)
            errors[url] = nil
        } catch {
            errors[url] = (error as? Failure)?.reason ?? error.localizedDescription
        }
    }

    struct Failure: Error { var reason: String }

    private func install(_ url: String) async throws {
        guard let u = URL(string: url) else { throw Failure(reason: "not a web address") }
        let (status, data) = try await fetch(u)
        switch status {
        case 200: break
        case 404: throw Failure(reason: "nothing at this address (HTTP 404)")
        default: throw Failure(reason: "the download failed (HTTP \(status))")
        }
        guard data.count <= RuleLists.maxBytes else { throw Failure(reason: "the list is too large") }
        guard ensureFolder() else { throw Failure(reason: "cannot write to \(dir.path)") }

        let final = srs(url)
        let stamp = UUID().uuidString
        let tempSRS = dir.appendingPathComponent(".\(stamp).srs")
        let tempJSON = dir.appendingPathComponent(".\(stamp).json")
        defer { unlink(tempSRS.path); unlink(tempJSON.path) }

        // Whatever came, as a source rule-set and a compiled one, both read
        // by sing-box.
        let matchesNames: Bool
        if RuleLists.looksLikeBinary(data) {
            try write(data, to: tempSRS)
            if let why = await tool(["decompile", tempSRS.path, "-o", tempJSON.path]) {
                throw Failure(reason: "sing-box cannot read the list: \(why)")
            }
            matchesNames = RuleLists.matchesNames((try? Data(contentsOf: tempJSON)) ?? Data())
        } else {
            let source: Data
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["rules"] != nil {
                source = data
            } else if let converted = RuleLists.sourceFromText(data) {
                source = converted
            } else {
                throw Failure(reason: "not a list: no line is a site or an address")
            }
            try write(source, to: tempJSON)
            if let why = await tool(["compile", tempJSON.path, "-o", tempSRS.path]) {
                throw Failure(reason: "sing-box cannot read the list: \(why)")
            }
            matchesNames = RuleLists.matchesNames(source)
        }
        guard let compiled = try? Data(contentsOf: tempSRS) else { throw Failure(reason: "sing-box wrote nothing") }

        let metaData = try JSONEncoder().encode(Meta(url: url, matchesNames: matchesNames))
        // The same as the copy on disk: only the date changes, and sing-box
        // has nothing to reload.
        if (try? Data(contentsOf: final)) == compiled, meta(url)?.matchesNames == matchesNames {
            utimes(final.path, nil)
            return
        }
        try write(metaData, to: tempJSON, replacing: true)
        guard rename(tempJSON.path, metaFile(url).path) == 0, rename(tempSRS.path, final.path) == 0 else {
            throw Failure(reason: "cannot replace the list: \(String(cString: strerror(errno)))")
        }
    }

    /// A new file, never through a link, readable by everyone (the lists
    /// are public), written through before it is used.
    private func write(_ data: Data, to url: URL, replacing: Bool = false) throws {
        if replacing { unlink(url.path) }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw Failure(reason: "cannot write \(url.path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        fchmod(fd, 0o644)
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else { throw Failure(reason: "cannot write \(url.path)") }
    }

    /// A real folder, root's and closed to others; created if missing.
    private func ensureFolder() -> Bool {
        if mkdir(dir.path, 0o755) != 0, errno != EEXIST { return false }
        var st = stat()
        guard lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        return getuid() != 0 || (st.st_uid == 0 && st.st_mode & 0o022 == 0)
    }

    private func isFile(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    private func meta(_ url: String) -> Meta? {
        guard isFile(metaFile(url)), let d = try? Data(contentsOf: metaFile(url)),
              let m = try? JSONDecoder().decode(Meta.self, from: d), m.url == url else { return nil }
        return m
    }

    private func srs(_ url: String) -> URL { dir.appendingPathComponent(RuleLists.fileKey(url) + ".srs") }
    private func metaFile(_ url: String) -> URL { dir.appendingPathComponent(RuleLists.fileKey(url) + ".json") }

    /// HTTPS straight from the helper: through the tunnel while the VPN is
    /// on (like any traffic of the Mac), directly while it is off. Never via
    /// a system proxy, never from a cache.
    public static let download: Fetch = { url in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 120
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(from: url)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
