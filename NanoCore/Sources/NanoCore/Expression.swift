// Expression pedal assignments (types 60–63), PROTOCOL-NOTES §12.
//
//   60 RetrieveExpAssignmentsRequest  { 1: 3 (read), 3: presetIndex }            → 61 (plus an rx 64 `{1:1 3:2}` notice)
//   61 RetrieveExpAssignmentsResponse { 1: 1, <records at save field − 1> }       empty = no assignments
//   62 SaveExpAssignmentsRequest      { 3: presetIndex, <one record per target> } → 63 `{1:1 3:1}` + 115 dirty
//
// A 62 replaces the whole set; `{3: presetIndex}` alone clears it. Field numbers and record layouts come from the
// upstream editor's EXP_RANGES / EXP_BYPASS / expSaveFrame; the phone-app trace (2026-10-09) confirms fields 4, 5,
// 14 and 17 and the explicit zeros byte for byte. Everything else is upstream-only (see the notes).

import Foundation

public struct ExpressionAssignments: Equatable, Sendable {
    /// Continuous targets: heel = min, toe = max, raw 0–255 like the amp knobs.
    public enum RangeTarget: Int, CaseIterable, Sendable, Comparable {
        case gain = 4, bass = 5, mid = 6, treble = 7
        case pre1 = 8, pre2 = 9, post1 = 10, post2 = 11, post3 = 12
        case level = 13
        case gate = 21
        /// Field in the 62 save request; the 61 reply uses `saveField − 1`.
        public var saveField: Int { rawValue }
        public var key: String {
            switch self { case .gain: "gain"; case .bass: "bass"; case .mid: "mid"; case .treble: "treble"; case .pre1: "pre1"; case .pre2: "pre2"
            case .post1: "post1"; case .post2: "post2"; case .post3: "post3"; case .level: "level"; case .gate: "gate" }
        }
        public var slot: Slot? { Slot(rawValue: key) }
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    /// On/off targets: the block is bypassed or engaged by the pedal.
    public enum BypassTarget: Int, CaseIterable, Sendable, Comparable {
        case capture = 14, cab = 15
        case pre1 = 16, pre2 = 17, post1 = 18, post2 = 19, post3 = 20
        case gate = 22
        public var saveField: Int { rawValue }
        public var key: String {
            switch self { case .capture: "capture"; case .cab: "cab"; case .pre1: "pre1"; case .pre2: "pre2"; case .post1: "post1"
            case .post2: "post2"; case .post3: "post3"; case .gate: "gate" }
        }
        public var slot: Slot? { Slot(rawValue: key) }
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// ExpressionPedalRangeRecord `{1: inverted, 2: min, 3: max}`, all three always written (zeros included).
    public struct Range: Equatable, Sendable {
        public var inverted: Bool
        public var min: Int
        public var max: Int
        public init(inverted: Bool = false, min: Int = 0, max: Int = 255) { self.inverted = inverted; self.min = min; self.max = max }
    }
    /// ExpressionPedalBypassRecord, a oneof:
    /// 1 heelToe `{1: inverted, 2: switchDelay ms}`, 2 switch `{1: inverted, 2: latchEmulation}`, 3 stop `{1: switchDelay ms}`.
    public enum Bypass: Equatable, Sendable {
        case heelToe(inverted: Bool, delayMs: Int)
        case toggle(inverted: Bool, latch: Bool)
        case stop(delayMs: Int)
        public static let `default` = Bypass.heelToe(inverted: false, delayMs: 600)   // the phone app's first value
        public var modeKey: String { switch self { case .heelToe: "heelToe"; case .toggle: "switch"; case .stop: "stop" } }
    }

    public var ranges: [RangeTarget: Range]
    public var bypasses: [BypassTarget: Bypass]
    public init(ranges: [RangeTarget: Range] = [:], bypasses: [BypassTarget: Bypass] = [:]) { self.ranges = ranges; self.bypasses = bypasses }

    public var isEmpty: Bool { ranges.isEmpty && bypasses.isEmpty }
    public var count: Int { ranges.count + bypasses.count }

    /// Upstream clamps the switch delay to 0–2000 ms.
    public static let maxDelayMs = 2000

    // MARK: encode (type 62)

