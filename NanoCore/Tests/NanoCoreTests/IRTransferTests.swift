import XCTest
import CryptoKit
@testable import NanoCore

/// Generated WAV files for the checks (no audio files are committed): RIFF/WAVE, an optional `fmt ` chunk (plain or
/// WAVE_FORMAT_EXTENSIBLE), and a `data` chunk, or a LIST chunk instead of audio. Mirrors the Electron UX test's `wavOf`.
struct WAVBuilder {
    var format = 3, channels = 1, rate = 48000, bits = 32, data = 16
    var fmt = true, extensible = false, cut = 0, riff = "RIFF"
    func bytes() -> [UInt8] {
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func u32(_ v: Int) -> [UInt8] { LE.bytes(UInt32(v)) }
        var chunks: [UInt8] = []
        if fmt {
            let len = extensible ? 40 : 16
            var f = Array("fmt ".utf8) + u32(len) + u16(extensible ? 0xFFFE : format) + u16(channels) + u32(rate)
            f += u32(rate * channels * bits / 8) + u16(channels * bits / 8) + u16(bits)
            if extensible { f += u16(22) + u16(bits) + u32(0) + u16(format) + [UInt8](repeating: 0, count: 14) }
            chunks += f
        }
        if data > 0 { chunks += Array("data".utf8) + u32(data + cut) + [UInt8](repeating: 0, count: data) }
        else { chunks += Array("LIST".utf8) + u32(28) + [UInt8](repeating: 0, count: 28) }
        return Array(riff.utf8) + u32(chunks.count + 4) + Array("WAVE".utf8) + chunks
    }
}

/// The Cloud IR transfer (15 → 16), the WAV check before it, and the IR delete (82 → 83).
final class IRTransferTests: XCTestCase {
    private func why(_ b: WAVBuilder) -> String { do { _ = try WAVCheck.check(b.bytes()); return "ok" } catch { return "\(error)" } }

    func testTheTracedKindOfWAVPasses() throws {
        XCTAssertEqual(why(WAVBuilder()), "ok", "mono 48 kHz float")
        let f = try WAVCheck.check(WAVBuilder().bytes())
        XCTAssertEqual(f, WAVFormat(format: 3, channels: 1, sampleRate: 48000, bits: 32, dataBytes: 16))
        XCTAssertEqual(why(WAVBuilder(format: 1, channels: 2, rate: 44100, bits: 24)), "ok", "24-bit PCM stereo 44.1 kHz")
        XCTAssertEqual(why(WAVBuilder(extensible: true)), "ok", "WAVE_FORMAT_EXTENSIBLE float")
        XCTAssertEqual(try WAVCheck.check(WAVBuilder(extensible: true).bytes()).format, 3)
        XCTAssertEqual(why(WAVBuilder(format: 3, bits: 64)), "ok")
        XCTAssertEqual(why(WAVBuilder(format: 1, rate: 8000, bits: 16)), "ok")
    }

    func testWhatThePedalCantUseIsRefusedWithTheReason() {
        XCTAssertEqual(why(WAVBuilder(format: 2, bits: 16)), "The IR is not PCM or floating-point audio (WAV format 2), so the pedal can’t use it.")
        XCTAssertEqual(why(WAVBuilder(channels: 6)), "The IR has 6 channels; the pedal takes mono or stereo IRs.")
        XCTAssertEqual(why(WAVBuilder(rate: 4000)), "The IR’s sample rate (4000 Hz) is outside 8–192 kHz.")
        XCTAssertTrue(why(WAVBuilder(rate: 384000)).contains("384000 Hz"))
        XCTAssertEqual(why(WAVBuilder(format: 1, bits: 8)), "The IR uses 8-bit PCM samples, which the pedal can’t read.")
        XCTAssertEqual(why(WAVBuilder(format: 3, bits: 16)), "The IR uses 16-bit float samples, which the pedal can’t read.")
        XCTAssertEqual(why(WAVBuilder(data: 64, fmt: false)), "The WAV file has no format chunk.")
        XCTAssertEqual(why(WAVBuilder(data: 0)), "The WAV file has no audio data.")
        XCTAssertEqual(why(WAVBuilder(cut: 100)), "The WAV file is cut short (its \"data\" chunk runs past the end).")
        XCTAssertEqual(why(WAVBuilder(riff: "RIFX")), "The Cloud IR payload is not a WAV file.")
        XCTAssertEqual(why(WAVBuilder(channels: 0)), "The IR has 0 channels; the pedal takes mono or stereo IRs.")
        XCTAssertThrowsError(try WAVCheck.check([UInt8](repeating: 0, count: 10)))
    }

