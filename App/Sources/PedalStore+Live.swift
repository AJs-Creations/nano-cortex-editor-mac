// Live pedal sync and the unsaved-changes guard, ported from the Electron edition's pro/live-sync.js and pro/ui.js
// (contributed by @itsbreaded in its #14). Reports the pedal sends unasked (NanoCore LiveReports.swift) update the
// editor at once: knobs (26), effect parameters (99), bypasses from a footswitch, the expression pedal's switch or USB
// MIDI CC (31), and the expression pedal (64). A report without enough context asks for one coalesced state read.
// The pedal's dirty report (115) is the unsaved-changes mark; an edit still on its way counts too, for the prompts only.
// The pure rules live in LiveMath.swift (unit-tested); DECISIONS #26.

import Foundation
import Observation
import NanoCore

/// Transient live-sync state. Nothing here survives a disconnect (`PedalStore.resetLive`).
@MainActor @Observable
final class LiveSync {
    @ObservationIgnored var edits = EditGuard()
    @ObservationIgnored var gestures = GestureHolds()
    @ObservationIgnored var bypass = BypassHolds()
    /// One coalesced state read for reports the editor can't apply on the spot.
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var refreshPending = false
    @ObservationIgnored var refreshKeepModels = true
    /// The expression pedal's last reported position (nil until it moves; a preset load forgets it).
    var expressionPosition: Int?
    /// Expression targets edited here since the pedal last moved: a state read doesn't put the pedal's position back on them.
    @ObservationIgnored var expressionOverrides: Set<String> = []
    @ObservationIgnored var readbackTask: Task<Void, Never>?
    @ObservationIgnored var readbackAt = Date.distantPast
    /// A type-99 report comes with a type-26 control 6 carrying the same raw value.
    @ObservationIgnored var recentFXParam: (raw: Float, at: Date)?
    /// Reports applied since connecting, by kind (dev remote).
    @ObservationIgnored var applied: [String: Int] = [:]
    @ObservationIgnored var refreshes = 0

    func cancelRefresh() { refreshTask?.cancel(); refreshTask = nil; refreshPending = false; refreshKeepModels = true }
    func cancelExpression() { readbackTask?.cancel(); readbackTask = nil; readbackAt = .distantPast; expressionPosition = nil; expressionOverrides = [] }
    func reset() {
        cancelRefresh(); cancelExpression()
        edits.reset(); gestures.reset(); bypass.reset()
        recentFXParam = nil; applied = [:]; refreshes = 0
    }
}

extension PedalStore {
    // MARK: unsaved changes

    /// For the "Save changes to …?" prompts: the pedal's report, or an edit write still on its way (EditGuard).
    /// The header's mark, Save and Discard follow `dirty` alone.
    var dirtyForPrompt: Bool { dirty || live.edits.pending(now: Date()) }

    /// The pedal's 115. Ignored while a preset move runs (the pedal reports dirty, then clean, around one); the state
    /// read after the move says what it is.
    func applyDirtyReport(_ d: Bool) {
        live.edits.pedalReported(at: Date())
        if reorder.awaitingMove { append("Ignoring transient preset-dirty notification during preset reorder."); return }
        dirty = d
    }

    /// Sends an edit write and counts it as unsaved until it has gone out (and 300 ms after, unless the pedal reports).
    func editWrite(_ op: @escaping @Sendable (Session) async -> Void) {
        guard let session else { return }
        live.edits.began()
        Task { await op(session); live.edits.ended(at: Date()) }
    }

    /// A knob moved here (`commit` false while dragging, true at the end): reports for it wait, and the pedal's
    /// expression position no longer overrides it until the pedal moves again.
    func noteGesture(_ key: String, commit: Bool) {
        let now = Date()
        if commit { live.gestures.ended(key, at: now) } else { live.gestures.moved(key, at: now) }
        live.expressionOverrides.insert(key)
    }
    /// A bypass clicked here: an older report for that block doesn't undo it.
    func noteBypassClick(_ slot: Slot, on: Bool) {
        live.bypass.clicked("on:\(slot.rawValue)", on: on, preset: presetIndex)
        live.expressionOverrides.insert("on:\(slot.rawValue)")
    }
    func noteBypassSent(_ slot: Slot, on: Bool) { live.bypass.sent("on:\(slot.rawValue)", on: on, at: Date()) }
    private func held(_ key: String) -> Bool { live.gestures.holds(key, now: Date()) }

    // MARK: state reads

