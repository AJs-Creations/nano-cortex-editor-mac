import XCTest
@testable import NanoCore

/// Every write builder reproduces the bytes the Electron app sent to the real pedal (first session).
final class WritesTests: XCTestCase {
    /// The recorded write logged under this label (RecordedFrames.swift).
    private func recorded(_ label: String) throws -> [UInt8] {
        Fixtures.bytes(try XCTUnwrap(Recorded.electronWrites[label], "no recorded write \(label)"))
    }

    func testRequestsAndKnobs() throws {
        XCTAssertEqual(try recorded("Current preset state request"), Writes.stateRequest)
        XCTAssertEqual(try recorded("Amp gain = 150"), Writes.amp(.gain, 150))
        XCTAssertEqual(try recorded("Capture volume -3.0 dB"), Writes.captureVolume(db: -3))
        XCTAssertEqual(try recorded("Gate reduction 70%"), Writes.gateReduction(percent: 70))
        XCTAssertEqual(try recorded("Gate ON"), Writes.gateEnabled(true))
    }

    func testFXWrites() throws {
        let green = try XCTUnwrap(Models.pre1.first { $0.name == "Green 808" })
        XCTAssertEqual(try recorded("Pre FX 1 model select Green 808"), Writes.fxModel(.pre1, id: green.id!))
        XCTAssertEqual(try recorded("Pre FX 1 ON"), Writes.fxEnabled(.pre1, true))
        XCTAssertEqual(try recorded("Pre FX 1 param Overdrive=10.0"), Writes.fxParam(.pre1, index: 0, normalized: 1))
        XCTAssertEqual(try recorded("Pre FX 1 param refresh"), Writes.fxParamRefresh(.pre1))
        XCTAssertEqual(FXParams.normalized(10, meta: green.params[0].meta), 1)
    }

    func testCaptureCabAndSave() throws {
        XCTAssertEqual(try recorded("08C0 capture change 25"), Writes.captureSelect(slot: 25))
        XCTAssertEqual(try recorded("Cab/IR slot select 3"), Writes.cabSelect(slot: 3))
        XCTAssertEqual(try recorded("Cab/IR param refresh slot 3"), Writes.cabRefresh(slot: 3))
        XCTAssertEqual(try recorded("Cab/IR level -4.0 dB"), Writes.cabLevel(db: -4))
        // Sent by hand after the recording stopped (Activity log), and accepted by the pedal: index 5, Ribbon 160, position 2.
        XCTAssertEqual(Fixtures.bytes("2E C0 1A 28 08 05 12 16 34 31 32 20 42 72 69 74 20 54 56 20 47 42 37 35 48 7A 20 27 36 39 18 01 22 0A 52 69 62 62 6F 6E 20 31 36 30 5E 00 00 00"),
                       Writes.cabMicPosition(libraryIndex: 5, cabName: "412 Brit TV GB75Hz '69", mic: "Ribbon 160", position: 2))
        XCTAssertEqual(try recorded("save preset 64"), Writes.save(index: 63, name: "Empty"))
        XCTAssertEqual(try recorded("Library content request"), Writes.libraryRequest)
        XCTAssertEqual(try recorded("Load library capture \"Anima Fuzz 8\" into slot 25"), Writes.loadLibraryCapture(slot: 25, factory: true, index: 24, name: "Anima Fuzz 8"))
        XCTAssertEqual(try recorded("Load library cab \"810 Amped VT Aln 70s\" into cab slot 5"), Writes.loadLibraryCab(slot: 5, factory: true, index: 9, name: "810 Amped VT Aln 70s"))
    }

    func testCabRefreshReplyFromPedal() throws {
        // The last cab reply of that session: after "Cab/IR level -4.0 dB", still Dynamic 57 at position 4.
        XCTAssertEqual(Frame.type(of: Fixtures.bytes(Recorded.cabReply)), 96)
        let c = CabSettings.parse(body: Fixtures.body(Recorded.cabReply))
        XCTAssertEqual(c.libraryIndex, 5)
        XCTAssertEqual(c.name, "412 Brit TV GB75Hz '69")
        XCTAssertEqual(c.mic, "Dynamic 57")
        XCTAssertEqual(c.position, 4)
        XCTAssertEqual(c.levelDb, -4, accuracy: 0.05)
        XCTAssertEqual(c.highPassHz, 20, accuracy: 1)
        XCTAssertEqual(c.lowPassHz, 20000, accuracy: 1)
    }

    func testFXRefreshReplyFromPedal() throws {
        // The reply to the first "Pre FX 1 param refresh": Green 808 with Overdrive at max → 1.0, 0.5, 0.5.
        XCTAssertEqual(Frame.type(of: Fixtures.bytes(Recorded.fxRefreshReply)), 138)
        XCTAssertEqual(FXParams.parse(body: Fixtures.body(Recorded.fxRefreshReply)), [1.0, 0.5, 0.5])
    }

    /// The phone app's delete, byte for byte (recorded phone-app session, not published): presets 63 and 64.
    func testDeletePresetMatchesPhoneTrace() throws {
        let writes = Recorded.deleteWrites.map(Fixtures.bytes)
        XCTAssertTrue(writes.contains(Writes.deletePreset(index: 62)), "delete of preset 63 not found among the app's writes")
        XCTAssertTrue(writes.contains(Writes.deletePreset(index: 63)))
        XCTAssertEqual(Writes.deletePreset(index: 62), [0x08, 0xC0, 0x08, 0x02, 0x18, 0x3E, 0x32, 0x00, 0x00, 0x00])
        // The ack the pedal sent back
        let acks = Recorded.deleteAcks.map(Fixtures.bytes).filter { Frame.type(of: $0) == 51 }
        XCTAssertEqual(acks.count, 2)
        XCTAssertEqual(ProtoFields.parse(Frame.body(of: acks[0]) ?? []).int(4), 1)
    }
}
