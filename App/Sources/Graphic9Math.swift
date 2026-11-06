// The pure rules of the Graphic 9 fader bank (Graphic9Bank.swift; pro/ui.js `graphic9BandSection`), unit-tested.

import Foundation
import NanoCore

enum Graphic9 {
    static let modelName = "Graphic 9"
    static let bandCount = 9
    /// The nine bands get the fader bank; HPF, LPF and Output stay knobs below it.
    static func isBank(_ model: ModelDef) -> Bool { model.name == modelName && model.params.count >= bandCount }
    /// "65Hz" → "65 Hz", "1kHz" → "1 kHz", "500hz" → "500 Hz".
    static func label(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.hasSuffix("khz") { return String(name.dropLast(3)) + " kHz" }
        if lower.hasSuffix("hz") { return String(name.dropLast(2)) + " Hz" }
        return name
    }
    /// The readout above a fader: one decimal, a plus sign above 0 (`graphic9BandValue`).
    static func readout(_ value: Double) -> String { (value > 0 ? "+" : "") + String(format: "%.1f", value + 0) }
    /// The band's range and step (−12…+12 dB by 0.1 without metadata, as upstream).
    static func range(_ meta: ParamMeta?) -> (min: Double, max: Double, step: Double) {
        if case .range(let lo, let hi, let step, _, _, _)? = meta { return (lo, hi, step > 0 ? step : 0.1) }
        return (-12, 12, 0.1)
    }
    /// A value put on the band's range and step (`setBandValue`).
    static func snap(_ value: Double, meta: ParamMeta?) -> Double {
        let r = range(meta)
        return FXParams.roundToStep(max(r.min, min(r.max, value)), r.step)
    }
    /// A typed gain ("3.5", "-2,5", "+1 dB"); nil when it isn't a number, so nothing changes.
    static func typed(_ text: String, meta: ParamMeta?) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if s.lowercased().hasSuffix("db") { s = String(s.dropLast(2)).trimmingCharacters(in: .whitespaces) }
        if s.hasPrefix("+") { s.removeFirst() }
        guard let v = Double(s), v.isFinite else { return nil }
        return snap(v, meta: meta)
    }
    /// The value under a point of the fader: `y` from the top of a `length`-point track whose thumb is `thumb` long, as
    /// an HTML range input places it (the thumb's centre travels from thumb/2 to length − thumb/2).
    static func value(atY y: Double, length: Double, thumb: Double, meta: ParamMeta?) -> Double {
        let r = range(meta), travel = max(1, length - thumb)
        let n = 1 - max(0, min(1, (y - thumb / 2) / travel))
        return snap(r.min + n * (r.max - r.min), meta: meta)
    }
    /// The thumb's centre for a value, from the top of the track.
    static func y(of value: Double, length: Double, thumb: Double, meta: ParamMeta?) -> Double {
        let r = range(meta), n = max(0, min(1, (value - r.min) / (r.max - r.min)))
        return thumb / 2 + (1 - n) * (length - thumb)
    }
}
