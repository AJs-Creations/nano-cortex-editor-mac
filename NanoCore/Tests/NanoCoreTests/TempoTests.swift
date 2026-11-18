import XCTest
@testable import NanoCore

/// Preset tempo (type 145, state field 56) against the phone-app trace of 2026-10-09 (recorded phone-app session,
/// not published; frames inlined in RecordedFrames.swift; PROTOCOL-NOTES §11).
final class TempoTests: XCTestCase {
    private func frame(_ key: String) throws -> [UInt8] { Fixtures.bytes(try XCTUnwrap(Recorded.tempo[key], key)) }

    func testWritesMatchTheTrace() throws {
        // 203.4 s: the first live write, 120 BPM; 246.3 s: the preset write before a save, 93 BPM.
        XCTAssertEqual(try frame("tx203"), Writes.tempo(bpm: 120, live: true))
        XCTAssertEqual(Writes.tempo(bpm: 120, live: true), Fixtures.bytes("0F C0 18 01 20 00 2D 00 00 F0 42 30 00 91 00 00 00"))
        XCTAssertEqual(try frame("tx246"), Writes.tempo(bpm: 93, live: false))
        XCTAssertEqual(Writes.tempo(bpm: 93, live: false), Fixtures.bytes("0F C0 18 00 20 00 2D 00 00 BA 42 30 00 91 00 00 00"))
        // Every 145 write in the trace with field 4 = 0 and a tempo is one of ours.
        var checked = 0
        for bytes in Recorded.tempoWrites.map(Fixtures.bytes) {
            let f = ProtoFields.parse(Frame.body(of: bytes)!)
            guard f.int(4) == 0, let bpm = f.first(5)?.float32 else { continue }
            XCTAssertEqual(Writes.tempo(bpm: Double(bpm), live: f.int(3) == 1), bytes)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 2)
        XCTAssertEqual(Writes.tempo(bpm: 500, live: true), Writes.tempo(bpm: 300, live: true))
        XCTAssertEqual(Writes.tempo(bpm: 5, live: true), Writes.tempo(bpm: 30, live: true))
    }

    func testEchoParses() throws {
        let echo = try frame("rx203")
        XCTAssertEqual(echo, Fixtures.bytes("0D C0 08 01 18 01 2D 00 00 F0 42 91 00 00 00"))
        XCTAssertEqual(Tempo.parseEcho(body: Frame.body(of: echo)!), 120)
        // With field 4 = 1 (the second tempo store) it reads the same.
        XCTAssertEqual(Tempo.parseEcho(body: Frame.body(of: try frame("rx243"))!), 114)
        XCTAssertEqual(Tempo.parseEcho(body: Frame.body(of: try frame("rx244"))!), 93)
        // The query the app sent at 238.2 s (no tempo).
        XCTAssertEqual(try frame("tx238"), Writes.tempoQuery)
    }

    /// State field 56 follows the saves: 93 → 114 → 222 → 106.
    func testStateFieldFollowsTheSaves() throws {
        XCTAssertEqual(Recorded.tempoDumps.map { StateDump.parse(Fixtures.base64($0)).tempo }, [93, 114, 222, 106])
        XCTAssertEqual(StateDump.parse([]).tempo, 120)
    }

    /// Firmware 2.2.1 keeps 1.2.3's frames and the old fake pedal (DECISIONS #41: only 2.3+ uses the tempo screen).
    private func pedal221() -> FakePedal { var s = DemoState.demo(); s.firmware = "2.2.1"; return FakePedal(state: s) }

