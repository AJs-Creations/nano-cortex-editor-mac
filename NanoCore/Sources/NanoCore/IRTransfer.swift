// Cortex Cloud IRs into the pedal's IR library (PROTOCOL-NOTES §15; the Electron edition's INVESTIGATION §6a,
// contributed in its PR #14), and deleting a user IR. The Cloud download's `payload` is base64 of the raw RIFF/WAVE
// file (not a tar like a capture). Before anything is sent the WAV is checked the way the Electron edition's
// `src/cloud-ir.js` does: at most 1 MB decoded, a `fmt ` chunk with PCM 16/24/32-bit or float 32/64-bit audio, 1–2
// channels, 8–192 kHz, and a non-empty `data` chunk. The traced Cloud IR was a 4 KB mono 48 kHz float WAV.

import Foundation

/// Why a Cloud IR is refused, with the Electron edition's wording.
public struct IRError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The `fmt ` chunk of a checked WAV, plus the size of its audio data.
public struct WAVFormat: Equatable, Sendable {
    public var format: Int        // 1 PCM, 3 IEEE float (WAVE_FORMAT_EXTENSIBLE resolved to its sub-format)
    public var channels: Int
    public var sampleRate: Int
    public var bits: Int
    public var dataBytes: Int
}

public enum WAVCheck {
    /// Reads the RIFF chunks; returns the format or throws the reason the pedal can't use the file.
    public static func check(_ b: [UInt8]) throws -> WAVFormat {
        func ascii(_ at: Int, _ n: Int) -> String { String(decoding: b[at..<at + n], as: UTF8.self) }
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { Int(LE.u32(b, at)) }
        guard b.count >= 44, ascii(0, 4) == "RIFF", ascii(8, 4) == "WAVE" else { throw IRError("The Cloud IR payload is not a WAV file.") }
        var fmt: WAVFormat?
        var dataBytes = 0
        var off = 12
        while off + 8 <= b.count {
            let id = ascii(off, 4), size = u32(off + 4), body = off + 8
            guard body + size <= b.count else {
                throw IRError("The WAV file is cut short (its \"\(id.trimmingCharacters(in: .whitespaces))\" chunk runs past the end).")
            }
            if id == "fmt " {
                guard size >= 16 else { throw IRError("The WAV format chunk is too short.") }
                var f = WAVFormat(format: u16(body), channels: u16(body + 2), sampleRate: u32(body + 4), bits: u16(body + 14), dataBytes: 0)
                // WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the sub-format GUID.
                if f.format == 0xFFFE, size >= 40 { f.format = u16(body + 24) }
                fmt = f
            } else if id == "data" {
                dataBytes = size
            }
            off = body + size + (size & 1)
        }
        guard var f = fmt else { throw IRError("The WAV file has no format chunk.") }
        let pcm = f.format == 1, float = f.format == 3
        guard pcm || float else { throw IRError("The IR is not PCM or floating-point audio (WAV format \(f.format)), so the pedal can’t use it.") }
        guard (pcm ? [16, 24, 32] : [32, 64]).contains(f.bits) else { throw IRError("The IR uses \(f.bits)-bit \(pcm ? "PCM" : "float") samples, which the pedal can’t read.") }
        guard (1...2).contains(f.channels) else { throw IRError("The IR has \(f.channels) channels; the pedal takes mono or stereo IRs.") }
        guard (8000...192000).contains(f.sampleRate) else { throw IRError("The IR’s sample rate (\(f.sampleRate) Hz) is outside 8–192 kHz.") }
        guard dataBytes > 0 else { throw IRError("The WAV file has no audio data.") }
        f.dataBytes = dataBytes
        return f
    }
}

public enum IRTransfer {
    /// Largest decoded WAV the app sends.
    public static let maxBytes = 1024 * 1024
    static let tooLarge = "The IR is larger than 1 MB; the pedal takes short IR WAV files."

