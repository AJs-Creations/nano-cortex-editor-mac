// The pure half of the live tools (mcp/PROTOCOL.md §4): the loudness limits, effect model and parameter names, and
// the plan of a tone change. `apply_tone` and every single live tool are planned here first, against the editor's
// values from before the call, so nothing is changed when any part is refused; the app (AgentBridge) then runs the plan
// through PedalStore's own actions.

import Foundation

/// A refusal for the assistant (one sentence).
public struct MCPRefusal: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - loudness (tools.json → safety)

public enum MCPLoudness {
    /// nil when `after` is allowed, else `maxRefusal` / `stepRefusal`. A value already above the cap may stay or go down.
    public static func check(what: String, before: Double, after: Double, step: Double, stepText: String,
                             max: Double? = nil, maxText: String? = nil, safety: MCPContract.Safety) -> String? {
        let eps = 1e-9
        guard after > before + eps else { return nil }   // a decrease (or no change) is always allowed
        if let max, after > max + eps {
            return MCPContract.fill(safety.maxRefusal, ["what": what, "max": maxText ?? MCPValidator.format(max)])
        }
        if after > before + step + eps {
            return MCPContract.fill(safety.stepRefusal, ["what": what, "step": stepText])
        }
        return nil
    }
    /// Amp Level, 0–10 (compared on the one-decimal values the editor shows).
    public static func ampLevel(before: Double, after: Double, safety: MCPContract.Safety) -> String? {
        check(what: "Level", before: before, after: after, step: safety.ampLevelStep, stepText: MCPValidator.format(safety.ampLevelStep), safety: safety)
    }
    public static func captureVolume(before: Double, after: Double, safety: MCPContract.Safety) -> String? {
        check(what: "volume_db", before: before, after: after, step: safety.captureVolumeDbStep, stepText: "\(MCPValidator.format(safety.captureVolumeDbStep)) dB",
              max: safety.captureVolumeDbMax, maxText: "+\(MCPValidator.format(safety.captureVolumeDbMax)) dB", safety: safety)
    }
    public static func cabLevel(before: Double, after: Double, safety: MCPContract.Safety) -> String? {
        check(what: "cab level_db", before: before, after: after, step: safety.cabLevelDbStep, stepText: "\(MCPValidator.format(safety.cabLevelDbStep)) dB",
              max: safety.cabLevelDbMax, maxText: "+\(MCPValidator.format(safety.cabLevelDbMax)) dB", safety: safety)
    }
    /// An effect parameter: only level-like names (`effectLevelParams`) with a numeric range are limited, to a share of
    /// the range per call.
    public static func effectParam(slot: Slot, param: ParamDef, before: Double, after: Double, safety: MCPContract.Safety) -> String? {
        guard safety.isLevelParam(param.name), case .range(let lo, let hi, _, _, _, _, _)? = param.meta else { return nil }
        return check(what: "\(slot.title) \(param.name)", before: before, after: after, step: safety.effectLevelStepShare * (hi - lo),
                     stepText: "\(MCPValidator.format(safety.effectLevelStepShare * 100)) % of its range", safety: safety)
    }
}

// MARK: - effects by name

