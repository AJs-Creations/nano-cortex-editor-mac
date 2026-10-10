// Every write the editor sends to C304, as single frames `len C0 body type`.
// Byte layouts come from the upstream editor and are checked against the pedal
// recordings in WritesTests. Types: 1 state/metadata request, 3 save, 26 knob
// (amp/capture volume/gate reduction), 28 slot select, 31 block enable, 94 cab
// parameter, 95 cab refresh, 99 FX parameter, 136 FX model, 137 FX refresh.

import Foundation

public enum Slot: String, CaseIterable, Sendable {
    case pre1, pre2, post1, post2, post3
    /// Upstream's blockSlotConfig: model/refresh slot 0–4, enable slot 4–8.
    public var modelSlot: UInt64 { UInt64(Slot.allCases.firstIndex(of: self)!) }
    public var enableSlot: UInt64 { modelSlot + 4 }
    public var stateField: Int { 48 + Int(modelSlot) }
    public var title: String { ["Pre FX 1", "Pre FX 2", "Post FX 1", "Post FX 2", "Post FX 3"][Int(modelSlot)] }
}

public enum AmpKnob: String, CaseIterable, Sendable {
    case gain, level, bass, mid, treble
    var writeId: UInt64 { UInt64(AmpKnob.allCases.firstIndex(of: self)!) }
}

public enum Writes {
    static func single(_ w: ProtoWriter, _ type: UInt32) -> [UInt8] { Frame.single(body: w.build(), type: type) }

    public static let metadataRequest: [UInt8] = single(ProtoWriter().int(1, 3), 1)
    public static let stateRequest: [UInt8] = single(ProtoWriter().int(1, 3).int(3, 1).int(4, 1).int(5, 1), 1)

    public static func amp(_ knob: AmpKnob, _ value: Int) -> [UInt8] {
        single(ProtoWriter().int(3, knob.writeId).int(4, UInt64(max(0, min(255, value)))).int(5, 0), 26)
    }
    public static func captureVolume(db: Double) -> [UInt8] { single(ProtoWriter().int(3, 10).int(4, UInt64(Capture.dbToRaw(db))).int(5, 0), 26) }
    public static func gateReduction(percent: Int) -> [UInt8] { single(ProtoWriter().int(3, 11).int(4, UInt64(max(0, min(100, percent)) + 108)).int(5, 0), 26) }
    public static func gateEnabled(_ on: Bool) -> [UInt8] { single(ProtoWriter().int(1, 1).int(3, 9).int(4, on ? 0 : 1), 31) }
    public static func fxEnabled(_ slot: Slot, _ on: Bool) -> [UInt8] { single(ProtoWriter().int(1, 1).int(3, slot.enableSlot).int(4, on ? 0 : 1), 31) }
    /// Normalized 0–1 value for parameter `index` of the model in `slot`.
    public static func fxParam(_ slot: Slot, index: Int, normalized: Float) -> [UInt8] {
        single(ProtoWriter().int(1, 1).int(3, slot.modelSlot).int(4, UInt64(index)).float32(5, max(0, min(1, normalized))), 99)
    }
    /// The model id is already the varint; it goes in as raw bytes.
    public static func fxModel(_ slot: Slot, id: [UInt8]) -> [UInt8] {
        Frame.single(body: [0x18, UInt8(slot.modelSlot), 0x20] + id, type: 136)
    }
    public static func fxParamRefresh(_ slot: Slot) -> [UInt8] { single(ProtoWriter().int(1, 3).int(3, slot.modelSlot), 137) }

    public static func captureSelect(slot: Int) -> [UInt8] { single(ProtoWriter().int(3, 4).int(4, UInt64(slot - 1)), 28) }   // 1–25
    public static let captureBypass: [UInt8] = single(ProtoWriter().int(3, 1).int(4, 0), 28)
    public static func cabSelect(slot: Int) -> [UInt8] { single(ProtoWriter().int(3, 3).int(4, UInt64(slot)), 28) }          // 1–5, 0 = bypass
    public static func cabRefresh(slot: Int) -> [UInt8] { single(ProtoWriter().int(3, 0).int(4, UInt64(slot - 1)), 95) }

    public static func cabLevel(db: Double) -> [UInt8] { single(ProtoWriter().float32(5, Float(Cab.levelDbToNormalized(db))), 94) }
    public static func cabHighPass(hz: Double) -> [UInt8] { single(ProtoWriter().float32(6, Float(Cab.rangeToNormalized(hz, 20, 800))), 94) }
    public static func cabLowPass(hz: Double) -> [UInt8] { single(ProtoWriter().float32(7, Float(Cab.rangeToNormalized(hz, 1000, 20000))), 94) }
    /// Mic and position for a factory cab. `libraryIndex` is the cab's index in the pedal's factory IR
    /// library (field 1 of the cab record in the type-96 reply); without it the pedal ignores the write.
    public static func cabMicPosition(libraryIndex: Int, cabName: String, mic: String, position: Int) -> [UInt8] {
        single(ProtoWriter().message(3, ProtoWriter().int(1, UInt64(libraryIndex)).string(2, cabName).int(3, UInt64(max(1, min(6, position)) - 1)).string(4, mic)), 94)
    }

