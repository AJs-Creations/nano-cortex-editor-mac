import XCTest
@testable import NanoCore

/// A capture without a description comes back from the pedal as the literal text "null" (a real pedal, 2026-10-23).
/// Empty, blank and "null" mean "no description" wherever a description is read, and "null" is never written.
final class CaptureTextTests: XCTestCase {
    func testNullBlankAndEmptyMeanNoDescription() {
        for s in ["null", "NULL", " Null ", "", "   ", "\n\t"] { XCTAssertEqual(CaptureText.description(s), "", "\"\(s)\"") }
        XCTAssertEqual(CaptureText.description(nil), "")
        XCTAssertEqual(CaptureText.description("Warm and round"), "Warm and round")
        XCTAssertEqual(CaptureText.description("null and void"), "null and void")
    }

    /// 18 with "null" in 18.8 and in the record's 5 (the Info popover's source): no description.
    func testCaptureDetailsSayingNull() {
        let rec = ProtoWriter().string(1, "ab").string(2, "Deluxe").string(5, "null").string(6, "amp_combo").string(10, "guitar").build()
        let body = ProtoWriter().int(1, 6).int(3, 1).string(8, "null").string(9, "ab").string(10, "Deluxe").bytes(11, rec).build()
        let d = CaptureDetails.parse(body, slot: 2)
        XCTAssertEqual(d.description, "")
        XCTAssertEqual(d.record?.description, "")
        XCTAssertEqual(d.deviceType, "amp_combo")
        // A real record description still fills in for a "null" 18.8, and a real 18.8 wins.
        let rec2 = ProtoWriter().string(1, "ab").string(2, "Deluxe").string(5, "Edge of breakup").build()
        XCTAssertEqual(CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, "NULL").bytes(11, rec2).build(), slot: 2).description, "Edge of breakup")
        XCTAssertEqual(CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, "Clean").bytes(11, rec2).build(), slot: 2).description, "Clean")
    }

    /// The demo pedal's slot 2 answers "null" like the real one (the Electron demo's slot 2 too).
    func testDemoSlot2SaysNull() {
        let s = DemoState.demo()
        let raw = ProtoFields.parse(StateEncoder.captureDetails(s, slot: 2))
        XCTAssertEqual(raw.string(8), "null")
        XCTAssertEqual(CaptureDetails.parse(StateEncoder.captureDetails(s, slot: 2), slot: 2).description, "")
    }

    func testLibraryCaptureSayingNull() {
        let body = ProtoWriter().message(3, ProtoWriter().string(1, "h").string(2, "Deluxe").string(5, "null").string(6, "amp_combo").string(10, "guitar"))
            .message(5, ProtoWriter().string(1, "h2").string(2, "Mine").string(5, "Bright").string(6, "pedal")).build()
        let lib = Library.parse(body)
        XCTAssertEqual(lib.factoryCaptures.first?.description, "")
        XCTAssertEqual(lib.factoryCaptures.first?.type, "amp_combo")
        XCTAssertEqual(lib.userCaptures.first?.description, "Bright")
    }

    /// Sending a capture (type 13's record, also the audition's) never writes "null": field 5 goes out empty.
    func testRecordNeverWritesNull() throws {
        let withNull = CaptureRecord(hash: "h", name: "n", cloudUUID: "u", description: "null")
        XCTAssertEqual(withNull.encode(), CaptureRecord(hash: "h", name: "n", cloudUUID: "u", description: "").encode())
        XCTAssertFalse(String(decoding: withNull.encode(), as: UTF8.self).contains("null"))
        XCTAssertEqual(ProtoFields.parse(withNull.encode()).string(5), "")
        XCTAssertEqual(CaptureRecord(hash: "h", name: "n", cloudUUID: "u", description: "Warm").encode(), ProtoWriter().string(1, "h").string(2, "n").string(3, "u")
            .message(4, ProtoWriter().string(1, "").string(2, "")).string(5, "Warm").string(6, "default").string(10, "instrument_not_set").string(12, "1").build())
        XCTAssertEqual(CaptureRecord.decode(ProtoFields.parse(ProtoWriter().string(5, "NULL").build())).description, "")

        var r = Frame.Reassembler(), whole: (body: [UInt8], type: UInt32)?
        for w in Messages.uploadCapture(cns: Array(repeating: 7, count: 600), record: withNull) { whole = r.feed(w) ?? whole }
        let done = try XCTUnwrap(whole)
        XCTAssertEqual(done.type, 13)
        XCTAssertEqual(ProtoFields.parse(done.body).message(4)?.string(5), "")
    }

    /// A Cortex Cloud download whose .json says "description": "null" (synthetic, built with Python's tarfile/gzip:
    /// 73 made-up .cns bytes ending in "NANO-TEST", "No Description" by "Tester", an amp_combo). Not a real capture.
    static let nullDescriptionBundle = "H4sIAAAAAAAC/+3UMUjDQBQG4IDgIDgIDoKD5QZBMHJp0woKgtIOBalCUwRF5UxDG2mTkrsUVDoIDoKD4CA4CA6Cg+AgOAgObm5ubm5ubm5ueqcRSxeHQkX8v+XIe/feW+6F0nbE2Zjtce0H6mbKNLWoqPWkhmFoTU01apgpmtRiVOuAkAsWyPHa/9TV0zcwNKybkzPZ+YUVp8I3t3f3D49Pzy+vb+/uHx6fnl9e37p7+wfJCB2fyszmF1nZrzd29g6OTs4urm5y07k53crkLQ3+Itru/q9z32tz/5M00bL/SXVg/ztgi5QZL5OJGGn3JZDRGPFY1VG9cn4s7XA7cGvC9T2VsSt+WCwUsmmVNiJ6XNITkm5KerKJKmKhKPtBtqhqxHcgF02xHC6cQMWLTcNkwgsrlc9w3bUda6P2cZ1Va6u2X13zVUqwEpfBJSJkE7IsIyXmetHVuPx0PS6CsOp44qu+FLryqajiuhPwaJRBGviJAAAAAAAAAAAAAAAAAAAAwK96B3obK7YAKAAA"

    func testCloudBundleSayingNull() throws {
        let b = try CaptureBundle.parse(payloadBase64: Self.nullDescriptionBundle)
        XCTAssertEqual(b.record.name, "No Description")
        XCTAssertEqual(b.record.deviceType, "amp_combo")
        XCTAssertEqual(Array(b.cns.suffix(9)), Array("NANO-TEST".utf8))
        XCTAssertEqual(b.record.description, "")
    }
}