    /// The download's base64 `payload` → the WAV bytes. A payload too long for 1 MB is refused before decoding.
    public static func decodePayload(_ payload: String) throws -> [UInt8] {
        guard !payload.isEmpty else { throw IRError("The Cloud response has no IR payload.") }
        if payload.utf8.count > (maxBytes + 2) / 3 * 4 + 4 { throw IRError(tooLarge) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { throw IRError("The Cloud IR payload is not a WAV file.") }
        if data.count > maxBytes { throw IRError(tooLarge) }
        return [UInt8](data)
    }

    /// The file name the pedal gets: the IR's name without characters a file system refuses, ending in `.wav`.
    public static func filename(for name: String) -> String {
        var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        base = base.replacingOccurrences(of: #"[\\/:*?"<>|]+"#, with: "_", options: .regularExpression)
        base = base.replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression)
        base = base.replacingOccurrences(of: #"\.wav$"#, with: "", options: [.regularExpression, .caseInsensitive])
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "cloud-impulse-response" : base) + ".wav"
    }

    /// A Cortex Cloud product id: a UUID in its 8-4-4-4-12 hex form.
    public static func isProductId(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }
    /// The signed-in account's IR list (`/cloud/profile/impulses`), the only page that gets Send to Nano buttons.
    public static func isIRPagePath(_ path: String) -> Bool {
        path.range(of: #"^/cloud/profile/impulses/?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Type 15 `{1: 6, 3: {1: WAV, 2: hex MD5 of the WAV}, 4: product UUID, 5: file name}`, streamed.
    public static func message(wav: [UInt8], productId: String, filename: String) -> [[UInt8]] {
        let content = ProtoWriter().bytes(1, wav).string(2, Transfer.md5Hex(wav))
        let body = ProtoWriter().int(1, 6).message(3, content).string(4, productId).string(5, filename).build()
        return Frame.chunks(body: body, type: TransferType.uploadIR)
    }

    /// Type 16 `{1: 6, 3: status (1 = accepted), 4: {1: user IR index, 2: name}, 5: message}`.
    public struct Reply: Equatable, Sendable {
        public var status: UInt64
        public var index: Int
        public var name: String
        public var message: String
        public var ok: Bool { status == 1 }
    }
    public static func parseReply(body: [UInt8]) -> Reply {
        let f = ProtoFields.parse(body), rec = f.message(4)
        return Reply(status: f.int(3) ?? 0, index: Int(rec?.int(1) ?? 0), name: rec?.string(2) ?? "", message: f.string(5) ?? rec?.string(4) ?? "")
    }

    /// Type 82 `{1: 2, 4: {1: user IR index, 2: name}}`: the index and name exactly as type 77 lists them. Acked by
    /// 83 `{1: 6, 3: 1}`. User IRs only; factory cabs are not deletable.
    public static func deleteRequest(index: Int, name: String) -> [UInt8] {
        Frame.single(body: ProtoWriter().int(1, 2).message(4, ProtoWriter().int(1, UInt64(max(0, index))).string(2, name)).build(), type: TransferType.deleteIR)
    }
    public static func deleteConfirmed(body: [UInt8]) -> Bool { ProtoFields.parse(body).int(3) == 1 }

    /// Case- and space-insensitive name match (the Electron edition's `sameName`).
    public static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension Session {
    /// Streams a Cloud IR into the pedal's IR library (15 → 16). Refused while another stream (13, 15, 150) runs.
    public func uploadIR(wav: [UInt8], productId: String, filename: String, name: String, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> IRTransfer.Reply {
        let body = try await stream(IRTransfer.message(wav: wav, productId: productId, filename: filename), label: "Cloud IR download \"\(name)\"",
                                    what: "IR download", expecting: TransferType.uploadIRReply, progress: progress)
        return IRTransfer.parseReply(body: body)
    }

    /// Deletes a user IR (82 → 83). Only from an explicit, confirmed user action, right after re-reading the library.
    public func deleteIR(index: Int, name: String) async throws -> Bool {
        IRTransfer.deleteConfirmed(body: try await request(IRTransfer.deleteRequest(index: index, name: name), label: "Delete IR \(name)", expecting: TransferType.deleteIRReply, timeout: 10))
    }
}
