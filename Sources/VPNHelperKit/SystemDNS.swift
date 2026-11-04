import Foundation
import SystemConfiguration
import VPNCore

/// Points macOS's resolver into the tunnel while the VPN is on, and puts it
/// back afterwards.
///
/// macOS resolves through the DNS servers of its network services. Most
/// networks hand out the router, which is reached over the local network —
/// past the tunnel, so the router (and whoever it forwards to) would see
/// every name looked up. While connected, every active service's DNS (both
/// its `State:` value from DHCP and its `Setup:` value from the user's
/// settings, which wins) is set to an address inside the tunnel, where
/// sing-box answers by the profile's rules.
///
/// Only the dynamic store is touched, never the saved network settings: a
/// restart of the Mac starts from the user's own settings, untouched. The
/// values replaced are kept on disk, so a helper that crashed still puts
/// them back when it starts again. Applying again is harmless: DHCP may
/// rewrite a value at any time (a new Wi-Fi), so the controller re-applies
/// on network changes and health checks.
public final class SystemDNS: @unchecked Sendable {
    let backupURL: URL
    private let lock = NSLock()
    private let store: SCDynamicStore?

    public init(backupURL: URL) {
        self.backupURL = backupURL
        store = SCDynamicStoreCreate(nil, "Silent Route" as CFString, nil, nil)
    }

    /// What was there before: the value of each key we changed, or nil
    /// where there was none; and what we put there, per key.
    private struct Backup {
        var server: String
        var originals: [String: [String: Any]?]
        var applied: [String: String] = [:]

        /// The address this key holds while it is ours.
        func ours(_ key: String) -> String { applied[key] ?? server }
    }

    // MARK: Apply and restore

    /// Every active service resolves through sing-box. With `local`, each
    /// service gets its own interface's IPv4 address — sing-box answers DNS
    /// on port 53 there — so that queries macOS scopes to that interface
    /// (its own network checks do) reach sing-box too; the tunnel address
    /// would only be reachable unscoped, and macOS takes a resolver that
    /// never answers for a broken network (it resets Wi-Fi). Without
    /// `local`, or for a service with no IPv4 address, `server`.
    /// Returns whether anything changed (then the DNS cache is flushed).
    @discardableResult
    public func apply(server: String, local: Bool = false) -> Bool {
        lock.withLock {
            guard let store else { return false }
            var backup = loadBackup() ?? Backup(server: server, originals: [:])
            backup.server = server
            var changed = false
            for id in activeServiceIDs(store) {
                let address = local ? (Self.ipv4Address(store, service: id) ?? server) : server
                for domain in ["State", "Setup"] {
                    let key = "\(domain):/Network/Service/\(id)/DNS"
                    let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
                    if Self.servers(current) == [address] { backup.applied[key] = address; continue }
                    // What is there now is the network's own value (a first
                    // apply, or DHCP rewrote it) — unless it is one of ours
                    // from before (the service's address changed): what goes
                    // back is still the network's.
                    if !(backup.originals.keys.contains(key) && Self.servers(current) == [backup.ours(key)]) {
                        backup.originals[key] = .some(current)
                    }
                    var mine = current ?? [:]
                    mine["ServerAddresses"] = [address]
                    if SCDynamicStoreSetValue(store, key as CFString, mine as CFDictionary) {
                        changed = true
                        backup.applied[key] = address
                    }
                }
            }
            saveBackup(backup)
            return changed
        }
    }

    /// Puts back what `apply` replaced (also after a crash: from disk).
    /// A key that had no value before is removed, but only if it still
    /// holds ours.
    public func restore() {
        lock.withLock {
            guard let store, let backup = loadBackup() else { return }
            for (key, original) in backup.originals {
                let current = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
                guard Self.servers(current) == [backup.ours(key)] else { continue }   // changed since: not ours to touch
                if let original {
                    SCDynamicStoreSetValue(store, key as CFString, original as CFDictionary)
                } else {
                    SCDynamicStoreRemoveValue(store, key as CFString)
                }
            }
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    // MARK: Pieces

    /// Services with an IPv4 or IPv6 state: the ones in use right now.
    private func activeServiceIDs(_ store: SCDynamicStore) -> [String] {
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv[46]" as CFString) as? [String] ?? []
        var ids: [String] = []
        for k in keys {
            let parts = k.split(separator: "/")
            if parts.count >= 4, !ids.contains(String(parts[3])) { ids.append(String(parts[3])) }
        }
        return ids
    }

    /// The service's first IPv4 address, as DHCP or the user set it.
    private static func ipv4Address(_ store: SCDynamicStore, service id: String) -> String? {
        let v = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any]
        guard let a = (v?["Addresses"] as? [String])?.first, IPNetwork(a)?.family == .v4 else { return nil }
        return a
    }

    static func servers(_ value: [String: Any]?) -> [String] {
        value?["ServerAddresses"] as? [String] ?? []
    }

    private func loadBackup() -> Backup? {
        guard let d = try? Data(contentsOf: backupURL),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let server = plist["server"] as? String,
              let originals = plist["originals"] as? [String: Any] else { return nil }
        var map: [String: [String: Any]?] = [:]
        for (k, v) in originals {
            let dict = v as? [String: Any]
            map[k] = .some(dict?["__none__"] != nil ? nil : dict)
        }
        // Backups of earlier versions have no "applied": every key held `server`.
        return Backup(server: server, originals: map, applied: plist["applied"] as? [String: String] ?? [:])
    }

    private func saveBackup(_ b: Backup) {
        var originals: [String: Any] = [:]
        // A key that had no value is stored as an empty marker.
        for (k, v) in b.originals { originals[k] = v ?? ["__none__": true] }
        let plist: [String: Any] = ["server": b.server, "originals": originals, "applied": b.applied]
        guard let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: backupURL.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}
