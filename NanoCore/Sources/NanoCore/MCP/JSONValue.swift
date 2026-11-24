// A JSON value with exact types (true stays a boolean, 1 stays a number), for the MCP contract and the messages the
// editor exchanges with its helper (mcp/PROTOCOL.md §2). JSONSerialization's NSNumber blurs booleans and numbers; this
// does not.

import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(_ v: Bool) { self = .bool(v) }
    public init(_ v: Int) { self = .number(Double(v)) }
    public init(_ v: Double) { self = .number(v) }
    public init(_ v: String) { self = .string(v) }
    public init(_ v: [JSONValue]) { self = .array(v) }
    public init(_ v: [String: JSONValue]) { self = .object(v) }
    /// nil → null.
    public init<T>(_ v: T?, _ wrap: (T) -> JSONValue) { self = v.map(wrap) ?? .null }

    public subscript(key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public subscript(index: Int) -> JSONValue? { if case .array(let a) = self, a.indices.contains(index) { return a[index] }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var numberValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .number(let n) = self, n == n.rounded(), abs(n) < 1e15 { return Int(n) }; return nil }
    public var isNull: Bool { self == .null }

    // MARK: text

    public static func parse(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }
    public static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8)) }
    /// One line of JSON (keys sorted, so the output is stable), no trailing newline.
    public var compact: String { Self.text(self, pretty: false) }
    /// 2-space indented JSON (the helper's text content).
    public var pretty: String { Self.text(self, pretty: true) }
    private static func text(_ v: JSONValue, pretty: Bool) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n.isFinite { try c.encode(n) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                     ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b })) }
}
