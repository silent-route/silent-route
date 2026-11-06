import Foundation
import Security
import VPNCore
import VPNRuntime

// The app and the CLI talk to the root helper over XPC. One method carrying a
// Codable request keeps the Objective-C surface tiny; everything typed lives
// in Swift. The helper decodes and validates every request itself.

@objc public protocol HelperXPCProtocol {
    func call(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum IPC {
    /// Bumped on any incompatible change; the app asks to reinstall the
    /// helper on a mismatch.
    public static let protocolVersion = 10
    public static let machService = "org.silentroute.app.helper"

    /// Clients the helper accepts. Each must be signed by the same
    /// certificate as the helper itself.
    public static let clientIdentifiers = ["org.silentroute.app", "org.silentroute.app.cli"]
    public static let helperIdentifier = "org.silentroute.app.helper"

    public enum Request: Codable, Sendable {
        case status
        case start
        case stop
        case panic
        case getLibrary
        /// Create or edit a profile (matched by id).
        case saveProfile(Profile)
        case deleteProfile(UUID)
        /// Make a profile active; when connected, switch over at once.
        case activateProfile(UUID)
        /// clash API address and secret, for live traffic stats in the app.
        case apiCredentials
        /// The Wi-Fi login proxy while a network wants a login.
        case captiveLogin
        /// Check a server the way the VPN reaches it: directly, past the
        /// tunnel and the kill switch (the helper runs the check).
        case probe(Tunnel)
        /// This user's sessions log every connection (sing-box at "info"),
        /// from their next session on.
        case setDetailedLogs(Bool)
    }

    public struct Envelope: Codable, Sendable {
        public var version: Int
        public var request: Request
        public init(_ r: Request) { version = IPC.protocolVersion; request = r }
    }

    public struct Response: Codable, Sendable {
        public var version: Int = IPC.protocolVersion
        public var error: String?
        public var status: VPNStatus?
        /// Name and id of the active profile, with every status.
        public var activeProfile: ProfileRef?
        /// Changes whenever the library changes: refetch it when it does.
        public var libraryRevision: Int?
        /// Only for getLibrary.
        public var library: ProfileLibrary?
        public var api: APICredentials?
        /// The installed helper's build (the app's CFBundleVersion it came
        /// from); the app offers an update when it differs from its own.
        public var helperVersion: String?
        /// The VPN is on, turned on by another user of this Mac: the status
        /// says only that, and only they can change what it runs.
        public var otherUsersVPN: Bool?
        /// Only for captiveLogin.
        public var captiveProxy: SingBoxConfig.LocalProxy?
        /// Only for probe.
        public var probe: Probe.Report?
        /// This user's sessions log every connection (see setDetailedLogs).
        public var detailedLogs: Bool?

        public init(error: String? = nil, status: VPNStatus? = nil, activeProfile: ProfileRef? = nil,
                    libraryRevision: Int? = nil, library: ProfileLibrary? = nil, api: APICredentials? = nil,
                    helperVersion: String? = nil) {
            self.helperVersion = helperVersion
            self.error = error
            self.status = status
            self.activeProfile = activeProfile
            self.libraryRevision = libraryRevision
            self.library = library
            self.api = api
        }
    }

    public struct ProfileRef: Codable, Hashable, Sendable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public struct APICredentials: Codable, Sendable {
        public var port: Int
        public var secret: String
        public init(port: Int, secret: String) { self.port = port; self.secret = secret }
    }

    /// SHA-1 of this process's signing certificate (the leaf), or nil if the
    /// code is ad-hoc signed. Used to build "signed by the same certificate
    /// as me" requirements in both directions.
    public static func ownLeafCertificateHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1Digest.hex(of: der)
    }

    /// Code requirement: one of `identifiers`, signed by `leafHash`.
    public static func requirement(identifiers: [String], leafHash: String) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        return "(\(ids)) and certificate leaf = H\"\(leafHash)\""
    }
}

import CryptoKit

extension Insecure.SHA1Digest {
    static func hex(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

/// Client side, used by the app and the CLI.
public final class HelperClient: @unchecked Sendable {
    public struct Failure: Error, LocalizedError {
        public var errorDescription: String?
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    public init() {}

    private func connect() -> NSXPCConnection {
        lock.withLock {
            if let c = connection { return c }
            let c = NSXPCConnection(machServiceName: IPC.machService, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)
            // Talk only to the real helper, signed by the same certificate as us.
            if let leaf = IPC.ownLeafCertificateHash() {
                c.setCodeSigningRequirement(IPC.requirement(identifiers: [IPC.helperIdentifier], leafHash: leaf))
            }
            c.invalidationHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            c.interruptionHandler = { [weak self] in self?.lock.withLock { self?.connection = nil } }
            c.resume()
            connection = c
            return c
        }
    }

    public func send(_ request: IPC.Request, timeout: Double = 60) async throws -> IPC.Response {
        let payload = try JSONEncoder().encode(IPC.Envelope(request))
        let c = connect()
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            let proxy = c.remoteObjectProxyWithErrorHandler { error in
                if once.claim() {
                    cont.resume(throwing: Failure(errorDescription:
                        "The Silent Route helper is not reachable (\(error.localizedDescription)). Is it installed?"))
                }
            } as? HelperXPCProtocol
            guard let proxy else {
                if once.claim() { cont.resume(throwing: Failure(errorDescription: "bad XPC proxy")) }
                return
            }
            proxy.call(payload) { reply in
                if once.claim() { cont.resume(returning: reply) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(throwing: Failure(errorDescription: "The helper did not answer in time")) }
            }
        }
        let response = try JSONDecoder().decode(IPC.Response.self, from: data)
        if response.version != IPC.protocolVersion {
            throw Failure(errorDescription: "The installed helper is a different version; reinstall it from the app")
        }
        if let e = response.error { throw Failure(errorDescription: e) }
        return response
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
}
