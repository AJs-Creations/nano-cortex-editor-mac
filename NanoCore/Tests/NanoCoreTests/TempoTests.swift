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

    func testFakePedalRoundTrip() async throws {
        let pedal = FakePedal()
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
        let pedal = FakePedal()
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
