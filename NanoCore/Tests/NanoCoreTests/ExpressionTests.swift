import XCTest
@testable import NanoCore

/// Expression assignments against the phone-app trace (recorded phone-app session, not published; frames inlined in
/// RecordedFrames.swift; preset index 61).
final class ExpressionTests: XCTestCase {
    func testReadRequestMatchesTrace() throws {
        let reads = Recorded.expressionReads.map(Fixtures.bytes)
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first, Writes.expressionRead(index: 61))
        XCTAssertEqual(Frame.body(of: Writes.expressionRead(index: 61)), [0x08, 0x03, 0x18, 0x3D])
        // The reply that followed: `{1: 1}` only = no assignments.
        let reply = Fixtures.bytes(Recorded.expressionReadReply)
        XCTAssertEqual(Frame.type(of: reply), 61)
        XCTAssertTrue(ExpressionAssignments.parse(reply: Frame.body(of: reply)!).isEmpty)
    }

    /// The five bodies from the trace, byte for byte, each found among the app's type-62 writes at 330–362 s.
    func testSaveBodiesMatchTrace() throws {
        let all = Recorded.expressionSaves.map(Fixtures.bytes)
        let saves = Set(all.prefix(Recorded.expressionSavesBefore362))
        let gain = ExpressionAssignments(ranges: [.gain: .init(min: 0, max: 255)])
        let gainBass = ExpressionAssignments(ranges: [.gain: .init(min: 0, max: 255), .bass: .init(min: 0, max: 255)])
        let captureHeelToe = ExpressionAssignments(bypasses: [.capture: .heelToe(inverted: false, delayMs: 600)])
        let pre2Latch = ExpressionAssignments(bypasses: [.pre2: .toggle(inverted: false, latch: true)])
        let cases: [(ExpressionAssignments, String)] = [
            (gain, "18 3D 22 07 08 00 10 00 18 FF 01"),
            (gainBass, "18 3D 22 07 08 00 10 00 18 FF 01 2A 07 08 00 10 00 18 FF 01"),
            (captureHeelToe, "18 3D 72 07 0A 05 08 00 10 D8 04"),
            (pre2Latch, "18 3D 8A 01 06 12 04 08 00 10 01"),
            (ExpressionAssignments(), "18 3D"),
        ]
        for (set, hex) in cases {
            XCTAssertEqual(set.encode(presetIndex: 61), Fixtures.bytes(hex), hex)
            XCTAssertTrue(saves.contains(Writes.expressionSave(index: 61, set)), "not in the trace: \(hex)")
        }
        // The two other values the app sent: heel-toe 693 ms and latch off.
        XCTAssertTrue(saves.contains(Writes.expressionSave(index: 61, .init(bypasses: [.capture: .heelToe(inverted: false, delayMs: 693)]))))
        XCTAssertTrue(saves.contains(Writes.expressionSave(index: 61, .init(bypasses: [.pre2: .toggle(inverted: false, latch: false)]))))
        // Every 62 in the trace decodes and re-encodes to itself.
        for w in saves {
            let (index, set) = ExpressionAssignments.parse(save: Frame.body(of: w)!)
            XCTAssertEqual(index, 61)
            XCTAssertEqual(Writes.expressionSave(index: index, set), w)
        }
        // Each save was acked with 63 {1:1 3:1}.
        let acks = Recorded.expressionAcks.map(Fixtures.bytes)
        XCTAssertEqual(acks.count, all.count)
        XCTAssertTrue(acks.allSatisfy { Frame.type(of: $0) == 63 && ProtoFields.parse(Frame.body(of: $0)!).int(3) == 1 })
    }

    func testEveryTargetRoundTrips() {
        var set = ExpressionAssignments()
        for (i, t) in ExpressionAssignments.RangeTarget.allCases.enumerated() { set.ranges[t] = .init(inverted: i % 2 == 1, min: i * 7, max: 255 - i * 3) }
        let modes: [ExpressionAssignments.Bypass] = [.heelToe(inverted: true, delayMs: 1500), .toggle(inverted: true, latch: false), .stop(delayMs: 250), .toggle(inverted: false, latch: true)]
        for (i, t) in ExpressionAssignments.BypassTarget.allCases.enumerated() { set.bypasses[t] = modes[i % modes.count] }
        let body = set.encode(presetIndex: 5)
        XCTAssertEqual(ExpressionAssignments.parse(save: body).set, set)
        XCTAssertEqual(ExpressionAssignments.parse(save: body).presetIndex, 5)
        XCTAssertEqual(ExpressionAssignments.parse(reply: set.replyBody()), set)
        XCTAssertLessThan(Writes.expressionSave(index: 63, set).count, 256, "a full set still fits one frame")
    }

    func testSessionReadAndSaveAgainstFakePedal() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let demo = try await session.readExpression(index: 1)
        XCTAssertEqual(demo.ranges[.gain], .init(min: 0, max: 255))
        let none = try await session.readExpression(index: 2)
        XCTAssertTrue(none.isEmpty)
        let set = ExpressionAssignments(ranges: [.bass: .init(inverted: true, min: 20, max: 200)], bypasses: [.pre2: .toggle(inverted: false, latch: true)])
        let ok = try await session.saveExpression(index: 2, set)
        XCTAssertTrue(ok)
        let back = try await session.readExpression(index: 2)
        XCTAssertEqual(back, set)
        let state = await pedal.state
        XCTAssertTrue(state.dirty)
        let cleared = try await session.saveExpression(index: 2, ExpressionAssignments())
        XCTAssertTrue(cleared)
        let empty = try await session.readExpression(index: 2)
        XCTAssertTrue(empty.isEmpty)
    }
}
