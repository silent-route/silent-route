import Foundation
import VPNCore

/// Checks a tunnel without touching the system's network: a separate sing-box
/// exposes only that tunnel as a SOCKS proxy on localhost — no TUN, no routes,
/// no pf. Whatever connection the machine has keeps working throughout.
public enum Probe {
    public struct Report: Sendable, Codable {
        public var ip: String
        public var country: String?
        public var city: String?
        /// Hosting network, e.g. "AS41745 Example Hosting".
        public var org: String?
        public var latencyMs: Int
        /// E.g. an exit that geolocates to the country the user is leaving
        /// defeats the purpose.
        public var warnings: [String]
    }

    public enum Failure: Error, CustomStringConvertible {
        case singBoxDidNotStart(String)
        case noResponse(String)

        public var description: String {
            switch self {
            case .singBoxDidNotStart(let log): "sing-box did not start:\n\(log)"
            case .noResponse(let why): "The server does not respond: \(why)"
            }
        }
    }

    /// - Parameters:
    ///   - launcher: a command to start sing-box through (the helper's
    ///     trampoline, which gives it the kill switch's group); empty: run it
    ///     directly.
    ///   - direct: bind to the physical interface, past the VPN's tunnel.
    ///   - socksPort: nil: a free one.
    public static func run(_ tunnel: Tunnel, singBox: String, socksPort: UInt16? = nil,
                           timeout: TimeInterval = 20, launcher: [String] = [], direct: Bool = false) async throws -> Report {
        guard let socksPort = socksPort ?? LocalPorts.free(1)?.first else {
            throw Failure.singBoxDidNotStart("no free local port for the check")
        }
        // The port is open on localhost while the check runs: a fresh
        // password keeps everything else on the Mac off it.
        let user = "probe"
        let password = Secret.random()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("silentroute-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("probe.json")
        // The config carries the tunnel password: owner-only.
        FileManager.default.createFile(atPath: config.path,
                                       contents: SingBoxConfig.probe(tunnel, socksPort: socksPort, auth: (user, password),
                                                                     direct: direct).encoded(),
                                       attributes: [.posixPermissions: 0o600])

        let process = Process()
        let argv = launcher + [singBox, "run", "-c", config.path, "--disable-color"]
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.currentDirectoryURL = dir
        // To a file, read once sing-box is gone: why it could not reach the
        // server is said there, and only there.
        let logURL = dir.appendingPathComponent("probe.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer { stop(process) }

        // Wait for the SOCKS port rather than sleeping a fixed time.
        let deadline = Date().addingTimeInterval(5)
        while !portOpen(socksPort) {
            if !process.isRunning || Date() > deadline {
                stop(process)
                throw Failure.singBoxDidNotStart((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: Int(socksPort),
            kCFStreamPropertySOCKSUser as String: user,
            kCFStreamPropertySOCKSPassword as String: password,
        ]
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let started = Date()
        let data: Data
        do {
            (data, _) = try await session.data(from: URL(string: "https://ipinfo.io/json")!)
        } catch {
            // macOS says only "bad URL" when the local proxy cannot reach the
            // server: sing-box's own words say why.
            stop(process)
            throw Failure.noResponse(reason(inLog: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
                                     ?? error.localizedDescription)
        }
        let latency = Int(Date().timeIntervalSince(started) * 1000)

        struct IPInfo: Decodable { var ip: String; var country: String?; var city: String?; var org: String? }
        guard let info = try? JSONDecoder().decode(IPInfo.self, from: data) else {
            throw Failure.noResponse("unexpected answer from ipinfo.io")
        }
        let warnings: [String] = []
        return Report(ip: info.ip, country: info.country, city: info.city, org: info.org,
                      latencyMs: latency, warnings: warnings)
    }

    /// The last error sing-box gave for a connection — "dial tcp
    /// 203.0.113.9:443: i/o timeout", "EOF" — or nil if it gave none.
    static func reason(inLog log: String) -> String? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains("ERROR") }) else { return nil }
        let text = line.range(of: "]: ", options: .backwards).map { String(line[$0.upperBound...]) } ?? String(line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed == "EOF" ? "the connection was closed (EOF)" : trimmed
    }

    /// SIGTERM, then SIGKILL after 3 s: a check must end, and must not keep
    /// a server-check slot (or the caller) waiting on a sing-box that hangs.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    static func portOpen(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
