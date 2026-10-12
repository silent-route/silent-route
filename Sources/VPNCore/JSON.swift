import Foundation

/// A minimal JSON value for building sing-box configs.
///
/// Configs are assembled from this rather than from Codable structs mirroring
/// sing-box's schema: the schema is large and changes between releases, and
/// only a small part of it is ever written. Output is deterministic (sorted
/// keys) so golden files diff cleanly.
public enum JSON: Hashable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSON])
    case object([String: JSON])

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding a tree of strings, ints and bools cannot fail.
        return try! enc.encode(self)
    }

    public var text: String { String(decoding: encoded(), as: UTF8.self) }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

extension JSON: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSON...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSON)...) { self = .object(Dictionary(v, uniquingKeysWith: { $1 })) }
}

extension JSON {
    static func strings(_ a: [String]) -> JSON { .array(a.map(JSON.string)) }
}
