// The connect rules (PedalLink.swift, compiled into this bundle): what makes a link ready, what is remembered and
// forgotten, and how often a failing connect is retried. A fake memory stands in for UserDefaults; one test runs
// DefaultsPedalMemory against a private suite (never the app's own defaults).
import XCTest

final class FakeMemory: PedalMemory {
    var identifier: String?
    var name: String?
    var forgets = 0
    init(_ id: String? = nil, name: String? = nil) { identifier = id; self.name = name }
    func remember(identifier: String, name: String?) { self.identifier = identifier; self.name = name }
    func forget() { identifier = nil; name = nil; forgets += 1 }
}

final class GattSetupTests: XCTestCase {
    func testReadyNeedsWriteNotifyAndNotificationsOn() {
        var s = GattSetup()
        XCTAssertNil(s.servicesDiscovered(["A002", "A003"]))
        XCTAssertNil(s.characteristicsDiscovered(["C304", "C305"], in: "A002"), "notifications are not on yet")
        XCTAssertNil(s.characteristicsDiscovered([], in: "A003"))
        XCTAssertEqual(s.notificationsUpdated(on: true), .ready)
        XCTAssertEqual(s.verdict, .ready)
        XCTAssertNil(s.notificationsUpdated(on: true), "the verdict is reported once")
    }

    func testReadyAsSoonAsBothAreThereEvenWithAServicePending() {
        var s = GattSetup()
        XCTAssertNil(s.servicesDiscovered(["a002", "a003"]))
        XCTAssertNil(s.characteristicsDiscovered(["C305"], in: "A003"))
        XCTAssertNil(s.notificationsUpdated(on: true), "no C304 yet, and A002 hasn't answered")
        XCTAssertEqual(s.characteristicsDiscovered(["C304"], in: "A002"), .ready, "write and notify may sit in different services")
    }

    func testDeviceWithoutTheNanoServiceIsNotANano() {
        var none = GattSetup()
        XCTAssertEqual(none.servicesDiscovered([]), .notANano)
        var other = GattSetup()
        XCTAssertEqual(other.servicesDiscovered(["180A", "180F"]), .notANano, "a headset's services")
    }

    func testNanoServiceWithoutTheCharacteristicsIsNotANano() {
        var s = GattSetup()
        XCTAssertNil(s.servicesDiscovered(["A002", "A003"]))
        XCTAssertNil(s.characteristicsDiscovered(["C304"], in: "A002"))
        XCTAssertEqual(s.characteristicsDiscovered(["1234"], in: "A003"), .notANano, "no C305 anywhere")
    }

    func testErrorsAreFailuresNotProof() {
        var services = GattSetup()
        XCTAssertEqual(services.servicesDiscovered([], error: "The connection has timed out unexpectedly."), .failed("The connection has timed out unexpectedly."))

        var chars = GattSetup()
        XCTAssertNil(chars.servicesDiscovered(["A002", "A003"]))
        XCTAssertNil(chars.characteristicsDiscovered([], in: "A002", error: "Unlikely error."))
        XCTAssertEqual(chars.characteristicsDiscovered([], in: "A003"), .failed("Unlikely error."), "a service that failed to answer might have held them")

        var notify = GattSetup()
        XCTAssertNil(notify.servicesDiscovered(["A002"]))
        XCTAssertNil(notify.characteristicsDiscovered(["C304", "C305"], in: "A002"))
        XCTAssertEqual(notify.notificationsUpdated(on: false, error: "Writing is not permitted."), .failed("Writing is not permitted."))
    }

    func testAnErrorOnOneServiceDoesNotSpoilTheOther() {
        var s = GattSetup()
        XCTAssertNil(s.servicesDiscovered(["A002", "A003"]))
        XCTAssertNil(s.characteristicsDiscovered([], in: "A003", error: "Unlikely error."))
        XCTAssertNil(s.characteristicsDiscovered(["C304", "C305"], in: "A002"))
        XCTAssertEqual(s.notificationsUpdated(on: true), .ready)
    }
}

final class LinkPolicyTests: XCTestCase {
    let pedal = "6F1C2D3E-0000-4000-8000-00000000A002"
    let headset = "11111111-2222-4333-8444-555555555555"

