import XCTest
@testable import NanoCore

/// Session recording: the tap sees both directions, and the file matches the Electron fixtures' format.
final class RecordingTests: XCTestCase {
    func testTapRecordsBothDirectionsAgainstTheFakePedal() async throws {
        let recorder = SessionRecorder()
        recorder.start()
        let session = Session(transport: FakePedal(), tap: recorder.tap)
        _ = try await session.connect()
        await session.setAmp(.gain, 180)
        recorder.note("Synced")
        let rec = try XCTUnwrap(recorder.stop(demo: true, device: "Demo pedal", preset: 2))
        XCTAssertFalse(recorder.isRecording)

        XCTAssertEqual(rec.tx.first?.hex, SessionRecorder.hex(Writes.metadataRequest))
        XCTAssertEqual(rec.tx.first?.label, "FE metadata request")
        XCTAssertEqual(rec.tx.last?.hex, SessionRecorder.hex(Writes.amp(.gain, 180)))
        XCTAssertFalse(rec.rx.isEmpty, "the metadata reply arrives as notifications")
        XCTAssertNil(rec.rx.first?.label)
        XCTAssertEqual(rec.log.map(\.text), ["Synced"])
        XCTAssertEqual(rec.events.map(\.t), rec.events.map(\.t).sorted(), "timestamps are monotonic")

        // Round trip through JSON, and through the decoder the fixtures use.
        let data = try rec.json()
        XCTAssertEqual(try SessionRecording.parse(data), rec)
        let asFixture = try JSONDecoder().decode(Recording.self, from: data)
        XCTAssertEqual(asFixture.events.count, rec.events.count)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["app", "recorded", "demo", "device", "preset", "events", "log"])
        XCTAssertEqual(object["app"] as? String, "nano-cortex-mac")
        XCTAssertEqual(object["preset"] as? Int, 2)
    }

    func testNotRecordingIsANoOp() {
        let recorder = SessionRecorder()
        recorder.record(.tx, [1, 2, 3], label: "x")
        recorder.note("x")
        XCTAssertNil(recorder.stop(demo: false, device: nil, preset: nil))
    }

    func testNullsAndFormats() throws {
        let start = Date(timeIntervalSince1970: 1_791_470_837.395)   // 2026-10-08T14:47:17.395Z
        let recorder = SessionRecorder()
        recorder.start(at: start)
        recorder.record(.rx, [0x06, 0xC0, 0x08, 0x01, 0x1F, 0x00, 0x00, 0x00], at: start.addingTimeInterval(0.0084))
        let rec = try XCTUnwrap(recorder.stop(demo: false, device: nil, preset: nil))
        XCTAssertEqual(rec.recorded, "2026-10-08T14:47:17.395Z")
        XCTAssertEqual(rec.events, [.init(t: 8, dir: .rx, hex: "06 C0 08 01 1F 00 00 00", label: nil)])
        XCTAssertEqual(SessionRecorder.fileName(for: start), "nano-session-2026-10-08T14-47-17.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: rec.json()) as? [String: Any])
        XCTAssertTrue(object["device"] is NSNull)
        XCTAssertTrue(object["preset"] is NSNull)
        XCTAssertNil((object["events"] as? [[String: Any]])?.first?["label"], "no label key on RX events")
    }

    /// A recording in the Electron app's format (its `log` lines included) decodes with the same type.
    func testElectronFormatDecodes() throws {
        let json = """
        {"app":"nano-cortex-desktop","recorded":"2026-10-08T14:47:17.395Z","demo":false,"device":"Neural DSP Nano Cortex","preset":64,
         "events":[{"t":0,"dir":"tx","hex":"0C C0 08 03 18 3F 20 01 1D 00 00 00","label":"Preset change 64"},{"t":42,"dir":"rx","hex":"08 C0 08 01 20 01 1E 00 00 00"}],
         "log":[{"t":0,"text":"Connected"}]}
        """
        let rec = try SessionRecording.parse(Data(json.utf8))
        XCTAssertEqual(rec.app, "nano-cortex-desktop")
        XCTAssertEqual(rec.events.count, 2)
        XCTAssertEqual(rec.events.first?.label, "Preset change 64")
        XCTAssertNil(rec.events.last?.label)
        XCTAssertEqual(rec.log.map(\.text), ["Connected"])
        let empty = try SessionRecording.parse(Data(#"{"app":"nano-cortex-desktop","recorded":"2026-10-08T16:28:58.000Z","demo":false,"device":null,"preset":null,"events":[],"log":[]}"#.utf8))
        XCTAssertTrue(empty.events.isEmpty, "a recording with no packets still decodes")
    }
}
