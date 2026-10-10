// The pedal's current-state dump (reply to the type-1 state request). Field
// numbers come from the upstream editor's parser and the rixrix notes, confirmed
// on the pedal: 3–7 amp knobs, 9 capture bank, 11 capture position (0 = bypass),
// 12 cab slot (0 = bypass), 13 preset index, 14/15/38/39 footswitch presets,
// 24 firmware, 31 FX bypass bytes, 32/33 current capture/IR, 41 dirty,
// 44 capture volume raw, 46 tuner reference (f32), 48–52 FX model ids,
// 53 gate reduction (f32, (percent+108)/255), 54 gate bypassed, 56 preset tempo (f32 BPM), 63 tuner muted.

import Foundation

public struct FXBlock: Equatable, Sendable {
    public var modelIdHex: String?     // nil = empty slot
    public var on: Bool
}

/// The four footswitch preset slots of 4-Preset mode: footswitch I / II, bank A / B (PROTOCOL-NOTES §10).
public enum FootswitchSlot: Int, CaseIterable, Sendable {
    case ia, ib, iia, iib
    public var label: String { ["IA", "IB", "IIA", "IIB"][rawValue] }
    /// Field of the state dump (type 2) holding the slot's 0-based preset index.
    public var stateField: Int { [14, 15, 38, 39][rawValue] }
    /// Field of the type-29 message (preset change / assignment) for this slot.
    public var presetSlotsField: Int { 5 + rawValue }
    public init?(label: String) { guard let s = FootswitchSlot.allCases.first(where: { $0.label.lowercased() == label.lowercased() }) else { return nil }; self = s }
}

/// 0-based preset index per footswitch slot. Protobuf elides zeros: a missing field is preset 1 (index 0).
public struct Footswitches: Equatable, Sendable {
    public var ia: Int, ib: Int, iia: Int, iib: Int
    public init(ia: Int = 0, ib: Int = 0, iia: Int = 0, iib: Int = 0) { self.ia = ia; self.ib = ib; self.iia = iia; self.iib = iib }
    public subscript(_ slot: FootswitchSlot) -> Int {
        get { [ia, ib, iia, iib][slot.rawValue] }
        set { switch slot { case .ia: ia = newValue; case .ib: ib = newValue; case .iia: iia = newValue; case .iib: iib = newValue } }
    }
    /// The first slot holding `preset`, as the official app picks field 9 of a preset change (nil = on none).
    public func slot(holding preset: Int) -> FootswitchSlot? { FootswitchSlot.allCases.first { self[$0] == preset } }
    /// Fields 5–8 of a type-29 message the pedal sends when a footswitch changes the preset.
    public static func fromPresetSlots(_ f: ProtoFields) -> Footswitches {
        let v = { (n: Int) -> Int in Int(Int32(truncatingIfNeeded: f.int(n) ?? 0)) }
        return Footswitches(ia: v(5), ib: v(6), iia: v(7), iib: v(8))
    }
}

public struct StateDump: Equatable, Sendable {
    public var presetIndex: Int            // 0-based
    public var dirty: Bool
    public var firmware: String?
    public var gain: Int, level: Int, bass: Int, mid: Int, treble: Int   // 0–255
    public var captureBank: Int            // 1–5
    public var capturePosition: Int        // 1–5 within the bank, 0 = bypassed
    public var captureName: String
    public var captureId: String
    public var captureVolumeRaw: Int       // 0–255
    public var cabSlot: Int                // 1–5, 0 = bypassed
    public var irShortName: String
    public var irFullName: String
    public var gateOn: Bool
    public var gateReductionPercent: Int?
    public var fx: [String: FXBlock]       // pre1, pre2, post1, post2, post3
    public var footswitch: Footswitches
    public var tunerReference: Float?
    public var tunerMuted: Bool
    /// The preset's stored tempo in BPM (field 56, f32; PROTOCOL-NOTES §11). 120 when absent.
    public var tempo: Double = Tempo.defaultBPM