    /// Type 50 `{1: 2, 3: index}`: empties a preset slot (PROTOCOL-NOTES §9). Acked by type 51 `{1: 6, 3: index, 4: 1}`.
    public static func deletePreset(index: Int) -> [UInt8] { single(ProtoWriter().int(1, 2).int(3, UInt64(index)), 50) }

    // MARK: device (PROTOCOL-NOTES §13)

    /// Type 46 `{1: 3, 3: Unix time in seconds}`: device info, answered by 47 (firmware, serial).
    public static func deviceInfoRequest(unixTime: UInt64) -> [UInt8] { single(ProtoWriter().int(1, 3).int(3, unixTime), 46) }
    /// Type 91 `{1: 3}`: the official app's keep-alive; its reply 92 carries the firmware build and the device name.
    public static let keepAlive: [UInt8] = single(ProtoWriter().int(1, 3), 91)
    /// Type 65 `{1: 3}`: read the global settings → 66.
    public static let settingsRequest: [UInt8] = single(ProtoWriter().int(1, 3), 65)
    /// Type 67 `{1: 1, 4: LED brightness 0–255, 14: USB playback volume dB (f32)}` → 68 `{1: 1, 3: 1}`.
    /// The phone app sends both fields in every write while either slider moves; so do we.
    public static func deviceSettings(brightness: Int, usbVolumeDb: Float) -> [UInt8] {
        single(ProtoWriter().int(1, 1).int(4, UInt64(max(0, min(255, brightness)))).float32(14, max(-60, min(12, usbVolumeDb))), 67)
    }
    /// Type 17 `{3: slot − 1, 5: 1}` (slot 1–25; the zero is sent explicitly, as the phone app does) → 18.
    public static func captureDetails(slot: Int) -> [UInt8] { single(ProtoWriter().int(3, UInt64(max(1, slot) - 1)).int(5, 1), 17) }
    /// Type 29 with field 4 = −1: puts `presetIndex` on a footswitch slot (fields 5–8 = IA, IB, IIA, IIB; the
    /// other three −1 = unchanged; field 9 = 0). Acked by type 30 `{1: 1, 4: 1}` (PROTOCOL-NOTES §10).
    public static func assignFootswitch(slot: FootswitchSlot, presetIndex: Int) -> [UInt8] {
        var w = ProtoWriter().int(3, 0).int32(4, -1)
        for s in FootswitchSlot.allCases { w = w.int32(s.presetSlotsField, s == slot ? Int32(presetIndex) : -1) }
        return single(w.int(9, 0), MessageType.setPresetSlots.rawValue)
    }
    /// Type 145 `{3: scope, 4: 0, 5: bpm f32, 6: 0}` (PROTOCOL-NOTES §11). `live` = scope 1: the pedal plays the tempo
    /// and the preset stays clean (sent while a control moves). Not live = scope 0: written into the preset, the pedal
    /// reports dirty (115) and the next save commits it as state field 56. The official app sends one scope-0 write with
    /// the final value right before saving. Field 4 is always 0 here (4:1 is a second tempo store, unverified).
    public static func tempo(bpm: Double, live: Bool) -> [UInt8] {
        single(ProtoWriter().int(3, live ? 1 : 0).int(4, 0).float32(5, Float(Tempo.clamp(bpm))).int(6, 0), MessageType.tempo.rawValue)
    }
    /// Type 145 without a tempo: the pedal answers with an echo carrying the current tempo.
    public static let tempoQuery: [UInt8] = single(ProtoWriter().int(3, 1).int(4, 0).int(6, 0), MessageType.tempo.rawValue)

    public static func save(index: Int, name: String) -> [UInt8] { single(ProtoWriter().int(1, 1).int(3, UInt64(index)).string(5, name), 3) }

    public static let libraryRequest: [UInt8] = single(ProtoWriter().int(3, 1).int(4, 1).int(5, 1).int(6, 1), 76)
    public static func loadLibraryCapture(slot: Int, factory: Bool, index: Int, name: String) -> [UInt8] {
        single(ProtoWriter().int(3, UInt64(slot - 1)).message(factory ? 4 : 5, ProtoWriter().int(1, UInt64(index)).string(2, name)), 80)
    }
    public static func loadLibraryCab(slot: Int, factory: Bool, index: Int, name: String) -> [UInt8] {
        single(ProtoWriter().int(3, UInt64(slot - 1)).message(factory ? 4 : 5, ProtoWriter().int(1, UInt64(index)).string(2, name)), 78)
    }
}

