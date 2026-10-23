// Known message types (the u32 trailing a frame). Numbers come from the DrD85
// editor, the pedal recordings and the phone-app trace; see docs/PROTOCOL-NOTES.md.

import Foundation
import CryptoKit

public enum MessageType: UInt32, Sendable, CaseIterable {
    case stateRequest = 1
    case captureDetails = 17, captureDetailsReply = 18
    case savePresetReply = 4
    case uploadCapture = 13
    case uploadCaptureReply = 14
    case setPresetSlots = 29
    case setPresetSlotsReply = 30
    case deviceInfoRequest = 46
    case deviceInfoReply = 47
    case retrieveExpAssignments = 60, retrieveExpAssignmentsReply = 61, saveExpAssignments = 62, saveExpAssignmentsReply = 63
    case expressionNotice = 64   // `{1:1 3:2}` between 60 and 61; `{5:1}`/`{3:1 5:1}` in capture mode; meaning unknown
    case retrieveSettings = 65, retrieveSettingsReply = 66, saveSettings = 67, saveSettingsReply = 68
    case retrieveLibraryContent = 76, retrieveLibraryContentReply = 77
    case setCabinetSlotContent = 78, setCabinetSlotContentReply = 79
    case setCaptureSlotContent = 80, setCaptureSlotContentReply = 81
    case keepAlive = 91, keepAliveReply = 92
    case renamePreset = 111, renamePresetReply = 112
    case presetDirtyStateChanged = 115
    case tunerMode = 127
    case tunerMetering = 128
    case tempo = 145
}

/// Capture metadata text, cleaned the same way wherever it is shown, searched or sent (the Electron edition's
/// `pro/capture-text.js`).
public enum CaptureText {
    /// A capture without a description comes back from the pedal as the literal text "null" (seen on a real pedal,
    /// 2026-10-23). Empty, blank and "null" (any case) all mean "no description" and become ""; real text is kept as is.
    public static func description(_ text: String?) -> String {
        guard let text else { return "" }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.lowercased() == "null" ? "" : text
    }
}

/// Metadata the pedal stores with a capture (the bundle's .json from Cortex Cloud).
public struct CaptureRecord: Equatable, Sendable {
    public var hash: String
    public var name: String
    public var cloudUUID: String
    public var authorId: String
    public var authorName: String
    public var description: String
    public var deviceType: String
    public var tags: [String]
    public var gainType: UInt64?
    public var instrumentType: String
    public var version: String

    public init(hash: String, name: String, cloudUUID: String, authorId: String = "", authorName: String = "", description: String = "",
                deviceType: String = "default", tags: [String] = [], gainType: UInt64? = nil, instrumentType: String = "instrument_not_set", version: String = "1") {
        self.hash = hash; self.name = name; self.cloudUUID = cloudUUID; self.authorId = authorId; self.authorName = authorName
        self.description = description; self.deviceType = deviceType; self.tags = tags; self.gainType = gainType
        self.instrumentType = instrumentType; self.version = version
    }

    /// Record layout: 1 hash, 2 name, 3 cloudUUID, 4 { 1 authorId, 2 authorName }, 5 description,
    /// 6 deviceType, 7 tags (repeated), 8 gainType, 10 instrumentType, 12 version.
    public func encode() -> [UInt8] {
        var w = ProtoWriter().string(1, hash).string(2, name).string(3, cloudUUID)
            .message(4, ProtoWriter().string(1, authorId).string(2, authorName))
            .string(5, CaptureText.description(description)).string(6, deviceType)   // never "null"
        for t in tags { w = w.string(7, t) }
        if let g = gainType { w = w.int(8, g) }
        return w.string(10, instrumentType).string(12, version).build()
    }

