// Live reports: what the pedal says, unasked, when something changes on the pedal itself (a knob, a footswitch or
// MIDI CC bypass, the expression pedal). PROTOCOL-NOTES §14; ported from the Electron edition's pro/live-sync.js
// (contributed by @itsbreaded in its #14). Protobuf leaves zero values out, so a missing field means 0.
//
//   26 {1:1 3:control 4:raw 6:1}        a knob moved: 0 gain, 1 level, 2 bass, 3 mid, 4 treble, 10 capture volume,
//                                       11 gate (raw − 108 = reduction %); 6 comes with every 99, same raw value
//   99 {1:1 3:FX slot 4:index 5:raw}    an FX parameter moved; 5 is the raw 0–255 value as a float32
//   31 {1:1 3:enable slot 4:0 on|1 off} an FX block switched (enable slots 4–8 = Pre FX 1 … Post FX 3)
//   31 {1:1}                            something changed: read the state again
//   64 {1:1 3:2 4:position}             the expression pedal's position 0–255 (heel: 4 left out)
//   94                                  a cab parameter changed (no field says which): read the state again
//   66                                  the global settings, when the pedal sends them unasked

import Foundation

/// The controls a type-26 report names (the same ids the editor writes with).
public enum LiveControl: Equatable, Sendable {
    case amp(AmpKnob)
    case captureVolume
    case gateReduction

    public init?(id: Int) {
        switch id {
        case 0...4: self = .amp(AmpKnob.allCases[id])
        case 10: self = .captureVolume
        case 11: self = .gateReduction
        default: return nil
        }
    }
}

public enum LiveReport: Equatable, Sendable {
    /// Type 26 for a control the editor shows; `raw` 0–255.
    case control(LiveControl, raw: Int)
    /// Type 26 for a control the editor doesn't map. Control 6 is the companion of a type-99 report.
    case otherControl(id: Int, raw: Int)
    /// Type 99: parameter `index` of the effect in `slot` moved; `raw` 0–255 (normalized = raw / 255).
    case fxParam(Slot, index: Int, raw: Float)
    /// Type 31 with an enable slot: the FX block was switched on the pedal.
    case fxEnabled(Slot, on: Bool)
    /// Type 64: the expression pedal's position 0–255.
    case expression(position: Int)
    /// Not enough context to apply (a bare 31, a cab parameter, a report the editor can't read): read the state again.
    /// `keepModels`: the change can't have swapped an effect (a bypass), and the pedal may report stale model ids then.
    case stateChanged(keepModels: Bool)
    /// Type 66 that nobody asked for: the global settings as the pedal has them now.
    case settings(DeviceSettings)

    /// Message types that carry live reports (as replies to a request they are the requester's).
    public static let types: Set<UInt32> = [26, 31, 64, 66, 94, 99]

    /// nil: not a live report (or one the editor ignores, like a 64 that isn't a position).
    public static func parse(type: UInt32, body: [UInt8]) -> LiveReport? {
        let f = ProtoFields.parse(body)
        switch type {
        case 26: return control(f) ?? .stateChanged(keepModels: false)
        case 99: return fxParam(f) ?? .stateChanged(keepModels: false)
        case 31: return enable(f) ?? .stateChanged(keepModels: true)
        case 64:
            guard varint(f, 3) == 2 else { return nil }   // selector 2 = the pedal's position; other shapes are notices
            return .expression(position: Int(min(255, varint(f, 4) ?? 0)))
        case 94: return .stateChanged(keepModels: false)
        case 66: return .settings(DeviceSettings.parse(body))
        default: return nil
        }
    }

    /// Field 1 = 1 marks a report (the pedal's own writes back to us would not have it).
    static func isReport(_ f: ProtoFields) -> Bool { f.first(1) == .varint(1) }
    /// A varint field, 0 when left out; nil when present with another wire type.
    static func varint(_ f: ProtoFields, _ n: Int) -> UInt64? {
        guard let v = f.first(n) else { return 0 }
        return v.varint
    }

    static func control(_ f: ProtoFields) -> LiveReport? {
        guard isReport(f), f.first(6) == .varint(1), let id = varint(f, 3), let value = varint(f, 4) else { return nil }
        let raw = Int(min(255, value))
        guard let c = LiveControl(id: Int(min(id, 1000))) else { return .otherControl(id: Int(min(id, 1000)), raw: raw) }
        return .control(c, raw: raw)
    }

    static func fxParam(_ f: ProtoFields) -> LiveReport? {
        guard isReport(f), let s = varint(f, 3), let i = varint(f, 4), s < UInt64(Slot.allCases.count), i < 64 else { return nil }
        let raw: Float
        if let v = f.first(5) { guard let x = v.float32 else { return nil }; raw = x } else { raw = 0 }
        guard raw.isFinite, raw >= 0, raw <= 255 else { return nil }
        return .fxParam(Slot.allCases[Int(s)], index: Int(i), raw: raw)
    }