public enum MCPEffects {
    /// The models `slot` takes (the picker's list: no Pitch in Pre FX 2), without "None".
    public static func models(for slot: Slot) -> [ModelDef] { Models.pickerList(for: slot, current: nil) }
    /// A model by name, case-insensitive; `.none` for "None".
    public enum Choice: Equatable, Sendable { case empty, model(ModelDef) }
    public static func choice(_ name: String, in slot: Slot) -> Choice? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.caseInsensitiveCompare("None") == .orderedSame { return Choice.empty }
        return models(for: slot).first { $0.name.caseInsensitiveCompare(n) == .orderedSame }.map(Choice.model)
    }
    public static func unknownModel(_ name: String, in slot: Slot) -> String {
        "\(slot.title) has no effect named “\(name)”. list_effects lists the models each slot takes (or \"None\" to empty it)."
    }
    public static func param(_ name: String, of model: ModelDef) -> ParamDef? {
        let n = name.trimmingCharacters(in: .whitespaces)
        return model.params.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }
    /// A value from the assistant (a number in the parameter's units, a switch's option text or index) → the value in
    /// parameter units (an option's index), on the parameter's step; or why not.
    public static func value(_ v: JSONValue, for p: ParamDef, slot: Slot) -> Result<Double, MCPRefusal> {
        let what = "\(slot.title) \(p.name)"
        switch p.meta {
        case .options(let options)?:
            if case .string(let s) = v {
                let t = s.trimmingCharacters(in: .whitespaces)
                if let i = options.firstIndex(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { return .success(Double(i)) }
                if let i = Int(t), options.indices.contains(i) { return .success(Double(i)) }
            } else if let i = v.intValue, options.indices.contains(i) { return .success(Double(i)) }
            return .failure(MCPRefusal("\(what) must be one of \(options.joined(separator: ", ")) (or its index 0–\(options.count - 1))."))
        case .range(let lo, let hi, let step, let unit, _, _, _)?:
            let n: Double? = v.numberValue ?? v.stringValue.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let range = "between \(MCPValidator.format(lo)) and \(MCPValidator.format(hi))\(unit.isEmpty ? "" : " " + unit)"
            guard let n, n.isFinite else { return .failure(MCPRefusal("\(what) must be a number \(range).")) }
            guard n >= lo - 1e-9, n <= hi + 1e-9 else { return .failure(MCPRefusal("\(what) must be \(range).")) }
            return .success(min(hi, max(lo, FXParams.roundToStep(n, step > 0 ? step : 0.1))))
        case nil:
            guard let n = v.numberValue, (0...10).contains(n) else { return .failure(MCPRefusal("\(what) must be a number between 0 and 10.")) }
            return .success(FXParams.roundToStep(n, 0.1))
        }
    }
    /// How the editor shows a value: "25 %", "6.5 dB", "Hall", "5.5".
    public static func display(_ value: Double, meta: ParamMeta?) -> String {
        switch meta {
        case .options(let o)?: let i = Int(value.rounded()); return o.indices.contains(i) ? o[i] : MCPValidator.format(value)
        case .range(_, _, let step, let unit, let decimals, _, _)?:
            let d = decimals ?? (step == step.rounded() ? 0 : (String(step).split(separator: ".").last?.count ?? 1))
            var s = String(format: "%.\(d)f", value)
            if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
            if s == "-0" { s = "0" }
            return unit.isEmpty ? s : s + " " + unit
        case nil: return MCPValidator.format(value)
        }
    }
}

// MARK: - the plan

/// What the editor shows before the call (the values the loudness limits compare with).
public struct MCPToneState: Sendable {
    public struct Effect: Sendable {
        public var model: ModelDef?
        public var unknown: Bool
        public var on: Bool
        public var values: [Double]
        public init(model: ModelDef?, unknown: Bool = false, on: Bool, values: [Double]? = nil) {
            self.model = model; self.unknown = unknown; self.on = on; self.values = values ?? model?.params.map(\.defaultValue) ?? []
        }
    }
    public var amp: [AmpKnob: Int]          // raw 0–255
    public var captureVolumeDb: Double
    public var cabLevelDb: Double
    public var gateOn: Bool
    public var gateReduction: Int
    public var effects: [Slot: Effect]
    public var captureNames: [String]       // one per capture slot ("" = empty)
    public var irNames: [String]            // one per cab/IR slot
    public init(amp: [AmpKnob: Int], captureVolumeDb: Double, cabLevelDb: Double, gateOn: Bool, gateReduction: Int,
                effects: [Slot: Effect], captureNames: [String], irNames: [String]) {
        self.amp = amp; self.captureVolumeDb = captureVolumeDb; self.cabLevelDb = cabLevelDb; self.gateOn = gateOn; self.gateReduction = gateReduction
        self.effects = effects; self.captureNames = captureNames; self.irNames = irNames
    }
    /// Amp knob raw → the 0–10 value the editor shows (one decimal).
    public static func knob(_ raw: Int) -> Double { (Double(raw) / 25.5 * 10).rounded() / 10 }
    public static func raw(_ knob: Double) -> Int { max(0, min(255, Int((knob * 25.5).rounded()))) }
}

public struct MCPTonePlan: Equatable, Sendable {
    public struct AmpChange: Equatable, Sendable { public let knob: AmpKnob; public let raw: Int }
    public struct ParamChange: Equatable, Sendable { public let index: Int; public let name: String; public let value: Double; public let display: String }
    public struct EffectChange: Equatable, Sendable {
        public let slot: Slot
        /// nil: the model stays; `.empty`: the slot is emptied (None); `.model`: that model goes in (from its defaults).
        public var model: MCPEffects.Choice?
        public var params: [ParamChange] = []
        public var on: Bool?
        public init(slot: Slot, model: MCPEffects.Choice? = nil, params: [ParamChange] = [], on: Bool? = nil) { self.slot = slot; self.model = model; self.params = params; self.on = on }
    }
    public var captureSlot: Int?
    public var cabSlot: Int?
    public var amp: [AmpChange] = []
    public var volumeDb: Double?
    public var gateOn: Bool?
    public var gateReduction: Int?
    public var cabLevelDb: Double?
    public var cabHighPassHz: Double?
    public var cabLowPassHz: Double?
    public var effects: [EffectChange] = []
    /// One line per change, in order (the Activity lines and apply_tone's `changes`).
    public var lines: [String] = []
    public init() {}
    public var isEmpty: Bool { lines.isEmpty }
}