    func testPayloadsOver1MBAreRefusedBeforeDecoding() throws {
        let tooLong = String(repeating: "A", count: 1_500_000)
        XCTAssertThrowsError(try IRTransfer.decodePayload(tooLong)) { XCTAssertEqual("\($0)", "The IR is larger than 1 MB; the pedal takes short IR WAV files.") }
        let exactly = [UInt8](repeating: 1, count: IRTransfer.maxBytes)
        XCTAssertEqual(try IRTransfer.decodePayload(Data(exactly).base64EncodedString()).count, IRTransfer.maxBytes, "1 MB itself is fine")
        let over = [UInt8](repeating: 1, count: IRTransfer.maxBytes + 1)
        XCTAssertThrowsError(try IRTransfer.decodePayload(Data(over).base64EncodedString()))
        let wav = WAVBuilder().bytes()
        XCTAssertEqual(try IRTransfer.decodePayload(Data(wav).base64EncodedString()), wav)
        XCTAssertThrowsError(try IRTransfer.decodePayload("")) { XCTAssertEqual("\($0)", "The Cloud response has no IR payload.") }
    }

    func testNamesIdsAndThePage() {
        XCTAssertEqual(IRTransfer.filename(for: "My IR"), "My IR.wav")
        XCTAssertEqual(IRTransfer.filename(for: " A/B: c*d?.wav "), "A_B_ c_d_.wav")
        XCTAssertEqual(IRTransfer.filename(for: "Trailing dots... "), "Trailing dots.wav")
        XCTAssertEqual(IRTransfer.filename(for: "  "), "cloud-impulse-response.wav")
        XCTAssertTrue(IRTransfer.isProductId("00000000-0000-4000-8000-000000000004"))
        XCTAssertTrue(IRTransfer.isProductId("ABCDEF01-2345-6789-abcd-ef0123456789"))
        XCTAssertFalse(IRTransfer.isProductId("00000000-0000-4000-8000-00000000000"))
        XCTAssertFalse(IRTransfer.isProductId("../../api/v1/user"))
        XCTAssertFalse(IRTransfer.isProductId("00000000-0000-4000-8000-000000000004/x"))
        XCTAssertTrue(IRTransfer.isIRPagePath("/cloud/profile/impulses"))
        XCTAssertTrue(IRTransfer.isIRPagePath("/cloud/profile/impulses/"))
        XCTAssertFalse(IRTransfer.isIRPagePath("/cloud/profile/impulses/other"))
        XCTAssertFalse(IRTransfer.isIRPagePath("/cloud/discover"))
        XCTAssertTrue(IRTransfer.sameName(" 412 v30", "412 V30 "))
    }

    // MARK: 15

    func testType15Layout() throws {
        let wav = WAVBuilder().bytes(), id = "00000000-0000-4000-8000-000000000004", file = "Demo Cloud IR.wav"
        let parts = IRTransfer.message(wav: wav, productId: id, filename: file)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(Array(parts[0][1...4]), [0xC0, 0x08, 0x06, 0x1A], "{1: 6, 3: …} as in the trace")
        XCTAssertEqual(Array(parts[0].suffix(4)), [0x0F, 0, 0, 0], "type 15")
        let md5 = Array(Insecure.MD5.hash(data: Data(wav)).map { String(format: "%02x", $0) }.joined().utf8)
        let content: [UInt8] = [0x0A] + Varint.encode(UInt64(wav.count)) + wav + [0x12, 0x20] + md5
        let body: [UInt8] = [0x08, 0x06, 0x1A] + Varint.encode(UInt64(content.count)) + content
            + [0x22, 36] + Array(id.utf8) + [0x2A, UInt8(file.utf8.count)] + Array(file.utf8)
        XCTAssertEqual(Frame.body(of: parts[0]), body)
    }