    /// The type-62 body: `{3: presetIndex}` followed by the records in ascending field order (protobuf's canonical
    /// order; upstream emits its own list order, which only differs once level/gate meet an FX amount).
    public func encode(presetIndex: Int) -> [UInt8] {
        var w = ProtoWriter().int(3, UInt64(presetIndex))
        for (field, record) in records() { w = w.bytes(field, record) }
        return w.build()
    }

    /// `(field, record bytes)` in ascending field order, with the save field numbers.
    func records() -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        for t in ranges.keys.sorted() { let r = ranges[t]!; out.append((t.saveField, Self.encode(r))) }
        for t in bypasses.keys.sorted() { out.append((t.saveField, Self.encode(bypasses[t]!))) }
        return out.sorted { $0.0 < $1.0 }
    }

    static func encode(_ r: Range) -> [UInt8] {
        ProtoWriter().int(1, r.inverted ? 1 : 0).int(2, UInt64(clampRaw(r.min))).int(3, UInt64(clampRaw(r.max))).build()
    }
    static func encode(_ b: Bypass) -> [UInt8] {
        switch b {
        case .heelToe(let inv, let ms): ProtoWriter().message(1, ProtoWriter().int(1, inv ? 1 : 0).int(2, UInt64(clampDelay(ms)))).build()
        case .toggle(let inv, let latch): ProtoWriter().message(2, ProtoWriter().int(1, inv ? 1 : 0).int(2, latch ? 1 : 0)).build()
        case .stop(let ms): ProtoWriter().message(3, ProtoWriter().int(1, UInt64(clampDelay(ms)))).build()
        }
    }
    static func clampRaw(_ v: Int) -> Int { Swift.max(0, Swift.min(255, v)) }
    static func clampDelay(_ v: Int) -> Int { Swift.max(0, Swift.min(maxDelayMs, v)) }

    // MARK: parse

    /// Reply 61: records sit at `save field − 1` (upstream; the trace only ever saw an empty reply).
    public static func parse(reply body: [UInt8]) -> ExpressionAssignments { decode(ProtoFields.parse(body), offset: -1) }
    /// A 62 request body (the fake pedal stores what it was sent). Returns the preset index too.
    public static func parse(save body: [UInt8]) -> (presetIndex: Int, set: ExpressionAssignments) {
        let f = ProtoFields.parse(body)
        return (Int(f.int(3) ?? 0), decode(f, offset: 0))
    }

    static func decode(_ f: ProtoFields, offset: Int) -> ExpressionAssignments {
        var out = ExpressionAssignments()
        // Protobuf elides zeros: a missing sub-field means 0 / false.
        for t in RangeTarget.allCases {
            guard let rec = f.message(t.saveField + offset) else { continue }
            out.ranges[t] = Range(inverted: (rec.int(1) ?? 0) != 0, min: Int(rec.int(2) ?? 0), max: Int(rec.int(3) ?? 0))
        }
        for t in BypassTarget.allCases {
            guard let rec = f.message(t.saveField + offset) else { continue }
            if let h = rec.message(1) { out.bypasses[t] = .heelToe(inverted: (h.int(1) ?? 0) != 0, delayMs: Int(h.int(2) ?? 0)) }
            else if let s = rec.message(2) { out.bypasses[t] = .toggle(inverted: (s.int(1) ?? 0) != 0, latch: (s.int(2) ?? 0) != 0) }
            else if let s = rec.message(3) { out.bypasses[t] = .stop(delayMs: Int(s.int(1) ?? 0)) }
            else { out.bypasses[t] = .default }   // an empty record: upstream treats it as on with its defaults
        }
        return out
    }

    /// The type-61 body the pedal would send for this set (used by the fake pedal).
    public func replyBody() -> [UInt8] {
        var w = ProtoWriter().int(1, 1)
        for (field, record) in records() { w = w.bytes(field - 1, record) }
        return w.build()
    }
}

extension Writes {
    /// Type 60 `{1: 3, 3: presetIndex}`: `08 03 18 3D` for index 61 (phone-app trace).
    public static func expressionRead(index: Int) -> [UInt8] { single(ProtoWriter().int(1, 3).int(3, UInt64(index)), 60) }
    /// Type 62: replaces the preset's whole assignment set; an empty set clears it.
    public static func expressionSave(index: Int, _ set: ExpressionAssignments) -> [UInt8] {
        Frame.single(body: set.encode(presetIndex: index), type: 62)
    }
}