/// The preset tempo (type 145, state field 56).
public enum Tempo {
    public static let range: ClosedRange<Double> = 30...300
    public static let defaultBPM = 120.0
    public static func clamp(_ bpm: Double) -> Double { min(range.upperBound, max(range.lowerBound, bpm)) }
    /// The pedal's 145 echo `{1: 1, 3: 1, [4: 1,] 5: bpm f32}`: after a live write, after a query, and unsolicited when
    /// the tempo changes on the pedal (hold footswitch I and tap). nil without field 5.
    public static func parseEcho(body: [UInt8]) -> Double? { ProtoFields.parse(body).first(5)?.float32.map(Double.init) }
}

public enum Cab {
    static let zeroDb = 0.66212219
    public static func levelNormalizedToDb(_ n: Double) -> Double { let x = max(0, min(1, n)); return x <= zeroDb ? (x / zeroDb) * 96 - 96 : ((x - zeroDb) / (1 - zeroDb)) * 12 }
    public static func levelDbToNormalized(_ db: Double) -> Double { let v = max(-96, min(12, db)); return v <= 0 ? ((v + 96) / 96) * zeroDb : zeroDb + (v / 12) * (1 - zeroDb) }
    public static func rangeToNormalized(_ value: Double, _ min: Double, _ max: Double) -> Double { Swift.max(0, Swift.min(1, (value - min) / (max - min))) }
    public static func normalizedToRange(_ n: Double, _ min: Double, _ max: Double) -> Double { min + Swift.max(0, Swift.min(1, n)) * (max - min) }
}

/// Reply to the cab refresh (type 96): the cab record and the three tone values.
public struct CabSettings: Equatable, Sendable {
    public var libraryIndex: Int?
    public var name: String
    public var mic: String?
    public var position: Int?          // 1–6, from the "name/mic/n" string
    public var positionFromRecord: Int? // field 3 of the record + 1, for comparison (hardware pass)
    public var fullName = ""           // record field 5 (the short name again on 2.2.1)
    public var mics: [String] = []     // field 7: the mics the pedal offers for this cab
    public var levelDb: Double
    public var highPassHz: Double
    public var lowPassHz: Double

    public static func parse(body: [UInt8]) -> CabSettings {
        let f = ProtoFields.parse(body)
        let rec = f.message(5)
        let full = rec?.string(5) ?? ""
        let parts = full.split(separator: "/").map(String.init)
        let micFromName = parts.count >= 3 ? parts[1] : nil
        let posFromName = parts.count >= 3 ? Int(parts[parts.count - 1]).map { $0 + 1 } : nil   // 0-based in the name, like the record
        let p = f.message(8)
        // Protobuf elides default values: no field 1 means library index 0, no field 3 means position 1 (verified, PROTOCOL-NOTES §8).
        let libraryIndex: Int? = rec.map { Int($0.int(1) ?? 0) }
        let recPosition: Int? = rec.map { Int($0.int(3) ?? 0) + 1 }
        let levelNorm = Double(p?.first(1)?.float32 ?? 0)
        let hpfNorm = Double(p?.first(2)?.float32 ?? 0)
        let lpfNorm = Double(p?.first(3)?.float32 ?? 0)
        var out = CabSettings(libraryIndex: libraryIndex, name: rec?.string(2) ?? "", mic: micFromName ?? rec?.string(4),
                              position: posFromName ?? recPosition, positionFromRecord: recPosition, levelDb: 0, highPassHz: 20, lowPassHz: 20000)
        out.fullName = full
        out.mics = f[7].compactMap { $0.string }   // plain strings, one per mic
        out.levelDb = Cab.levelNormalizedToDb(levelNorm)
        out.highPassHz = Cab.normalizedToRange(hpfNorm, 20, 800)
        out.lowPassHz = Cab.normalizedToRange(lpfNorm, 1000, 20000)
        return out
    }
}

/// Reply to the FX refresh (type 138): `{ 1: 6, 4: <f32 LE list> }`.
public enum FXParams {
    public static func parse(body: [UInt8]) -> [Float] {
        guard let b = ProtoFields.parse(body).first(4)?.bytes else { return [] }
        var out: [Float] = []
        var i = 0
        while i + 4 <= b.count { out.append(Float(bitPattern: LE.u32(b, i))); i += 4 }
        return out
    }
    /// Parameter value → normalized, upstream's rule: ranges linear, options index/(count−1).
    public static func normalized(_ value: Double, meta: ParamMeta?) -> Float {
        switch meta {
        case .options(let o)?: return Float(max(0, min(1, value / Double(max(1, o.count - 1)))))
        case .range(let lo, let hi, _, _, _)?: return Float(max(0, min(1, (value - lo) / (hi - lo))))
        case nil: return Float(max(0, min(1, value / 10)))
        }
    }
    public static func value(_ n: Float, meta: ParamMeta?) -> Double {
        let x = Double(max(0, min(1, n)))
        switch meta {
        case .options(let o)?: return (x * Double(max(0, o.count - 1))).rounded()
        case .range(let lo, let hi, let step, _, _)?: let v = lo + x * (hi - lo); return step > 0 ? (v / step).rounded() * step : v
        case nil: return (x * 100).rounded() / 10
        }
    }
}
