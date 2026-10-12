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

    public static func run(_ tunnel: Tunnel, singBox: String, socksPort: UInt16 = 11099,
                           timeout: TimeInterval = 20) async throws -> Report {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("silentroute-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("probe.json")
        // The config carries the tunnel password: owner-only.
        FileManager.default.createFile(atPath: config.path, contents: SingBoxConfig.probe(tunnel, socksPort: socksPort).encoded(),
                                       attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: singBox)
        process.arguments = ["run", "-c", config.path]
        process.currentDirectoryURL = dir
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        // Wait for the SOCKS port rather than sleeping a fixed time.
        let deadline = Date().addingTimeInterval(5)
        while !portOpen(socksPort) {
            if !process.isRunning || Date() > deadline {
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                let text = String(decoding: log.fileHandleForReading.availableData, as: UTF8.self)
                throw Failure.singBoxDidNotStart(text)
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFStreamPropertySOCKSProxyHost as String: "127.0.0.1",
            kCFStreamPropertySOCKSProxyPort as String: Int(socksPort),
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
            throw Failure.noResponse(error.localizedDescription)
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
