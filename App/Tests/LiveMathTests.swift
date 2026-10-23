// The pure rules of live pedal sync, the unsaved-changes guard and preset moves (LiveMath.swift, compiled into this
// bundle). The Electron edition's UX-test checks for the same behaviour are quoted where they apply.
import XCTest

final class ExpressionMathTests: XCTestCase {
    func testFullRangeFollowsThePedal() {
        XCTAssertEqual(ExpressionMath.travel(position: 0, min: 0, max: 255, inverted: false), 0)
        XCTAssertEqual(ExpressionMath.travel(position: 255, min: 0, max: 255, inverted: false), 1)
        XCTAssertEqual(ExpressionMath.travel(position: 51, min: 0, max: 255, inverted: false), 0.2, accuracy: 1e-9)
    }

    func testHeelAndToeLimitTheTravel() {
        // Heel 20 %, toe 80 % (raw 51 and 204).
        XCTAssertEqual(ExpressionMath.travel(position: 0, min: 51, max: 204, inverted: false), 0.2, accuracy: 1e-9)
        XCTAssertEqual(ExpressionMath.travel(position: 255, min: 51, max: 204, inverted: false), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ExpressionMath.travel(position: 128, min: 51, max: 204, inverted: false), 0.2 + 0.6 * 128 / 255, accuracy: 1e-9)
        // A toe below the heel sweeps downwards.
        XCTAssertEqual(ExpressionMath.travel(position: 255, min: 204, max: 51, inverted: false), 0.2, accuracy: 1e-9)
    }

    func testInversionSwapsTheEnds() {
        XCTAssertEqual(ExpressionMath.travel(position: 0, min: 51, max: 204, inverted: true), 0.8, accuracy: 1e-9)
        XCTAssertEqual(ExpressionMath.travel(position: 255, min: 51, max: 204, inverted: true), 0.2, accuracy: 1e-9)
    }

    func testOutOfRangeValuesAreClamped() {
        XCTAssertEqual(ExpressionMath.travel(position: 400, min: 0, max: 255, inverted: false), 1)
        XCTAssertEqual(ExpressionMath.travel(position: -3, min: -10, max: 999, inverted: false), 0)
    }

    func testHeelToeSwitchesOnlyAtTheEnds() {
        XCTAssertEqual(ExpressionMath.heelToe(position: 0, inverted: false), false)
        XCTAssertEqual(ExpressionMath.heelToe(position: 2, inverted: false), false)
        XCTAssertNil(ExpressionMath.heelToe(position: 3, inverted: false), "a sweep doesn't flip it halfway")
        XCTAssertNil(ExpressionMath.heelToe(position: 128, inverted: false))
        XCTAssertNil(ExpressionMath.heelToe(position: 252, inverted: false))
        XCTAssertEqual(ExpressionMath.heelToe(position: 253, inverted: false), true)
        XCTAssertEqual(ExpressionMath.heelToe(position: 255, inverted: false), true)
        XCTAssertEqual(ExpressionMath.heelToe(position: 255, inverted: true), false)
        XCTAssertEqual(ExpressionMath.heelToe(position: 0, inverted: true), true)
    }

    func testValuesLandOnTheParameterStep() {
        // Electron: "pedal FX report updates a non-selected effect parameter" (raw 68 of 0–10 in 0.1 steps → 2.7).
        XCTAssertEqual(ExpressionMath.value(68.0 / 255, min: 0, max: 10, step: 0.1), 2.7)
        // Transpose's Semitones, −12…12 in steps of 1: heel −12, toe 12 ("expression heel/toe updates the assigned effect amount").
        XCTAssertEqual(ExpressionMath.value(0, min: -12, max: 12, step: 1), -12)
        XCTAssertEqual(ExpressionMath.value(1, min: -12, max: 12, step: 1), 12)
        XCTAssertEqual(ExpressionMath.value(0.52, min: -12, max: 12, step: 1), 0)
        XCTAssertEqual(ExpressionMath.value(184.0 / 255, min: 0, max: 100, step: 0.1), 72.2)
        XCTAssertEqual(ExpressionMath.value(0.333, min: 2, max: 10, step: 0.01), 4.66)
        XCTAssertEqual(ExpressionMath.value(0.5, min: 20, max: 800, step: 1), 410)
        XCTAssertEqual(ExpressionMath.value(2, min: 0, max: 10, step: 0.1), 10, "clamped")
        XCTAssertEqual(ExpressionMath.option(0.5, count: 3), 1)
        XCTAssertEqual(ExpressionMath.option(1, count: 9), 8)
    }

