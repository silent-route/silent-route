import CryptoKit
import Foundation

/// A list of sites or addresses the user adds by its address: a sing-box
/// rule-set (binary .srs or source .json) or plain text, one entry per
/// line. Routes use it as `list:<name>`. The helper downloads it, keeps it
/// on disk and up to date; nothing about any publisher is built in.
public struct RuleList: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var url: String
    public var id: String { name }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

public enum RuleLists {
    /// A list's name: lowercase letters and digits, with `-`, `_`, `.`,
    /// `@` or `!` inside ("blocked-sites", "geoip-cn").
    public static func isValidName(_ n: String) -> Bool {
        n.count <= 64 && n.range(of: #"^[a-z0-9][a-z0-9!@._-]*$"#, options: .regularExpression) != nil
            && !n.contains("..")
    }

    /// HTTPS only, and nothing that is not a plain web address.
    public static func isValidURL(_ s: String) -> Bool {
        guard s.count <= 2048, let u = URL(string: s), u.scheme == "https", let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, !s.contains(where: { $0.isWhitespace }) else { return false }
        return true
    }

    /// The rule-set tag of a list in sing-box's config.
    public static func tag(_ name: String) -> String { "list-" + name }

    /// The file name a list is kept under: from its address, so profiles
    /// naming one list differently share the file.
    public static func fileKey(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// The addresses of the lists a profile's routes use, in order.
    public static func urls(_ p: Profile) -> [String] {
        var out: [String] = []
        for r in p.routes {
            for case .list(let n) in r.conditions.destinations {
                if let u = p.lists.first(where: { $0.name == n })?.url, !out.contains(u) { out.append(u) }
            }
        }
        return out
    }

    public static func looksLikeBinary(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(3) == Data("SRS".utf8)
    }

    /// The largest list taken (a list of every blocked domain of a country,
    /// some 700 000 of them, is a few MB).
    public static let maxBytes = 64 << 20

    // MARK: Text lists

    /// A plain-text list as a sing-box source rule-set, or nil if no line
    /// is usable. Understood, one per line: `example.com` (with subdomains),
    /// `*.`/`+.`/`.` before a name, `domain:`, `full:` and `keyword:` (the
    /// v2fly style), `DOMAIN-SUFFIX,`, `DOMAIN,`, `DOMAIN-KEYWORD,`,
    /// `IP-CIDR,`, `IP-CIDR6,` (the Clash style), and addresses or networks.
    /// Comments (`#`, `//`, `;`) and anything else are skipped.
    public static func sourceFromText(_ data: Data) -> Data? {
        var suffix: [String] = [], exact: [String] = [], keyword: [String] = [], cidr: [String] = []
        for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") { continue }
            // "domain:x @cn", "x # note": the entry is the first word.
            line = String(line.split(separator: " ").first ?? "")
            let parts = line.split(separator: ",", maxSplits: 2).map(String.init)
            var kind = "", value = line
            if parts.count >= 2 { kind = parts[0].uppercased(); value = parts[1] }
            else if let c = line.firstIndex(of: ":"), ["domain", "full", "keyword"].contains(line[..<c].lowercased()) {
                kind = line[..<c].lowercased(); value = String(line[line.index(after: c)...])
            }
            switch kind {
            case "DOMAIN-SUFFIX", "domain": if let d = domain(value) { suffix.append(d) }
            case "DOMAIN", "full": if let d = domain(value) { exact.append(d) }
            case "DOMAIN-KEYWORD", "keyword": if !value.isEmpty { keyword.append(value.lowercased()) }
            case "IP-CIDR", "IP-CIDR6": if let n = IPNetwork(value) { cidr.append(n.description) }
            case "":
                if let n = IPNetwork(value) { cidr.append(n.description) }
                else if let d = domain(value) { suffix.append(d) }
            default: break
            }
        }
        var rules: [[String: [String]]] = []
        if !suffix.isEmpty { rules.append(["domain_suffix": suffix]) }
        if !exact.isEmpty { rules.append(["domain": exact]) }
        if !keyword.isEmpty { rules.append(["domain_keyword": keyword]) }
        if !cidr.isEmpty { rules.append(["ip_cidr": cidr]) }
        guard !rules.isEmpty else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["version": 3, "rules": rules], options: [.sortedKeys])
    }

    private static func domain(_ s: String) -> String? {
        var d = s.lowercased()
        for p in ["*.", "+.", "."] where d.hasPrefix(p) { d.removeFirst(p.count); break }
        d = Validation.normalizeDomain(d)
        // A name with a dot: a lone word is more likely prose than a site.
        return d.contains(".") && Validation.isValidDomain(d) ? d : nil
    }

