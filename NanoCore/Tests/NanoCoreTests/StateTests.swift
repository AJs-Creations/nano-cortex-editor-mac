import XCTest
@testable import NanoCore

/// Golden tests from the pedal recordings: the replies the real Nano sent.
final class StateTests: XCTestCase {
    /// The phone trace begins with a full sync: the metadata reply (presets, capture and IR slots) carries the
    /// current state too. The Electron recordings started after their sync, so this is the only sample of it.
    func testMetadataAndStateFromFirstSync() throws {
        let body = Fixtures.base64(Recorded.metadataDump)
        XCTAssertGreaterThan(body.count, 8000)
        let m = Metadata.parse(body)
        XCTAssertEqual(m.presetNames.count, 64)
        XCTAssertEqual(m.presetNames[0], "Clean 1 Simple")
        XCTAssertEqual(m.presetNames[13], "Crunch 2 FX")
        XCTAssertEqual(m.presetNames[25], "", "empty slots come back nameless; the UI shows them as Empty")
        XCTAssertEqual(m.captureNames[0], "CA John's Ch1 1")
        XCTAssertEqual(m.captureNames[11], "Brit 2555 Rhy 12")
        XCTAssertEqual(m.captureNames[24], "Anima Fuzz 8")
        XCTAssertEqual(m.irNames, ["110 US PRN C10R", "212 US TWN C12Q 00s", "412 Brit TV GB75Hz '69", "412 CA Stand OS A V30 '01", "810 Amped VT Aln 70s"])

        let d = StateDump.parse(body)
        XCTAssertEqual(d.presetIndex, 13, "Crunch 2 FX")
        XCTAssertEqual(d.firmware, "2.2.1")
        XCTAssertEqual(d.captureName, "Brit 2555 Rhy 12")
        XCTAssertEqual(d.captureSlot, 12, "bank 3, position 2")
        XCTAssertEqual(d.irShortName, "412 Brit TV GB75Hz '69")
        XCTAssertEqual(d.cabMicAndPosition?.mic, "Dynamic 57")
        XCTAssertEqual(d.fx.mapValues(\.on), ["pre1": false, "pre2": false, "post1": true, "post2": true, "post3": true])
        XCTAssertEqual(Models.byId(d.fx["pre1"]!.modelIdHex!, in: "pre1")?.name, "Transpose")
        XCTAssertEqual(Models.byId(d.fx["pre2"]!.modelIdHex!, in: "pre2")?.name, "Green 808")
        XCTAssertEqual(Models.byId(d.fx["post2"]!.modelIdHex!, in: "post2")?.name, "Analog Delay")
        XCTAssertEqual(Models.byId(d.fx["post3"]!.modelIdHex!, in: "post3")?.name, "Mind Hall")
        XCTAssertEqual(d.tunerReference, 440)
    }

    func testStateDumpOfPreset64AfterSave() throws {
        // In the first pedal session, the dump read back right after "save preset 64" must show the saved edits:
        // gain 150, capture volume −3 dB, Green 808 on in Pre FX 1.
        let d = StateDump.parse(Fixtures.base64(Recorded.dumpAfterSave))
        XCTAssertEqual(d.firmware, "2.2.1")
        XCTAssertEqual(d.presetIndex, 63)
        XCTAssertEqual(d.gain, 150)
        XCTAssertEqual(d.captureVolumeDb, -3.0, accuracy: 0.05)
        XCTAssertEqual(d.fx["pre1"], FXBlock(modelIdHex: "1B", on: true))
        XCTAssertEqual(Models.byId(d.fx["pre1"]!.modelIdHex!, in: "pre1")?.name, "Green 808")
        XCTAssertFalse(d.dirty, "the pedal reported the preset clean after the save")
    }

    func testGateReadBackAfterWrite() throws {
        // The last dump of the first pedal session came after "Gate reduction 70%" and "Gate ON" were written.
        let last = StateDump.parse(Fixtures.base64(Recorded.lastDump))
        XCTAssertEqual(last.presetIndex, 63)
        XCTAssertEqual(last.gateReductionPercent, 70)
        XCTAssertTrue(last.gateOn)
        XCTAssertEqual(last.captureName, "Anima Fuzz 8", "library capture loaded into slot 25 during that session")
    }

    func testLibraryReplies() throws {
        let lib1 = Library.parse(Fixtures.base64(Recorded.libraryFirst))
        XCTAssertEqual(lib1.factoryCaptures.count, 25)
        XCTAssertEqual(lib1.userCaptures.count, 0)
        XCTAssertEqual(lib1.factoryIRs.count, 10)
        XCTAssertEqual(lib1.factoryCaptures.first { $0.name == "Brit 2555 Rhy 12" }?.index, 11)
        XCTAssertEqual(lib1.factoryIRs.first { $0.name == "412 Brit TV GB75Hz '69" }?.index, 5)
        let lib2 = Library.parse(Fixtures.base64(Recorded.libraryLater))
        XCTAssertEqual(lib2.userCaptures.map(\.name).sorted(), ["68 Purple Plexi Dirty", "Dumbbell ODS 15", "Klon Centaur 1"])
        // Hashes are zeroed in the inlined reply; the field is still read as a 64-character string.
        XCTAssertEqual(lib2.userCaptures.first { $0.name == "Klon Centaur 1" }?.hash, String(repeating: "0", count: 64))
    }

    func testCaptureVolumeCurveRoundTrips() {
        for db in [-24.0, -12.0, -3.0, 0.0, 6.0, 12.0] { XCTAssertEqual(Capture.rawToDb(Capture.dbToRaw(db)), db, accuracy: 0.2) }
        XCTAssertEqual(Capture.dbToRaw(-3), 112)
        XCTAssertEqual(Capture.rawToDb(127), -0.1875, accuracy: 0.001)
    }
}
