// What the Cloud toolbar and every preset-changing action read about auditions, and the gate those actions pass.
// Pure (no NanoCore, no UI), compiled into the unit tests: the toolbar's Live Preview never sticks, and an action is
// refused when the pedal doesn't confirm stopping what plays. The Electron edition's `stopAnyAudition` and toolbar
// (pro/ui.js, src/toolbar.html) are the spec.

import Foundation

/// The Cloud toolbar's Live Preview as a state machine. Every way out of `preparing` and `stopping` lands in `idle`
/// or `active`, so the button can't stay on "Preparing..." or "Stopping...".
struct CapturePreviewState: Equatable {
    enum Phase: String { case idle, preparing, active, stopping }
    private(set) var phase: Phase = .idle
    private(set) var name = ""
    /// Why the last start or stop didn't happen (the toolbar shows it); cleared by the next start.
    private(set) var error = ""

    /// The pedal may be playing the preview (a stop is going out, or it is confirmed playing).
    var playing: Bool { phase == .active || phase == .stopping }
    /// A start or a stop is in flight.
    var busy: Bool { phase == .preparing || phase == .stopping }

    /// idle → preparing. False, and nothing changes, from any other phase.
    mutating func beginStart(name: String = "") -> Bool {
        guard phase == .idle else { return false }
        phase = .preparing; self.name = name; error = ""
        return true
    }
    /// The capture's name once the download is in (still preparing).
    mutating func named(_ name: String) { if phase == .preparing { self.name = name } }
    /// preparing → active (the pedal accepted it) or idle (refused, failed, the download failed). From any other
    /// phase (a disconnect ended it meanwhile) nothing changes.
    mutating func finishStart(accepted: Bool, error: String = "") {
        guard phase == .preparing else { return }
        phase = accepted ? .active : .idle
        if !accepted { name = ""; self.error = error }
    }
    /// active → stopping. False from any other phase.
    mutating func beginStop() -> Bool {
        guard phase == .active else { return false }
        phase = .stopping; error = ""
        return true
    }
    /// stopping → idle (the pedal confirmed) or back to active (not confirmed: it may still be playing).
    mutating func finishStop(confirmed: Bool, error: String = "") {
        guard phase == .stopping else { return }
        phase = confirmed ? .idle : .active
        if confirmed { name = "" } else { self.error = error }
    }
    /// The pedal changed presets itself: a preview that plays is over (a start in flight carries on and ends on its own).
    mutating func endPlaying() { if playing { phase = .idle; name = "" } }
    /// Disconnected: over, whatever the phase.
    mutating func end(error: String = "") { phase = .idle; name = ""; self.error = error }
    mutating func clearError() { error = "" }

    // MARK: the toolbar button (src/toolbar.html `#c-preview`)

    var buttonTitle: String {
        switch phase { case .preparing: "Preparing..."; case .stopping: "Stopping..."; case .active: "Stop Preview"; case .idle: "Live Preview" }
    }
    /// Enabled to start on a capture page while connected, and to stop while one plays; never during a transition.
    func buttonEnabled(onCapturePage: Bool, connected: Bool) -> Bool {
        switch phase { case .preparing, .stopping: false; case .active: true; case .idle: onCapturePage && connected }
    }
    func buttonHelp(onCapturePage: Bool, connected: Bool) -> String {
        if phase == .active { return "Stop the live capture preview" }
        if !onCapturePage { return "Open a capture’s page first (Discover → Neural Captures)." }
        if !connected { return "Connect your Nano Cortex first." }
        return "Audition this capture on the Nano without loading it into a slot"
    }
}

/// A library cab or IR (factory cabs and the user's IRs are numbered separately).
struct IRKey: Hashable, Sendable { var factory: Bool; var index: Int; var name: String }

/// The library IR audition (▶ in the Cab / IR inspector): what plays, what is starting, and a start or stop in flight.
struct IRAuditionState: Equatable {
    var active: IRKey?
    var pending: IRKey?
    var busy = false
    var stopping = false
    var auditioning: Bool { busy || pending != nil || active != nil }
    func isActive(_ k: IRKey) -> Bool { active?.factory == k.factory && active?.index == k.index }
    func isPending(_ k: IRKey) -> Bool { pending?.factory == k.factory && pending?.index == k.index }
}

enum AuditionGate {
    enum Verdict: Equatable { case proceed, refused(String) }

    static func busyMessage(_ action: String) -> String { "A preview is starting or stopping. Try \(action) again in a moment." }
    static func refusedMessage(_ action: String) -> String {
        "The pedal did not confirm stopping the preview, so \(action) did not happen. Stop the preview and try again."
    }

    /// Before Save, Save as, a preset change, Rename, Delete, a footswitch assignment, Discard, the slot scan, a reorder
    /// or an IR delete: nothing plays → go ahead. A start or stop in flight → refused. Otherwise the capture preview
    /// and then the IR are stopped, each confirmed by the pedal (149 with its transaction); a stop that isn't confirmed
    /// refuses the action, because the pedal may still be playing the audition.
    @MainActor
    static func check(action: String, capture: CapturePreviewState, ir: IRAuditionState,
                      stopCapture: () async -> Bool, stopIR: () async -> Bool) async -> Verdict {
        guard capture.phase != .idle || ir.auditioning else { return .proceed }
        if capture.busy || ir.busy || ir.pending != nil { return .refused(busyMessage(action)) }
        if capture.phase == .active, !(await stopCapture()) { return .refused(refusedMessage(action)) }
        if ir.active != nil, !(await stopIR()) { return .refused(refusedMessage(action)) }
        return .proceed
    }
}