    /// What of a list can choose the DNS server: its names.
    public enum Names: Equatable, Sendable {
        /// No names: addresses only.
        case none
        /// Names only: the list itself.
        case whole
        /// Names and addresses: this source rule-set, its names alone.
        case part(Data)
    }

    static let nameFields = ["domain", "domain_suffix", "domain_keyword", "domain_regex"]
    /// In a DNS rule sing-box matches these against the answer, after asking
    /// the rule's server — for any name, in the list or not.
    static let addressFields = ["ip_cidr", "ip_is_private"]

    /// The names of a source rule-set, for DNS rules. Its addresses stay
    /// out: there they would send names that are not in the list to the
    /// list's DNS server too (only to see whether the answer is one of
    /// them), past the tunnel when the list goes direct.
    public static func names(_ source: Data) -> Names {
        guard var obj = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
              let rules = obj["rules"] as? [[String: Any]] else { return .none }
        func has(_ r: [String: Any], _ fields: [String]) -> Bool {
            fields.contains { r[$0] != nil } || ((r["rules"] as? [[String: Any]])?.contains { has($0, fields) } ?? false)
        }
        guard rules.contains(where: { has($0, nameFields) }) else { return .none }
        guard rules.contains(where: { has($0, addressFields) }) else { return .whole }
        // A plain rule loses its address fields (they only widen it: sing-box
        // matches any of a rule's names and addresses); an inverted or a
        // logical one is kept only without addresses, since taking a part
        // out of it could make it match more.
        var kept: [[String: Any]] = []
        for r in rules {
            if (r["type"] as? String ?? "default") == "default", r["invert"] as? Bool != true {
                var named = r
                for f in addressFields { named[f] = nil }
                if has(named, nameFields) { kept.append(named) }
            } else if has(r, nameFields), !has(r, addressFields) {
                kept.append(r)
            }
        }
        guard !kept.isEmpty else { return .none }
        obj["rules"] = kept
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return .none }
        return .part(data)
    }

    /// The rule-set tag of a list's names alone (`Names.part`). Not
    /// `list-…`: no list name can make it.
    public static func namesTag(_ name: String) -> String { "names-" + tag(name) }

    /// A list's addresses, for macOS's routing table and the kill switch
    /// (`SingBoxConfig.systemDirect`): its networks when each one matches
    /// on its own, whatever else the list holds. Nil when an address is
    /// tied to something only sing-box can check (a port, an inverted or a
    /// logical rule, the local network): such a list is left to sing-box.
    public static func addresses(_ source: Data) -> [IPNetwork]? {
        guard let obj = try? JSONSerialization.jsonObject(with: source) as? [String: Any],
              let rules = obj["rules"] as? [[String: Any]] else { return nil }
        func has(_ r: [String: Any], _ fields: [String]) -> Bool {
            fields.contains { r[$0] != nil } || ((r["rules"] as? [[String: Any]])?.contains { has($0, fields) } ?? false)
        }
        var out: [IPNetwork] = []
        for r in rules where has(r, addressFields) {
            // sing-box matches any of a plain rule's names and networks:
            // its networks alone are then exactly what it matches by address.
            let plain = (r["type"] as? String ?? "default") == "default" && r["invert"] as? Bool != true
            let fields = Set(r.keys).subtracting(["type", "invert"])
            // One network is written as a string, several as a list.
            guard plain, r["ip_is_private"] == nil, fields.isSubset(of: Set(nameFields + ["ip_cidr"])),
                  let cidrs = r["ip_cidr"] as? [String] ?? (r["ip_cidr"] as? String).map({ [$0] }) else { return nil }
            for c in cidrs {
                guard let n = IPNetwork(c) else { return nil }
                out.append(n)
            }
        }
        return out
    }
}

/// One list, as the helper reports it.
public struct RuleListInfo: Codable, Hashable, Sendable, Identifiable {
    public var url: String
    /// Size on disk; nil: not downloaded yet.
    public var bytes: Int?
    /// When it was last confirmed current (downloaded, or found unchanged).
    public var updated: Date?
    /// Why the last attempt failed, if it did.
    public var error: String?
    /// Whether it holds networks macOS can route (`RuleLists.addresses`);
    /// nil: not known.
    public var hasAddresses: Bool?
    public var id: String { url }

    public init(url: String, bytes: Int? = nil, updated: Date? = nil, error: String? = nil, hasAddresses: Bool? = nil) {
        self.url = url
        self.bytes = bytes
        self.updated = updated
        self.error = error
        self.hasAddresses = hasAddresses
    }
}
