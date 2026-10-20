// Auditions (PROTOCOL-NOTES §14, from the Electron edition's INVESTIGATION §12, contributed in its PR #14): hearing
// something on the pedal without storing it. A Cortex Cloud capture streams as type 150 (reply 151); a library IR
// plays with 158 (reply 159). Both end with 148 → 149, and while anything plays the official app sends the keep-alive
// 91 about every 20 s (the pedal answers 92; without it the audition ends after about a minute).

import Foundation
import CryptoKit

/// Message types of the streamed transfers, the auditions and the IR delete. Kept here (not in `MessageType`) so this
/// feature lives in its own files.
public enum TransferType {
    public static let uploadIR: UInt32 = 15, uploadIRReply: UInt32 = 16
    public static let deleteIR: UInt32 = 82, deleteIRReply: UInt32 = 83
    public static let auditionStop: UInt32 = 148, auditionStopReply: UInt32 = 149
    public static let capturePreview: UInt32 = 150, capturePreviewReply: UInt32 = 151
    public static let irPreview: UInt32 = 158, irPreviewReply: UInt32 = 159
}

/// What a 148 stops: a Cloud capture preview (field 3) or a library IR audition (field 4).
public enum AuditionKind: String, Sendable { case capture, ir }

/// A library cab or IR as type 77 lists it: factory cabs (library field 4) or the user's IRs (field 6).
public struct IRRef: Equatable, Hashable, Sendable {
    public var factory: Bool
    public var index: Int
    public var name: String
    public init(factory: Bool, index: Int, name: String) { self.factory = factory; self.index = index; self.name = name }
}

/// Streamed transfers are one at a time; these say why one did not happen.
public enum StreamError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Another stream (13, 15 or 150) is still going out: what it is.
    case busy(String)
    /// A Bluetooth write failed part way: part n of total.
    case writeFailed(part: Int, of: Int)
    public var description: String {
        switch self {
        case .busy(let what): "Another transfer to the pedal is still running (\(what)). Try again when it has finished."
        case .writeFailed(let part, let total): "Bluetooth write failed at part \(part) of \(total)"
        }
    }
    public var errorDescription: String? { description }
}

public enum Transfer {
    /// Lowercase hex MD5, as the pedal wants it next to a capture (13, 150) or an IR (15). CryptoKit's MD5.
    public static func md5Hex(_ bytes: [UInt8]) -> String {
        Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Audition {
    /// How often the keep-alive goes out while anything is auditioned (the official app's rhythm).
    public static let keepAliveSeconds: Double = 20

    /// 158 `{3: {1: index, 2: name}, 8: 1}` for a factory cab, `{4: …, 8: 1}` for a user IR: the exact index and
    /// name type 77 listed. Field 8 = 1 in every observed Play; field 4 for user IRs is the matching guess (unverified).
    public static func irPreview(_ item: IRRef) -> [UInt8] {
        let record = ProtoWriter().int(1, UInt64(max(0, item.index))).string(2, item.name)
        return Frame.single(body: ProtoWriter().message(item.factory ? 3 : 4, record).int(8, 1).build(), type: TransferType.irPreview)
    }

    /// 148 `{2: transaction, 3: 0}` ends a capture preview, `{2: transaction, 4: 0}` an IR audition.
    public static func stop(_ kind: AuditionKind, transaction: UInt64) -> [UInt8] {
        Frame.single(body: ProtoWriter().int(2, transaction).int(kind == .ir ? 4 : 3, 0).build(), type: TransferType.auditionStop)
    }

    /// 150 `{5: {1: {1: .cns, 2: hex MD5 of the .cns}, 2: CaptureRecord}, 7: 2, 8: 1}`, streamed like a capture upload.
    public static func capturePreview(cns: [UInt8], record: CaptureRecord) -> [[UInt8]] {
        let content = ProtoWriter().bytes(1, cns).string(2, Transfer.md5Hex(cns))
        let object = ProtoWriter().message(1, content).bytes(2, record.encode())
        return Frame.chunks(body: ProtoWriter().message(5, object).int(7, 2).int(8, 1).build(), type: TransferType.capturePreview)
    }

    /// The keep-alive (91 `{1: 3}`), the same frame the device page sends.
    public static var keepAlive: [UInt8] { Writes.keepAlive }

    /// 151, 159 and 149 share a shape: `{1: kind, 2: transaction (149), 3: status (1 = ok), 4: {1: index, 2: name, 3: hash}, 5: message}`.
    public struct Reply: Equatable, Sendable {
        public var status: UInt64
        public var transaction: UInt64?
        public var name: String
        public var hash: String
        public var message: String
        public var ok: Bool { status == 1 }
    }
    public static func parseReply(body: [UInt8]) -> Reply {
        let f = ProtoFields.parse(body), rec = f.message(4)
        return Reply(status: f.int(3) ?? 0, transaction: f.int(2), name: rec?.string(2) ?? "", hash: rec?.string(3) ?? "", message: f.string(5) ?? "")
    }
    /// A stop is confirmed only by a 149 with status 1 that echoes this stop's transaction.
    public static func stopConfirmed(_ reply: Reply, transaction: UInt64) -> Bool {
        reply.status == 1 && reply.transaction == transaction
    }

    /// The official app's transaction is its millisecond clock. Strictly increasing within a process, so two stops in
    /// the same millisecond never share one.
    public static func nextTransaction(now: Date = Date()) -> UInt64 { TransactionClock.shared.next(now: now) }
}

final class TransactionClock: @unchecked Sendable {
    static let shared = TransactionClock()
    private let lock = NSLock()
    private var last: UInt64 = 0
    func next(now: Date) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        last = max(ms, last + 1)
        return last
    }
}

extension Session {
    /// Streams a Cloud capture as a preview (150 → 151). Nothing is stored on the pedal. Refused while another
    /// stream (13, 15, 150) runs.
    public func previewCapture(cns: [UInt8], record: CaptureRecord, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Audition.Reply {
        let body = try await stream(Audition.capturePreview(cns: cns, record: record), label: "Capture preview \"\(record.name)\"",
                                    what: "capture preview", expecting: TransferType.capturePreviewReply, progress: progress)
        return Audition.parseReply(body: body)
    }

    /// 158 → 159: plays a library cab or IR without loading it into a slot. A new 158 replaces the IR playing.
    public func previewIR(_ item: IRRef) async throws -> Audition.Reply {
        Audition.parseReply(body: try await request(Audition.irPreview(item), label: "Preview IR \"\(item.name)\"", expecting: TransferType.irPreviewReply, timeout: 10))
    }

    /// 148 → 149. The caller checks `Audition.stopConfirmed` against `transaction`.
    public func stopAudition(_ kind: AuditionKind, transaction: UInt64) async throws -> Audition.Reply {
        let label = kind == .ir ? "Stop IR preview" : "Stop capture preview"
        return Audition.parseReply(body: try await request(Audition.stop(kind, transaction: transaction), label: label, expecting: TransferType.auditionStopReply, timeout: 10))
    }

    /// 91 → 92 while something is auditioned; true when the pedal answers with status 1.
    public func previewKeepAlive() async throws -> Bool {
        let body = try await request(Audition.keepAlive, label: "Preview keep-alive", expecting: MessageType.keepAliveReply.rawValue, timeout: 10)
        return ProtoFields.parse(body).int(3) == 1
    }
}