public enum MCPTone {
    static let knobOrder: [(AmpKnob, String)] = [(.gain, "gain"), (.bass, "bass"), (.mid, "mid"), (.treble, "treble"), (.level, "level")]

    /// `apply_tone`: every part checked (names, ranges, loudness against the values before the call) before anything
    /// is planned; parts left out stay. Order: capture slot, cab slot, amp, gate, cab tone, effects.
    public static func plan(applyTone args: [String: JSONValue], state: MCPToneState, safety: MCPContract.Safety) -> Result<MCPTonePlan, MCPRefusal> {
        do {
            var p = MCPTonePlan()
            if let n = args["capture_slot"]?.intValue { try planCaptureSlot(n, state: state, into: &p) }
            if let n = args["cab_slot"]?.intValue { try planCabSlot(n, state: state, into: &p) }
            if let amp = args["amp"]?.objectValue { try planAmp(amp, state: state, safety: safety, into: &p) }
            if let gate = args["gate"]?.objectValue { planGate(gate, into: &p) }
            if let tone = args["cab_tone"]?.objectValue { try planCabTone(tone, state: state, safety: safety, into: &p) }
            if let effects = args["effects"]?.arrayValue {
                var seen: Set<Slot> = []
                for item in effects {
                    guard let o = item.objectValue, let slot = o["slot"]?.stringValue.flatMap(Slot.init(rawValue:)) else { continue }
                    guard seen.insert(slot).inserted else { throw MCPRefusal("effects lists \(slot.rawValue) more than once.") }
                    try planEffect(slot: slot, model: o["model"]?.stringValue, params: o["params"]?.objectValue ?? [:], on: o["on"]?.boolValue, state: state, safety: safety, into: &p)
                }
            }
            return .success(p)
        } catch let r as MCPRefusal { return .failure(r) } catch { return .failure(MCPRefusal("\(error)")) }
    }

    public static func planCaptureSlot(_ n: Int, state: MCPToneState, into p: inout MCPTonePlan) throws {
        let count = state.captureNames.count
        guard n >= 1, n <= count else { throw MCPRefusal("capture_slot must be between 1 and \(count) (the pedal's capture slots).") }
        let name = state.captureNames[n - 1]
        guard !name.isEmpty else { throw MCPRefusal("Capture slot \(n) is empty. list_library kind=capture lists the slots and what they hold.") }
        p.captureSlot = n
        p.lines.append("capture slot \(n) (\(name))")
    }
    public static func planCabSlot(_ n: Int, state: MCPToneState, into p: inout MCPTonePlan) throws {
        let count = state.irNames.count
        guard n >= 1, n <= count else { throw MCPRefusal("cab_slot must be between 1 and \(count) (the pedal's cab/IR slots).") }
        let name = state.irNames[n - 1]
        guard !name.isEmpty else { throw MCPRefusal("Cab/IR slot \(n) is empty. list_library kind=cab lists the slots and what they hold.") }
        p.cabSlot = n
        p.lines.append("cab slot \(n) (\(name))")
    }

    public static func planAmp(_ amp: [String: JSONValue], state: MCPToneState, safety: MCPContract.Safety, into p: inout MCPTonePlan) throws {
        var parts: [String] = []
        for (knob, key) in knobOrder {
            guard let v = amp[key]?.numberValue else { continue }
            let after = (v * 10).rounded() / 10
            if knob == .level, let why = MCPLoudness.ampLevel(before: MCPToneState.knob(state.amp[.level] ?? 0), after: after, safety: safety) { throw MCPRefusal(why) }
            p.amp.append(.init(knob: knob, raw: MCPToneState.raw(after)))
            parts.append("\(key.capitalized) \(String(format: "%.1f", after))")
        }
        if let v = amp["volume_db"]?.numberValue {
            let after = (v * 10).rounded() / 10
            if let why = MCPLoudness.captureVolume(before: (state.captureVolumeDb * 10).rounded() / 10, after: after, safety: safety) { throw MCPRefusal(why) }
            p.volumeDb = after
            parts.append("volume \(String(format: "%.1f", after)) dB")
        }
        if !parts.isEmpty { p.lines.append("amp " + parts.joined(separator: ", ")) }
    }

