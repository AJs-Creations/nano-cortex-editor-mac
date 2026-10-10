import XCTest
@testable import NanoCore

/// Device info, global settings and capture details against the phone app's trace of 2026-10-09
/// (recorded phone-app session, not published; frames inlined in RecordedFrames.swift; PROTOCOL-NOTES §13).
final class DeviceTests: XCTestCase {
    func testDeviceInfoRequestAndReply() throws {
        XCTAssertEqual(Fixtures.bytes(Recorded.deviceInfoRequest), Writes.deviceInfoRequest(unixTime: 1_791_574_340))
        var info = DeviceInfo.parse(deviceInfo: Fixtures.bytes(Recorded.deviceInfoReply))
        XCTAssertEqual(info.firmware, "2.2.1")
        XCTAssertEqual(info.serial, "XXXXXXXXX")   // masked in the trace
        XCTAssertEqual(info.hash?.count, 64)        // zeroed here
        XCTAssertEqual(Fixtures.bytes(Recorded.keepAlive), Writes.keepAlive)
        info.merge(keepAlive: Fixtures.bytes(Recorded.keepAliveReply))
        XCTAssertEqual(info.firmwareBuild, "2.2.1+06d34443")
        XCTAssertEqual(info.name, "Neural DSP Nano Cortex")
    }

    func testSettingsReadAndParse() throws {
        XCTAssertEqual(Fixtures.bytes(Recorded.settingsRequest), Writes.settingsRequest)
        let s = DeviceSettings.parse(Fixtures.bytes(Recorded.settingsFirst))
        XCTAssertEqual(s.name, "Neural DSP Nano Cortex")
        XCTAssertEqual(s.ledBrightness, 153)
        XCTAssertEqual(DeviceSettings.brightnessPercent(153), 60)
        XCTAssertEqual(DeviceSettings.brightnessRaw(percent: 60), 153)
        XCTAssertEqual(try XCTUnwrap(s.usbVolumeDb), -6.0, accuracy: 0.001)
        XCTAssertEqual(s.raw.map(\.field), [5, 6, 7, 8, 11, 12, 13, 14, 17])
        XCTAssertEqual(s.raw.first { $0.field == 11 }?.value, "0")
        XCTAssertEqual(s.raw.first { $0.field == 13 }?.value, "129")
        XCTAssertEqual(s.raw.last?.value, "-6.00")
        // The last read of the session: brightness 155, field 12 gone after the 67 {9:0} write.
        let l = DeviceSettings.parse(Fixtures.bytes(Recorded.settingsLast))
        XCTAssertEqual(l.ledBrightness, 155)
        XCTAssertNil(l.raw.first { $0.field == 12 })
    }

    /// The phone app's brightness + volume writes (≈463 s and ≈466 s), byte for byte, and the ack.
    func testSettingsWriteMatchesPhoneTrace() throws {
        let writes = Recorded.settingsWrites.map { (t: $0.t, packet: Fixtures.bytes($0.packet)) }
        let at463 = try XCTUnwrap(writes.first { abs($0.t - 463.2) < 0.2 })
        XCTAssertEqual(at463.packet, Writes.deviceSettings(brightness: 153, usbVolumeDb: -6.0))
        XCTAssertEqual(Array(Writes.deviceSettings(brightness: 153, usbVolumeDb: -6.0)[2..<12]), [0x08, 0x01, 0x20, 0x99, 0x01, 0x75, 0x00, 0x00, 0xC0, 0xC0])
        // A mid-drag value: 140 with −6.0 (460.5 s), and −10.41 dB with 153 (464.4 s).
        XCTAssertTrue(writes.contains { $0.packet == Writes.deviceSettings(brightness: 140, usbVolumeDb: -6.0) })
        let mid = try XCTUnwrap(writes.first { abs($0.t - 464.4) < 0.05 })
        let f = ProtoFields.parse(Frame.body(of: mid.packet)!)
        XCTAssertEqual(mid.packet, Writes.deviceSettings(brightness: 153, usbVolumeDb: try XCTUnwrap(f.first(14)?.float32)))
        XCTAssertEqual(ProtoFields.parse(Fixtures.bytes(Recorded.settingsAck)).int(3), 1)
    }

    /// Capture details for slot 1 (306 s) and slot 12 (521 s).
    func testCaptureDetailsMatchPhoneTrace() throws {
        let reqs = Recorded.captureDetailRequests.map { (t: $0.t, packet: Fixtures.bytes($0.packet)) }
        let r306 = try XCTUnwrap(reqs.first { abs($0.t - 306.1) < 0.2 })
        XCTAssertEqual(r306.packet, Writes.captureDetails(slot: 1))
        XCTAssertEqual(Writes.captureDetails(slot: 1), [0x08, 0xC0, 0x18, 0x00, 0x28, 0x01, 0x11, 0x00, 0x00, 0x00])
        XCTAssertTrue(reqs.contains { $0.packet == Writes.captureDetails(slot: 12) })

        let replies = Recorded.captureDetailReplies.map(Fixtures.bytes)
        let d1 = CaptureDetails.parse(try XCTUnwrap(replies.first), slot: 1)
        XCTAssertTrue(d1.ok)
        XCTAssertEqual(d1.name, "CA John's Ch1 1")
        XCTAssertEqual(d1.author, "NeuralDSP")
        XCTAssertEqual(d1.hash.count, 64)
        XCTAssertEqual(d1.deviceType, "amp_head")
        XCTAssertEqual(d1.instrument, "guitar")
        XCTAssertEqual(d1.tags, ["Mesaboogie", "JP2C", "Mesa", "Boogie", "John", "Petrucci"])
        XCTAssertEqual(d1.record?.gainType, 4)
        XCTAssertEqual(d1.record?.hash, d1.hash)
        XCTAssertEqual(d1.description, "")
        let d12 = CaptureDetails.parse(replies[1], slot: 12)
        XCTAssertEqual(d12.name, "Brit 2555 Rhy 12")
        XCTAssertEqual(d12.tags, ["Marshall", "Silver Jubilee", "Rhythm"])
    }

    func testSessionAgainstFakePedal() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let info = try await session.readDeviceInfo(now: Date(timeIntervalSince1970: 1_791_574_340))
        XCTAssertEqual(info.firmware, "2.2.1")
        XCTAssertEqual(info.serial, "NP00XXXXXX")
        XCTAssertEqual(info.name, "Neural DSP Nano Cortex")
        let s = try await session.readDeviceSettings()
        XCTAssertEqual(s.ledBrightness, 153)
        XCTAssertEqual(s.usbVolumeDb, -6)
        let ok = try await session.writeDeviceSettings(brightness: 200, usbVolumeDb: -9.5)
        XCTAssertTrue(ok)
        let again = try await session.readDeviceSettings()
        XCTAssertEqual(again.ledBrightness, 200)
        XCTAssertEqual(again.usbVolumeDb, -9.5)
        let d = try await session.captureDetails(slot: 6)
        XCTAssertTrue(d.ok)
        XCTAssertEqual(d.name, "SVT Classic")
        XCTAssertEqual(d.instrument, "bass")
        XCTAssertTrue(d.tags.contains("Demo"))
        let writes = await pedal.writes
        XCTAssertTrue(writes.contains(Writes.deviceInfoRequest(unixTime: 1_791_574_340)))
        XCTAssertTrue(writes.contains(Writes.deviceSettings(brightness: 200, usbVolumeDb: -9.5)))
        XCTAssertTrue(writes.contains(Writes.captureDetails(slot: 6)))
    }
}