    func testTheAmountIsAnimatedOnlyWhereItIsCertain() {
        let transpose: [(name: String, isOptions: Bool)] = [("Mix", false), ("Semitones", false), ("Pitch Fine", false)]
        XCTAssertEqual(ExpressionMath.amountParam(model: "Transpose", params: transpose), 1, "Transpose → Semitones, checked on a pedal")
        let comp: [(name: String, isOptions: Bool)] = [("Threshold", false), ("Ratio", true), ("Mix", false)]
        XCTAssertEqual(ExpressionMath.amountParam(model: "VCA Comp (M)", params: comp), 2)
        XCTAssertEqual(ExpressionMath.amountParam(model: "X", params: [("Depth", false), (" amount ", false)]), 1, "names compare trimmed, any case")
        XCTAssertNil(ExpressionMath.amountParam(model: "Green 808", params: [("Overdrive", false), ("Tone", false), ("Level", false)]),
                     "no Mix or Amount: not animated, read back instead")
        XCTAssertNil(ExpressionMath.amountParam(model: "X", params: [("Mix", true)]), "a list of options is never the amount")
    }
}

final class EditGuardTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testAnEditOnItsWayCountsAsUnsaved() {
        // Electron: "an edit write that just went out counts as unsaved for the prompts, before any 115".
        var g = EditGuard()
        XCTAssertFalse(g.pending(now: t0))
        g.began()
        XCTAssertTrue(g.pending(now: t0), "queued or in flight")
        XCTAssertTrue(g.pending(now: t0.addingTimeInterval(5)), "still in flight, however long it takes")
        g.ended(at: t0.addingTimeInterval(5))
        XCTAssertTrue(g.pending(now: t0.addingTimeInterval(5.2)), "sent under 300 ms ago, no report yet")
        XCTAssertFalse(g.pending(now: t0.addingTimeInterval(5.31)), "… and no longer once 300 ms pass without a 115")
    }

    func testThePedalsReportSettlesIt() {
        var g = EditGuard()
        g.began(); g.ended(at: t0)
        g.pedalReported(at: t0.addingTimeInterval(0.05))
        XCTAssertFalse(g.pending(now: t0.addingTimeInterval(0.06)), "the pedal has spoken: its report is the truth")
        // A report from before the write doesn't count.
        g.began(); g.ended(at: t0.addingTimeInterval(1))
        XCTAssertTrue(g.pending(now: t0.addingTimeInterval(1.1)))
    }

    func testSeveralWritesInFlight() {
        var g = EditGuard()
        g.began(); g.began()
        g.ended(at: t0)
        XCTAssertTrue(g.pending(now: t0.addingTimeInterval(1)), "one still on its way")
        g.ended(at: t0.addingTimeInterval(1))
        g.ended(at: t0.addingTimeInterval(1))   // an extra end never goes negative
        XCTAssertEqual(g.inFlight, 0)
        g.reset()
        XCTAssertFalse(g.pending(now: t0.addingTimeInterval(1)))
    }
}

final class HoldTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testReportsWaitWhileAKnobIsDragged() {
        var h = GestureHolds()
        h.moved("amp:gain", at: t0)
        XCTAssertTrue(h.holds("amp:gain", now: t0.addingTimeInterval(0.5)))
        XCTAssertFalse(h.holds("amp:bass", now: t0), "other controls apply at once")
        h.ended("amp:gain", at: t0.addingTimeInterval(1))
        XCTAssertTrue(h.holds("amp:gain", now: t0.addingTimeInterval(1.1)), "an older value still on its way")
        XCTAssertFalse(h.holds("amp:gain", now: t0.addingTimeInterval(1.3)))
        h.moved("amp:mid", at: t0)
        XCTAssertFalse(h.holds("amp:mid", now: t0.addingTimeInterval(2.5)), "a drag that never ended stops holding")
    }

    func testAnUnconfirmedBypassClickWins() {
        var b = BypassHolds()
        b.clicked("on:pre2", on: false, preset: 1)
        XCTAssertTrue(b.keepsLocal("on:pre2", reportedOn: true, preset: 1, now: t0), "an older report saying on is dropped")
        XCTAssertFalse(b.keepsLocal("on:pre2", reportedOn: false, preset: 1, now: t0), "the same state applies")
        XCTAssertFalse(b.keepsLocal("on:pre2", reportedOn: true, preset: 2, now: t0), "another preset: the report wins")
        XCTAssertFalse(b.keepsLocal("on:post1", reportedOn: true, preset: 1, now: t0))
        b.sent("on:pre2", on: false, at: t0)
        XCTAssertTrue(b.keepsLocal("on:pre2", reportedOn: true, preset: 1, now: t0.addingTimeInterval(0.2)))
        XCTAssertFalse(b.keepsLocal("on:pre2", reportedOn: true, preset: 1, now: t0.addingTimeInterval(0.4)), "a footswitch press after it is news")
    }
}