    /// Called by `applyState` with the dump just applied: any read means the editor knows the current preset again;
    /// a preset load makes the expression position and a pending refresh stale.
    func liveStateApplied(presetLoad: Bool) {
        reorder.knowledge.stateRead()
        if presetLoad { live.cancelRefresh(); live.cancelExpression(); live.bypass.reset() }
    }
    /// The values a held gesture owns, so a state read in the middle of a drag doesn't yank the knob.
    func heldValues() -> [String: Double] {
        var out: [String: Double] = [:]
        for k in AmpKnob.allCases where held("amp:\(k.rawValue)") { out["amp:\(k.rawValue)"] = Double(amp[k] ?? 0) }
        if held("capture-volume") { out["capture-volume"] = captureVolumeDb }
        if held("gate-reduction") { out["gate-reduction"] = Double(gateReduction) }
        for (slot, b) in blocks { for i in b.values.indices where held("fx:\(slot.rawValue):\(i)") { out["fx:\(slot.rawValue):\(i)"] = b.values[i] } }
        return out
    }
    func restoreHeld(_ values: [String: Double]) {
        for (key, v) in values {
            let parts = key.split(separator: ":").map(String.init)
            switch parts[0] {
            case "amp": if let k = AmpKnob(rawValue: parts[1]) { amp[k] = Int(v) }
            case "capture-volume": captureVolumeDb = v
            case "gate-reduction": gateReduction = Int(v)
            case "fx": if let s = Slot(rawValue: parts[1]), let i = Int(parts[2]), var b = blocks[s], i < b.values.count { b.values[i] = v; blocks[s] = b }
            default: break
            }
        }
    }

    // MARK: reports

    func applyLive(_ report: LiveReport) {
        guard connected, state != nil else { return }
        switch report {
        case .control(let c, let raw): applyControl(c, raw: raw)
        case .otherControl(let id, let raw):
            if id == 6, let r = live.recentFXParam, Date().timeIntervalSince(r.at) < 0.25, raw == Int(r.raw.rounded()) { live.recentFXParam = nil; return }
            scheduleStateRefresh(keepModels: false)
        case .fxParam(let slot, let index, let raw):
            if !applyFXParam(slot, index: index, raw: raw) { scheduleStateRefresh(keepModels: false) }
        case .fxEnabled(let slot, let on): applyEnable(slot, on: on)
        case .expression(let position): applyExpressionReport(position)
        case .stateChanged(let keepModels): scheduleStateRefresh(keepModels: keepModels)
        case .settings(let s): applyMonitoringReport(s)
        }
    }

    private func count(_ kind: String) { live.applied[kind, default: 0] += 1 }

    private func applyControl(_ c: LiveControl, raw: Int) {
        count("control")
        switch c {
        case .amp(let k):
            guard !held("amp:\(k.rawValue)") else { return }
            amp[k] = raw
            switch k { case .gain: state?.gain = raw; case .level: state?.level = raw; case .bass: state?.bass = raw; case .mid: state?.mid = raw; case .treble: state?.treble = raw }
        case .captureVolume:
            guard !held("capture-volume") else { return }
            captureVolumeDb = Capture.rawToDb(raw); state?.captureVolumeRaw = raw
        case .gateReduction:
            guard !held("gate-reduction") else { return }
            let pct = max(0, min(100, raw - 108))
            gateReduction = pct; state?.gateReductionPercent = pct
        }
    }

    /// The parameter's new value, or false when the block or parameter isn't known (then the state is read again).
    private func applyFXParam(_ slot: Slot, index: Int, raw: Float) -> Bool {
        guard var b = blocks[slot], b.unknownId == nil, let m = b.model, index < m.params.count else { return false }
        count("fxParam")
        live.recentFXParam = (raw, Date())
        guard !held("fx:\(slot.rawValue):\(index)") else { return true }
        if b.values.count < m.params.count { b.values = m.params.map(\.defaultValue) }
        b.values[index] = Self.paramValue(Double(raw) / 255, meta: m.params[index].meta)
        blocks[slot] = b
        return true
    }
    /// Normalized → a parameter's value, on its step (ExpressionMath.value, tested; options by index).
    static func paramValue(_ n: Double, meta: ParamMeta?) -> Double {
        switch meta {
        case .options(let o)?: Double(ExpressionMath.option(n, count: o.count))
        case .range(let lo, let hi, let step, _, _)?: ExpressionMath.value(n, min: lo, max: hi, step: step)
        case nil: ExpressionMath.value(n, min: 0, max: 10, step: 0.1)
        }
    }

    private func applyEnable(_ slot: Slot, on: Bool) {
        count("enable")
        if live.bypass.keepsLocal("on:\(slot.rawValue)", reportedOn: on, preset: presetIndex, now: Date()) { return }
        guard var b = blocks[slot] else { return }
        if b.on != on { b.on = on; blocks[slot] = b }
        state?.fx[slot.rawValue]?.on = on
    }

    // MARK: expression pedal

    private func applyExpressionReport(_ position: Int) {
        count("expression")
        live.expressionPosition = position
        live.expressionOverrides = []   // the pedal moved: local edits of its targets give way
        applyExpressionPosition(position)
        scheduleExpressionReadback()
    }

