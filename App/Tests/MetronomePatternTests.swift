// The metronome's event generator and trainers (MetronomePattern.swift, compiled into this bundle).
import XCTest

final class MetronomePatternTests: XCTestCase {
    typealias P = MetronomePattern

    func roles(_ e: [P.Event]) -> [String: Int] { Dictionary(grouping: e, by: { $0.role.rawValue }).mapValues { $0.count } }

    func testSimpleFourFour() {
        let e = P.events(beats: 4, accents: P.defaultAccents(4))
        XCTAssertEqual(e.map(\.offset), [0, 1, 2, 3])
        XCTAssertEqual(e.map(\.role), [.accent, .normal, .normal, .normal])
    }

    func testFiveFourThreePlusTwoInTriplets() {
        let preset = P.presets.first { $0.name == "5/4 (3+2)" }!
        XCTAssertEqual(preset.accents, [.accent, .soft, .soft, .normal, .soft])
        let e = P.events(beats: 5, noteValue: 4, accents: preset.accents, subdivision: 3)
        XCTAssertEqual(e.count, 15)
        XCTAssertEqual(roles(e), ["accent": 1, "soft": 3, "normal": 1, "sub": 10])
        XCTAssertEqual(e[1].offset, 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(e[3].offset, 1)
        XCTAssertEqual(e[9].role, .normal); XCTAssertEqual(e[9].beat, 3)
    }

    func testSwing() {
        let straight = P.events(beats: 1, accents: [.accent], subdivision: 2, swing: 0)
        XCTAssertEqual(straight.map(\.offset), [0, 0.5])
        let full = P.events(beats: 1, accents: [.accent], subdivision: 2, swing: 1)
        XCTAssertEqual(full[1].offset, 2.0 / 3, accuracy: 1e-9)
        let sixteenths = P.events(beats: 1, accents: [.accent], subdivision: 4, swing: 1).map(\.offset)
        XCTAssertEqual(sixteenths[0], 0); XCTAssertEqual(sixteenths[1], 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(sixteenths[2], 0.5); XCTAssertEqual(sixteenths[3], 0.5 + 1.0 / 3, accuracy: 1e-9)
        // Triplets ignore swing.
        XCTAssertEqual(P.events(beats: 1, accents: [.accent], subdivision: 3, swing: 1)[1].offset, 1.0 / 3, accuracy: 1e-9)
    }

    func testMuteCellsAndMutedBars() {
        let e = P.events(beats: 4, accents: [.accent, .mute, .normal, .soft], subdivision: 2)
        XCTAssertEqual(e[2].role, .mute)       // beat 2 silent…
        XCTAssertEqual(e[3].role, .sub)        // …its off-beat still plays
        let muted = P.events(beats: 4, accents: P.defaultAccents(4), subdivision: 2, kind: .muted)
        XCTAssertEqual(muted.count, 8)
        XCTAssertTrue(muted.allSatisfy { $0.role == .mute })
    }

    func testCountInBarsAndGap() {
        let c = P.events(beats: 7, noteValue: 8, accents: P.grouped([2, 2, 3]), subdivision: 4, kind: .countIn)
        XCTAssertEqual(c.map(\.role), [.accent] + Array(repeating: .normal, count: 6))
        let kinds = (0..<9).map { P.barKind(index: $0, countIn: 1, gap: (2, 1)) }
        XCTAssertEqual(kinds, [.countIn, .play, .play, .muted, .play, .play, .muted, .play, .play])
        XCTAssertEqual(P.barKind(index: 5, countIn: 0), .play)
    }

    func testRamp() {
        XCTAssertEqual((0..<12).map { P.rampTempo(start: 96, target: 120, step: 8, every: 2, barsCompleted: $0) },
                       [96, 96, 104, 104, 112, 112, 120, 120, 120, 120, 120, 120])
        XCTAssertEqual(P.rampTempo(start: 120, target: 100, step: 7, every: 1, barsCompleted: 5), 100)   // down, stops at the target
        XCTAssertEqual(P.rampTempo(start: 100, target: 100, step: 5, every: 1, barsCompleted: 9), 100)
    }

    func testPresetsAndSetup() {
        XCTAssertEqual(P.presets.map(\.name), ["4/4", "3/4", "6/8 (3+3)", "5/4 (3+2)", "7/8 (2+2+3)", "12/8 (4×3)"])
        for p in P.presets { XCTAssertEqual(p.accents.count, p.beats, p.name) }
        var s = MetronomeSetup()
        XCTAssertEqual(s.presetName, "4/4")
        s.setBeats(6); XCTAssertEqual(s.accents, [.accent, .normal, .normal, .normal, .normal, .normal])
        s.setBeats(2); XCTAssertEqual(s.accents, [.accent, .normal])
        s.apply(P.presets[5]); XCTAssertEqual(s.presetName, "12/8 (4×3)"); XCTAssertEqual(s.noteValue, 8)
        s.gapOn = true; s.countIn = 2
        XCTAssertEqual(s.barKind(1), .countIn); XCTAssertEqual(s.barKind(4), .muted)
        let data = try! JSONEncoder().encode(s)
        XCTAssertEqual(try! JSONDecoder().decode(MetronomeSetup.self, from: data), s)
    }

    func testLevels() {
        let l = MetronomeLevels()
        XCTAssertEqual(l.gain(.accent), 1); XCTAssertEqual(l.gain(.normal), 0.7)   // the original accent/click mix
        XCTAssertEqual(l.gain(.soft), 0.7 * MetronomeLevels.softFactor, accuracy: 1e-9)
        XCTAssertEqual(l.gain(.mute), 0)
    }

    // A stepper's typed value (overlay, Settings, /metro?type=): parsed, clamped to the range, nil when not a number.
    func testTypedNumberCommit() {
        XCTAssertEqual(TypedNumber.commit("175", range: MetronomeSetup.rampTargetRange), 175)
        XCTAssertEqual(TypedNumber.commit(" 12 ", range: MetronomeSetup.barsRange), 12)
        XCTAssertEqual(TypedNumber.commit("999", range: MetronomeSetup.rampTargetRange), 300)
        XCTAssertEqual(TypedNumber.commit("0", range: MetronomeSetup.rampStepRange), 1)
        XCTAssertEqual(TypedNumber.commit("-3", range: MetronomeSetup.beatsRange), 1)
        XCTAssertEqual(TypedNumber.commit("40", range: MetronomeSetup.barsRange), 16)
        XCTAssertNil(TypedNumber.commit("", range: MetronomeSetup.barsRange))
        XCTAssertNil(TypedNumber.commit("abc", range: MetronomeSetup.barsRange))
        XCTAssertNil(TypedNumber.commit("4.5", range: MetronomeSetup.barsRange))
    }
}

final class TapTempoTests: XCTestCase {
    func testTapsAverageAndReset() {
        var t = TapTempo()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertNil(t.tap(at: t0))
        XCTAssertEqual(t.tap(at: t0 + 0.5), 120)
        XCTAssertEqual(t.tap(at: t0 + 1.1), 109)          // gaps 0.5, 0.6 → 0.55 s
        XCTAssertNil(t.tap(at: t0 + 5))                   // a long pause starts over
        XCTAssertEqual(t.tap(at: t0 + 5.1), 300)          // clamped
        for i in 2...9 { _ = t.tap(at: t0 + 5 + Double(i)) }
        XCTAssertEqual(t.taps.count, 5)
    }
}