final class PresetOrderTests: XCTestCase {
    /// The demo pedal's names (24 presets, the rest empty), as the sidebar shows them.
    let names: [String] = (1...64).map { i in
        i <= 24 ? ["Princeton Clean", "JP2C Lead", "Jubilee Crunch", "5150 Rhythm", "VH4 Ambient Lead", "SVT Bass", "Tremolo Surf", "Funk Wah", "Fuzz Wall", "Octave Down Riff"][(i - 1) % 10] + (i > 10 ? " \((i - 1) / 10 + 1)" : "") : "Empty"
    }

    func testFilteredRowsKeepAbsoluteIndices() {
        let lead = PresetOrder.rows(names: names, filter: "Lead")
        XCTAssertEqual(lead, [1, 4, 11, 14, 21])
        XCTAssertEqual(PresetOrder.rows(names: names, filter: "  lead "), lead, "trimmed, any case")
        XCTAssertEqual(PresetOrder.rows(names: names, filter: "12"), [11], "a number is the preset's number")
        XCTAssertEqual(PresetOrder.rows(names: names, filter: "").count, 64)
    }

    func testADropWithTheFilterOnSendsAbsoluteIndices() {
        // Electron: "the drop sends 143 with absolute 0-based indices": the last "Lead" row onto the first.
        let lead = PresetOrder.rows(names: names, filter: "Lead")
        let move = PresetOrder.move(source: lead.last!, target: lead.first!)
        XCTAssertEqual(move?.from, 21)
        XCTAssertEqual(move?.to, 1)
        XCTAssertNil(PresetOrder.move(source: 5, target: 5), "onto itself: nothing")
        XCTAssertNil(PresetOrder.move(source: 70, target: 1), "out of range")
        // The pedal then lists "JP2C Lead 3" second and shifts 2…21 down by one.
        let after = PresetOrder.apply(names, from: 21, to: 1)
        XCTAssertEqual(after[1], "JP2C Lead 3")
        XCTAssertEqual(after[2], "JP2C Lead")
        XCTAssertEqual(after[21], names[20])
        XCTAssertEqual(after[22], names[22], "below the moved one nothing changes")
        XCTAssertEqual(PresetOrder.rows(names: after, filter: "Lead"), [1, 2, 5, 12, 15])
    }

    func testRefusals() {
        XCTAssertEqual(ReorderRefusal.check(connected: false, scanning: true, operationInFlight: true), .notConnected)
        XCTAssertEqual(ReorderRefusal.check(connected: true, scanning: true, operationInFlight: true), .scanning)
        XCTAssertEqual(ReorderRefusal.check(connected: true, scanning: false, operationInFlight: true), .busy)
        XCTAssertNil(ReorderRefusal.check(connected: true, scanning: false, operationInFlight: false))
        XCTAssertEqual(ReorderRefusal.scanning.message, "Wait for the slot usage scan to finish before reordering.")
    }

    func testUnknownPresetAfterAFailedRead() {
        // Electron: "a failed read after a move marks the current preset unknown (header, status bar, toast)".
        var k = PresetKnowledge()
        XCTAssertTrue(k.allowsCurrentPresetActions)
        XCTAssertEqual(k.header(number: 22, name: "JP2C Lead 3").number, "Preset 22")
        k.moveReadFailed()
        XCTAssertTrue(k.unknown)
        XCTAssertFalse(k.allowsCurrentPresetActions, "Save, Save as, Discard and Rename stay off")
        XCTAssertEqual(k.header(number: 22, name: "JP2C Lead 3").number, "Preset ?")
        XCTAssertEqual(k.header(number: 22, name: "JP2C Lead 3").name, "Not known yet")
        XCTAssertEqual(PresetKnowledge.status, "Current preset unknown: Refresh to read it")
        k.stateRead()
        XCTAssertFalse(k.unknown, "a successful state read clears it")
        k.moveReadFailed(); k.reset()
        XCTAssertFalse(k.unknown, "disconnecting clears it")
    }
}