    /// The pedal has applied the position already; this only updates what the editor shows. Amp knobs, capture volume
    /// and gate reduction follow their ranges; an FX Amount only where its parameter is certain; heel-toe switches at
    /// the ends of the travel.
    func applyExpressionPosition(_ position: Int) {
        guard let set = expression, expressionPreset == presetIndex else { return }
        let skip = { (key: String) in self.live.expressionOverrides.contains(key) || self.held(key) }
        for (target, range) in set.ranges {
            let n = ExpressionMath.travel(position: position, min: range.min, max: range.max, inverted: range.inverted)
            switch target {
            case .gain, .bass, .mid, .treble:
                guard let k = AmpKnob(rawValue: target.key), !skip("amp:\(k.rawValue)") else { continue }
                amp[k] = Int((n * 255).rounded())
            case .level:
                if !skip("capture-volume") { captureVolumeDb = Capture.rawToDb(Int((n * 255).rounded())) }
            case .gate:
                if !skip("gate-reduction") { gateReduction = Int((n * 100).rounded()) }
            default:
                guard let slot = target.slot, var b = blocks[slot], let i = expressionAmountIndex(slot), let m = b.model, !skip("fx:\(slot.rawValue):\(i)") else { continue }
                if b.values.count < m.params.count { b.values = m.params.map(\.defaultValue) }
                b.values[i] = Self.paramValue(n, meta: m.params[i].meta)
                blocks[slot] = b
            }
        }
        for (target, bypass) in set.bypasses {
            guard case .heelToe(let inverted, _) = bypass, let on = ExpressionMath.heelToe(position: position, inverted: inverted), !skip("on:\(target.key)") else { continue }
            switch target {
            case .capture: captureOn = on
            case .cab: cab.on = on
            case .gate: gateOn = on
            default: if let slot = target.slot, var b = blocks[slot] { b.on = on; blocks[slot] = b }
            }
        }
    }
    /// After a state read the dump shows the stored values: put the last reported position back on top.
    func reapplyExpression() { if let p = live.expressionPosition { applyExpressionPosition(p) } }

    /// The parameter an FX block's Amount drives, when certain (ExpressionMath.amountParam).
    func expressionAmountIndex(_ slot: Slot) -> Int? {
        guard let b = blocks[slot], b.unknownId == nil, let m = b.model else { return nil }
        return ExpressionMath.amountParam(model: m.name, params: m.params.map { (name: $0.name, isOptions: { if case .options = $0.meta { true } else { false } }($0)) })
    }
    /// The FX blocks the expression pedal drives that are on (reading a bypassed block crashed the Nano), known and
    /// have parameters. Nothing assigned → nothing to read.
    func expressionReadbackSlots() -> [Slot] {
        guard let set = expression, expressionPreset == presetIndex else { return [] }
        return Slot.allCases.filter { slot in
            guard let t = ExpressionAssignments.RangeTarget.allCases.first(where: { $0.slot == slot }), set.ranges[t] != nil, let b = blocks[slot] else { return false }
            return b.on && b.unknownId == nil && !(b.model?.params.isEmpty ?? true)
        }
    }
    /// Expression events come faster than a parameter read: at most one read-back every 250 ms while the pedal moves,
    /// never on top of other traffic.
    func scheduleExpressionReadback() {
        guard connected, live.readbackTask == nil, !expressionReadbackSlots().isEmpty else { return }
        let wait = max(0, ExpressionMath.readbackInterval - Date().timeIntervalSince(live.readbackAt))
        live.readbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.live.readbackTask = nil
            guard self.connected, let session = self.session else { return }
            if await session.isBusy || self.reorder.moving { self.scheduleExpressionReadback(); return }
            let slots = self.expressionReadbackSlots()
            guard !slots.isEmpty else { return }
            self.live.readbackAt = Date()
            for s in slots { await session.refreshFXParams(s) }
        }
    }

    // MARK: one coalesced state read

    /// Several reports in a row make one read; it waits for reads and writes in flight, and a preset load (which reads
    /// the state anyway) drops it.
    func scheduleStateRefresh(keepModels: Bool) {
        guard connected, session != nil else { return }
        live.refreshKeepModels = live.refreshPending ? (live.refreshKeepModels && keepModels) : keepModels
        live.refreshPending = true
        live.refreshTask?.cancel()
        live.refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.runStateRefresh()
        }
    }
    private func runStateRefresh() async {
        guard let session, connected, live.refreshPending else { return }
        while await session.isBusy || reorder.moving || scanning != nil {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled || !connected || !live.refreshPending { return }
        }
        guard !Task.isCancelled, live.refreshPending else { return }
        let keepModels = live.refreshKeepModels
        live.refreshPending = false; live.refreshTask = nil; live.refreshKeepModels = true
        live.refreshes += 1
        append("Pedal state changed; refreshing the current preset")
        do { let st = try await session.requestState(); await applyState(st, presetLoad: false, keepModels: keepModels) }
        catch { append("Refreshing after a pedal change failed: \(error)") }
    }

    /// The pedal switched presets itself (footswitch): what was reported and clicked belongs to the old one.
    func livePresetChangedOnDevice() { live.cancelRefresh(); live.cancelExpression(); live.bypass.reset(); live.gestures.reset() }

    /// Disconnect (or demo exit): every timer and everything reported goes.
    func resetLive() {
        live.reset()
        resetMonitoring()
        resetReorder()
    }
}
