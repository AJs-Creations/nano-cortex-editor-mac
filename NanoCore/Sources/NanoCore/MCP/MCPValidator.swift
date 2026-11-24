// Argument validation against a tool's input schema (mcp/PROTOCOL.md §4 "Validation and order"): types, enums,
// ranges, lengths, patterns, required, no unknown keys. A refusal is one sentence naming the field, e.g.
// "slot must be one of pre1, pre2, post1, post2, post3." Covers the JSON Schema subset tools.json uses.

import Foundation

public enum MCPValidator {
    /// nil when `args` fits `schema`, else the sentence for the assistant.
    public static func validate(_ args: JSONValue, schema: JSONValue) -> String? {
        guard case .object = args else { return "The arguments must be an object." }
        return check(args, schema, path: "")
    }

    private static func check(_ value: JSONValue, _ schema: JSONValue, path: String) -> String? {
        let field = path.isEmpty ? "The arguments" : path
        if let types = typeList(schema["type"]), !types.contains(where: { matches(value, $0) }) {
            return "\(field) must be \(describe(types))."
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            return "\(field) must be one of \(options.map(show).joined(separator: ", "))."
        }
        switch value {
        case .number(let n):
            let lo = schema["minimum"]?.numberValue, hi = schema["maximum"]?.numberValue
            if (lo.map { n < $0 } ?? false) || (hi.map { n > $0 } ?? false) {
                if let lo, let hi { return "\(field) must be between \(format(lo)) and \(format(hi))." }
                if let lo { return "\(field) must be at least \(format(lo))." }
                if let hi { return "\(field) must be at most \(format(hi))." }
            }
        case .string(let s):
            let count = s.count
            let lo = schema["minLength"]?.intValue, hi = schema["maxLength"]?.intValue
            if (lo.map { count < $0 } ?? false) || (hi.map { count > $0 } ?? false) {
                if let lo, let hi { return "\(field) must be \(lo) to \(hi) characters long." }
                if let lo { return "\(field) must be at least \(lo) characters long." }
                if let hi { return "\(field) must be at most \(hi) characters long." }
            }
            if let pattern = schema["pattern"]?.stringValue, s.range(of: pattern, options: .regularExpression) == nil {
                return pattern.contains("{8}-") ? "\(field) must be a Cortex Cloud product id (a UUID such as 3f2b9c1e-…), as cloud_search returns it."
                                                : "\(field) is not in the expected format."
            }
        case .array(let items):
            if let max = schema["maxItems"]?.intValue, items.count > max { return "\(field) may have at most \(max) entries." }
            if let min = schema["minItems"]?.intValue, items.count < min { return "\(field) needs at least \(min) entries." }
            if let item = schema["items"] {
                for (i, v) in items.enumerated() { if let e = check(v, item, path: "\(path)[\(i)]") { return e } }
            }
        case .object(let o):
            let props = schema["properties"]?.objectValue ?? [:]
            for name in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where o[name] == nil {
                return "\(join(path, name)) is required."
            }
            for key in o.keys.sorted() {
                let sub = join(path, key)
                if let p = props[key] {
                    if let e = check(o[key]!, p, path: sub) { return e }
                } else if let extra = schema["additionalProperties"] {
                    if extra == .bool(false) {
                        let allowed = props.keys.sorted()
                        return "\(sub) is not a known argument" + (allowed.isEmpty ? " (this tool takes none)." : " (allowed: \(allowed.joined(separator: ", "))).")
                    }
                    if case .object = extra, let e = check(o[key]!, extra, path: sub) { return e }
                }
            }
        default: break
        }
        return nil
    }

    private static func join(_ path: String, _ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
    private static func typeList(_ t: JSONValue?) -> [String]? {
        switch t { case .string(let s)?: [s]; case .array(let a)?: a.compactMap(\.stringValue); default: nil }
    }
    private static func matches(_ v: JSONValue, _ type: String) -> Bool {
        switch (type, v) {
        case ("number", .number): true
        case ("integer", .number(let n)): n == n.rounded()
        case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null): true
        default: false
        }
    }
    private static func describe(_ types: [String]) -> String {
        let words = types.map { t -> String in
            switch t { case "number": "a number"; case "integer": "a whole number"; case "string": "a string"; case "boolean": "true or false"
            case "object": "an object"; case "array": "a list"; default: t }
        }
        return words.count == 1 ? words[0] : words.dropLast().joined(separator: ", ") + " or " + words.last!
    }
    private static func show(_ v: JSONValue) -> String { if case .string(let s) = v { return s }; return v.compact }

    /// 2 → "2", 2.5 → "2.5", -96 → "-96".
    public static func format(_ x: Double) -> String {
        if x == x.rounded(), abs(x) < 1e12 { return String(Int(x)) }
        var s = String(format: "%.4f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
