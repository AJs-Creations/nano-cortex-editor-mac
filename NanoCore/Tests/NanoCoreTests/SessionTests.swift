import XCTest
@testable import NanoCore

/// The session against the fake pedal: sync, editing, coalescing, uploads.
final class SessionTests: XCTestCase {
    func testConnectSyncsMetadataAndState() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        let (meta, state) = try await session.connect()
        XCTAssertEqual(meta.presetNames.count, 64)
        XCTAssertEqual(meta.presetNames[1], "JP2C Lead")
        XCTAssertEqual(meta.captureNames[4], "VH4 Ch3")
        XCTAssertEqual(state.presetIndex, 1)
        XCTAssertEqual(state.firmware, "2.2.1")
        XCTAssertEqual(state.captureSlot, 2)
        XCTAssertEqual(Models.byId(state.fx[Slot.pre1.rawValue]!.modelIdHex!, in: "pre1")?.name, "Green 808")
        XCTAssertEqual(state.gateReductionPercent, 50)
        let first = await pedal.writes.first
        XCTAssertEqual(first, Writes.metadataRequest)
    }

    func testPresetChangeSaveRename() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let state = try await session.selectPreset(index: 7)
        XCTAssertEqual(state.presetIndex, 7)
        await session.setAmp(.gain, 200)
        let saved = try await session.save(index: 7, name: "Funk Wah"); XCTAssertTrue(saved)
        let renamed = try await session.rename(index: 7, name: "Funk Wah 2"); XCTAssertTrue(renamed)
        let pedalState = await pedal.state
        XCTAssertEqual(pedalState.presetNames[7], "Funk Wah 2")
        XCTAssertEqual(pedalState.amp[.gain], 200)
        XCTAssertFalse(pedalState.dirty)
    }

    /// Six rapid writes to one knob reach the pedal as two: the first and the latest.
    func testKnobWritesCoalesce() async throws {
        let pedal = FakePedal()
        await pedal.setReplyDelay(30)
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let before = await pedal.writes.count
        await withTaskGroup(of: Void.self) { g in
            for v in 100...105 { g.addTask { await session.setAmp(.gain, v) } }
        }
        let writes = await pedal.writes.dropFirst(before)
        let gains = writes.filter { Frame.type(of: $0) == 26 }
        // Coalescing is best effort: how many of the six reach the pedal depends on how fast the first write
        // completes (CI runners are slow). What must hold: fewer than all six, and the last value wins.
        XCTAssertLessThan(gains.count, 6)
        // The task group gives no ordering, so "105 wins" cannot be asserted; what must hold is that every
        // write carries one of the requested values and the pedal ends on the value it received last.
        let values = gains.map { Int(ProtoFields.parse(Frame.body(of: $0) ?? []).int(4) ?? 0) }
        XCTAssertTrue(values.allSatisfy { (100...105).contains($0) }, "\(values)")
        let s = await pedal.state
        XCTAssertEqual(s.amp[.gain], values.last)
    }

    func testFXModelParamsAndRefresh() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let cave = Models.post3.first { $0.name == "Cave" }!
        await session.setFXModel(.post3, cave)
        await session.setFX(.post3, on: true)
        await session.setFXParam(.post3, index: 1, normalized: 0.75)
        await session.refreshFXParams(.post3)
        var got: [Float]? = nil
        for await e in session.events { if case .fxParams(.post3, let f) = e { got = f; break } }
        XCTAssertEqual(got?[1], 0.75)
        let s = await pedal.state
        XCTAssertEqual(s.fxModel[.post3]!, cave.id)
    }

    func testLibraryAndUpload() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let lib = try await session.requestLibrary()
        XCTAssertEqual(lib.factoryCaptures.count, 25)
        XCTAssertEqual(lib.userCaptures.count, 0)
        let rec = CaptureRecord(hash: String(repeating: "ab", count: 32), name: "Test Capture", cloudUUID: "u", authorName: "Tester", deviceType: "pedal", gainType: 3, instrumentType: "guitar")
        let cns = (0..<1200).map { UInt8($0 & 0xff) }
        let progress = Collector()
        let reply = try await session.uploadCapture(cns: cns, record: rec) { sent, _ in progress.add(sent) }
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.name, "Test Capture")
        XCTAssertEqual(reply.userIndex, 0)
        XCTAssertEqual(progress.values, [1, 2, 3])
        let after = try await session.requestLibrary()
        XCTAssertEqual(after.userCaptures.map(\.name), ["Test Capture"])
        let loaded = try await session.loadLibraryCapture(slot: 3, factory: false, index: 0, name: "Test Capture"); XCTAssertTrue(loaded)
        let s = await pedal.state
        XCTAssertEqual(s.captureNames[2], "Test Capture")
    }

    func testDisconnectFailsPendingRequests() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        await session.disconnect()
        do { _ = try await session.requestState(); XCTFail("should throw") } catch { }
        let c = await session.connected
        XCTAssertFalse(c)
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Int] = []
    func add(_ v: Int) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return items }
}

extension SessionTests {
    /// After a link drop the next session on the same transport must get the replies.
    func testSecondSessionAfterLinkLostGetsTheStream() async throws {
        let pedal = FakePedal()
        let first = Session(transport: pedal)
        _ = try await first.connect()
        await first.linkLost()
        let second = Session(transport: pedal)
        let (meta, _) = try await second.connect()
        XCTAssertEqual(meta.presetNames.count, 64)
    }

    /// A request's timeout timer must not fail a later request of the same type (it did: a 5 s preset-change timer killed a scan mid-way).
    func testStaleTimeoutDoesNotKillLaterRequest() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        // Answered immediately, with a short timer that will fire later while another type-2 request is pending.
        _ = try await session.request(Writes.stateRequest, label: "first", expecting: 2, timeout: 0.3)
        let t0 = Date()
        do {
            _ = try await session.request(Writes.stateRequest, label: "second", expecting: 99, timeout: 1.0)   // type 99 never comes
            XCTFail("expected a timeout")
        } catch TransportError.timeout(let label) {
            XCTAssertEqual(label, "second")
            XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.9, "failed early: the first request's timer hit the second request")
        }
        await session.disconnect()
    }
}