    func testABigIRStreamsAndReassembles() throws {
        let wav = WAVBuilder(data: 4108).bytes()   // the traced IR's size class (4 KB)
        let parts = IRTransfer.message(wav: wav, productId: "00000000-0000-4000-8000-000000000004", filename: "Big.wav")
        XCTAssertEqual(parts.count, 9)
        XCTAssertEqual(parts.first?[1], 0x41)
        XCTAssertEqual(parts.last.map { $0[1] & 0xC0 }, 0x80)
        XCTAssertTrue(parts.allSatisfy { $0.count == 500 }, "500-byte writes, the last padded")
        var r = Frame.Reassembler(), whole: (body: [UInt8], type: UInt32)?
        for p in parts { whole = r.feed(p) ?? whole }
        XCTAssertEqual(whole?.type, 15)
        let f = ProtoFields.parse(try XCTUnwrap(whole?.body))
        XCTAssertEqual(f.message(3)?.first(1)?.bytes, wav)
        XCTAssertEqual(f.message(3)?.string(2), Transfer.md5Hex(wav))
        XCTAssertEqual(f.string(5), "Big.wav")
    }

    func testReplyParsing() {
        let accepted = IRTransfer.parseReply(body: ProtoWriter().int(1, 6).int(3, 1).message(4, ProtoWriter().int(1, 1).string(2, "Demo Cloud IR")).build())
        XCTAssertEqual(accepted, .init(status: 1, index: 1, name: "Demo Cloud IR", message: ""))
        XCTAssertTrue(accepted.ok)
        let refused = IRTransfer.parseReply(body: ProtoWriter().int(1, 6).int(3, 0).string(5, "Library full").build())
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.message, "Library full")
    }

    // MARK: 82

    func testDeleteFrameCarriesTheIndexAndName() {
        let name = Array("Demo Cloud IR".utf8)
        let expected = AuditionTests.frame([0x08, 0x02, 0x22, UInt8(2 + 2 + name.count), 0x08, 0x01, 0x12, UInt8(name.count)] + name, 82)
        XCTAssertEqual(IRTransfer.deleteRequest(index: 1, name: "Demo Cloud IR"), expected)
        XCTAssertEqual(AuditionTests.hex(IRTransfer.deleteRequest(index: 0, name: "My IR")), "11 C0 08 02 22 09 08 00 12 05 4D 79 20 49 52 52 00 00 00", "index 0 is sent explicitly")
        XCTAssertTrue(IRTransfer.deleteConfirmed(body: ProtoWriter().int(1, 6).int(3, 1).build()))
        XCTAssertFalse(IRTransfer.deleteConfirmed(body: ProtoWriter().int(1, 6).build()))
    }

    // MARK: against the fake pedal

    func testCloudIRInAndOutOfTheLibrary() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let progress = Collector()
        let reply = try await session.uploadIR(wav: WAVBuilder().bytes(), productId: "00000000-0000-4000-8000-000000000004",
                                               filename: "Demo Cloud IR.wav", name: "Demo Cloud IR") { i, _ in progress.add(i) }
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.index, 1, "after the demo's own user IR")
        XCTAssertEqual(reply.name, "Demo Cloud IR")
        XCTAssertEqual(progress.values, [1])
        var lib = try await session.requestLibrary()
        XCTAssertEqual(lib.userIRs.map(\.name), ["OwnHammer 412 Mix", "Demo Cloud IR"])
        XCTAssertEqual(lib.userIRs.last?.index, 1)

        let wrongName = try await session.deleteIR(index: 1, name: "Someone else")
        XCTAssertFalse(wrongName, "the index must still hold that IR")
        let deleted = try await session.deleteIR(index: 0, name: "OwnHammer 412 Mix")
        XCTAssertTrue(deleted)
        lib = try await session.requestLibrary()
        XCTAssertEqual(lib.userIRs.map(\.name), ["Demo Cloud IR"])
        XCTAssertEqual(lib.userIRs.first?.index, 0, "indices shift after a delete")
        XCTAssertEqual(lib.factoryIRs.count, 5, "factory cabs are not touched")

        // A wrong MD5 is refused by the (fake) pedal, as the real one would.
        let badBody = ProtoWriter().int(1, 6).message(3, ProtoWriter().bytes(1, [1, 2]).string(2, "00"))
            .string(4, "00000000-0000-4000-8000-000000000005").string(5, "X.wav").build()
        let bad = try await session.stream(Frame.chunks(body: badBody, type: 15), label: "bad", what: "IR download", expecting: 16)
        XCTAssertFalse(IRTransfer.parseReply(body: bad).ok)
        await session.disconnect()
    }
}
