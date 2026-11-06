// Effect parameter values between the wire and the editor (Electron #31, from @itsbreaded): the wire order of a
// model's parameters (Graphic 9 puts HPF first), the values an FX slot shows and where they came from, and the values
// last read per preset, kept on the computer for effects the pedal won't report because they are off.

import Foundation

extension ModelDef {
    /// The parameter at a wire index (a 99 report, a float of a 138 reply): its UI index and definition.
    public func param(wire: Int) -> (index: Int, def: ParamDef)? {
        params.firstIndex { $0.wireIndex == wire }.map { ($0, params[$0]) }
    }
    /// A 138 reply's floats (wire order) as values in UI order. A parameter the reply doesn't reach keeps its current
    /// value (upstream's `applyFloatValuesToBlock`).
    public func values(fromWire floats: [Float], current: [Double]) -> [Double] {
        params.enumerated().map { i, p in
            p.wireIndex < floats.count ? FXParams.value(Double(floats[p.wireIndex]), meta: p.meta) : (i < current.count ? current[i] : p.defaultValue)
        }
    }
    /// Values in UI order as the floats the pedal would report (wire order); nil when a count doesn't match or a
    /// value isn't a number (upstream's `saveCurrentFxParamCache`).
    public func wireFloats(_ values: [Double]) -> [Float]? {
        guard values.count == params.count, values.allSatisfy(\.isFinite) else { return nil }
        var out = [Float](repeating: 0, count: params.count)
        for (i, p) in params.enumerated() where p.wireIndex < out.count { out[p.wireIndex] = FXParams.normalized(values[i], meta: p.meta) }
        return out
    }
    /// The defaults as the pedal holds them, in wire order (the fake pedal's freshly loaded effect).
    public var defaultWireFloats: [Float] { wireFloats(params.map(\.defaultValue)) ?? [] }
}

/// An FX slot as the editor shows it (upstream's `state.blocks[key]`): the model, on/off, the values in UI order and
/// where they came from. The pedal reports an effect's parameters only while it is on (reading a bypassed block crashed
/// the Nano), so an effect that is off shows the values last read for this preset (`FXSavedValues`), marked as saved.
/// Saved values are display-only (deliberate, Electron #31): they never count as known (`valuesKnown`), one value
/// changed on a saved set leaves the set marked as saved, and only a full live read replaces them and clears the mark.
public struct FXSlotState: Equatable, Sendable {
    public var model: ModelDef?
    public var on: Bool
    public var values: [Double]         // parameter units, UI order
    /// A model id Models.swift doesn't list (newer firmware): on/off and replacing it only.
    public var unknownId: String?
    /// The values were read from the pedal or restored from saved values (`paramsLoaded`); false = the model's defaults.
    public var loaded = false
    /// … restored from saved values rather than read live (`paramsFromCache`).
    public var fromSaved = false
    /// The preset the values belong to (`paramsPreset`).
    public var preset: Int?
    /// When the saved values on screen were read (`cachedAt`).
    public var savedAt: Date?

    public init(model: ModelDef?, on: Bool, values: [Double]? = nil, unknownId: String? = nil, preset: Int? = nil) {
        self.model = model; self.on = on; self.values = values ?? model?.params.map(\.defaultValue) ?? []; self.unknownId = unknownId; self.preset = preset
    }

    /// The model's defaults, not read yet (another model, another preset, a discarded saved set).
    public mutating func reset(preset: Int?) {
        values = model?.params.map(\.defaultValue) ?? []
        loaded = false; fromSaved = false; self.preset = preset; savedAt = nil
    }
    /// A full read from the pedal (138, wire order): live values, the saved mark cleared.
    public mutating func applyRead(_ floats: [Float], preset: Int) {
        guard let model else { return }
        values = model.values(fromWire: floats, current: values)
        loaded = true; fromSaved = false; self.preset = preset; savedAt = nil
    }
    /// Shows saved values (display only). False when they don't fit this model.
    @discardableResult
    public mutating func applySaved(_ entry: FXSavedValues.Entry?, preset: Int) -> Bool {
        guard let model, !model.params.isEmpty, let entry, entry.model == model.name, entry.floats.count == model.params.count,
              entry.floats.allSatisfy(\.isFinite) else { return false }
        values = model.values(fromWire: entry.floats, current: values)
        loaded = true; fromSaved = true; self.preset = preset; savedAt = entry.savedAt
        return true
    }
    /// One value changed (a knob here, a report from the pedal): that one is now known, a saved set stays marked as saved.
    public mutating func set(_ value: Double, at index: Int, preset: Int) {
        guard let model, index < model.params.count else { return }
        if values.count < model.params.count { values = model.params.map(\.defaultValue) }
        values[index] = value
        if loaded { self.preset = preset }
    }
    /// True when every value was read live from the pedal for this preset (upstream's `fxValuesKnown`): what may write
    /// or export a whole effect. Saved values never are.
    public func valuesKnown(preset: Int) -> Bool { model == nil || (loaded && !fromSaved && self.preset == preset) }
    /// The values to keep for later (`FXSavedValues.save`): only once they were read or restored.
    public var floatsToSave: [Float]? { loaded ? model?.wireFloats(values) : nil }
    /// The note above the parameters while they aren't a live read (pro/ui.js `.fx-read-status`); nil once they are.
    public var readNote: String? {
        guard model != nil, unknownId == nil, fromSaved || !loaded else { return nil }
        if fromSaved { return on ? "Showing cached values until a fresh pedal readback replaces them." : "Showing cached values; they may be stale while this effect is bypassed." }
        return on ? "Reading current effect values from the pedal…" : "No parameter readback yet. The pedal does not return bypassed effect values."
    }
}

/// The values last read per pedal, preset, slot and effect (upstream's `FX_PARAM_CACHE_KEY`, Electron #31), so an effect
/// that is off can still show something. The newest 500 are kept. Only shown, never written back to the pedal.
public struct FXSavedValues: Equatable, Sendable, Codable {
    public struct Entry: Equatable, Sendable, Codable {
        public var model: String
        public var floats: [Float]      // wire order, as the pedal reports them
        public var savedAt: Date
        public init(model: String, floats: [Float], savedAt: Date) { self.model = model; self.floats = floats; self.savedAt = savedAt }
    }
    public static let limit = 500
    public private(set) var entries: [String: Entry] = [:]
    public init() {}

    /// `[pedal name, preset, slot, model id]`, like upstream's `fxParamCacheKey`.
    public static func key(pedal: String, preset: Int, slot: Slot, model: ModelDef) -> String {
        "\(pedal)|\(preset)|\(slot.rawValue)|\(model.idHex ?? model.name)"
    }
    public func entry(pedal: String, preset: Int, slot: Slot, model: ModelDef) -> Entry? {
        entries[Self.key(pedal: pedal, preset: preset, slot: slot, model: model)]
    }
    /// Keeps a full set (one float per parameter) for a known model; the oldest entries beyond `limit` go.
    public mutating func save(_ floats: [Float], pedal: String, preset: Int, slot: Slot, model: ModelDef, at date: Date = Date()) {
        guard model.id != nil, floats.count == model.params.count, floats.allSatisfy(\.isFinite) else { return }
        entries[Self.key(pedal: pedal, preset: preset, slot: slot, model: model)] = Entry(model: model.name, floats: floats, savedAt: date)
        if entries.count > Self.limit {
            let keep = entries.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(Self.limit)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    /// Unreadable data counts as nothing saved (the store is optional, like upstream's localStorage).
    public init(data: Data?) { self = data.flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self() }
}