    public static func decode(_ f: ProtoFields) -> CaptureRecord {
        let author = f.message(4)
        return CaptureRecord(hash: f.string(1) ?? "", name: f.string(2) ?? "", cloudUUID: f.string(3) ?? "",
                             authorId: author?.string(1) ?? "", authorName: author?.string(2) ?? "",
                             description: CaptureText.description(f.string(5)), deviceType: f.string(6) ?? "default",
                             tags: f[7].compactMap(\.string), gainType: f.int(8),
                             instrumentType: f.string(10) ?? "instrument_not_set", version: f.string(12) ?? "1")
    }
}

public enum Messages {
    /// Type 13: `{ 1: 6, 3: { 1: cns, 2: hex MD5 of cns }, 4: CaptureRecord }`, streamed.
    /// The MD5 is what the official app sends (DECISION #8 is about the framing; this is the payload).
    public static func uploadCapture(cns: [UInt8], record: CaptureRecord) -> [[UInt8]] {
        let digest = Insecure.MD5.hash(data: Data(cns)).map { String(format: "%02x", $0) }.joined()
        let body = ProtoWriter().int(1, 6).message(3, ProtoWriter().bytes(1, cns).string(2, digest)).bytes(4, record.encode()).build()
        return Frame.chunks(body: body, type: MessageType.uploadCapture.rawValue)
    }

    public struct UploadReply: Equatable, Sendable {
        public var ok: Bool; public var userIndex: Int; public var name: String; public var hash: String
    }
    /// Type 14: `{ 1: 6, 3: status, 4: { 1: userIndex, 2: name, 3: hash } }`.
    public static func parseUploadReply(body: [UInt8]) -> UploadReply {
        let f = ProtoFields.parse(body), rec = f.message(4)
        return UploadReply(ok: f.int(3) == 1, userIndex: Int(rec?.int(1) ?? 0), name: rec?.string(2) ?? "", hash: rec?.string(3) ?? "")
    }

    /// Type 29: preset change. Footswitch slots −1 = unchanged; field 9 is the footswitch slot (0–3, IA…IIB)
    /// holding the preset, 4 when it is on none (phone trace 2026-10-09: preset 8 on IIA sent 9:2, 16 on IIB 9:3).
    public static func presetChange(index: Int, footswitchSlot: Int = 4) -> [UInt8] {
        let body = ProtoWriter().int(3, 0).int(4, UInt64(index)).int32(5, -1).int32(6, -1).int32(7, -1).int32(8, -1).int(9, UInt64(footswitchSlot)).build()
        return Frame.single(body: body, type: MessageType.setPresetSlots.rawValue)
    }
    /// Field 9 for a change to `index`, given the current footswitch assignments.
    public static func presetChange(index: Int, footswitch: Footswitches?) -> [UInt8] {
        presetChange(index: index, footswitchSlot: footswitch?.slot(holding: index)?.rawValue ?? 4)
    }
    /// Type 30 ack the app must send when the pedal reports a change (status = 1).
    public static let presetChangeAck: [UInt8] = Frame.single(body: ProtoWriter().int(4, 1).build(), type: MessageType.setPresetSlotsReply.rawValue)

    /// Type 111: `{ 1: UPDATE, 3: index, 4: name }`.
    public static func renamePreset(index: Int, name: String) -> [UInt8] {
        Frame.single(body: ProtoWriter().int(1, 1).int(3, UInt64(index)).string(4, name).build(), type: MessageType.renamePreset.rawValue)
    }

    /// Type 127: `{ 4: on, 5: baseFrequency f32, 6: liveTuner, 7: muted }`; off is `{ 4: 0 }`.
    public static func tunerMode(on: Bool, baseFrequency: Float = 440, live: Bool = true, muted: Bool = false) -> [UInt8] {
        let body = on ? ProtoWriter().int(4, 1).float32(5, baseFrequency).int(6, live ? 1 : 0).int(7, muted ? 1 : 0).build() : ProtoWriter().int(4, 0).build()
        return Frame.single(body: body, type: MessageType.tunerMode.rawValue)
    }
}
