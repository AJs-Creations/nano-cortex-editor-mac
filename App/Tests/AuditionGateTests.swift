// The audition gate and the Cloud toolbar's Live Preview state machine (AuditionGate.swift, compiled into this bundle).
// The Electron edition's UX checks are the spec: a refused stop refuses Save and the preset switch, the toolbar never
// sticks on Preparing... or Stopping..., a refused stop leaves Stop Preview with the reason.
import XCTest

final class CapturePreviewStateTests: XCTestCase {
    func testAStartEndsActiveOrIdle() {
        var p = CapturePreviewState()
        XCTAssertEqual(p.buttonTitle, "Live Preview")
        XCTAssertTrue(p.beginStart())
        XCTAssertEqual(p.phase, .preparing)
        XCTAssertEqual(p.buttonTitle, "Preparing...")
        XCTAssertFalse(p.beginStart(), "one start at a time")
        p.named("Test Preview")
        p.finishStart(accepted: true)
        XCTAssertEqual(p.phase, .active)
        XCTAssertEqual(p.name, "Test Preview")
        XCTAssertEqual(p.buttonTitle, "Stop Preview")

        var refused = CapturePreviewState()
        _ = refused.beginStart(name: "X")
        refused.finishStart(accepted: false, error: "The pedal refused the live preview.")
        XCTAssertEqual(refused.phase, .idle)
        XCTAssertEqual(refused.error, "The pedal refused the live preview.")
        XCTAssertEqual(refused.buttonTitle, "Live Preview")
    }

    func testARefusedStopLeavesStopPreviewWithTheReason() {
        var p = CapturePreviewState()
        _ = p.beginStart(); p.finishStart(accepted: true)
        XCTAssertTrue(p.beginStop())
        XCTAssertEqual(p.buttonTitle, "Stopping...")
        p.finishStop(confirmed: false, error: "The pedal did not confirm stopping the live preview. It may still be playing.")
        XCTAssertEqual(p.phase, .active)
        XCTAssertEqual(p.buttonTitle, "Stop Preview")
        XCTAssertTrue(p.error.contains("did not confirm"))
        XCTAssertTrue(p.beginStop())
        p.finishStop(confirmed: true)
        XCTAssertEqual(p.phase, .idle)
        XCTAssertEqual(p.buttonTitle, "Live Preview")
    }

    /// Every event from every phase: the transitional phases always have a way out, and every completion lands in
    /// idle or active. Random walks never leave the button in Preparing... or Stopping... once the work is done.
    func testTheToolbarNeverSticks() {
        enum Event: CaseIterable { case start, accept, refuse, stop, confirm, unconfirmed, pedalPresetChange, disconnect }
        func apply(_ e: Event, _ p: inout CapturePreviewState) {
            switch e {
            case .start: _ = p.beginStart(name: "C")
            case .accept: p.finishStart(accepted: true)
            case .refuse: p.finishStart(accepted: false, error: "no")
            case .stop: _ = p.beginStop()
            case .confirm: p.finishStop(confirmed: true)
            case .unconfirmed: p.finishStop(confirmed: false, error: "no")
            case .pedalPresetChange: p.endPlaying()
            case .disconnect: p.end()
            }
        }
        // The work that follows each start or stop: whatever happens meanwhile, its own completion ends the transition.
        for meanwhile in Event.allCases {
            for completion in [Event.accept, .refuse] {
                var p = CapturePreviewState(); apply(.start, &p); apply(meanwhile, &p); apply(completion, &p)
                XCTAssertFalse(p.busy, "start, \(meanwhile), \(completion) → \(p.phase)")
            }
            for completion in [Event.confirm, .unconfirmed] {
                var p = CapturePreviewState(); apply(.start, &p); apply(.accept, &p); apply(.stop, &p); apply(meanwhile, &p); apply(completion, &p)
                XCTAssertFalse(p.busy, "stop, \(meanwhile), \(completion) → \(p.phase)")
            }
        }
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var p = CapturePreviewState()
            for _ in 0..<12 {
                apply(Event.allCases.randomElement(using: &rng)!, &p)
                // Whatever the state, the matching completion (or a disconnect) gets out of a transition.
                var done = p
                if done.phase == .preparing { done.finishStart(accepted: Bool.random(using: &rng)) }
                if done.phase == .stopping { done.finishStop(confirmed: Bool.random(using: &rng)) }
                XCTAssertTrue(done.phase == .idle || done.phase == .active)
                var gone = p; gone.end()
                XCTAssertEqual(gone.phase, .idle)
                XCTAssertEqual(gone.buttonTitle, "Live Preview")
            }
        }
    }

    func testAPedalPresetChangeEndsWhatPlaysButNotAStartInFlight() {
        var playing = CapturePreviewState()
        _ = playing.beginStart(); playing.finishStart(accepted: true)
        playing.endPlaying()
        XCTAssertEqual(playing.phase, .idle)
        var starting = CapturePreviewState()
        _ = starting.beginStart()
        starting.endPlaying()
        XCTAssertEqual(starting.phase, .preparing, "the start carries on and ends on its own")
        starting.finishStart(accepted: true)
        XCTAssertEqual(starting.phase, .active)
        var disconnected = CapturePreviewState()
        _ = disconnected.beginStart()
        disconnected.end(error: "The Nano Cortex disconnected; live preview stopped.")
        disconnected.finishStart(accepted: true)
        XCTAssertEqual(disconnected.phase, .idle, "a reply after a disconnect doesn't bring it back")
    }

    func testTheButtonFollowsElectron() {
        var p = CapturePreviewState()
        XCTAssertFalse(p.buttonEnabled(onCapturePage: false, connected: true))
        XCTAssertFalse(p.buttonEnabled(onCapturePage: true, connected: false))
        XCTAssertTrue(p.buttonEnabled(onCapturePage: true, connected: true))
        XCTAssertEqual(p.buttonHelp(onCapturePage: false, connected: true), "Open a capture’s page first (Discover → Neural Captures).")
        XCTAssertEqual(p.buttonHelp(onCapturePage: true, connected: true), "Audition this capture on the Nano without loading it into a slot")
        _ = p.beginStart()
        XCTAssertFalse(p.buttonEnabled(onCapturePage: true, connected: true), "no clicks during Preparing...")
        p.finishStart(accepted: true)
        XCTAssertTrue(p.buttonEnabled(onCapturePage: false, connected: true), "Stop Preview works from any page")
        XCTAssertEqual(p.buttonHelp(onCapturePage: false, connected: true), "Stop the live capture preview")
    }
}

