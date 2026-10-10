import XCTest
@testable import NanoCore

/// Footswitch assignment and the preset change's field 9, against the phone app's trace
/// (recorded phone-app session, not published; frames inlined in RecordedFrames.swift; PROTOCOL-NOTES §10).
final class FootswitchTests: XCTestCase {
    func testAssignmentBodiesMatchPhoneTrace() throws {
        let assigns = Recorded.footswitchAssignments
        XCTAssertEqual(assigns.map { Fixtures.bytes($0.write) }, [
            Writes.assignFootswitch(slot: .ib, presetIndex: 0),
            Writes.assignFootswitch(slot: .ib, presetIndex: 1),
            Writes.assignFootswitch(slot: .ia, presetIndex: 14),
        ])
        // Preset 15 (index 14) → IA, spelled out: −1 is the 10-byte sign-extended varint.
        let m1: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]
        let body: [UInt8] = [0x18, 0x00, 0x20] + m1 + [0x28, 0x0E, 0x30] + m1 + [0x38] + m1 + [0x40] + m1 + [0x48, 0x00]
        XCTAssertEqual(Writes.assignFootswitch(slot: .ia, presetIndex: 14), Frame.single(body: body, type: 29))

        // Each assignment is acked with type 30 {1: 1, 4: 1}; the next state dump shows the new slot.
        let expected: [(FootswitchSlot, Int)] = [(.ib, 0), (.ib, 1), (.ia, 14)]
        for (a, (slot, preset)) in zip(assigns, expected) {
            XCTAssertEqual(ProtoFields.parse(Fixtures.bytes(a.ack)).int(4), 1)
            XCTAssertEqual(StateDump.parse(Fixtures.base64(a.dump)).footswitch[slot], preset, "\(slot.label) after assigning preset \(preset + 1)")
        }
        // Preset 1 → IB: field 15 is elided (protobuf default) and reads as 0.
        XCTAssertNil(ProtoFields.parse(Fixtures.base64(assigns[0].dump)).first(15))
    }

    /// Field 9 of a preset change names the footswitch slot holding the preset (4 = none), as the official app sends it.
    func testPresetChangeCarriesTheFootswitchSlot() throws {
        // The pedal reported IA 14, IB 4, IIA 8, IIB 16 (1-based) in its footswitch notifications before these changes.
        let slots = Footswitches(ia: 13, ib: 3, iia: 7, iib: 15)
        let changes = Recorded.presetChanges.map(Fixtures.bytes)
        XCTAssertTrue(changes.contains(Messages.presetChange(index: 7, footswitch: slots)), "preset 8 (IIA) with 9:2")
        XCTAssertTrue(changes.contains(Messages.presetChange(index: 15, footswitch: slots)), "preset 16 (IIB) with 9:3")
        XCTAssertTrue(changes.contains(Messages.presetChange(index: 62, footswitch: slots)), "preset 63 (none) with 9:4")
        XCTAssertEqual(Messages.presetChange(index: 7, footswitch: slots).suffix(6), [0x48, 0x02, 0x1D, 0x00, 0x00, 0x00])
        XCTAssertEqual(Messages.presetChange(index: 3, footswitch: nil), Messages.presetChange(index: 3))
    }

    /// A footswitch press on the pedal: type 29 {1: 1, 4: index, 5..8: slots}.
    func testDeviceSideChangeCarriesTheSlots() throws {
        let f = ProtoFields.parse(Fixtures.bytes(Recorded.footswitchPress))
        XCTAssertEqual(f.int(1), 1)
        XCTAssertEqual(Footswitches.fromPresetSlots(f), Footswitches(ia: 13, ib: 3, iia: 7, iib: 15))
    }

    func testStateDumpFieldsAndDefaults() {
        let body = ProtoWriter().int(13, 2).int(14, 5).int(38, 9).int(39, 63).build()
        XCTAssertEqual(StateDump.parse(body).footswitch, Footswitches(ia: 5, ib: 0, iia: 9, iib: 63))
        XCTAssertEqual(FootswitchSlot.allCases.map(\.label), ["IA", "IB", "IIA", "IIB"])
        XCTAssertEqual(FootswitchSlot(label: "iib"), .iib)
    }

    /// Like the real pedal (trace, 649 s), the fake drops unsaved edits on an assignment and reports clean.
    func testAssignmentDropsUnsavedEdits() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        let (_, start) = try await session.connect()
        await session.setAmp(.gain, 222)
        let edited = try await session.requestState()
        XCTAssertEqual(edited.gain, 222); XCTAssertTrue(edited.dirty)
        let st = try await session.assignFootswitch(slot: .ia, presetIndex: 3)
        XCTAssertEqual(st.footswitch.ia, 3)
        XCTAssertEqual(st.gain, start.gain)
        XCTAssertFalse(st.dirty)
    }

    /// Against the fake pedal: assigning updates the slot, a preset change leaves the slots alone and sends the right field 9.
    func testSessionAssignsAndPresetChangeUsesSlots() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        let (_, start) = try await session.connect()
        XCTAssertEqual(start.footswitch, Footswitches(ia: 0, ib: 2, iia: 6, iib: 14))
        let st = try await session.assignFootswitch(slot: .iib, presetIndex: 5)
        XCTAssertEqual(st.footswitch, Footswitches(ia: 0, ib: 2, iia: 6, iib: 5))
        let assignWrite = await pedal.writes.last { Frame.type(of: $0) == 29 }
        XCTAssertEqual(assignWrite, Writes.assignFootswitch(slot: .iib, presetIndex: 5))

        let after = try await session.selectPreset(index: 5)
        XCTAssertEqual(after.presetIndex, 5)
        XCTAssertEqual(after.footswitch, st.footswitch)
        var change = await pedal.writes.last { Frame.type(of: $0) == 29 }
        XCTAssertEqual(change, Messages.presetChange(index: 5, footswitchSlot: 3))
        _ = try await session.selectPreset(index: 9)
        change = await pedal.writes.last { Frame.type(of: $0) == 29 }
        XCTAssertEqual(change, Messages.presetChange(index: 9, footswitchSlot: 4))
    }
}