    func testRemembersOnlyAReadyPedal() {
        let memory = FakeMemory()
        var policy = LinkPolicy(memory: memory)
        policy.begin()
        XCTAssertNil(policy.target, "nothing remembered: scan")
        XCTAssertTrue(policy.accepts(identifier: pedal, name: "NDSP Nano Cortex"))
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry)
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: false), .giveUp)
        XCTAssertNil(memory.identifier, "picking, connecting, a failed setup: none of it remembers")
        policy.ready(identifier: pedal, name: "Nano Cortex")
        XCTAssertEqual(memory.identifier, pedal)
        XCTAssertEqual(memory.name, "Nano Cortex")
        XCTAssertEqual(policy.target, pedal)
    }

    func testARememberedDeviceProvenNotANanoIsForgottenAndSkipped() {
        let memory = FakeMemory(headset, name: "JBL Flip 5")   // remembered by 1.0.0, which saved on didConnect
        var policy = LinkPolicy(memory: memory)
        policy.begin()
        XCTAssertEqual(policy.target, headset)
        XCTAssertEqual(policy.notANano(identifier: headset), .proven(forgot: true))
        XCTAssertNil(memory.identifier)
        XCTAssertEqual(memory.forgets, 1)
        policy.begin()
        XCTAssertNil(policy.target, "the next Connect scans")
        XCTAssertFalse(policy.accepts(identifier: headset, name: ""), "and never takes it again this session")
        XCTAssertTrue(policy.accepts(identifier: pedal, name: ""))
    }

    func testNotANanoLeavesAnotherRememberedPedalAlone() {
        let memory = FakeMemory(pedal, name: "Nano Cortex")
        var policy = LinkPolicy(memory: memory)
        XCTAssertEqual(policy.notANano(identifier: headset), .proven(forgot: false))
        XCTAssertEqual(memory.identifier, pedal)
        XCTAssertEqual(memory.forgets, 0)
    }

    func testTimeoutsErrorsAndDropsForgetNothing() {
        let memory = FakeMemory(pedal, name: "Nano Cortex")
        var policy = LinkPolicy(memory: memory)
        policy.begin()
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: false), .giveUp, "a connect someone clicked ends at once")
        XCTAssertEqual(memory.identifier, pedal, "out of range or busy is not proof")
        XCTAssertEqual(policy.target, pedal)
    }

    func testAPedalThatWasReadyIsNotForgottenOnAnEmptyDiscovery() {
        let memory = FakeMemory()
        var policy = LinkPolicy(memory: memory)
        policy.ready(identifier: pedal, name: "Nano Cortex")
        XCTAssertEqual(policy.notANano(identifier: pedal), .doubted)
        XCTAssertEqual(memory.identifier, pedal)
        XCTAssertTrue(policy.accepts(identifier: pedal, name: "Nano Cortex"))
    }

    func testFailedConnectsRetryThenScanThenGiveUp() {
        let memory = FakeMemory(pedal, name: "Nano Cortex")
        var policy = LinkPolicy(memory: memory)
        policy.begin()
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry)
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry)
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .scan, "after \(LinkPolicy.maxAttempts) tries, a fresh scan")
        XCTAssertNil(policy.target, "the scan doesn't go back to the remembered device")
        XCTAssertEqual(memory.identifier, pedal, "still remembered: a failed connect proves nothing")
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .giveUp, "found again by the scan and failing again: stop")
        policy.begin()
        XCTAssertEqual(policy.target, pedal, "the next Connect starts with it again")
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry, "with a fresh count")
    }

    func testFailedConnectsOnAScannedDeviceGiveUpWithoutAnotherScan() {
        var policy = LinkPolicy(memory: FakeMemory())
        policy.begin()
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry)
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .retry)
        XCTAssertEqual(policy.connectFailed(identifier: pedal), .giveUp)
    }

    func testAnAutomaticReconnectRetriesAFailedSetupABoundedNumberOfTimes() {
        var policy = LinkPolicy(memory: FakeMemory(pedal))
        policy.ready(identifier: pedal, name: nil)
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: true), .retry)
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: true), .retry)
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: true), .giveUp)
        policy.ready(identifier: pedal, name: nil)
        XCTAssertEqual(policy.setupFailed(identifier: pedal, unattended: true), .retry, "a ready link resets the count")
    }

    func testScanResultsByName() {
        let policy = LinkPolicy(memory: FakeMemory())
        XCTAssertTrue(policy.accepts(identifier: pedal, name: "NDSP Nano Cortex"))
        XCTAssertTrue(policy.accepts(identifier: pedal, name: "neural dsp"))
        XCTAssertTrue(policy.accepts(identifier: pedal, name: ""), "unnamed but advertising A002/A003")
        XCTAssertFalse(policy.accepts(identifier: headset, name: "JBL Flip 5"))
    }

    func testDefaultsMemoryUsesTheSettingsKeys() throws {
        let suite = "nanocortex.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = DefaultsPedalMemory(defaults: defaults)
        XCTAssertNil(memory.identifier)
        memory.remember(identifier: pedal, name: "Nano Cortex")
        XCTAssertEqual(defaults.string(forKey: "pedal.identifier"), pedal, "AppSettings.Key.pedalIdentifier")
        XCTAssertEqual(defaults.string(forKey: "pedal.name"), "Nano Cortex", "AppSettings.Key.pedalName")
        memory.remember(identifier: pedal, name: nil)
        XCTAssertEqual(defaults.string(forKey: "pedal.name"), "Nano Cortex", "the same pedal without a name keeps its name")
        memory.remember(identifier: headset, name: nil)
        XCTAssertNil(defaults.string(forKey: "pedal.name"), "another device doesn't inherit the old name")
        memory.forget()
        XCTAssertNil(defaults.string(forKey: "pedal.identifier"))
        XCTAssertNil(memory.identifier)
    }

    func testMessages() {
        XCTAssertEqual(LinkError.notANano(name: "JBL Flip 5", forgot: true).message,
                       "“JBL Flip 5” isn’t a Nano Cortex: it has no Nano Cortex Bluetooth service. The app forgot it. Hold EXIT + CAPTURE on the pedal, then click Connect to look for it.")
        XCTAssertTrue(LinkError.notANano(name: nil, forgot: false).message.hasPrefix("That device isn’t a Nano Cortex"))
        XCTAssertFalse(LinkError.notANano(name: nil, forgot: false).message.contains("forgot"))
        XCTAssertTrue(LinkError.setupTimedOut.message.contains("within 10 seconds"))
        XCTAssertTrue(LinkError.setupFailed("Unlikely error.").message.contains("(Unlikely error.)"))
        XCTAssertEqual(LinkError.setupTimedOut.localizedDescription, LinkError.setupTimedOut.message)
    }
}

