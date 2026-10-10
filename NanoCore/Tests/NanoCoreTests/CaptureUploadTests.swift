import XCTest
import CryptoKit
@testable import NanoCore

/// Golden tests against the official app's capture transfer (phone trace) and the Electron app's transfer to the
/// real pedal. The capture data itself is not published: the frames' envelope, record and write layout are inlined
/// (RecordedFrames.swift) and synthetic .cns bytes of the same size stand in for the capture.
final class CaptureUploadTests: XCTestCase {
    /// The phone's uploads: field 1 = 6, the .cns of the recorded size, a capture record that re-encodes to itself.
    func testPhoneAppUploadsDecode() throws {
        XCTAssertEqual(Recorded.phoneUploads.count, 2)
        let first = try XCTUnwrap(Recorded.phoneUploads.first)
        XCTAssertEqual(first.cnsBytes, 19811)
        let prefix = ProtoFields.parse(Fixtures.bytes(first.prefix))
        XCTAssertEqual(prefix.int(1), 6)
        let rec = CaptureRecord.decode(ProtoFields.parse(Fixtures.bytes(first.record)))
        XCTAssertEqual(rec.name, "Dumbbell ODS 15")
        XCTAssertEqual(rec.authorName, "NeuralDSP")
        XCTAssertEqual(rec.deviceType, "amp_head")
        XCTAssertEqual(rec.gainType, 2)
        XCTAssertEqual(rec.hash.count, 64)
        for up in Recorded.phoneUploads {
            let record = Fixtures.bytes(up.record)
            XCTAssertEqual(CaptureRecord.decode(ProtoFields.parse(record)).encode(), record, "the record re-encodes byte for byte")
        }
    }

    /// Our upload of a capture of the same size and record reproduces the phone's envelope and write layout:
    /// the body up to the .cns, the MD5 of the .cns, the record, the same number of 500-byte writes with the same
    /// headers, and the padded last write.
    func testUploadMatchesThePhoneLayout() throws {
        for up in Recorded.phoneUploads {
            let cns = Fixtures.syntheticCapture(up.cnsBytes)
            let record = Fixtures.bytes(up.record)
            let rec = CaptureRecord.decode(ProtoFields.parse(record))
            let ours = Messages.uploadCapture(cns: cns, record: rec)
            XCTAssertEqual(ours.count, up.headers.count, rec.name)
            XCTAssertEqual(ours.map { Self.hex(Array($0.prefix(2))) }, up.headers, rec.name)
            XCTAssertTrue(ours.allSatisfy { $0.count == 500 })
            XCTAssertEqual(ours.last?.count, up.lastWriteSize)

            var r = Frame.Reassembler(), whole: (body: [UInt8], type: UInt32)?
            for w in ours { whole = r.feed(w) ?? whole }
            let done = try XCTUnwrap(whole)
            XCTAssertEqual(done.type, 13)
            let md5 = Array(Insecure.MD5.hash(data: Data(cns)).map { String(format: "%02x", $0) }.joined().utf8)
            let expected = Fixtures.bytes(up.prefix) + cns + [0x12, 0x20] + md5 + [0x22] + Varint.encode(UInt64(record.count)) + record
            XCTAssertEqual(done.body, expected, rec.name)
        }
    }

    func testElectronUploadToRealPedalAndReply() throws {
        // The Electron transfer of a 10 350-byte capture went out as 22 full 500-byte writes.
        XCTAssertEqual(Recorded.electronUpload.writes, 22)
        XCTAssertEqual(Recorded.electronUpload.writeSizes, [500])
        let rec = CaptureRecord.decode(ProtoFields.parse(Fixtures.bytes(Recorded.electronUploadRecord)))
        XCTAssertEqual(rec.name, "Klon Centaur 1")
        let ours = Messages.uploadCapture(cns: Fixtures.syntheticCapture(Recorded.electronUpload.cnsBytes), record: rec)
        XCTAssertTrue(ours.allSatisfy { $0.count == 500 })
        XCTAssertEqual(ours.count, 22, "ours adds the .cns MD5 (34 bytes), which still fits the 22 writes")

        let reply = Fixtures.bytes(Recorded.electronUploadReply)
        XCTAssertEqual(Frame.type(of: reply), 14)
        let parsed = Messages.parseUploadReply(body: Frame.body(of: reply)!)
        XCTAssertEqual(parsed, .init(ok: true, userIndex: 2, name: "Klon Centaur 1", hash: String(repeating: "0", count: 64)))
    }

    private static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