@MainActor
final class AuditionGateTests: XCTestCase {
    private final class Calls { var log: [String] = [] }

    private func run(_ action: String = "Save", capture: CapturePreviewState = .init(), ir: IRAuditionState = .init(),
                     captureStops: Bool = true, irStops: Bool = true) async -> (AuditionGate.Verdict, [String]) {
        let calls = Calls()
        let verdict = await AuditionGate.check(action: action, capture: capture, ir: ir,
                                               stopCapture: { calls.log.append("capture"); return captureStops },
                                               stopIR: { calls.log.append("ir"); return irStops })
        return (verdict, calls.log)
    }
    private var playingCapture: CapturePreviewState { var p = CapturePreviewState(); _ = p.beginStart(); p.finishStart(accepted: true); return p }
    private var playingIR: IRAuditionState { IRAuditionState(active: IRKey(factory: true, index: 0, name: "412 V30")) }

    func testNothingPlaysNothingIsSent() async {
        let (v, calls) = await run()
        XCTAssertEqual(v, .proceed)
        XCTAssertEqual(calls, [])
    }

    func testAConfirmedStopLetsTheActionGoAhead() async {
        let (v, calls) = await run(ir: playingIR)
        XCTAssertEqual(v, .proceed)
        XCTAssertEqual(calls, ["ir"])
        let (both, order) = await run(capture: playingCapture, ir: playingIR)
        XCTAssertEqual(both, .proceed)
        XCTAssertEqual(order, ["capture", "ir"], "the capture preview first, then the IR")
    }

    func testAnUnconfirmedStopRefusesTheAction() async {
        let (v, _) = await run(ir: playingIR, irStops: false)
        XCTAssertEqual(v, .refused("The pedal did not confirm stopping the preview, so Save did not happen. Stop the preview and try again."))
        let (switchVerdict, calls) = await run("the preset switch", capture: playingCapture, ir: playingIR, captureStops: false)
        XCTAssertEqual(switchVerdict, .refused(AuditionGate.refusedMessage("the preset switch")))
        XCTAssertTrue(AuditionGate.refusedMessage("the preset switch").contains("so the preset switch did not happen"))
        XCTAssertEqual(calls, ["capture"], "no IR stop once the capture's stop failed")
    }

    func testAStartOrStopInFlightRefusesWithoutSendingAnything() async {
        var starting = CapturePreviewState(); _ = starting.beginStart()
        var stopping = playingCapture; _ = stopping.beginStop()
        for (capture, ir) in [(starting, IRAuditionState()), (stopping, IRAuditionState()),
                              (CapturePreviewState(), IRAuditionState(busy: true)),
                              (CapturePreviewState(), IRAuditionState(pending: IRKey(factory: false, index: 0, name: "Mine"), busy: true))] {
            let (v, calls) = await run("Rename", capture: capture, ir: ir)
            XCTAssertEqual(v, .refused("A preview is starting or stopping. Try Rename again in a moment."))
            XCTAssertEqual(calls, [])
        }
    }

    func testIRStateKeys() {
        let a = IRKey(factory: true, index: 2, name: "212 Blue")
        let s = IRAuditionState(active: a)
        XCTAssertTrue(s.isActive(IRKey(factory: true, index: 2, name: "212 Blue")))
        XCTAssertFalse(s.isActive(IRKey(factory: false, index: 2, name: "212 Blue")), "user IR 2 is another item")
        XCTAssertTrue(s.auditioning)
        XCTAssertFalse(IRAuditionState().auditioning)
    }
}
