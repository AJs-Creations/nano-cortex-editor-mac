import XCTest
@testable import NanoCore

/// Live reports (26, 31, 64, 94, 99), monitoring (67 → 68, 66 fields 15/16) and preset moves (143 → 144), byte for byte
/// against the frames in the Electron edition's INVESTIGATION §11–12 (contributed in its #14) and its UX test.
final class LiveReportsTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
    /// The body and type of a single-packet frame given as hex.
    private func report(_ s: String) -> LiveReport? {
        let f = hex(s)
        return LiveReport.parse(type: Frame.type(of: f)!, body: Frame.body(of: f)!)
    }
    private func frame(_ body: [UInt8], _ type: UInt32) -> LiveReport? { LiveReport.parse(type: type, body: body) }

    // MARK: 26

    func testKnobReports() {
        // {1:1 3:control 4:raw 6:1}: mid 37, capture volume 191, gate 158 (= 50 % reduction).
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x03, 0x20, 37, 0x30, 0x01], 26), .control(.amp(.mid), raw: 37))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x0A, 0x20, 0xBF, 0x01, 0x30, 0x01], 26), .control(.captureVolume, raw: 191))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x0B, 0x20, 0x9E, 0x01, 0x30, 0x01], 26), .control(.gateReduction, raw: 158))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x01, 0x20, 73, 0x30, 0x01], 26), .control(.amp(.level), raw: 73))
    }

    func testOmittedZerosInAKnobReport() {
        // Gain is control 0 and the value 0: protobuf leaves both out.
        XCTAssertEqual(frame([0x08, 0x01, 0x30, 0x01], 26), .control(.amp(.gain), raw: 0))
        XCTAssertEqual(frame([0x08, 0x01, 0x20, 0xC9, 0x01, 0x30, 0x01], 26), .control(.amp(.gain), raw: 201))
    }

    func testKnobReportsTheEditorCantApplyAskForARead() {
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x06, 0x20, 0xC4, 0x01, 0x30, 0x01], 26), .otherControl(id: 6, raw: 196), "the 99 companion")
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x03, 0x20, 37], 26), .stateChanged(keepModels: false), "no 6:1 marker")
        XCTAssertEqual(frame([0x18, 0x03, 0x20, 37, 0x30, 0x01], 26), .stateChanged(keepModels: false), "no 1:1 (not a report)")
        XCTAssertEqual(frame([0x08, 0x01, 0x1A, 0x00, 0x30, 0x01], 26), .stateChanged(keepModels: false), "control with the wrong wire type")
    }

    // MARK: 99

    func testFXParameterReports() {
        // Pre FX 2, parameter 1, raw 184 as a float32.
        var w = ProtoWriter().int(1, 1).int(3, 1).int(4, 1).float32(5, 184)
        XCTAssertEqual(frame(w.build(), 99), .fxParam(.pre2, index: 1, raw: 184))
        // Slot 0, index 0 and the value 0 all left out.
        XCTAssertEqual(frame([0x08, 0x01], 99), .fxParam(.pre1, index: 0, raw: 0))
        w = ProtoWriter().int(1, 1).int(3, 4).float32(5, 17)
        XCTAssertEqual(frame(w.build(), 99), .fxParam(.post3, index: 0, raw: 17))
        XCTAssertEqual(report("0A C0 08 01 18 01 2D 00 00 88 42 63 00 00 00"), .fxParam(.pre2, index: 0, raw: 68))
    }

    func testFXParameterReportsOutOfRangeAskForARead() {
        XCTAssertEqual(frame(ProtoWriter().int(1, 1).int(3, 5).float32(5, 10).build(), 99), .stateChanged(keepModels: false), "slot 5 doesn't exist")
        XCTAssertEqual(frame(ProtoWriter().int(1, 1).float32(5, 300).build(), 99), .stateChanged(keepModels: false), "raw above 255")
        XCTAssertEqual(frame(ProtoWriter().int(1, 1).int(5, 10).build(), 99), .stateChanged(keepModels: false), "value as a varint")
    }

    // MARK: 31

    func testBypassReports() {
        XCTAssertEqual(report("0A C0 08 01 18 05 20 01 1F 00 00 00"), .fxEnabled(.pre2, on: false))
        XCTAssertEqual(report("0A C0 08 01 18 05 20 00 1F 00 00 00"), .fxEnabled(.pre2, on: true))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x05], 31), .fxEnabled(.pre2, on: true), "on = 0, left out")
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x08, 0x20, 0x01], 31), .fxEnabled(.post3, on: false))
    }

    func testBareStateChangeKeepsTheModels() {
        XCTAssertEqual(report("04 C0 08 01 1F 00 00 00"), .stateChanged(keepModels: true))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x09, 0x20, 0x01], 31), .stateChanged(keepModels: true), "the gate's enable slot: read back like Electron")
    }

    // MARK: 64, 94, 66

    func testExpressionPosition() {
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x02, 0x20, 0xC8, 0x01], 64), .expression(position: 200))
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x02], 64), .expression(position: 0), "heel: the position is left out")
        XCTAssertEqual(frame([0x08, 0x01, 0x18, 0x02, 0x20, 0xFF, 0x01], 64), .expression(position: 255))
        XCTAssertNil(frame([0x28, 0x01], 64), "capture-mode notice")
        XCTAssertNil(frame([0x08, 0x01, 0x18, 0x01, 0x28, 0x01], 64))
    }

    func testCabChangeAndUnknownTypes() {
        XCTAssertEqual(frame([0x08, 0x01], 94), .stateChanged(keepModels: false))
        XCTAssertNil(frame([0x08, 0x01, 0x18, 0x01], 115), "the dirty report has its own event")
        XCTAssertNil(frame([0x08, 0x01], 2))
    }

    // MARK: monitoring

    func testMonitoringWritesMatchTheTrace() {
        XCTAssertEqual(Writes.monitoring(.input, on: true), hex("08 C0 08 01 60 01 43 00 00 00"))
        XCTAssertEqual(Writes.monitoring(.input, on: false), hex("08 C0 08 01 60 00 43 00 00 00"), "off is an explicit 0")
        XCTAssertEqual(Writes.monitoring(.outputs, on: true), hex("08 C0 08 01 68 01 43 00 00 00"))
        XCTAssertEqual(Writes.monitoring(.outputs, on: false), hex("08 C0 08 01 68 00 43 00 00 00"))
        XCTAssertEqual(Monitor.input.label, "Mute Input")
        XCTAssertEqual(Monitor.outputs.label, "Mute Outputs 1L/2R")
    }

    func testMonitoringReadBack() {
        // 66 with 15 (tag 0x78) and 16 (tag 0x80 0x01) on; left out = off.
        let on = DeviceSettings.parse([0x08, 0x01, 0x18, 0x01, 0x30, 0x99, 0x01, 0x78, 0x01, 0x80, 0x01, 0x01])
        XCTAssertTrue(on.muteInput); XCTAssertTrue(on.muteOutputs)
        XCTAssertTrue(on.muted(.input)); XCTAssertTrue(on.muted(.outputs))
        let off = DeviceSettings.parse([0x08, 0x01, 0x18, 0x01, 0x30, 0x99, 0x01])
        XCTAssertFalse(off.muteInput); XCTAssertFalse(off.muteOutputs)
        let only = DeviceSettings.parse(StateEncoder.settings({ var s = DemoState.demo(); s.muteOutputs = true; return s }()))
        XCTAssertFalse(only.muteInput); XCTAssertTrue(only.muteOutputs)
        XCTAssertEqual(LiveReport.parse(type: 66, body: [0x08, 0x01, 0x18, 0x01, 0x78, 0x01]), .settings(DeviceSettings.parse([0x08, 0x01, 0x18, 0x01, 0x78, 0x01])))
    }

    // MARK: preset move

    func testPresetMoveFrameMatchesTheTrace() {
        // "5 → 3" in the app's numbering: 0-based 4 → 2.
        XCTAssertEqual(PresetMove.frame(from: 4, to: 2), hex("0A C0 08 04 18 04 20 02 8F 00 00 00"))
        // 36 → 6, the other move observed.
        XCTAssertEqual(PresetMove.frame(from: 35, to: 5), hex("0A C0 08 04 18 23 20 05 8F 00 00 00"))
        // Index 0 is written, not left out.
        XCTAssertEqual(PresetMove.frame(from: 0, to: 63), hex("0A C0 08 04 18 00 20 3F 8F 00 00 00"))
    }

    func testPresetMoveReply() {
        let r = PresetMove.Reply.parse([0x08, 0x06, 0x18, 0x04, 0x20, 0x02, 0x28, 0x01])
        XCTAssertEqual(r, PresetMove.Reply(from: 4, to: 2, status: 1))
        XCTAssertTrue(r.confirms(from: 4, to: 2))
        XCTAssertFalse(r.confirms(from: 4, to: 3), "a different destination is not this move")
        XCTAssertFalse(PresetMove.Reply.parse([0x08, 0x06, 0x18, 0x04, 0x20, 0x02]).confirms(from: 4, to: 2), "no status = not moved")
        // A from of 0 left out still reads as 0.
        XCTAssertTrue(PresetMove.Reply.parse([0x08, 0x06, 0x20, 0x05, 0x28, 0x01]).confirms(from: 0, to: 5))
    }

    func testInsertionOrder() {
        let names = ["A", "B", "C", "D", "E", "F"]
        XCTAssertEqual(PresetMove.apply(names, from: 4, to: 1), ["A", "E", "B", "C", "D", "F"])
        XCTAssertEqual(PresetMove.apply(names, from: 1, to: 4), ["A", "C", "D", "E", "B", "F"])
        XCTAssertEqual(PresetMove.apply(names, from: 2, to: 2), names)
        XCTAssertEqual(PresetMove.apply(names, from: 9, to: 1), names, "out of range: unchanged")
        // Every index lands where `apply` puts its item.
        for (from, to) in [(4, 1), (1, 4), (0, 5), (5, 0)] {
            let moved = PresetMove.apply(names, from: from, to: to)
            for i in names.indices { XCTAssertEqual(moved[PresetMove.newIndex(of: i, from: from, to: to)], names[i], "\(from)→\(to) index \(i)") }
        }
    }

    // MARK: session

    func testSessionEmitsPedalSideReports() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        var events = session.events.makeAsyncIterator()
        await pedal.turnOnPedal(.amp(.bass), raw: 182)
        var got: [LiveReport] = []
        var dirty: Bool?
        while got.isEmpty || dirty == nil, let e = await events.next() {
            if case .live(let r) = e { got.append(r) }
            if case .dirty(let d) = e { dirty = d }
        }
        XCTAssertEqual(got, [.control(.amp(.bass), raw: 182)])
        XCTAssertEqual(dirty, true)
        // Turning it back to the saved value reports clean again.
        await pedal.turnOnPedal(.amp(.bass), raw: 127)
        dirty = nil
        while dirty == nil, let e = await events.next() { if case .dirty(let d) = e { dirty = d } }
        XCTAssertEqual(dirty, false)
    }

    func testFXParamReportComesWithItsCompanion() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        var events = session.events.makeAsyncIterator()
        await pedal.turnFXOnPedal(.pre1, index: 1, raw: 68)
        var got: [LiveReport] = []
        while got.count < 2, let e = await events.next() { if case .live(let r) = e { got.append(r) } }
        XCTAssertEqual(got, [.fxParam(.pre1, index: 1, raw: 68), .otherControl(id: 6, raw: 68)])
        let writes = await pedal.writes
        XCTAssertFalse(writes.dropFirst().contains(Writes.stateRequest), "the report itself sends nothing")
    }

    func testExpressionNoticeDuringAReadIsNotAPosition() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        _ = try await session.readExpression(index: 1)   // the fake answers 64 {1:1 3:2} before 61, like the pedal
        await pedal.expressionOnPedal(position: 200)
        var events = session.events.makeAsyncIterator()
        var got: LiveReport?
        while got == nil, let e = await events.next() { if case .live(let r) = e { got = r } }
        XCTAssertEqual(got, .expression(position: 200), "the read's 64 was dropped; the pedal's move came through")
    }

    func testMonitoringRoundTrip() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let ok = try await session.writeMonitoring(.input, on: true)
        XCTAssertTrue(ok)
        let s = try await session.readDeviceSettings()
        XCTAssertTrue(s.muteInput); XCTAssertFalse(s.muteOutputs)
        let writes = await pedal.writes
        XCTAssertTrue(writes.contains(Writes.monitoring(.input, on: true)))
        let state = await pedal.state
        XCTAssertTrue(state.muteInput)
        XCTAssertFalse(state.dirty, "a global setting doesn't dirty the preset")
    }

    func testRefusedMonitoringWrite() async throws {
        let pedal = FakePedal()
        var h = FakePedal.Hooks(); h.refuseSettings = true
        await pedal.setHooks(h)
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let ok = try await session.writeMonitoring(.outputs, on: true)
        XCTAssertFalse(ok, "68 with status 0")
        let s = try await session.readDeviceSettings()
        XCTAssertFalse(s.muteOutputs)
    }

    func testPresetMoveAgainstTheFakePedal() async throws {
        let pedal = FakePedal()   // current preset index 1; footswitches IA 0, IB 2, IIA 6, IIB 14
        let session = Session(transport: pedal)
        let (before, _) = try await session.connect()
        let reply = try await session.movePreset(from: 1, to: 6)
        XCTAssertTrue(reply.confirms(from: 1, to: 6))
        let (after, state) = try await session.readAll()
        XCTAssertEqual(after.presetNames, PresetMove.apply(before.presetNames, from: 1, to: 6))
        XCTAssertEqual(state.presetIndex, 6, "the current preset moved with it")
        XCTAssertEqual(state.footswitch, Footswitches(ia: 0, ib: 1, iia: 5, iib: 14), "the slots follow their presets")
        let refused = try await session.movePreset(from: 3, to: 3)
        XCTAssertFalse(refused.confirms(from: 3, to: 3))
    }

    func testSettingsReplyIsNotALiveReport() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        _ = try await session.readDeviceSettings()
        await pedal.notify(type: 66, body: StateEncoder.settings({ var s = DemoState.demo(); s.muteInput = true; return s }()))
        var events = session.events.makeAsyncIterator()
        var got: LiveReport?
        while got == nil, let e = await events.next() { if case .live(let r) = e { got = r } }
        guard case .settings(let s) = got else { return XCTFail("expected the unasked 66, got \(String(describing: got))") }
        XCTAssertTrue(s.muteInput)
    }

    func testBusyWhileAReplyIsAwaited() async throws {
        let pedal = FakePedal()
        await pedal.setReplyDelay(200)
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let idle = await session.isBusy
        XCTAssertFalse(idle)
        async let st = session.requestState()
        try await Task.sleep(for: .milliseconds(50))
        let busy = await session.isBusy
        XCTAssertTrue(busy)
        _ = try await st
        let after = await session.isBusy
        XCTAssertFalse(after)
    }
}
