import Foundation

/// The rule editor's text forms: one destination per line, ports as
/// "443, 8000-8100". Parsing is strict and reports every bad line, so a
/// typo never silently becomes a rule that matches nothing (or everything).
public enum RuleText {
    public struct LineError: Hashable, Sendable, CustomStringConvertible {
        public var line: String
        public var reason: String
        public var description: String { "“\(line)”: \(reason)" }
    }

    /// Accepted forms, one per line (blank lines and `#` comments ignored):
    ///   example.com            the domain and its subdomains
    ///   =example.com           exactly this name
    ///   *.example.com, .example.com   same as example.com
    ///   keyword:tube           any domain containing "tube"
    ///   list:blocked-sites        one of the profile's lists
    ///   10.0.0.0/8, 1.2.3.4, 2001:db8::/32   addresses
    public static func destinations(_ text: String) -> (values: [Destination], errors: [LineError]) {
        var out: [Destination] = []
        var errors: [LineError] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            switch destination(line) {
            case .success(let d): if !out.contains(d) { out.append(d) }
            case .failure(let e): errors.append(LineError(line: line, reason: e.reason))
            }
        }
        return (out, errors)
    }

    struct Reason: Error { var reason: String }

    static func destination(_ s: String) -> Result<Destination, Reason> {
        let lower = s.lowercased()
        if lower.hasPrefix("list:") {
            let name = String(lower.dropFirst(5))
            guard RuleLists.isValidName(name) else { return .failure(Reason(reason: "a list name is letters, digits and “-”, like list:blocked-sites")) }
            return .success(.list(name))
        }
        if lower.hasPrefix("keyword:") {
            let k = String(lower.dropFirst(8))
            guard !k.isEmpty, k.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
                return .failure(Reason(reason: "a keyword is letters, digits, “-” or “.”"))
            }
            return .success(.domainKeyword(k))
        }
        // A pasted web address means its host.
        if lower.contains("://"), let host = URL(string: s)?.host, !host.isEmpty {
            return destination(host)
        }
        if let net = IPNetwork(s) { return .success(.cidr(net)) }
        if s.contains("/") || s.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
            return .failure(Reason(reason: "not a valid address or network"))
        }
        var exact = false
        var name = lower
        if name.hasPrefix("=") { exact = true; name.removeFirst() }
        if name.hasPrefix("*.") { name.removeFirst(2) } else if name.hasPrefix(".") { name.removeFirst() }
        name = Validation.normalizeDomain(name)
        guard Validation.isValidDomain(name) else { return .failure(Reason(reason: "not a valid domain")) }
        return .success(exact ? .domain(name) : .domainSuffix(name))
    }

    /// The editor text for a list of destinations; `destinations` reads it back.
    public static func text(_ ds: [Destination]) -> String {
        ds.map(text).joined(separator: "\n")
    }

    public static func text(_ d: Destination) -> String {
        switch d {
        case .cidr(let n): n.description
        case .domainSuffix(let s): s
        case .domain(let s): "=" + s
        case .domainKeyword(let k): "keyword:" + k
        case .list(let n): "list:" + n
        case .localNetwork: "local network"
        }
    }

    /// "443, 8000-8100" (spaces and commas both separate).
    public static func ports(_ text: String) -> (values: [PortRange], errors: [LineError]) {
        var out: [PortRange] = []
        var errors: [LineError] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            let item = String(raw)
            let ends = item.split(separator: "-", omittingEmptySubsequences: false)
            let nums = ends.map { UInt16($0) }
            guard (1...2).contains(ends.count), nums.allSatisfy({ ($0 ?? 0) > 0 }) else {
                errors.append(LineError(line: item, reason: "a port is 1–65535, a range is like 8000-8100"))
                continue
            }
            let r = PortRange(nums[0]!, nums.last!!)
            guard r.lower <= r.upper else {
                errors.append(LineError(line: item, reason: "the range is backwards"))
                continue
            }
            if !out.contains(r) { out.append(r) }
        }
        return (out, errors)
    }

    public static func text(_ ports: [PortRange]) -> String {
        ports.map { $0.lower == $0.upper ? "\($0.lower)" : "\($0.lower)-\($0.upper)" }.joined(separator: ", ")
    }
}