/// The session across a dropped link and across the Mac's sleep (Bluetooth state 4, then 5 on wake, and no
/// didDisconnect: seen in the activity log). Before 1.2.1 the wake reconnected the link but never synced a session.
final class LinkLifeTests: XCTestCase {
    func testASleepEndsTheSessionAndTheWakeReconnectStartsANewOne() {
        var life = LinkLife()
        XCTAssertFalse(life.becameReady(callerWaiting: true), "Connect: the caller starts the session")
        XCTAssertTrue(life.ready)
        XCTAssertTrue(life.bluetoothOff(wantConnection: true), "Bluetooth off with a ready link: the session is lost")
        XCTAssertFalse(life.ready)
        XCTAssertTrue(life.reconnecting)
        XCTAssertFalse(life.bluetoothOff(wantConnection: true), "a second state change loses nothing more")
        XCTAssertTrue(life.becameReady(callerWaiting: false), "the reconnect on wake starts a new session")
        XCTAssertFalse(life.reconnecting)
        XCTAssertFalse(life.becameReady(callerWaiting: false), "once")
    }

    func testADropIsTheSameAndALateDisconnectAfterTheSleepLosesNothingMore() {
        var life = LinkLife()
        _ = life.becameReady(callerWaiting: true)
        XCTAssertTrue(life.ended(wantConnection: true))
        XCTAssertFalse(life.ended(wantConnection: true), "a didDisconnect after Bluetooth went off")
        XCTAssertTrue(life.reconnecting)
        XCTAssertTrue(life.becameReady(callerWaiting: false))
    }

    func testBluetoothOffDuringSetupOrWithoutALinkChangesNothing() {
        var life = LinkLife()
        XCTAssertFalse(life.bluetoothOff(wantConnection: true))
        XCTAssertFalse(life.reconnecting)
        XCTAssertFalse(life.becameReady(callerWaiting: false), "a first connect is no reconnect")
    }

    func testAConnectCallerWaitingStartsItsOwnSession() {
        var life = LinkLife()
        _ = life.becameReady(callerWaiting: true)
        _ = life.bluetoothOff(wantConnection: true)
        XCTAssertFalse(life.becameReady(callerWaiting: true), "Connect was clicked meanwhile: that call starts the session")
        XCTAssertFalse(life.reconnecting)
    }

    func testDisconnectAndGivingUpEndEverything() {
        var life = LinkLife()
        _ = life.becameReady(callerWaiting: true)
        life.reset()
        XCTAssertFalse(life.ended(wantConnection: false), "the didDisconnect after Disconnect loses no session (the store ended it)")
        XCTAssertFalse(life.becameReady(callerWaiting: false))
        _ = life.becameReady(callerWaiting: true)
        XCTAssertTrue(life.ended(wantConnection: false))
        XCTAssertFalse(life.reconnecting, "not wanted: no reconnect")
    }
}