    func testFakePedalRoundTrip() async throws {
        let pedal = pedal221()
        let session = Session(transport: pedal)
        let (_, state) = try await session.connect()
        XCTAssertEqual(state.tempo, 96)   // demo preset 2
        var it = session.events.makeAsyncIterator()

        // Live: the pedal plays it and echoes; the preset stays clean.
        await session.setTempo(bpm: 133, live: true)
        var echoed: Double?
        while echoed == nil, let e = await it.next() { if case .tempo(let b) = e { echoed = b } }
        XCTAssertEqual(echoed, 133)
        var p = await pedal.state
        XCTAssertEqual(p.liveTempo, 133); XCTAssertEqual(p.tempo, 96); XCTAssertFalse(p.dirty)
        let query = try await session.requestTempo()
        XCTAssertEqual(query, 133)

        // Commit: a live write with the final value, then the scope-0 write; dirty; Save stores it as field 56.
        await session.setTempo(bpm: 141, live: false)
        let tail = await pedal.writes.suffix(2)
        XCTAssertEqual(Array(tail), [Writes.tempo(bpm: 141, live: true), Writes.tempo(bpm: 141, live: false)])
        p = await pedal.state
        XCTAssertEqual(p.tempo, 141); XCTAssertTrue(p.dirty)
        let dirtyRead = try await session.requestState().tempo
        XCTAssertEqual(dirtyRead, 141)
        _ = try await session.save(index: 1, name: "JP2C Lead")
        let other = try await session.selectPreset(index: 2).tempo
        XCTAssertEqual(other, 140)
        let back = try await session.selectPreset(index: 1).tempo
        XCTAssertEqual(back, 141)

        // A tap on the pedal arrives as an unsolicited event.
        await pedal.tapTempoOnPedal(bpm: 87)
        echoed = nil
        while echoed != 87, let e = await it.next() { if case .tempo(let b) = e { echoed = b } }
        XCTAssertEqual(echoed, 87)
        let live = await pedal.state.liveTempo
        XCTAssertEqual(live, 87)
    }

    /// A commit goes out as live + preset with the final value; later live writes follow it.
    func testCommitOrder() async throws {
        let pedal = pedal221()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let before = await pedal.writes.count
        await session.setTempo(bpm: 100, live: true)
        await session.setTempo(bpm: 103, live: false)
        await session.setTempo(bpm: 104, live: true)
        let sent = await Array(pedal.writes.dropFirst(before))
        XCTAssertEqual(sent, [Writes.tempo(bpm: 100, live: true), Writes.tempo(bpm: 103, live: true), Writes.tempo(bpm: 103, live: false), Writes.tempo(bpm: 104, live: true)])
    }
}

