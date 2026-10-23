// The pure rules behind live pedal sync, the unsaved-changes guard and preset moves: no NanoCore, no UI, so the app's
// unit tests compile this file on its own (project.yml). The Electron edition is the spec: pro/live-sync.js (from
// @itsbreaded's #14) and the matching parts of pro/ui.js.

import Foundation

// MARK: - expression pedal

/// The expression pedal's position (type 64, 0–255) mapped onto an assigned target, like Electron's travel().
enum ExpressionMath {
    /// The target's normalized value 0–1 between heel (`min`) and toe (`max`), both raw 0–255 as the assignment stores
    /// them. Inverted: the heel gives `max` and the toe `min`.
    static func travel(position: Int, min: Int, max: Int, inverted: Bool) -> Double {
        let pos = Double(Swift.max(0, Swift.min(255, position))) / 255
        let t = inverted ? 1 - pos : pos
        let lo = Double(Swift.max(0, Swift.min(255, min))) / 255, hi = Double(Swift.max(0, Swift.min(255, max))) / 255
        return Swift.max(0, Swift.min(1, lo + t * (hi - lo)))
    }

    /// A heel-toe switch acts only at the ends of the travel (≤ 2 heel, ≥ 253 toe), so a sweep doesn't flip it halfway:
    /// on at the toe (at the heel when inverted); nil in between.
    static func heelToe(position: Int, inverted: Bool) -> Bool? {
        guard position <= 2 || position >= 253 else { return nil }
        let atToe = position >= 253
        return inverted ? !atToe : atToe
    }

    /// A ranged parameter's value at normalized `n`, on its step (upstream's normalizedToParamValue + roundToStep,
    /// without the float noise: 68 / 255 of 0–10 in 0.1 steps is 2.7, not 2.7000000000000002).
    static func value(_ n: Double, min lo: Double, max hi: Double, step: Double) -> Double {
        let v = lo + Swift.max(0, Swift.min(1, n)) * (hi - lo)
        guard step > 0 else { return v }
        let decimals = Swift.max(0, Int((-log10(step)).rounded(.up)))
        let scale = pow(10, Double(decimals))
        return (((v / step).rounded() * step) * scale).rounded() / scale
    }
    /// An option list's index at normalized `n`.
    static func option(_ n: Double, count: Int) -> Int { Int((Swift.max(0, Swift.min(1, n)) * Double(Swift.max(0, count - 1))).rounded()) }

    /// The parameter an FX block's "Amount" drives when that is certain: Transpose's Semitones (checked on a pedal),
    /// otherwise one called Mix or else Amount that isn't a list of options. nil = not certain, so the editor doesn't
    /// animate it and reads the block's parameters back instead.
    static func amountParam(model: String, params: [(name: String, isOptions: Bool)]) -> Int? {
        let names = amountByModel[model].map { [$0] } ?? ["mix", "amount"]
        for name in names {
            if let i = params.firstIndex(where: { normalise($0.name) == name && !$0.isOptions }) { return i }
        }
        return nil
    }
    static let amountByModel = ["Transpose": "semitones"]
    private static func normalise(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").joined(separator: " ") }

    /// At most one parameter read-back every 250 ms while the pedal moves.
    static let readbackInterval: TimeInterval = 0.25
}

// MARK: - unsaved changes

/// The pedal's dirty report (115) is the unsaved-changes mark. It comes after an edit lands, so a prompt right after an
/// edit would see a clean preset: an edit write queued or in flight, or sent less than 300 ms ago with no report since,
/// counts as unsaved for the "Save changes to …?" prompts. (Electron: editWrites / isDirtyNow in pro/ui.js.)
struct EditGuard: Equatable {
    static let settle: TimeInterval = 0.3
    private(set) var inFlight = 0
    private(set) var lastSentAt: Date?
    private(set) var lastReportAt: Date?

    /// An edit write was queued.
    mutating func began() { inFlight += 1 }
    /// It went out (or the link dropped).
    mutating func ended(at: Date) { inFlight = max(0, inFlight - 1); lastSentAt = at }
    /// The pedal reported its dirty state.
    mutating func pedalReported(at: Date) { lastReportAt = at }
    mutating func reset() { self = EditGuard() }

