import CryptoKit
import Foundation
import VPNCore

/// The real sing-box: a root-owned, hash-checked binary, started through the
/// helper's own trampoline so it runs with the Silent Route group (pf's kill
/// switch lets only that group out).
public final class SingBoxEngine: Engine, @unchecked Sendable {
    let paths: Paths
    let group: UInt32
    /// The helper executable; `helper exec-engine <gid> <binary> <args…>`
    /// drops to the group and execs sing-box (see SilentRouteHelper/main.swift).
    let trampoline: String
    let expectedSHA256: String?

    private let lock = NSLock()
    private var processes: [Int32: Process] = [:]
    private var api: (port: Int, secret: String)?
    /// Where sing-box's output goes: the session log's file. Without one
    /// (it should not happen) the shared sing-box.log.
    private let output: @Sendable () -> FileHandle?

    public init(paths: Paths, group: UInt32, trampoline: String,
                expectedSHA256: String? = VPNCore.singBoxSHA256[SingBoxEngine.machineArch],
                output: @escaping @Sendable () -> FileHandle? = { nil }) {
        self.output = output
        self.paths = paths
        self.group = group
        self.trampoline = trampoline
        self.expectedSHA256 = expectedSHA256
    }

    public static var machineArch: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }

    struct Refused: Error, LocalizedError {
        var errorDescription: String?
    }

    /// Before every use: the binary must be exactly the pinned build, and
    /// owned by root so nobody can swap it between this check and exec.
    /// The pinned sing-box, checked: for one-off runs (a server check).
    public func verifiedBinary() throws -> String {
        try verifyBinary()
        return paths.singBox.path
    }

    func verifyBinary() throws {
        let path = paths.singBox.path
        // The file and every folder above it: a folder others can write to
        // would let them swap the file between this check and the exec. Ours
        // (the file, bin, the installation) are root's alone; the system's
        // above them must at least be root's and not open to everyone (some
        // Macs let admins write to /Library/Application Support).
        var url = paths.singBox
        while true {
            let ours = url.path.hasPrefix(paths.root.path)
            guard Self.rootOwned(url.path, groupMayWrite: !ours) else {
                throw Refused(errorDescription: "\(url.path) is writable by non-root users; refusing to run sing-box")
            }
            if url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        guard let want = expectedSHA256 else { throw Refused(errorDescription: "no pinned sing-box for this CPU") }
        let got = SHA256.hash(data: try Data(contentsOf: paths.singBox, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard got == want else {
            throw Refused(errorDescription: "sing-box does not match the pinned checksum; reinstall Silent Route")
        }
    }

    /// Owned by root, not a link, and not writable by others (nor by the
    /// group, unless `groupMayWrite`).
    static func rootOwned(_ path: String, groupMayWrite: Bool) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return false }
        return st.st_uid == 0 && st.st_mode & (groupMayWrite ? 0o002 : 0o022) == 0
    }

    func writeConfig(_ data: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: paths.config)
        // Created 0600 from the start: the config holds tunnel passwords.
        guard fm.createFile(atPath: paths.config.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Refused(errorDescription: "cannot write \(paths.config.path)")
        }
    }

    public func check(config: Data) async throws {
        try verifyBinary()
        try writeConfig(config)
        let r = await Command.run(paths.singBox.path, ["check", "-c", paths.config.path, "-D", paths.run.path])
        guard r.ok else { throw Command.Failed(tool: "sing-box check", output: r.text) }
    }

    /// `sing-box rule-set <arguments>` (compile, decompile): a downloaded
    /// list is read whole, as sing-box reads it on start. nil: it could;
    /// else its complaint.
    public func ruleSet(_ arguments: [String]) async -> String? {
        do { try verifyBinary() } catch { return error.localizedDescription }
        let r = await Command.run(paths.singBox.path, ["rule-set"] + arguments + ["--disable-color"], timeout: 60)
        guard !r.ok else { return nil }
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit \(r.status)" : String(text.prefix(200))
    }

    public func launch(config: Data, onExit: @escaping @Sendable (Int32) -> Void) async throws -> Int32 {
        try verifyBinary()
        try writeConfig(config)
        let api = Self.clashAPI(in: config)

        let log: FileHandle
        if let session = output() {
            log = session
        } else {
            try FileManager.default.createDirectory(at: paths.run, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            rotateLog()
            if !FileManager.default.fileExists(atPath: paths.singBoxLog.path) {
                FileManager.default.createFile(atPath: paths.singBoxLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            log = try FileHandle(forWritingTo: paths.singBoxLog)
            log.seekToEndOfFile()
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: trampoline)
        p.arguments = ["exec-engine", String(group), paths.singBox.path,
                       "run", "-c", paths.config.path, "-D", paths.run.path, "--disable-color"]
        p.currentDirectoryURL = paths.run
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let pid = proc.processIdentifier
            self?.lock.withLock { _ = self?.processes.removeValue(forKey: pid) }
            try? log.close()
            onExit(pid)
        }
        try p.run()
        let pid = p.processIdentifier
        lock.withLock {
            processes[pid] = p
            self.api = api
        }
        return pid
    }

    public func terminate(pid: Int32) async {
        // Only a sing-box: one that already ended may have handed its PID on.
        guard pid > 1, await isRunning(pid: pid) else { return }
        if kill(pid, SIGTERM) != 0 { return }
        for _ in 0..<30 {                          // 3 s grace
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        kill(pid, SIGKILL)
        for _ in 0..<20 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func isRunning(pid: Int32) async -> Bool {
        // As root, kill(pid, 0) is truthful (a user process probing a root
        // one gets EPERM). Also make sure it is not a reused PID.
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        if lock.withLock({ processes[pid]?.isRunning == true }) { return true }
        return Self.executablePath(of: pid) == paths.singBox.path
    }

    static func executablePath(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? SystemNetwork.cString(buf) : nil
    }

    // MARK: clash API

    static func clashAPI(in config: Data) -> (port: Int, secret: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
              let exp = obj["experimental"] as? [String: Any],
              let clash = exp["clash_api"] as? [String: Any],
              let ctl = clash["external_controller"] as? String,
              let port = ctl.split(separator: ":").last.flatMap({ Int($0) }) else { return nil }
        return (port, clash["secret"] as? String ?? "")
    }

    func request(_ method: String, _ path: String, body: Data? = nil, timeout: Double = 8) async throws -> (Int, Data) {
        guard let api = lock.withLock({ self.api }) else { throw Refused(errorDescription: "sing-box API not configured") }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(api.port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(api.secret)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]       // never via a system proxy
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func select(_ selector: String, member: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": member])
        let (code, data) = try await request("PUT", "/proxies/\(selector)", body: body)
        guard code == 204 || code == 200 else {
            throw Refused(errorDescription: "sing-box refused the switch (\(code)): \(String(decoding: data, as: UTF8.self))")
        }
    }

    public func isReady() async -> Bool {
        (try? await request("GET", "/version", timeout: 2))?.0 == 200
    }

    public func delay(_ tag: String) async -> Int? {
        // sing-box itself fetches the URL through that outbound. Up to 10 s:
        // a busy server answering slowly is slow, not dead (it may need most
        // of that just to accept the connection). One try: a server counts
        // as down only after two missed checks in a row (the controller).
        let url = "https://www.gstatic.com/generate_204"
        let q = "url=\(url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url)&timeout=10000"
        guard let (code, data) = try? await request("GET", "/proxies/\(tag)/delay?\(q)", timeout: 12), code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = (obj["delay"] as? NSNumber)?.intValue, ms > 0 else { return nil }
        return ms
    }


    /// Keep the log bounded, like every log: at 4 MB the current file becomes .1.
    func rotateLog() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: paths.singBoxLog.path))?[.size] as? NSNumber,
              size.intValue > 4_000_000 else { return }
        let old = paths.singBoxLog.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: paths.singBoxLog, to: old)
    }
}
