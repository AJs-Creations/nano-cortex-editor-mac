// Protobuf wire format, the subset the Nano Cortex uses: varints, length-delimited
// fields, fixed32 floats, fixed64. Ported one to one from the Electron app's
// parseProtoFields/encodeVarint so the bytes match the verified implementation.

import Foundation

public enum ProtoValue: Equatable, Sendable {
    case varint(UInt64)
    case fixed64([UInt8])
    case bytes([UInt8])
    case fixed32([UInt8])

    public var varint: UInt64? { if case .varint(let v) = self { return v }; return nil }
    public var bytes: [UInt8]? { if case .bytes(let b) = self { return b }; return nil }
    public var string: String? { bytes.flatMap { String(bytes: $0, encoding: .utf8) } }
    public var float32: Float? {
        if case .fixed32(let b) = self, b.count == 4 { return Float(bitPattern: LE.u32(b, 0)) }
        return nil
    }
}

/// Parsed fields in order; repeated fields keep every value.
public struct ProtoFields: Sendable {
    public private(set) var fields: [Int: [ProtoValue]] = [:]

    public subscript(_ number: Int) -> [ProtoValue] { fields[number] ?? [] }
    public func first(_ number: Int) -> ProtoValue? { fields[number]?.first }
    public func string(_ number: Int) -> String? { first(number)?.string }
    public func int(_ number: Int) -> UInt64? { first(number)?.varint }
    public func message(_ number: Int) -> ProtoFields? { first(number)?.bytes.map { ProtoFields.parse($0) } }

    /// Lenient like upstream: stops at the first malformed tag instead of throwing.
    public static func parse(_ bytes: [UInt8]) -> ProtoFields {
        var out = ProtoFields()
        var i = 0
        while i < bytes.count {
            guard let (tag, next) = Varint.read(bytes, at: i) else { break }
            let field = Int(tag >> 3), wire = tag & 0x7
            i = next
            switch wire {
            case 0:
                guard let (v, n) = Varint.read(bytes, at: i) else { return out }
                out.fields[field, default: []].append(.varint(v)); i = n
            case 1:
                guard i + 8 <= bytes.count else { return out }
                out.fields[field, default: []].append(.fixed64(Array(bytes[i..<i + 8]))); i += 8
            case 2:
                guard let (len, start) = Varint.read(bytes, at: i), start + Int(len) <= bytes.count else { return out }
                out.fields[field, default: []].append(.bytes(Array(bytes[start..<start + Int(len)]))); i = start + Int(len)
            case 5:
                guard i + 4 <= bytes.count else { return out }
                out.fields[field, default: []].append(.fixed32(Array(bytes[i..<i + 4]))); i += 4
            default:
                return out
            }
        }
        return out
    }
}

public enum Varint {
    public static func encode(_ value: UInt64) -> [UInt8] {
        var v = value, out: [UInt8] = []
        while v > 0x7f { out.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        out.append(UInt8(v))
        return out
    }
    /// protobuf int32: negative values are sign-extended to 10 bytes.
    public static func encodeInt32(_ value: Int32) -> [UInt8] { encode(UInt64(bitPattern: Int64(value))) }
    public static func read(_ bytes: [UInt8], at index: Int) -> (UInt64, Int)? {
        var v: UInt64 = 0, shift: UInt64 = 0, i = index
        while i < bytes.count, shift < 64 {
            let b = bytes[i]; i += 1
            v |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return (v, i) }
            shift += 7
        }
        return nil
    }
}

/// Builds protobuf bodies: `ProtoWriter().int(1, 6).bytes(3, ...).build()`.
public struct ProtoWriter: Sendable {
    private var out: [UInt8] = []
    public init() {}
    private static func tag(_ field: Int, _ wire: UInt64) -> [UInt8] { Varint.encode(UInt64(field) << 3 | wire) }
    public func int(_ field: Int, _ value: UInt64) -> ProtoWriter { var w = self; w.out += Self.tag(field, 0) + Varint.encode(value); return w }
    public func int32(_ field: Int, _ value: Int32) -> ProtoWriter { var w = self; w.out += Self.tag(field, 0) + Varint.encodeInt32(value); return w }
    public func bytes(_ field: Int, _ value: [UInt8]) -> ProtoWriter { var w = self; w.out += Self.tag(field, 2) + Varint.encode(UInt64(value.count)) + value; return w }
    public func string(_ field: Int, _ value: String) -> ProtoWriter { bytes(field, Array(value.utf8)) }
    public func message(_ field: Int, _ inner: ProtoWriter) -> ProtoWriter { bytes(field, inner.build()) }
    public func float32(_ field: Int, _ value: Float) -> ProtoWriter {
        var w = self
        w.out += Self.tag(field, 5) + LE.bytes(value.bitPattern)
        return w
    }
    public func build() -> [UInt8] { out }
}

/// Little-endian helpers, kept trivial so the type checker stays fast.
public enum LE {
    public static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        var v = UInt32(b[i + 3]); v <<= 8
        v |= UInt32(b[i + 2]); v <<= 8
        v |= UInt32(b[i + 1]); v <<= 8
        v |= UInt32(b[i])
        return v
    }
    public static func bytes(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
}