    static func enable(_ f: ProtoFields) -> LiveReport? {
        guard isReport(f), let e = f.first(3)?.varint, let v = varint(f, 4), v <= 1,
              let slot = Slot.allCases.first(where: { $0.enableSlot == e }) else { return nil }
        return .fxEnabled(slot, on: v == 0)
    }
}

// MARK: - preset move (type 143 → 144), PROTOCOL-NOTES §14

/// One message moves a preset by insertion (the presets in between shift by one); indices are 0-based and absolute.
public enum PresetMove {
    public static let request: UInt32 = 143
    public static let reply: UInt32 = 144

    /// `{1: 4, 3: from, 4: to}`, both written even when 0 (as the phone app does): 5 → 3 is `0A C0 08 04 18 04 20 02 8F 00 00 00`.
    public static func frame(from: Int, to: Int) -> [UInt8] {
        Frame.single(body: ProtoWriter().int(1, 4).int(3, UInt64(max(0, from))).int(4, UInt64(max(0, to))).build(), type: request)
    }

    /// Type 144 `{1: 6, 3: from, 4: to, 5: status}`; status 1 = moved. A left-out field reads 0.
    public struct Reply: Equatable, Sendable {
        public var from: Int, to: Int, status: Int
        public init(from: Int, to: Int, status: Int) { self.from = from; self.to = to; self.status = status }
        public static func parse(_ body: [UInt8]) -> Reply {
            let f = ProtoFields.parse(body)
            return Reply(from: Int(f.int(3) ?? 0), to: Int(f.int(4) ?? 0), status: Int(f.int(5) ?? 0))
        }
        /// The pedal moved exactly what was asked.
        public func confirms(from: Int, to: Int) -> Bool { status == 1 && self.from == from && self.to == to }
    }

    /// The order after moving `from` to `to` (an insertion), for any list (names, the fake pedal's per-preset data).
    public static func apply<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard from != to, items.indices.contains(from), items.indices.contains(to) else { return items }
        var out = items
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }
    /// Where the preset at `index` ends up after the move (the moved one, or a neighbour shifted by one).
    public static func newIndex(of index: Int, from: Int, to: Int) -> Int {
        if index == from { return to }
        if from < to, index > from, index <= to { return index - 1 }
        if to < from, index >= to, index < from { return index + 1 }
        return index
    }
}

// MARK: - monitoring (type 67 fields 12 / 13 → 68; read back as 66 fields 15 / 16), PROTOCOL-NOTES §13

public enum Monitor: String, CaseIterable, Sendable {
    /// Mute the Guitar Input (USB input still plays).
    case input
    /// Mute the processed sound at Outputs 1L/2R (USB playback still plays).
    case outputs

    /// Field of the type-67 write.
    public var writeField: Int { self == .input ? 12 : 13 }
    /// Field of the type-66 read.
    public var readField: Int { self == .input ? 15 : 16 }
    /// The Electron edition's switch labels.
    public var label: String { self == .input ? "Mute Input" : "Mute Outputs 1L/2R" }
}

extension Writes {
    /// Type 67 `{1: 1, 12|13: 0|1}`: one monitoring switch, always with an explicit 0 or 1 (as the phone app sends it).
    /// Mute Input on: `08 C0 08 01 60 01 43 00 00 00`; Mute Outputs off: `08 C0 08 01 68 00 43 00 00 00`.
    public static func monitoring(_ which: Monitor, on: Bool) -> [UInt8] {
        single(ProtoWriter().int(1, 1).int(which.writeField, on ? 1 : 0), 67)
    }
}

extension DeviceSettings {
    public func muted(_ which: Monitor) -> Bool { which == .input ? muteInput : muteOutputs }
}

extension Session {
    /// Type 143 → 144: moves a preset by insertion (0-based, absolute indices). Only from an explicit user drag.
    public func movePreset(from: Int, to: Int) async throws -> PresetMove.Reply {
        PresetMove.Reply.parse(try await request(PresetMove.frame(from: from, to: to), label: "Move preset \(from + 1) to position \(to + 1)",
                                                 expecting: PresetMove.reply, timeout: 10))
    }
    /// Type 67 with one monitoring field → 68; true when the pedal accepted it. A global setting: no dirty report, no Save.
    public func writeMonitoring(_ which: Monitor, on: Bool) async throws -> Bool {
        let reply = try await request(Writes.monitoring(which, on: on), label: "Device monitoring: \(which.label) \(on ? "ON" : "OFF")", expecting: 68)
        return ProtoFields.parse(reply).int(3) == 1
    }
}
