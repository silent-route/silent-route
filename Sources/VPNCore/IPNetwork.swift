import Foundation

/// An IPv4 or IPv6 network in CIDR form, parsed rather than passed through as
/// text: whatever ends up in a sing-box config or a pf table has been through
/// this parser, so a malformed or hostile string cannot reach either.
public struct IPNetwork: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Family: Sendable { case v4, v6 }

    /// Network address bytes (4 or 16), host bits cleared.
    public let bytes: [UInt8]
    public let prefix: Int

    public var family: Family { bytes.count == 4 ? .v4 : .v6 }

    /// Accepts `a.b.c.d`, `a.b.c.d/n`, IPv6 in any standard form, `addr/n`.
    /// A bare address becomes a /32 or /128. Host bits are cleared, so
    /// `10.1.2.3/8` is stored as `10.0.0.0/8`.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let addr = String(parts[0])
        guard let raw = IPNetwork.parseV4(addr) ?? IPNetwork.parseV6(addr) else { return nil }
        let maxPrefix = raw.count * 8
        var prefix = maxPrefix
        if parts.count == 2 {
            let p = parts[1]
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCIIDigit), let n = Int(p), n <= maxPrefix else { return nil }
            prefix = n
        }
        self.bytes = IPNetwork.mask(raw, prefix: prefix)
        self.prefix = prefix
    }

    public var description: String {
        let addr = family == .v4 ? bytes.map(String.init).joined(separator: ".") : IPNetwork.formatV6(bytes)
        return "\(addr)/\(prefix)"
    }

    /// True if `address` (a single host) lies inside this network.
    public func contains(_ address: IPNetwork) -> Bool {
        guard address.bytes.count == bytes.count, address.prefix >= prefix else { return false }
        return IPNetwork.mask(address.bytes, prefix: prefix) == bytes
    }

    /// The part of this network outside `other`: itself when they do not
    /// overlap, nothing when `other` covers it, else the halves around
    /// `other`, one per bit between the two prefixes.
    public func subtracting(_ other: IPNetwork) -> [IPNetwork] {
        guard other.bytes.count == bytes.count else { return [self] }
        if other.prefix <= prefix, IPNetwork.mask(bytes, prefix: other.prefix) == other.bytes { return [] }
        guard prefix < other.prefix, IPNetwork.mask(other.bytes, prefix: prefix) == bytes else { return [self] }
        var out: [IPNetwork] = []
        var rest = self
        while rest.prefix < other.prefix {
            // Split in two: the half holding `other` goes on, the other stays.
            let bit = rest.prefix
            var flipped = IPNetwork.mask(other.bytes, prefix: bit + 1)
            flipped[bit / 8] ^= 0x80 >> UInt8(bit % 8)
            out.append(IPNetwork(bytes: flipped, prefix: bit + 1))
            rest = IPNetwork(bytes: IPNetwork.mask(other.bytes, prefix: bit + 1), prefix: bit + 1)
        }
        return out
    }

    init(bytes: [UInt8], prefix: Int) {
        self.bytes = IPNetwork.mask(bytes, prefix: prefix)
        self.prefix = prefix
    }

    // MARK: Codable as a plain string

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let net = IPNetwork(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not an IP network: \(text)"))
        }
        self = net
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    // MARK: Parsing

    static func parseV4(_ s: String) -> [UInt8]? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var out: [UInt8] = []
        for o in octets {
            // No leading zeros: "010" is octal to some parsers and decimal to
            // others, so it is rejected rather than guessed.
            guard !o.isEmpty, o.count <= 3, o.allSatisfy(\.isASCIIDigit),
                  o == "0" || o.first != "0", let v = UInt8(o) else { return nil }
            out.append(v)
        }
        return out
    }

    static func parseV6(_ s: String) -> [UInt8]? {
        guard s.contains(":"), !s.contains(":::") else { return nil }
        var text = Substring(s)
        var tail4: [UInt8] = []
        // Embedded IPv4 in the last 32 bits, e.g. ::ffff:1.2.3.4
        if let lastColon = text.lastIndex(of: ":"), text[text.index(after: lastColon)...].contains(".") {
            guard let v4 = parseV4(String(text[text.index(after: lastColon)...])) else { return nil }
            tail4 = v4
            text = text[...lastColon]
            if text.hasSuffix(":") && !text.hasSuffix("::") { text = text.dropLast() }
        }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [UInt16]? {
            if part.isEmpty { return [] }
            var out: [UInt16] = []
            for g in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard !g.isEmpty, g.count <= 4, g.allSatisfy(\.isHexDigit), let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        guard let head = groups(halves[0]) else { return nil }
        let tail = halves.count == 2 ? groups(halves[1]) : []
        guard let tail else { return nil }
        let needed = 8 - tail4.count / 2
        var all: [UInt16]
        if halves.count == 2 {
            let missing = needed - head.count - tail.count
            guard missing >= 1 else { return nil }
            all = head + Array(repeating: 0, count: missing) + tail
        } else {
            guard head.count == needed else { return nil }
            all = head
        }
        var out: [UInt8] = []
        for g in all { out += [UInt8(g >> 8), UInt8(g & 0xff)] }
        return out + tail4
    }

    static func mask(_ raw: [UInt8], prefix: Int) -> [UInt8] {
        raw.enumerated().map { i, b in
            let bits = max(0, min(8, prefix - i * 8))
            return bits == 8 ? b : b & UInt8(truncatingIfNeeded: 0xff << (8 - bits))
        }
    }

    /// RFC 5952 form: lowercase, longest run of zero groups as "::".
    static func formatV6(_ b: [UInt8]) -> String {
        let g = stride(from: 0, to: 16, by: 2).map { UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]) }
        var bestStart = -1, bestLen = 0, i = 0
        while i < 8 {
            if g[i] == 0 {
                var j = i
                while j < 8 && g[j] == 0 { j += 1 }
                if j - i > bestLen && j - i >= 2 { bestStart = i; bestLen = j - i }
                i = j
            } else { i += 1 }
        }
        let hex = g.map { String($0, radix: 16) }
        if bestStart < 0 { return hex.joined(separator: ":") }
        let left = hex[..<bestStart].joined(separator: ":")
        let right = hex[(bestStart + bestLen)...].joined(separator: ":")
        return left + "::" + right
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
