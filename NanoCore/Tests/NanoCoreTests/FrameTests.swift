import XCTest
@testable import NanoCore

final class FrameTests: XCTestCase {
    func testVarintRoundTrip() {
        for v: UInt64 in [0, 1, 127, 128, 300, 19811, 1_791_477_816_511] {
            let enc = Varint.encode(v)
            XCTAssertEqual(Varint.read(enc, at: 0)?.0, v)
        }
        XCTAssertEqual(Varint.encodeInt32(-1), [UInt8](repeating: 0xFF, count: 9) + [0x01])
    }

    func testSingleWriteFrameIsTheClassicFrame() {
        XCTAssertEqual(Frame.single(body: [1, 2, 3], type: 13), [0x07, 0xC0, 1, 2, 3, 0x0D, 0, 0, 0])
        XCTAssertEqual(Frame.chunks(body: [1, 2, 3], type: 13), [[0x07, 0xC0, 1, 2, 3, 0x0D, 0, 0, 0]])
        XCTAssertEqual(Frame.type(of: [0x07, 0xC0, 1, 2, 3, 0x0D, 0, 0, 0]), 13)
    }

    func testLongMessageStreamsIn500ByteWrites() {
        let body = (0..<1100).map { UInt8($0 & 0xff) }
        let parts = Frame.chunks(body: body, type: 13)
        XCTAssertEqual(parts.map(\.count), [500, 500, 500])
        XCTAssertEqual(parts[0][0..<2].map { $0 }, [0xF2, 0x41])
        XCTAssertEqual(parts[1][0..<2].map { $0 }, [0xF2, 0x01])
        XCTAssertEqual(parts[2][1], 0x80) // 108 bytes left: no length bit 8
        var r = Frame.Reassembler()
        XCTAssertNil(r.feed(parts[0])); XCTAssertNil(r.feed(parts[1]))
        let done = r.feed(parts[2])
        XCTAssertEqual(done?.type, 13)
        XCTAssertEqual(done?.body, body)
    }

    /// The preset change the Electron app sent to the real pedal, and the pedal's reply (RecordedFrames.swift).
    func testPresetChangeAgainstPedalRecording() throws {
        XCTAssertEqual(Fixtures.bytes(try XCTUnwrap(Recorded.electronWrites["Preset change 64"])), Messages.presetChange(index: 63))
        XCTAssertEqual(Frame.type(of: Fixtures.bytes(Recorded.presetChangeAck)), 30)
        let f = ProtoFields.parse(Fixtures.body(Recorded.presetChangeAck))
        XCTAssertEqual(f.int(4), 1, "pedal confirmed the preset change")
    }

    func testRenameAgainstPedalRecording() throws {
        XCTAssertEqual(Fixtures.bytes(try XCTUnwrap(Recorded.electronWrites["Rename preset 64"])), Messages.renamePreset(index: 63, name: "Claude Test 64"))
    }

    func testTunerFramesAgainstPedalRecording() throws {
        XCTAssertEqual(Fixtures.bytes(try XCTUnwrap(Recorded.electronWrites["Tuner on"])), Messages.tunerMode(on: true, baseFrequency: 440, live: true, muted: true))
        XCTAssertEqual(Fixtures.bytes(try XCTUnwrap(Recorded.electronWrites["Tuner off"])), Messages.tunerMode(on: false))
    }
}
