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

    // MARK: a bare Cortex Cloud product ID as the whole description (seen on a real pedal, 2026-10-24)

    /// Synthetic, in the shape of a real product ID.
    static let anId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"

    func testCloudIdIsTheWholeTrimmedDescription() {
        XCTAssertEqual(CaptureText.cloudId(Self.anId), Self.anId)
        XCTAssertEqual(CaptureText.cloudId(Self.anId.uppercased()), Self.anId, "any case, lowercased")
        XCTAssertEqual(CaptureText.cloudId("A1B2c3d4-E5F6-4a7b-8C9D-0e1f2a3B4C5D"), Self.anId)
        XCTAssertEqual(CaptureText.cloudId("  \(Self.anId)\n\t"), Self.anId, "trimmed")
        let not = [nil, "", "   ", "null", "Warm and round",
                   "See \(Self.anId)", "\(Self.anId) (cloud)", "\(Self.anId) \(Self.anId)",   // not the whole text
                   "{\(Self.anId)}", "urn:uuid:\(Self.anId)",
                   String(Self.anId.dropLast()), Self.anId + "0",                      // 35 and 37 characters
                   "a1b2c3d4e5f64a7b8c9d0e1f2a3b4c5d",                                     // no dashes
                   "a1b2c3d4-e5f64-a7b-8c9d-0e1f2a3b4c5d", "a1b2c3d4-e5f6-4a7b-8c9d0-e1f2a3b4c5d",   // wrong groups
                   "a1b2c3g4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",                                 // not hex
                   "a１b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",                                // a full-width digit
                   "a1b2c3d4 e5f6 4a7b 8c9d 0e1f2a3b4c5d"]
        for s in not { XCTAssertNil(CaptureText.cloudId(s), "\(s ?? "nil")") }
    }

    func testABareCloudIdIsNotShownButIsKept() {
        XCTAssertEqual(CaptureText.description(Self.anId), "", "shown and searched as no description")
        XCTAssertEqual(CaptureText.description(" \(Self.anId.uppercased()) "), "")
        XCTAssertEqual(CaptureText.description("See \(Self.anId)"), "See \(Self.anId)", "an ID inside text is text")
        XCTAssertEqual(CaptureText.stored(Self.anId), Self.anId, "the record keeps it as it came")
        XCTAssertEqual(CaptureText.stored(Self.anId.uppercased()), Self.anId.uppercased())
        XCTAssertEqual(CaptureText.stored("null"), "")
        XCTAssertEqual(CaptureText.cloudURL(Self.anId)?.absoluteString, "https://cloud.neuraldsp.com/cloud/neural-capture/view/\(Self.anId)")
        XCTAssertEqual(CaptureText.cloudURL(Self.anId.uppercased())?.absoluteString, "https://cloud.neuraldsp.com/cloud/neural-capture/view/\(Self.anId)")
        XCTAssertNil(CaptureText.cloudURL("../../profile"))
    }

    /// 18 whose description is the ID: no description, the ID for "Open in Cortex Cloud". 18.8 first, then the record's 5.
    func testCaptureDetailsWithACloudId() {
        let rec = ProtoWriter().string(1, "ab").string(2, "Darkglass").string(5, Self.anId).string(6, "pedal").build()
        let d = CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, Self.anId.uppercased()).string(10, "Darkglass").bytes(11, rec).build(), slot: 4)
        XCTAssertEqual(d.description, "")
        XCTAssertEqual(d.cloudId, Self.anId)
        XCTAssertEqual(d.record?.description, Self.anId, "the record as the pedal has it")
        let fromRecord = CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, "null").bytes(11, rec).build(), slot: 4)
        XCTAssertEqual(fromRecord.description, "")
        XCTAssertEqual(fromRecord.cloudId, Self.anId)
        let text = CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, "Tight and dry").bytes(11, rec).build(), slot: 4)
        XCTAssertEqual(text.description, "Tight and dry", "a real 18.8 wins")
        XCTAssertNil(text.cloudId)
        let none = CaptureDetails.parse(ProtoWriter().int(1, 6).int(3, 1).string(8, "Clean").build(), slot: 4)
        XCTAssertNil(none.cloudId)
    }

    func testDemoSlot3CarriesACloudId() {
        let s = DemoState.demo()
        let d = CaptureDetails.parse(StateEncoder.captureDetails(s, slot: DemoState.cloudIdSlot), slot: DemoState.cloudIdSlot)
        XCTAssertEqual(d.cloudId, DemoState.demoCloudId)
        XCTAssertEqual(d.description, "")
        XCTAssertNil(CaptureDetails.parse(StateEncoder.captureDetails(s, slot: 2), slot: 2).cloudId)
        XCTAssertNil(CaptureDetails.parse(StateEncoder.captureDetails(s, slot: 1), slot: 1).cloudId)
    }

    /// The library's details and search text never carry the bare ID.
    func testLibraryCaptureWithACloudId() {
        let body = ProtoWriter().message(3, ProtoWriter().string(1, "h").string(2, "Darkglass").string(5, Self.anId).string(6, "pedal"))
            .message(5, ProtoWriter().string(1, "h2").string(2, "Mine").string(5, "Bright").string(6, "pedal")).build()
        let lib = Library.parse(body)
        XCTAssertEqual(lib.factoryCaptures.first?.description, "")
        XCTAssertEqual(lib.userCaptures.first?.description, "Bright")
    }

    /// Writing a record keeps a bare ID exactly as before 1.2.1 (only "null" is dropped): nothing new goes to the pedal.
    func testRecordWritesACloudIdAsItCame() {
        let rec = CaptureRecord(hash: "h", name: "n", cloudUUID: "u", description: Self.anId.uppercased())
        XCTAssertEqual(ProtoFields.parse(rec.encode()).string(5), Self.anId.uppercased())
        XCTAssertEqual(CaptureRecord.decode(ProtoFields.parse(rec.encode())).description, Self.anId.uppercased())
    }

    /// A Cortex Cloud download whose .json description is a bare ID (synthetic, Python's tarfile/gzip: 73 made-up .cns
    /// bytes ending in "NANO-TEST", "Cloud Id" by "Tester", the demo ID in upper case). Not a real capture.
    static let cloudIdBundle = "H4sIAAAAAAAC/+3UMSzEUBgH8E5MbGzk0oTpTvpOz4kwyN0NQmq4biTSvL5oj2sv77WXcLEwsbGxMbGxsbHZ2NjYbGxseO05CYuhySX4/5K+135f+n3D61dKNJsmuIaoJ5QfaNKIrse79H3XCCGf93Gc5PPZrJLSlDYIRWBx2V75nzoHS/bGwcX9W//EfGPv7PalN2eKnZPrp+7MzNLW0eVDx0CRru+f3732jc+t7p7ePPfoZb59fPXYlZ6ubB4ak8ZsxiyVTQV+I5p0/ivC9xLO/3BO+zr/WflLyGH+26GhOpZw1DE16YegplXPqjJZqbDsh3ZqKorYTFDu1gLX92SidcCZeNGjZbT1GCkQrShfssLA8bnRLGYyETAel6q7lJkrtShqVWsLDrOiFq4nAh5WmRd85BZDV56ozNQZF83GRF3DpAMAAAAAAAAAAAAAAAAAAMBf9Q5ZlSN5ACgAAA=="

    func testCloudBundleWithACloudIdSendsItAsBefore() throws {
        let b = try CaptureBundle.parse(payloadBase64: Self.cloudIdBundle)
        XCTAssertEqual(b.record.name, "Cloud Id")
        XCTAssertEqual(Array(b.cns.suffix(9)), Array("NANO-TEST".utf8))
        XCTAssertEqual(b.record.description, "00000000-0000-4000-8000-00000000C10D", "sent to the pedal as the Cloud gave it")
        XCTAssertEqual(CaptureText.description(b.record.description), "")
        XCTAssertEqual(CaptureText.cloudId(b.record.description), DemoState.demoCloudId)
    }
}
