// Quitting during an audition (QuitGuard.swift, compiled into this bundle): the reply to AppKit comes once, after the
// pedal's answer to the stop (148 → 149) or after the 1.5 s cap, whichever is first. Driven against the fake pedal
// with a Live Preview playing: a stop it confirms, one it refuses, and one it answers too late.
import XCTest
import NanoCore

@MainActor
final class QuitGuardTests: XCTestCase {
    @MainActor private final class Replies { var all: [(QuitGuard.Outcome, Duration)] = [] }

    /// A connected fake pedal playing a Live Preview (150 → 151).
    private func previewing() async throws -> (FakePedal, Session) {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let rec = CaptureRecord(hash: String(repeating: "ab", count: 32), name: "Quit Preview", cloudUUID: "u")
        let r = try await session.previewCapture(cns: (0..<1500).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }, record: rec)
        XCTAssertTrue(r.ok)
        let playing = await pedal.state.auditioning
        XCTAssertEqual(playing, "capture: Quit Preview")
        return (pedal, session)
    }

    /// What the store's quit stop does for a capture preview: 148, counted only with the 149 that echoes it.
    private func stop(on session: Session) -> @MainActor () async -> Bool {
        {
            let tx = Audition.nextTransaction()
            guard let r = try? await session.stopAudition(.capture, transaction: tx) else { return false }
            return Audition.stopConfirmed(r, transaction: tx)
        }
    }

    /// Runs a quit and waits for its reply, then `linger` more to catch a second one.
    private func quit(_ stop: @escaping @MainActor () async -> Bool, linger: Duration = .milliseconds(200)) async -> [(QuitGuard.Outcome, Duration)] {
        let replies = Replies()
        let replied = expectation(description: "reply")
        QuitGuard.run(stop: stop) { outcome, took in
            replies.all.append((outcome, took))
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 5)
        try? await Task.sleep(for: linger)
        return replies.all
    }

    func testAConfirmedStopRepliesAsSoonAsThePedalAnswers() async throws {
        let (pedal, session) = try await previewing()
        let replies = await quit(stop(on: session))
        XCTAssertEqual(replies.map(\.0), [.stopped])
        XCTAssertLessThan(replies[0].1, .milliseconds(1000), "no waiting for the cap")
        let playing = await pedal.state.auditioning
        XCTAssertNil(playing, "the pedal stopped the preview")
        let last = await pedal.writes.last ?? []
        XCTAssertEqual(Array(last.suffix(4)), LE.bytes(TransferType.auditionStop), "the last write is the stop (148)")
        XCTAssertEqual(QuitGuard.line(replies[0].0, after: replies[0].1).prefix(42), "Quit: stopped the preview first (the pedal")
        await session.disconnect()
    }

    func testARefusedStopStillQuitsWithoutWaitingForTheCap() async throws {
        let (pedal, session) = try await previewing()
        await pedal.mutate { $0.refuseAuditionStop = true }
        let replies = await quit(stop(on: session))
        XCTAssertEqual(replies.map(\.0), [.notConfirmed])
        XCTAssertLessThan(replies[0].1, .milliseconds(1000))
        let playing = await pedal.state.auditioning
        XCTAssertEqual(playing, "capture: Quit Preview", "the pedal kept playing; the app quits anyway")
        XCTAssertEqual(QuitGuard.line(.notConfirmed, after: .zero), "Quit: the pedal did not confirm stopping the preview; quitting anyway.")
        await session.disconnect()
    }

    func testASlowStopIsCutOffAtOneAndAHalfSecondsAndRepliesOnce() async throws {
        let (pedal, session) = try await previewing()
        await pedal.setReplyDelay(2000)   // the 149 comes after the cap
        let replies = await quit(stop(on: session), linger: .milliseconds(800))   // past the late 149
        XCTAssertEqual(replies.map(\.0), [.timedOut], "one reply, from the cap; the late answer adds none")
        XCTAssertGreaterThanOrEqual(replies[0].1, .milliseconds(1450))
        XCTAssertLessThan(replies[0].1, .milliseconds(1900))
        XCTAssertEqual(QuitGuard.line(.timedOut, after: replies[0].1), "Quit: the pedal did not answer the preview stop within 1.5 s; quitting anyway.")
        await session.disconnect()
    }

    func testTheCapIsOneAndAHalfSeconds() {
        XCTAssertEqual(QuitGuard.cap, .milliseconds(1500))
        XCTAssertEqual(QuitGuard.line(.stopped, after: .milliseconds(42)), "Quit: stopped the preview first (the pedal confirmed in 42 ms).")
    }
}
