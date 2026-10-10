// C304/C305 framing. Every message is `protobuf body + u32 LE message type`.
// One write/notification: `[len & 0xFF, flags, …]` with
//   flags = 0x40 first | 0x80 last | bit 0 = bit 8 of len.
// A message that fits in one packet is therefore the familiar `len C0 body type`.
// Big ones are streamed in 500-byte writes (the official app's size), the last
// one padded to 500. Verified against the phone-app trace and the pedal.

import Foundation

public enum Frame {
    public static let writeSize = 500
    public static let chunkData = writeSize - 2

    /// Message type carried in the last 4 bytes of a complete (single-packet) frame.
    public static func type(of packet: [UInt8]) -> UInt32? {
        guard packet.count >= 6, packet[1] == 0xC0 else { return nil }
        return LE.u32(packet, packet.count - 4)
    }

    /// Body of a single-packet frame (between the 2-byte header and the 4-byte type).
    public static func body(of packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 6, packet[1] == 0xC0 else { return nil }
        return Array(packet[2..<(packet.count - 4)])
    }

    /// A single-packet frame for a small message.
    public static func single(body: [UInt8], type: UInt32) -> [UInt8] {
        let all = body + typeBytes(type)
        return [UInt8(all.count & 0xff), 0xC0 | UInt8(all.count >> 8 & 1)] + all
    }

    /// The writes for a message of any size (padded last chunk like the official app).
    public static func chunks(body: [UInt8], type: UInt32, pad: Bool = true) -> [[UInt8]] {
        let all = body + typeBytes(type)
        var out: [[UInt8]] = []
        var i = 0
        while i < all.count || out.isEmpty {
            let part = Array(all[i..<min(i + chunkData, all.count)])
            let last = i + chunkData >= all.count
            let flags: UInt8 = (i == 0 ? 0x40 : 0) | (last ? 0x80 : 0) | UInt8(part.count >> 8 & 1)
            var frame = [UInt8(part.count & 0xff), flags] + part
            if pad && !out.isEmpty && last { frame += [UInt8](repeating: 0, count: writeSize - frame.count) }
            out.append(frame)
            i += chunkData
        }
        return out
    }

    private static func typeBytes(_ t: UInt32) -> [UInt8] { LE.bytes(t) }

    /// Feeds packets, returns the complete message (body + type) when the last one arrives.
    public struct Reassembler: Sendable {
        private var buffer: [UInt8]? = nil
        public init() {}
        public mutating func feed(_ packet: [UInt8]) -> (body: [UInt8], type: UInt32)? {
            guard packet.count >= 2 else { return nil }
            let flags = packet[1]
            let len = Int(packet[0]) | Int(flags & 1) << 8
            if flags & 0x40 != 0 { buffer = [] }
            guard buffer != nil else { return nil }
            buffer! += packet[2..<min(2 + len, packet.count)]
            guard flags & 0x80 != 0, let all = buffer, all.count >= 4 else { return nil }
            buffer = nil
            let n = all.count
            return (Array(all[0..<(n - 4)]), LE.u32(all, n - 4))
        }
    }
}
