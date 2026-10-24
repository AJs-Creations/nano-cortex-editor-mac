import XCTest
import CryptoKit
@testable import NanoCore

/// Auditions (158 → 159, 150 → 151, 148 → 149, keep-alive 91 → 92) and the one-stream-at-a-time rule, byte for byte
/// against the frames in PROTOCOL-NOTES §15 (the Electron edition's INVESTIGATION §12 and its UX checks).
final class AuditionTests: XCTestCase {
    static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    /// `[len] C0 body type` like the Electron test's `frameHex`.
    static func frame(_ body: [UInt8], _ type: UInt32) -> [UInt8] { [UInt8(body.count + 4), 0xC0] + body + LE.bytes(type) }

    // MARK: 158

    func testFactoryCabPreviewIsTheTracedFrame() {
        // PROTOCOL-NOTES §15: factory cab 0 "412 V30".
        XCTAssertEqual(Self.hex(Audition.irPreview(IRRef(factory: true, index: 0, name: "412 V30"))),
                       "13 C0 1A 0B 08 00 12 07 34 31 32 20 56 33 30 40 01 9E 00 00 00")
    }

    func testUserIRPreviewPutsTheRecordInField4() {
        let name = Array("OwnHammer 412 Mix".utf8)
        let expected = Self.frame([0x22, UInt8(4 + name.count), 0x08, 0x00, 0x12, UInt8(name.count)] + name + [0x40, 0x01], 158)
        XCTAssertEqual(Audition.irPreview(IRRef(factory: false, index: 0, name: "OwnHammer 412 Mix")), expected)
        let third = Audition.irPreview(IRRef(factory: false, index: 3, name: "My IR"))
        XCTAssertEqual(Self.hex(third), "11 C0 22 09 08 03 12 05 4D 79 20 49 52 40 01 9E 00 00 00", "the exact index type 77 listed")
    }

    // MARK: 148 / 149

    func testStopFramesCarryTheTransaction() {
        let tx: UInt64 = 1_760_000_000_123   // a millisecond clock, past 2³²
        let v = Varint.encode(tx)
        XCTAssertEqual(Audition.stop(.capture, transaction: tx), Self.frame([0x10] + v + [0x18, 0x00], 148), "capture: field 3 = 0")
        XCTAssertEqual(Audition.stop(.ir, transaction: tx), Self.frame([0x10] + v + [0x20, 0x00], 148), "IR: field 4 = 0")
        XCTAssertTrue(Self.hex(Audition.stop(.ir, transaction: tx)).hasSuffix("20 00 94 00 00 00"))
    }

    func testOnlyAMatchingConfirmedStopCounts() {
        let tx: UInt64 = 1_760_000_000_123
        func reply(_ w: ProtoWriter) -> Audition.Reply { Audition.parseReply(body: w.build()) }
        XCTAssertTrue(Audition.stopConfirmed(reply(ProtoWriter().int(1, 1).int(2, tx).int(3, 1)), transaction: tx))
        XCTAssertFalse(Audition.stopConfirmed(reply(ProtoWriter().int(1, 1).int(2, tx + 1).int(3, 1)), transaction: tx), "another stop's transaction")
        XCTAssertFalse(Audition.stopConfirmed(reply(ProtoWriter().int(1, 1).int(2, tx).int(3, 0)), transaction: tx), "status 0")
        XCTAssertFalse(Audition.stopConfirmed(reply(ProtoWriter().int(1, 1).int(3, 1)), transaction: tx), "no transaction echoed")
        XCTAssertNotEqual(Audition.nextTransaction(now: Date(timeIntervalSince1970: 5)), Audition.nextTransaction(now: Date(timeIntervalSince1970: 5)), "two stops never share one")
    }

    // MARK: 150

    func testCapturePreviewBody() throws {
        let rec = CaptureRecord(hash: String(repeating: "cd", count: 32), name: "Test Preview", cloudUUID: "00000000-0000-4000-8000-000000000002",
                                authorId: "x", authorName: "Tester", deviceType: "pedal", tags: ["#test"], gainType: 3, instrumentType: "guitar")
        let cns: [UInt8] = [1, 2, 3, 4]
        let parts = Audition.capturePreview(cns: cns, record: rec)
        XCTAssertEqual(parts.count, 1, "a small preview fits one write")
        XCTAssertTrue(Self.hex(parts[0]).hasSuffix("96 00 00 00"), "type 150")
        let md5 = Array(Insecure.MD5.hash(data: Data(cns)).map { String(format: "%02x", $0) }.joined().utf8)
        let content: [UInt8] = [0x0A, 4] + cns + [0x12, 0x20] + md5
        let record = rec.encode()
        let object: [UInt8] = [0x0A, UInt8(content.count)] + content + [0x12] + Varint.encode(UInt64(record.count)) + record
        let body: [UInt8] = [0x2A] + Varint.encode(UInt64(object.count)) + object + [0x38, 0x02, 0x40, 0x01]
        XCTAssertEqual(Frame.body(of: parts[0]), body)
    }

