// A small JSON value type for the MCP helper: ordered object keys, numbers as Double (as in JavaScript), a strict
// parser (what JSON.parse accepts) and a serializer that writes exactly what JSON.stringify writes (key order of
// JavaScript objects, number formatting, string escaping, the 2-space indented form).

import Foundation

struct JSONObject: Sendable, Equatable {
    private(set) var keys: [String] = []
    private var dict: [String: JSON] = [:]

    init() {}

    /// Pairs with a nil value are left out (JSON.stringify drops undefined values).
    init(_ pairs: [(String, JSON?)]) {
        for (k, v) in pairs { if let v { self[k] = v } }
    }

    subscript(key: String) -> JSON? {
        get { dict[key] }
        set {
            if let newValue {
                if dict.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if dict.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    var isEmpty: Bool { keys.isEmpty }
    var entries: [(String, JSON)] { keys.map { ($0, dict[$0]!) } }
}

enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)

    static func obj(_ pairs: [(String, JSON?)]) -> JSON { .object(JSONObject(pairs)) }
    static let emptyObject = JSON.object(JSONObject())

    var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }

    subscript(key: String) -> JSON? { object?[key] }

    /// JavaScript truthiness.
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let d): return d != 0 && !d.isNaN
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    /// JavaScript String(value).
    var jsString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let d): return jsNumberString(d)
        case .string(let s): return s
        case .array(let a): return a.map { $0 == .null ? "" : $0.jsString }.joined(separator: ",")
        case .object: return "[object Object]"
        }
    }
}

/// String(x) for a value that may be undefined (nil).
func jsConcat(_ v: JSON?) -> String { v?.jsString ?? "undefined" }

/// `a && a.key` in JavaScript: a falsy `a` is the result itself; nil stands for undefined.
func andProp(_ v: JSON?, _ key: String) -> JSON? {
    guard let v else { return nil }
    if !v.truthy { return v }
    return v[key]
}

// MARK: - Numbers as JavaScript prints them (Number::toString)