    func pending(now: Date) -> Bool {
        if inFlight > 0 { return true }
        guard let sent = lastSentAt else { return false }
        if let report = lastReportAt, report >= sent { return false }
        return now.timeIntervalSince(sent) < Self.settle
    }
}

// MARK: - reports vs. the user's own gestures

/// While a knob is dragged, reports for that control wait: the user's value is written when the gesture ends, so it
/// wins, and a report that comes in up to `settle` after (an older value still on its way) doesn't yank it back.
struct GestureHolds: Equatable {
    static let settle: TimeInterval = 0.25
    /// A drag whose release never arrived (the view went away) stops holding after this long without a move.
    static let stale: TimeInterval = 2
    private var moving: [String: Date] = [:]
    private var ended: [String: Date] = [:]

    mutating func moved(_ key: String, at: Date) { moving[key] = at }
    mutating func ended(_ key: String, at: Date) { moving[key] = nil; ended[key] = at }
    mutating func reset() { self = GestureHolds() }

    func holds(_ key: String, now: Date) -> Bool {
        if let t = moving[key], now.timeIntervalSince(t) < Self.stale { return true }
        if let t = ended[key], now.timeIntervalSince(t) < Self.settle { return true }
        return false
    }
}

/// A bypass click the pedal hasn't confirmed yet wins over an older report for that block (Electron: keepLocalBypass).
struct BypassHolds: Equatable {
    static let grace: TimeInterval = 0.3
    struct Click: Equatable { var on: Bool; var preset: Int; var sentAt: Date? }
    private(set) var clicks: [String: Click] = [:]

    mutating func clicked(_ key: String, on: Bool, preset: Int) { clicks[key] = Click(on: on, preset: preset, sentAt: nil) }
    mutating func sent(_ key: String, on: Bool, at: Date) { if clicks[key]?.on == on { clicks[key]?.sentAt = at } }
    mutating func reset() { clicks = [:] }

    /// True when a report saying `on` for `key` is older than the user's click and should be dropped.
    func keepsLocal(_ key: String, reportedOn on: Bool, preset: Int, now: Date) -> Bool {
        guard let c = clicks[key], c.preset == preset, c.on != on else { return false }
        guard let sent = c.sentAt else { return true }
        return now.timeIntervalSince(sent) < Self.grace
    }
}

// MARK: - preset moves

enum PresetOrder {
    /// The sidebar's rows for a filter: 0-based presets whose name contains the text (any case), or whose number it is.
    static func rows(names: [String], filter: String) -> [Int] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return names.indices.filter { q.isEmpty || names[$0].lowercased().contains(q) || String($0 + 1) == q }
    }
    /// A drop of the row for preset `source` onto the row for preset `target`: the move to send. Rows carry absolute
    /// indices, so a filter changes nothing here. nil: nothing to move.
    static func move(source: Int, target: Int, count: Int = 64) -> (from: Int, to: Int)? {
        guard source != target, (0..<count).contains(source), (0..<count).contains(target) else { return nil }
        return (source, target)
    }
    /// The order an insertion gives (the presets in between shift by one): what the pedal's list should read after.
    static func apply<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard from != to, items.indices.contains(from), items.indices.contains(to) else { return items }
        var out = items
        out.insert(out.remove(at: from), at: to)
        return out
    }
}

/// Why a move can't start now (the toast says so), or nil.
enum ReorderRefusal: Equatable {
    case notConnected, scanning, busy
    var message: String {
        switch self {
        case .notConnected: "Connect your Nano Cortex first."
        case .scanning: "Wait for the slot usage scan to finish before reordering."
        case .busy: "Wait for the current pedal operation to finish before reordering."
        }
    }
    static func check(connected: Bool, scanning: Bool, operationInFlight: Bool) -> ReorderRefusal? {
        if !connected { return .notConnected }
        if scanning { return .scanning }
        if operationInFlight { return .busy }
        return nil
    }
}

/// Whether the editor knows which preset the pedal is on. A move can shift it; when the state read after a move fails,
/// it doesn't, and what acts on "the current preset" (Save, Save as, Discard, Rename) stays off until a read succeeds.
struct PresetKnowledge: Equatable {
    static let message = "The editor doesn’t know which preset the pedal is on. Refresh (or pick a preset) to read it again."
    static let status = "Current preset unknown: Refresh to read it"
    private(set) var unknown = false

    mutating func moveReadFailed() { unknown = true }
    /// Any current-state read that completes (Refresh, a preset switch, reconnecting).
    mutating func stateRead() { unknown = false }
    mutating func reset() { unknown = false }

    var allowsCurrentPresetActions: Bool { !unknown }
    /// The header's "Preset N" and name.
    func header(number: Int, name: String) -> (number: String, name: String) {
        unknown ? ("Preset ?", "Not known yet") : ("Preset \(number)", name)
    }
}