/// NanOS 2.3+ tempo (DECISIONS #41, #42): the TempoScreenMessage frames, the open → answer → write → close sequence, the
/// pedal metronome's copy and the fake pedal's 2.3.0 behaviour. Expected bytes: the Electron edition's UX checks
/// "NanOS 2.3.0 frames" and the "2.3.0: …" sequence checks (test/ux-test.js), measured on the pedal on 2026-11-17.
final class Tempo23Tests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func writes(_ a: [TempoScreen.Action]) -> [String] { a.compactMap { if case .write(let b, _) = $0 { hex(b) } else { nil } } }
    private func labels(_ a: [TempoScreen.Action]) -> [String] { a.compactMap { if case .write(_, let l) = $0 { l } else { nil } } }
    /// Every 3:1 frame on 2.3+ is whole, carrying the editor's copy of the metronome (default: muted, 0 dB, 4/4, 1/4, Blip).
    private func short(_ bpm: Double, _ g: Bool = false, _ m: PedalMetronome = PedalMetronome()) -> String { hex(Writes.tempoScreen(bpm: bpm, global: g, metronome: m)) }
    private let close = "06 C0 18 00 91 00 00 00"
    /// A screen that has read the pedal's state (tempo, Preset mode, no clock).
    private func screen(_ bpm: Double = 120, global: Bool = false, clock: Bool = false) -> TempoScreen {
        var s = TempoScreen(); s.dump(tempo: bpm, global: global, externalClock: clock, now: t0); return s
    }

    func testFrames() {
        // Open at 120 and tempo 123 (Preset mode) with the default copy; 123 with "on, −6 dB, Digital, 3/4, 1/8".
        XCTAssertEqual(short(120), "1C C0 18 01 20 00 2D 00 00 F0 42 30 00 3D 00 00 00 00 40 01 48 02 50 00 58 00 91 00 00 00")
        XCTAssertEqual(short(123), "1C C0 18 01 20 00 2D 00 00 F6 42 30 00 3D 00 00 00 00 40 01 48 02 50 00 58 00 91 00 00 00")
        XCTAssertEqual(short(123, false, PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)),
                       "1C C0 18 01 20 00 2D 00 00 F6 42 30 00 3D 00 00 C0 C0 40 00 48 01 50 01 58 01 91 00 00 00")
        XCTAssertEqual(hex(Writes.tempoScreenClose), close)
        let m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        XCTAssertEqual(hex(Writes.tempoScreen(bpm: 120, global: false, metronome: m)),
                       "1C C0 18 01 20 00 2D 00 00 F0 42 30 00 3D 00 00 C0 C0 40 00 48 01 50 01 58 01 91 00 00 00")
        XCTAssertEqual(PedalMetronome.timeSignatures[m.timeSig], "3/4"); XCTAssertEqual(PedalMetronome.notes[m.note], "1/8"); XCTAssertEqual(PedalMetronome.sounds[m.sound], "Digital")
        // Global mode: field 4 is 1.
        XCTAssertTrue(short(120, true).hasPrefix("1C C0 18 01 20 01 2D"))
        // A typed decimal goes out as it is.
        XCTAssertEqual(Array(Writes.tempoScreen(bpm: 120.5, global: false, metronome: PedalMetronome())[7...10]), Array(Float(120.5).bitPattern.littleEndianBytes))
        // The 1.2.3 frames are untouched (2.2.1 path).
        XCTAssertEqual(hex(Writes.tempo(bpm: 120, live: true)), "0F C0 18 01 20 00 2D 00 00 F0 42 30 00 91 00 00 00")
        XCTAssertEqual(hex(Writes.tempo(bpm: 93, live: false)), "0F C0 18 00 20 00 2D 00 00 BA 42 30 00 91 00 00 00")
    }

    func testRangeDecimalsAndFirmware() {
        XCTAssertEqual(Tempo23.clamp(300), 240); XCTAssertEqual(Tempo23.clamp(241), 240)
        XCTAssertEqual(Tempo23.clamp(30), 40); XCTAssertEqual(Tempo23.clamp(39), 40)
        XCTAssertEqual(Tempo23.clamp(120.5), 120.5); XCTAssertEqual(Tempo23.clamp(120.54), 120.5); XCTAssertEqual(Tempo23.clamp(120.55), 120.6)
        XCTAssertEqual(Tempo23.format(123), "123"); XCTAssertEqual(Tempo23.format(120.5), "120.5")
        XCTAssertTrue(Tempo23.applies(firmware: "2.3.0")); XCTAssertTrue(Tempo23.applies(firmware: "2.3.0+05c36621")); XCTAssertTrue(Tempo23.applies(firmware: "2.4.0"))
        XCTAssertTrue(Tempo23.applies(firmware: "3.0")); XCTAssertTrue(Tempo23.applies(firmware: "2.10"))
        XCTAssertFalse(Tempo23.applies(firmware: "2.2.1")); XCTAssertFalse(Tempo23.applies(firmware: nil)); XCTAssertFalse(Tempo23.applies(firmware: "garbage"))
        // 1.2.3's range for older firmware.
        XCTAssertEqual(Tempo.clamp(500), 300); XCTAssertEqual(Tempo.clamp(5), 30)
    }

    /// "2.3.0: a typed 123 sends open (the pedal's 120) → the tempo frame → {3:0}"; the write waits for the answer;
    /// the state is read again after the close.
    func testTypedTempo() {
        var s = screen()
        var a = s.commit(123, now: t0)
        XCTAssertEqual(writes(a), [short(120)])
        XCTAssertEqual(labels(a), ["Tempo screen open (120 BPM, preset, metronome off, 4/4, 1/4, Blip)"])
        XCTAssertTrue(a.contains(.start(.open, after: 0.3)))
        XCTAssertEqual(s.phase, .opening); XCTAssertEqual(s.tempo, 123)
        XCTAssertTrue(s.busy(now: t0))
        a = s.report(bpm: 120, now: at(0.03)).actions   // the answer: the tempo it had
        XCTAssertEqual(writes(a), [short(123), close])
        XCTAssertEqual(labels(a), ["Tempo 123 BPM (preset), metronome off, 4/4, 1/4, Blip", "Tempo screen close"])
        XCTAssertTrue(a.contains(.cancel(.open))); XCTAssertTrue(a.contains(.start(.reread, after: 0.3))); XCTAssertEqual(a.last, .opened)
        XCTAssertEqual(s.phase, .closed); XCTAssertEqual(s.tempo, 123)
        XCTAssertEqual(s.fired(.reread, now: at(0.4)), [.reread])
        XCTAssertEqual(s.fired(.reread, now: at(0.5)), [], "a timer fires once")
        // Typing the value it already has sends nothing.
        XCTAssertEqual(s.commit(123, now: at(1)), [])
    }

    func testTypedValuesAreClampedAndDecimalsKept() {
        var s = screen()
        _ = s.commit(120.5, now: t0)
        XCTAssertEqual(writes(s.report(bpm: 120, now: at(0.05)).actions).first, short(120.5))
        _ = s.fired(.reread, now: at(1))
        s.dump(tempo: 120.5, global: false, externalClock: false, now: at(1))
        _ = s.commit(300, now: at(2))
        XCTAssertEqual(writes(s.report(bpm: 120.5, now: at(2.05)).actions), [short(240), close])
        XCTAssertEqual(s.tempo, 240)
        _ = s.fired(.reread, now: at(3))
        _ = s.commit(30, now: at(4))
        XCTAssertEqual(writes(s.report(bpm: 240, now: at(4.05)).actions).first, short(40))
    }

    /// No answer in 300 ms: the write goes out anyway (logged).
    func testNoAnswerWritesAnyway() {
        var s = screen()
        _ = s.commit(123, now: t0)
        let a = s.fired(.open, now: at(0.3))
        XCTAssertTrue(a.contains(.log("Tempo screen: no answer in 300 ms, writing anyway")))
        XCTAssertEqual(writes(a), [short(123), close])
    }

    /// "the first + step is not lost (open 40 → 41 → close after it settles)".
    func testStepIsWrittenThenClosesWhenSettled() {
        var s = screen(40)
        var a = s.live(41, now: t0)
        a += s.closeSoon(after: Tempo23.settleStep)
        XCTAssertEqual(writes(a), [short(40)])
        XCTAssertTrue(a.contains(.start(.close, after: 0.8)))
        a = s.report(bpm: 40, now: at(0.02)).actions
        XCTAssertEqual(writes(a), [short(41)]); XCTAssertEqual(s.phase, .open)
        a = s.fired(.close, now: at(0.8))
        XCTAssertEqual(writes(a), [close]); XCTAssertTrue(a.contains(.start(.reread, after: 0.3)))
    }

    /// "the first step of a drag is not lost": writes at least 120 ms apart, the last value wins, then the close.
    func testDragIsPacedAndTheLastValueWins() {
        var s = screen(41)
        s.dragging = true
        var all = s.live(42, now: t0)
        all += s.report(bpm: 41, now: at(0.01)).actions      // open answered: 42 goes out at 0.01
        all += s.live(43, now: at(0.05))                      // too soon: a send timer
        XCTAssertTrue(all.contains { if case .start(.send, let w) = $0 { abs(w - 0.08) < 1e-6 } else { false } })
        all += s.live(44, now: at(0.06))                      // the timer is already running
        XCTAssertEqual(s.report(bpm: 99, now: at(0.07)).changed, false, "reports wait while the user drags")
        all += s.fired(.send, now: at(0.13))
        s.dragging = false
        all += s.closeSoon(after: Tempo23.settleStep)
        all += s.fired(.close, now: at(1))
        XCTAssertEqual(writes(all), [short(41), short(42), short(44), close])
    }

    /// "in Global mode field 4 is 1 in every frame"; "the Global | Preset switch writes the mode (open in Global,
    /// write with 4:0, close)"; then the state is read again.
    func testGlobalMode() {
        var s = screen(120, global: true)
        XCTAssertTrue(s.global)
        var a = s.live(121, now: t0)
        a += s.report(bpm: 120, now: at(0.02)).actions
        a += s.close(now: at(0.1))
        XCTAssertEqual(writes(a), [short(120, true), short(121, true), close])
        _ = s.fired(.reread, now: at(1))
        s.dump(tempo: 121, global: true, externalClock: false, now: at(1))
        a = s.setMode(global: false, now: at(2))
        a += s.report(bpm: 121, now: at(2.02)).actions
        XCTAssertEqual(writes(a), [short(121, true), short(121, false), close])
        XCTAssertTrue(a.contains(.start(.reread, after: 0.3)))
        XCTAssertFalse(s.global)
        XCTAssertEqual(s.setMode(global: false, now: at(3)), [], "already Preset")
    }

    /// "MIDI clock running: tempo field and switch are read-only … and nothing is sent".
    func testExternalClockIsReadOnly() {
        var s = screen(120, clock: true)
        XCTAssertTrue(s.externalClock)
        XCTAssertEqual(s.live(130, now: t0), [])
        XCTAssertEqual(s.commit(150, now: t0), [])
        XCTAssertEqual(s.setMode(global: true, now: t0), [])
        XCTAssertEqual(s.tempo, 120); XCTAssertEqual(s.phase, .closed)
        s.dump(tempo: 120, global: false, externalClock: false, now: at(1))
        XCTAssertFalse(s.externalClock)
    }

    /// The Pedal tab holds the screen open: "Metronome on opens the screen and sends the whole frame (muted 0); the screen
    /// stays open"; later controls send whole frames; "leaving the Pedal tab closes the screen ({3:0} alone)".
    func testPedalTabHoldsTheScreen() {
        var s = screen(100)
        XCTAssertEqual(s.setHeld(true, now: t0), [], "opening the tab sends nothing")
        var m = PedalMetronome(); m.muted = false
        var a = s.setMetronome(m, now: at(1))
        XCTAssertFalse(a.contains { if case .start(.close, _) = $0 { true } else { false } }, "held: no close")
        a += s.report(bpm: 100, now: at(1.02)).actions
        XCTAssertEqual(writes(a), [short(100, false, m), short(100, false, m)], "the open frame already carries the copy")
        XCTAssertEqual(labels(a).first, "Tempo screen open (100 BPM, preset, metronome on 0.0 dB, 4/4, 1/4, Blip)")
        XCTAssertEqual(labels(a).last, "Tempo 100 BPM (preset), metronome on 0.0 dB, 4/4, 1/4, Blip")
        m.volume = -6
        a = s.setMetronome(m, now: at(2))
        XCTAssertEqual(writes(a), [hex(Writes.tempoScreen(bpm: 100, global: false, metronome: m))], "the screen is still open: no new open")
        // A tap on the tab: a whole frame with the copy, still open.
        a = s.live(110, now: at(3)) + s.closeSoon(after: Tempo23.settleTap)
        XCTAssertEqual(writes(a), [short(110, false, m)]); XCTAssertEqual(s.phase, .open)
        a = s.setHeld(false, now: at(4))
        XCTAssertEqual(writes(a), [close])
        XCTAssertEqual(s.phase, .closed)
    }

    /// Without the Pedal tab (one click at a time: the computer metronome mutes the pedal's): open, whole, close later.
    func testMetronomeChangeOutsideTheTabClosesWhenSettled() {
        var s = screen(100)
        var m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        _ = s.setMetronome(m, now: t0)
        m.muted = true
        var a = s.setMetronome(m, now: at(0.01))
        a += s.report(bpm: 100, now: at(0.02)).actions
        a += s.fired(.close, now: at(0.9))
        XCTAssertEqual(writes(a), [hex(Writes.tempoScreen(bpm: 100, global: false, metronome: m)), close])
    }

    /// "Save right after a step: open, the tempo, close, then the save frame": while the open waits, the close comes
    /// with the answer (the caller waits for .opened); otherwise it closes at once.
    func testSaveFlushes() {
        var s = screen(100)
        _ = s.live(101, now: t0)
        XCTAssertEqual(s.flush(now: at(0.01)), [], "waits for the open")
        let a = s.report(bpm: 100, now: at(0.03)).actions
        XCTAssertEqual(writes(a), [short(101), close]); XCTAssertEqual(a.last, .opened)
        var o = screen(100)
        _ = o.live(102, now: t0); _ = o.report(bpm: 100, now: at(0.01))
        _ = o.live(103, now: at(0.02))   // pending behind the 120 ms gap
        XCTAssertEqual(writes(o.flush(now: at(0.03))), [short(103), close])
        XCTAssertEqual(o.flush(now: at(0.1)), [], "closed: nothing")
    }

    /// A preset change abandons a pending sequence: the old preset's write is dropped, the screen closes, no reread.
    func testPresetChangeAbandons() {
        var s = screen(100)
        _ = s.live(101, now: t0); _ = s.report(bpm: 100, now: at(0.01))
        _ = s.live(102, now: at(0.02))
        let a = s.abandon(now: at(0.03))
        XCTAssertEqual(writes(a), [close])
        XCTAssertFalse(a.contains { if case .start(.reread, _) = $0 { true } else { false } })
        XCTAssertFalse(s.pending)
        var o = screen(100)
        _ = o.live(101, now: t0)
        XCTAssertEqual(o.abandon(now: at(0.01)), [])
        XCTAssertEqual(writes(o.report(bpm: 100, now: at(0.02)).actions), [close], "opening: closes when answered, nothing written")
    }

    /// A tempo changed on the pedal shows (logged) once nothing of ours is under way; a dump never overwrites a pending change.
    func testReportsAndDumps() {
        var s = screen(100)
        let r = s.report(bpm: 132, now: t0)
        XCTAssertTrue(r.changed); XCTAssertEqual(r.actions, [.log("Pedal tempo: 132 BPM")]); XCTAssertEqual(s.tempo, 132)
        XCTAssertFalse(s.report(bpm: 132, now: at(1)).changed)
        XCTAssertFalse(s.report(bpm: 500, now: at(1)).changed, "out of any range: ignored")
        _ = s.live(140, now: at(2))
        s.dump(tempo: 132, global: true, externalClock: true, now: at(2.01))
        XCTAssertEqual(s.tempo, 140); XCTAssertFalse(s.global); XCTAssertTrue(s.externalClock, "the clock flag always follows")
    }

    /// "the open frame carries the metronome settings"; "the mode switch carries the metronome settings"; "a tempo change
    /// carries the metronome settings, so the pedal keeps subdivision 1/8" (the listening check of 2026-11-18).
    func testEveryFrameCarriesTheMetronomeCopy() {
        let m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        var s = screen(120); s.metronome = m
        var a = s.commit(123, now: t0)
        XCTAssertEqual(writes(a), [short(120, false, m)], "the open frame carries the copy")
        a = s.report(bpm: 120, now: at(0.02)).actions
        XCTAssertEqual(writes(a), [short(123, false, m), close], "the tempo frame carries the copy")
        _ = s.fired(.reread, now: at(1))
        a = s.setMode(global: true, now: at(2)) + s.report(bpm: 123, now: at(2.02)).actions
        XCTAssertEqual(writes(a), [short(123, false, m), short(123, true, m), close], "the mode switch carries the copy")
        // No frame with field 3 = 1 ever leaves out fields 7–11.
        for w in writes(a) where w != close { XCTAssertTrue(w.hasPrefix("1C C0 18 01")) }
    }

    /// "state field 60 closes / opens the editor's screen state", with the follow-up write.
    func testStateField60() {
        // The pedal says closed while we think it is open: the next write opens it again first.
        var s = screen(100)
        _ = s.live(101, now: t0); _ = s.report(bpm: 100, now: at(0.01))
        XCTAssertEqual(s.phase, .open)
        var a = s.dump(tempo: 101, global: false, externalClock: false, screenActive: false, now: at(1))
        XCTAssertEqual(a, [.log("Tempo screen: the pedal reports it closed")]); XCTAssertEqual(s.phase, .closed)
        a = s.live(102, now: at(2))
        XCTAssertEqual(writes(a), [short(101)], "an open frame first")
        a = s.report(bpm: 101, now: at(2.02)).actions
        XCTAssertEqual(writes(a), [short(102)])
        // The pedal says open while we think it is closed: the next write needs no open (write, close).
        var o = screen(100)
        a = o.dump(tempo: 100, global: false, externalClock: false, screenActive: true, now: at(1))
        XCTAssertEqual(a, [.log("Tempo screen: the pedal reports it open")]); XCTAssertEqual(o.phase, .open)
        a = o.live(101, now: at(2)) + o.closeSoon(after: Tempo23.settleStep)
        a += o.fired(.close, now: at(3))
        XCTAssertEqual(writes(a), [short(101), close])
        // Not while a write is in flight or a re-read is pending.
        var b = screen(100)
        _ = b.live(101, now: t0)   // opening: busy
        XCTAssertEqual(b.dump(tempo: 100, global: false, externalClock: false, screenActive: true, now: at(0.01)), [])
        XCTAssertEqual(b.phase, .opening)
        _ = b.report(bpm: 100, now: at(0.02)); _ = b.close(now: at(0.03))   // closed, re-read pending
        XCTAssertEqual(b.dump(tempo: 101, global: false, externalClock: false, screenActive: true, now: at(1)), [])
        XCTAssertEqual(b.phase, .closed)
        // Agreeing with us: nothing logged.
        var c = screen(100)
        XCTAssertEqual(c.dump(tempo: 100, global: false, externalClock: false, screenActive: false, now: at(1)), [])
    }

    func testPedalMetronomeCopy() throws {
        let d = PedalMetronome()
        XCTAssertEqual([d.muted ? 1 : 0, d.volume, Double(d.timeSig), Double(d.note), Double(d.sound)], [1, 0, 2, 0, 0], "muted, 0 dB, 4/4, 1/4, Blip")
        XCTAssertEqual(PedalMetronome.timeSignatures.count, 21)
        XCTAssertEqual(PedalMetronome.timeSignatures[2], "4/4")
        XCTAssertEqual(PedalMetronome.timeSignatures.last, "7/8 (2+2+3)")
        XCTAssertEqual(PedalMetronome.notes, ["1/4", "1/8", "1/8T", "1/16"]); XCTAssertEqual(PedalMetronome.sounds, ["Blip", "Digital"])
        let m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        XCTAssertEqual(PedalMetronome.decode(m.encoded), m)
        // Electron's localStorage shape, partial or out of range: defaults fill in, volume snaps to 0.5 dB in −60…+9.
        XCTAssertEqual(PedalMetronome.decode(Data(#"{"muted":false,"volume":-6.3}"#.utf8)), PedalMetronome(muted: false, volume: -6.5))
        XCTAssertEqual(PedalMetronome.decode(Data(#"{"volume":40,"timeSig":99,"note":-1,"sound":7}"#.utf8)), PedalMetronome(volume: 9))
        XCTAssertEqual(PedalMetronome.decode(Data("nope".utf8)), d); XCTAssertEqual(PedalMetronome.decode(nil), d)
        XCTAssertEqual(PedalMetronome.formatDb(-6), "−6 dB"); XCTAssertEqual(PedalMetronome.formatDb(0), "0 dB"); XCTAssertEqual(PedalMetronome.formatDb(4.5), "+4.5 dB")
    }

    func testStateDumpFields() {
        var s = DemoState.demo()
        var d = StateDump.parse(StateEncoder.dump(s, withLists: false))
        XCTAssertFalse(d.tempoIsGlobal); XCTAssertFalse(d.externalMidiClock)
        s.tempoGlobal = true; s.globalTempo = 133; s.externalMidiClock = true
        d = StateDump.parse(StateEncoder.dump(s, withLists: false))
        XCTAssertTrue(d.tempoIsGlobal); XCTAssertTrue(d.externalMidiClock); XCTAssertEqual(d.tempo, 133)
        // The Electron demo's dump bytes: B8 03 01 (55), C5 03 f32 (56), E8 03 01 (61).
        let raw: [UInt8] = [0xB8, 0x03, 0x01, 0xC5, 0x03] + Array(Float(120).bitPattern.littleEndianBytes) + [0xE8, 0x03, 0x01]
        d = StateDump.parse(raw)
        XCTAssertTrue(d.tempoIsGlobal); XCTAssertTrue(d.externalMidiClock); XCTAssertEqual(d.tempo, 120)
        // A 2.2.1 pedal never reports them.
        s.firmware = "2.2.1"
        d = StateDump.parse(StateEncoder.dump(s, withLists: false))
        XCTAssertFalse(d.tempoIsGlobal); XCTAssertFalse(d.externalMidiClock)
    }

    /// The fake pedal behaves like the real one on 2.3.0.
    func testFakePedalOn23() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        let (_, st) = try await session.connect()
        XCTAssertEqual(st.firmware, "2.3.0"); XCTAssertEqual(st.tempo, 96)
        var it = session.events.makeAsyncIterator()
        // The first 3:1 only opens: its tempo is ignored, the answer carries the tempo it had.
        await session.send(Writes.tempoScreen(bpm: 130, global: false, metronome: PedalMetronome()), label: "open")
        var answer: Double?
        while answer == nil, let e = await it.next() { if case .tempo(let b) = e { answer = b } }
        XCTAssertEqual(answer, 96)
        var p = await pedal.state
        XCTAssertTrue(p.tempoScreenOpen); XCTAssertEqual(p.tempo, 96); XCTAssertFalse(p.dirty)
        // Later 3:1 frames set it (clamped, decimals kept) and mark the preset edited.
        await session.send(Writes.tempoScreen(bpm: 123.5, global: false, metronome: PedalMetronome()), label: "write")
        p = await pedal.state
        XCTAssertEqual(p.tempo, 123.5); XCTAssertTrue(p.dirty)
        await session.send(Writes.tempoScreen(bpm: 300, global: false, metronome: PedalMetronome()), label: "write")
        p = await pedal.state
        XCTAssertEqual(p.tempo, 240)
        // Writing the stored value clears "edited".
        await session.send(Writes.tempoScreen(bpm: 96, global: false, metronome: PedalMetronome()), label: "write")
        p = await pedal.state
        XCTAssertFalse(p.dirty)
        // A whole frame stores the metronome.
        let m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        await session.send(Writes.tempoScreen(bpm: 96, global: false, metronome: m), label: "whole")
        p = await pedal.state
        XCTAssertEqual(p.pedalMetronome, m)
        // 3:0 only closes: a tempo in it is ignored; the next 3:1 opens again.
        await session.send(Writes.single(ProtoWriter().int(3, 0).float32(5, 150), MessageType.tempo.rawValue), label: "close with a tempo")
        p = await pedal.state
        XCTAssertFalse(p.tempoScreenOpen); XCTAssertEqual(p.tempo, 96)
        await session.send(Writes.tempoScreen(bpm: 150, global: false, metronome: PedalMetronome()), label: "open again")
        p = await pedal.state
        XCTAssertTrue(p.tempoScreenOpen); XCTAssertEqual(p.tempo, 96)
        // Global mode (field 4 = 1): the global tempo changes, nothing is edited; the dump says so.
        await session.send(Writes.tempoScreen(bpm: 111, global: true, metronome: PedalMetronome()), label: "global")
        p = await pedal.state
        XCTAssertTrue(p.tempoGlobal); XCTAssertEqual(p.globalTempo, 111); XCTAssertEqual(p.tempo, 96); XCTAssertFalse(p.dirty)
        var d = try await session.requestState()
        XCTAssertTrue(d.tempoIsGlobal); XCTAssertEqual(d.tempo, 111)
        // An external MIDI clock: writes are ignored.
        await pedal.setTempoHooks(global: false, midiClock: true)
        await session.send(Writes.tempoScreen(bpm: 170, global: false, metronome: PedalMetronome()), label: "under a clock")
        p = await pedal.state
        XCTAssertEqual(p.tempo, 96)
        d = try await session.requestState()
        XCTAssertTrue(d.externalMidiClock); XCTAssertFalse(d.tempoIsGlobal)
        XCTAssertTrue(d.tempoScreenActive, "field 60 while the screen is open")
        await session.send(Writes.tempoScreenClose, label: "close")
        d = try await session.requestState()
        XCTAssertFalse(d.tempoScreenActive, "absent after {3:0}")
    }

    /// "a frame without the metronome fields resets them": the real pedal's behaviour, kept by the fake one. Every 3:1
    /// frame, the open one included, replaces the metronome with fields 7–11 (missing → protocol defaults).
    func testFakePedalFrameWithoutMetronomeFieldsResetsThem() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        var p = await pedal.state
        XCTAssertEqual(p.pedalMetronome, PedalMetronome(), "starts muted, 0 dB, 4/4, 1/4, Blip")
        let m = PedalMetronome(muted: false, volume: -6, timeSig: 1, note: 1, sound: 1)
        await session.send(Writes.tempoScreen(bpm: 96, global: false, metronome: m), label: "open with the copy")
        p = await pedal.state
        XCTAssertEqual(p.pedalMetronome, m, "the open frame sets it too")
        let bare = Writes.single(ProtoWriter().int(3, 1).int(4, 0).float32(5, 97).int(6, 0), MessageType.tempo.rawValue)
        await session.send(bare, label: "a tempo frame without 7–11")
        p = await pedal.state
        XCTAssertEqual(p.pedalMetronome, PedalMetronome(muted: false, volume: 0, timeSig: 0, note: 0, sound: 0))
        XCTAssertEqual(p.tempo, 97)
    }
}

private extension UInt32 { var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 24)] } }