    public var captureOn: Bool { capturePosition > 0 }
    /// Position 6 (of 5) means the preset references its capture straight from the library, not from a slot;
    /// the cab slot does the same with 6 of 5. Verified on firmware 2.2.1 (PROTOCOL-NOTES §8).
    public var captureFromLibrary: Bool { capturePosition > 5 }
    public var cabFromLibrary: Bool { cabSlot > 5 }
    /// Absolute capture slot 1–25 derived from bank and position.
    public var captureSlot: Int? { capturePosition > 0 && !captureFromLibrary ? (captureBank - 1) * 5 + capturePosition : nil }
    public var captureVolumeDb: Double { Capture.rawToDb(captureVolumeRaw) }
    public var cabOn: Bool { cabSlot > 0 }
    /// "412 Brit TV GB75Hz '69/Dynamic 57/3" → (mic, position); nil for user IRs.
    /// From field 33.3 "name/mic/n"; n is 0-based on the pedal (verified against the type-96 record, PROTOCOL-NOTES §8).
    public var cabMicAndPosition: (mic: String, position: Int)? {
        let parts = irFullName.split(separator: "/").map(String.init)
        guard parts.count >= 3, let n = Int(parts[parts.count - 1]) else { return nil }
        return (parts[parts.count - 2], n + 1)
    }

    public static let fxFields: [(key: String, field: Int)] = [("pre1", 48), ("pre2", 49), ("post1", 50), ("post2", 51), ("post3", 52)]

    public static func parse(_ body: [UInt8]) -> StateDump {
        let f = ProtoFields.parse(body)
        let v = { (n: Int) -> Int in Int(f.int(n) ?? 0) }
        let capture = f.message(32), ir = f.message(33)
        var fx: [String: FXBlock] = [:]
        let bypass = f.first(31)?.bytes ?? []
        for (i, (key, field)) in fxFields.enumerated() {
            // Model ids are varints; the catalogue (Models.swift, from upstream) keys them by the raw varint
            // bytes in hex, e.g. 18001 → "D18C01" (Transpose), 27 → "1B" (Green 808).
            let id = f.first(field)?.varint.map { Varint.encode($0).map { String(format: "%02X", $0) }.joined() }
            fx[key] = FXBlock(modelIdHex: id, on: i < bypass.count ? bypass[i] == 0 : false)
        }
        var gate: Int? = nil
        if let g = f.first(53)?.float32 { let pct = Int((g * 255).rounded()) - 108; if (0...100).contains(pct) { gate = pct } }
        return StateDump(
            presetIndex: v(13), dirty: v(41) != 0, firmware: f.string(24),
            gain: v(3), level: v(4), bass: v(5), mid: v(6), treble: v(7),
            captureBank: min(5, max(1, f.int(9).map(Int.init) ?? 1)), capturePosition: v(11),
            captureName: capture?.string(2) ?? "", captureId: capture?.string(3) ?? "",
            captureVolumeRaw: v(44),
            cabSlot: v(12), irShortName: ir?.string(2) ?? "", irFullName: ir?.string(3) ?? "",
            gateOn: f.first(54) == nil, gateReductionPercent: gate,
            fx: fx, footswitch: Footswitches(ia: v(14), ib: v(15), iia: v(38), iib: v(39)),
            tunerReference: f.first(46)?.float32, tunerMuted: v(63) != 0,
            tempo: f.first(56)?.float32.map(Double.init) ?? Tempo.defaultBPM)
    }
}

public enum Capture {
    /// Capture volume: raw 0–128 maps to −24…0 dB, 128–255 to 0…+12 dB (upstream's curve).
    public static func rawToDb(_ raw: Int) -> Double {
        let r = Double(max(0, min(255, raw)))
        return r <= 128 ? (r / 128) * 24 - 24 : ((r - 128) / 127) * 12
    }
    public static func dbToRaw(_ db: Double) -> Int {
        let d = max(-24, min(12, db))
        return d <= 0 ? Int(((d + 24) / 24 * 128).rounded()) : Int((128 + d / 12 * 127).rounded())
    }
}