    public static func planGate(_ gate: [String: JSONValue], into p: inout MCPTonePlan) {
        var parts: [String] = []
        if let on = gate["on"]?.boolValue { p.gateOn = on; parts.append(on ? "on" : "off") }
        if let r = gate["reduction"]?.numberValue { let v = max(0, min(100, Int(r.rounded()))); p.gateReduction = v; parts.append("reduction \(v) %") }
        if !parts.isEmpty { p.lines.append("gate " + parts.joined(separator: ", ")) }
    }

    public static func planCabTone(_ tone: [String: JSONValue], state: MCPToneState, safety: MCPContract.Safety, into p: inout MCPTonePlan) throws {
        var parts: [String] = []
        if let v = tone["level_db"]?.numberValue {
            let after = (v * 10).rounded() / 10
            if let why = MCPLoudness.cabLevel(before: (state.cabLevelDb * 10).rounded() / 10, after: after, safety: safety) { throw MCPRefusal(why) }
            p.cabLevelDb = after; parts.append("level \(String(format: "%.1f", after)) dB")
        }
        if let v = tone["high_pass_hz"]?.numberValue { p.cabHighPassHz = v.rounded(); parts.append("high-pass \(Int(v.rounded())) Hz") }
        if let v = tone["low_pass_hz"]?.numberValue { p.cabLowPassHz = v.rounded(); parts.append("low-pass \(Int(v.rounded())) Hz") }
        if !parts.isEmpty { p.lines.append("cab " + parts.joined(separator: ", ")) }
    }

    /// One effect slot: model (by name, or "None"), then parameters (by name, in their units), then on/off.
    public static func planEffect(slot: Slot, model name: String?, params: [String: JSONValue], on: Bool?, state: MCPToneState,
                                  safety: MCPContract.Safety, into p: inout MCPTonePlan) throws {
        let current = state.effects[slot] ?? MCPToneState.Effect(model: nil, on: false)
        var change = MCPTonePlan.EffectChange(slot: slot)
        var model = current.model
        var before = current.values
        if let name {
            guard let choice = MCPEffects.choice(name, in: slot) else { throw MCPRefusal(MCPEffects.unknownModel(name, in: slot)) }
            change.model = choice
            switch choice {
            case .empty: model = nil; before = []
            case .model(let m):
                // The same model again keeps its values (the editor doesn't reload it); another starts from its defaults.
                if m.name != current.model?.name || current.unknown { model = m; before = m.params.map(\.defaultValue) }
                else { change.model = nil }
            }
            if change.model != nil { p.lines.append(choice == .empty ? "\(slot.title) emptied (None)" : "\(slot.title) → \(model!.name)") }
        }
        if !params.isEmpty {
            guard let m = model else {
                if current.unknown && name == nil { throw MCPRefusal("\(slot.title) holds an effect this editor doesn't know (newer firmware); choose a model for it first.") }
                throw MCPRefusal("\(slot.title) is empty; choose a model for it first (list_effects).")
            }
            for key in params.keys.sorted(by: { a, b in (MCPEffects.param(a, of: m)?.index ?? 99) < (MCPEffects.param(b, of: m)?.index ?? 99) }) {
                guard let def = MCPEffects.param(key, of: m) else {
                    throw MCPRefusal("\(slot.title) \(m.name) has no parameter “\(key)”. Its parameters: \(m.params.map(\.name).joined(separator: ", ")).")
                }
                let value: Double
                switch MCPEffects.value(params[key]!, for: def, slot: slot) { case .success(let v): value = v; case .failure(let r): throw r }
                let old = def.index < before.count ? before[def.index] : def.defaultValue
                if let why = MCPLoudness.effectParam(slot: slot, param: def, before: old, after: value, safety: safety) { throw MCPRefusal(why) }
                let shown = MCPEffects.display(value, meta: def.meta)
                change.params.append(.init(index: def.index, name: def.name, value: value, display: shown))
                p.lines.append("\(slot.title) \(def.name) → \(shown)")
            }
        }
        if let on {
            if model == nil && !(current.unknown && name == nil) {
                if on { throw MCPRefusal("\(slot.title) is empty (None), so it cannot be switched on; choose a model first.") }
            } else {
                change.on = on
                p.lines.append("\(slot.title) \(on ? "on" : "off")")
            }
        }
        if change.model != nil || !change.params.isEmpty || change.on != nil { p.effects.append(change) }
    }
}