    func testBigMessagesStreamIn500ByteWrites() throws {
        // 1100 bytes of body + type: 3 writes (498, 498, 108 bytes of data), flags 0x41, 0x01, 0x80, the last padded.
        let parts = Frame.chunks(body: [UInt8](repeating: 7, count: 1100), type: TransferType.capturePreview)
        XCTAssertEqual(parts.map { [$0.count, Int($0[0]), Int($0[1])] }, [[500, 242, 0x41], [500, 242, 0x01], [500, 108, 0x80]])
        // A real preview reassembles to its body and type.
        let rec = CaptureRecord(hash: "h", name: "Big", cloudUUID: "u")
        let cns = Fixtures.syntheticCapture(3000)
        let preview = Audition.capturePreview(cns: cns, record: rec)
        XCTAssertGreaterThan(preview.count, 1)
        XCTAssertTrue(preview.allSatisfy { $0.count == 500 })
        var r = Frame.Reassembler(), whole: (body: [UInt8], type: UInt32)?
        for p in preview { whole = r.feed(p) ?? whole }
        XCTAssertEqual(whole?.type, 150)
        let object = ProtoFields.parse(try XCTUnwrap(whole?.body)).message(5)
        XCTAssertEqual(object?.message(1)?.first(1)?.bytes, cns)
        XCTAssertEqual(object?.message(1)?.string(2), Transfer.md5Hex(cns))
    }