func jsNumberString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
    if d == 0 { return "0" }
    // Swift prints the shortest digits that round-trip (as JavaScript does); only the layout differs.
    let s = abs(d).description
    var mantissa = Substring(s)
    var exp = 0
    if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = s[..<e]
        exp = Int(s[s.index(after: e)...]) ?? 0
    }
    var digits: [UInt8] = []
    var point = -1
    for c in mantissa.utf8 {
        if c == UInt8(ascii: ".") { point = digits.count } else { digits.append(c) }
    }
    if point < 0 { point = digits.count }
    var n = point + exp
    var lead = 0
    while lead < digits.count - 1 && digits[lead] == UInt8(ascii: "0") { lead += 1 }
    digits.removeFirst(lead)
    n -= lead
    while digits.count > 1 && digits.last == UInt8(ascii: "0") { digits.removeLast() }
    let k = digits.count
    let zero = UInt8(ascii: "0")
    var out: [UInt8] = d < 0 ? [UInt8(ascii: "-")] : []
    if k <= n && n <= 21 {
        out += digits
        out += [UInt8](repeating: zero, count: n - k)
    } else if 0 < n && n <= 21 {
        out += digits[0..<n]
        out.append(UInt8(ascii: "."))
        out += digits[n...]
    } else if -6 < n && n <= 0 {
        out += [zero, UInt8(ascii: ".")]
        out += [UInt8](repeating: zero, count: -n)
        out += digits
    } else {
        let e = n - 1
        out.append(digits[0])
        if k > 1 {
            out.append(UInt8(ascii: "."))
            out += digits[1...]
        }
        out.append(UInt8(ascii: "e"))
        out.append(e < 0 ? UInt8(ascii: "-") : UInt8(ascii: "+"))
        out += Array(String(abs(e)).utf8)
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Parser (strict, as JSON.parse)

struct JSONParser {
    private struct Bad: Error {}
    private let b: [UInt8]
    private var i = 0
    private var depth = 0
    private static let maxDepth = 512

    private init(_ bytes: [UInt8]) { b = bytes }

    static func parse(_ bytes: [UInt8]) -> JSON? {
        var p = JSONParser(bytes)
        do {
            p.skipWhitespace()
            let v = try p.value()
            p.skipWhitespace()
            return p.i == p.b.count ? v : nil
        } catch {
            return nil
        }
    }

    static func parse(_ text: String) -> JSON? { parse(Array(text.utf8)) }

    private mutating func skipWhitespace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    private mutating func expect(_ word: String) throws {
        for c in word.utf8 {
            guard i < b.count, b[i] == c else { throw Bad() }
            i += 1
        }
    }

    private mutating func value() throws -> JSON {
        guard i < b.count else { throw Bad() }
        switch b[i] {
        case UInt8(ascii: "{"): return try objectValue()
        case UInt8(ascii: "["): return try arrayValue()
        case UInt8(ascii: "\""): return .string(try stringValue())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try numberValue())
        }
    }

    private mutating func objectValue() throws -> JSON {
        depth += 1
        guard depth <= Self.maxDepth else { throw Bad() }
        defer { depth -= 1 }
        i += 1
        var o = JSONObject()
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
        while true {
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw Bad() }
            let k = try stringValue()
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw Bad() }
            i += 1
            skipWhitespace()
            o[k] = try value()
            skipWhitespace()
            guard i < b.count else { throw Bad() }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
            throw Bad()
        }
    }

    private mutating func arrayValue() throws -> JSON {
        depth += 1
        guard depth <= Self.maxDepth else { throw Bad() }
        defer { depth -= 1 }
        i += 1
        var a: [JSON] = []
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
        while true {
            skipWhitespace()
            a.append(try value())
            skipWhitespace()
            guard i < b.count else { throw Bad() }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            throw Bad()
        }
    }

    private static func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(c - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(c - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw Bad() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            guard let h = Self.hexValue(b[i]) else { throw Bad() }
            v = v << 4 | h
            i += 1
        }
        return v
    }

    private mutating func stringValue() throws -> String {
        i += 1   // the opening quote
        var out: [UInt8] = []
        var runStart = i
        while true {
            guard i < b.count else { throw Bad() }
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                out += b[runStart..<i]
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { throw Bad() }
            if c != UInt8(ascii: "\\") { i += 1; continue }
            out += b[runStart..<i]
            i += 1
            guard i < b.count else { throw Bad() }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var code = try hex4()
                if (0xD800...0xDBFF).contains(code), i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u") {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save   // a lone high surrogate; the next escape stands on its own
                    }
                }
                // A lone surrogate cannot live in a Swift string: it becomes U+FFFD.
                let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                out += Array(String(Character(scalar)).utf8)
            default:
                throw Bad()
            }
            runStart = i
        }
    }

    private mutating func numberValue() throws -> Double {
        let start = i
        if i < b.count, b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw Bad() }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if b[i] >= UInt8(ascii: "1") && b[i] <= UInt8(ascii: "9") {
            while i < b.count, b[i] >= UInt8(ascii: "0") && b[i] <= UInt8(ascii: "9") { i += 1 }
        } else {
            throw Bad()
        }
        if i < b.count, b[i] == UInt8(ascii: ".") {
            i += 1
            let s = i
            while i < b.count, b[i] >= UInt8(ascii: "0") && b[i] <= UInt8(ascii: "9") { i += 1 }
            guard i > s else { throw Bad() }
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            let s = i
            while i < b.count, b[i] >= UInt8(ascii: "0") && b[i] <= UInt8(ascii: "9") { i += 1 }
            guard i > s else { throw Bad() }
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        guard let d = Double(text) else { throw Bad() }
        return d
    }
}

// MARK: - Serializer (as JSON.stringify)