    func testMD5MatchesTheReferenceAndCryptoKit() {
        XCTAssertEqual(Transfer.md5Hex([]), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(Transfer.md5Hex(Array("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
        let data = Fixtures.syntheticCapture(10_350)
        XCTAssertEqual(Transfer.md5Hex(data), Insecure.MD5.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined())
    }

    // MARK: against the fake pedal

    func testAuditionsAgainstTheFakePedal() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let lib = try await session.requestLibrary()
        XCTAssertEqual(lib.factoryIRs.first?.name, "412 V30")
        XCTAssertEqual(lib.userIRs.map(\.name), ["OwnHammer 412 Mix"])

        let play = try await session.previewIR(IRRef(factory: true, index: 0, name: "412 V30"))
        XCTAssertTrue(play.ok)
        XCTAssertEqual(play.name, "412 V30")
        let wrong = try await session.previewIR(IRRef(factory: false, index: 0, name: "412 V30"))
        XCTAssertFalse(wrong.ok, "not that user IR: the pedal refuses")
        let alive = try await session.previewKeepAlive()
        XCTAssertTrue(alive)

        let tx = Audition.nextTransaction()
        let stop = try await session.stopAudition(.ir, transaction: tx)
        XCTAssertTrue(Audition.stopConfirmed(stop, transaction: tx))
        var s = await pedal.state
        XCTAssertNil(s.auditioning)

        let rec = CaptureRecord(hash: String(repeating: "ab", count: 32), name: "Preview Me", cloudUUID: "u")
        let preview = try await session.previewCapture(cns: Fixtures.syntheticCapture(2000), record: rec)
        XCTAssertTrue(preview.ok)
        XCTAssertEqual(preview.name, "Preview Me")
        s = await pedal.state
        XCTAssertEqual(s.auditioning, "capture: Preview Me")
        XCTAssertEqual(s.libraryUser.count, 0, "a preview stores nothing")

        await pedal.mutate { $0.refuseAuditionStop = true }
        let tx2 = Audition.nextTransaction()
        let refused = try await session.stopAudition(.capture, transaction: tx2)
        XCTAssertFalse(Audition.stopConfirmed(refused, transaction: tx2))
        s = await pedal.state
        XCTAssertEqual(s.auditioning, "capture: Preview Me", "still playing")
        await session.disconnect()
    }

    /// A real pedal's state named the Live Preview's capture after the confirmed stop until the app read the state again
    /// (2026-10-24), so the app reads it right after the stop (PedalStore+Audition.swift). The fake behaves the same:
    /// the state names the preview while it plays, and the read after the stop names the preset's own capture.
    func testTheStateReadAfterAPreviewStopNamesThePresetsCapture() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let own = try await session.requestState()
        XCTAssertEqual(own.captureName, "5150 Lead")
        let rec = CaptureRecord(hash: String(repeating: "cd", count: 32), name: "Preview Capture", cloudUUID: "u")
        let preview = try await session.previewCapture(cns: Fixtures.syntheticCapture(2000), record: rec)
        XCTAssertTrue(preview.ok)
        let during = try await session.requestState()
        XCTAssertEqual(during.captureName, "Preview Capture", "the pedal reports the preview while it plays")
        XCTAssertEqual(during.captureSlot, own.captureSlot)

        // A refused stop changes nothing: still the preview.
        await pedal.mutate { $0.refuseAuditionStop = true }
        let tx0 = Audition.nextTransaction()
        let refused = try await session.stopAudition(.capture, transaction: tx0)
        XCTAssertFalse(Audition.stopConfirmed(refused, transaction: tx0))
        let stillPreview = try await session.requestState()
        XCTAssertEqual(stillPreview.captureName, "Preview Capture")

        await pedal.mutate { $0.refuseAuditionStop = false }
        let tx = Audition.nextTransaction()
        let stop = try await session.stopAudition(.capture, transaction: tx)
        XCTAssertTrue(Audition.stopConfirmed(stop, transaction: tx))
        let after = try await session.requestState()
        XCTAssertEqual(after.captureName, "5150 Lead", "the read after the stop names the preset's own capture")
        XCTAssertEqual(after.captureSlot, own.captureSlot)
        await session.disconnect()
    }

    // MARK: one stream at a time

    func testASecondStreamIsRefusedWhileOneRuns() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let rec = CaptureRecord(hash: "cd", name: "Test Preview", cloudUUID: "u")
        let preview = Task { try await session.previewCapture(cns: Fixtures.syntheticCapture(20_000), record: rec) }
        var busy: String?
        for _ in 0..<200 { busy = await session.streamBusy; if busy != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(busy, "capture preview")
        do {
            _ = try await session.uploadIR(wav: Self.wav(), productId: "00000000-0000-4000-8000-000000000003", filename: "Mutex IR.wav", name: "Mutex IR")
            XCTFail("a Cloud IR must wait for the preview")
        } catch let e as StreamError {
            XCTAssertEqual(e, .busy("capture preview"))
            XCTAssertEqual(e.description, "Another transfer to the pedal is still running (capture preview). Try again when it has finished.")
        }
        let result = try await preview.value
        XCTAssertTrue(result.ok, "the preview completes")
        let after = await session.streamBusy
        XCTAssertNil(after)
        let writes = await pedal.writes
        XCTAssertFalse(writes.contains { $0.count >= 6 && $0.suffix(4).elementsEqual(LE.bytes(15)) }, "no part of the IR went out")
        // Now the IR goes.
        let ir = try await session.uploadIR(wav: Self.wav(), productId: "00000000-0000-4000-8000-000000000003", filename: "Mutex IR.wav", name: "Mutex IR")
        XCTAssertTrue(ir.ok)
        await session.disconnect()
    }

    func testACancelledStreamEndsAndFreesTheLink() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        await pedal.setReplyDelay(2000)   // the reply would come late
        let rec = CaptureRecord(hash: "cd", name: "Cancelled", cloudUUID: "u")
        let preview = Task { try await session.previewCapture(cns: Fixtures.syntheticCapture(800), record: rec) }
        for _ in 0..<200 { if await session.streamBusy != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        preview.cancel()
        do { _ = try await preview.value; XCTFail("cancelled") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let busy = await session.streamBusy
        XCTAssertNil(busy, "the stream slot is free again")
        await session.disconnect()
    }

    func testALostLinkEndsAStream() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        await pedal.setReplyDelay(2000)
        let wav = Self.wav()   // made outside the task: older compilers' isolation checker trips over `Self` in it
        let up = Task { try await session.uploadIR(wav: wav, productId: "00000000-0000-4000-8000-000000000004", filename: "Lost.wav", name: "Lost") }
        for _ in 0..<200 { if await session.streamBusy != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        await session.linkLost()
        do { _ = try await up.value; XCTFail("the link is gone") } catch {}
        let busy = await session.streamBusy
        XCTAssertNil(busy)
    }

    /// A minimal float mono 48 kHz WAV (4 samples).
    static func wav() -> [UInt8] { WAVBuilder().bytes() }
}