enum JSONWriter {
    /// JSON.stringify(v) (indent 0) or JSON.stringify(v, null, indent).
    static func bytes(_ v: JSON, indent: Int = 0) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(256)
        emit(v, indent, 0, &out)
        return out
    }

    static func string(_ v: JSON, indent: Int = 0) -> String {
        String(decoding: bytes(v, indent: indent), as: UTF8.self)
    }

    private static func newline(_ indent: Int, _ level: Int, _ out: inout [UInt8]) {
        guard indent > 0 else { return }
        out.append(0x0A)
        out += [UInt8](repeating: 0x20, count: indent * level)
    }

    private static func emit(_ v: JSON, _ indent: Int, _ level: Int, _ out: inout [UInt8]) {
        switch v {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(let d): out += Array((d.isFinite ? jsNumberString(d) : "null").utf8)
        case .string(let s): escape(s, &out)
        case .array(let a):
            if a.isEmpty { out += Array("[]".utf8); return }
            out.append(UInt8(ascii: "["))
            for (n, e) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(indent, level + 1, &out)
                emit(e, indent, level + 1, &out)
            }
            newline(indent, level, &out)
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            if o.isEmpty { out += Array("{}".utf8); return }
            out.append(UInt8(ascii: "{"))
            for (n, k) in jsKeyOrder(o.keys).enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                newline(indent, level + 1, &out)
                escape(k, &out)
                out.append(UInt8(ascii: ":"))
                if indent > 0 { out.append(0x20) }
                emit(o[k]!, indent, level + 1, &out)
            }
            newline(indent, level, &out)
            out.append(UInt8(ascii: "}"))
        }
    }

    /// JavaScript objects list array-index keys first (ascending), then the others in insertion order.
    private static func jsKeyOrder(_ keys: [String]) -> [String] {
        var indexed: [(UInt64, String)] = []
        var named: [String] = []
        for k in keys {
            if let n = arrayIndex(k) { indexed.append((n, k)) } else { named.append(k) }
        }
        if indexed.isEmpty { return keys }
        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 } + named
    }

    private static func arrayIndex(_ k: String) -> UInt64? {
        let u = Array(k.utf8)
        guard let f = u.first, f >= UInt8(ascii: "0"), f <= UInt8(ascii: "9") else { return nil }
        if u.count == 1 { return UInt64(f - UInt8(ascii: "0")) }
        guard f != UInt8(ascii: "0"), u.count <= 10, u.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let n = UInt64(k), n < 4_294_967_295 else { return nil }
        return n
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func escape(_ s: String, _ out: inout [UInt8]) {
        out.append(0x22)
        for c in s.utf8 {
            switch c {
            case 0x22: out += [0x5C, 0x22]
            case 0x5C: out += [0x5C, 0x5C]
            case 0x08: out += [0x5C, UInt8(ascii: "b")]
            case 0x0C: out += [0x5C, UInt8(ascii: "f")]
            case 0x0A: out += [0x5C, UInt8(ascii: "n")]
            case 0x0D: out += [0x5C, UInt8(ascii: "r")]
            case 0x09: out += [0x5C, UInt8(ascii: "t")]
            case 0..<0x20:
                out += [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hexDigits[Int(c >> 4)], hexDigits[Int(c & 15)]]
            default: out.append(c)
            }
        }
        out.append(0x22)
    }
}

// MARK: - JavaScript String.prototype.trim

private let jsWhitespace: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
]

func jsTrim(_ s: String) -> String {
    let u = s.unicodeScalars
    guard let first = u.firstIndex(where: { !jsWhitespace.contains($0.value) }) else { return "" }
    let last = u.lastIndex(where: { !jsWhitespace.contains($0.value) })!
    return String(u[first...last])
}

/// JavaScript s.slice(0, n) (UTF-16 code units). A surrogate pair cut in half is dropped instead of kept alone.
func jsSlice(_ s: String, _ n: Int) -> String {
    let u = s.utf16
    guard u.count > n else { return s }
    var end = u.index(u.startIndex, offsetBy: n)
    if let r = String(u[..<end]) { return r }
    end = u.index(before: end)
    return String(u[..<end]) ?? ""
}
