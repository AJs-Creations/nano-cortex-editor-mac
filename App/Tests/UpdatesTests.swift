// Update notifications (Updates.swift, compiled into this bundle): the appcast URL, the launch-check rule, and the
// Settings switch bound to the updater's automaticallyChecksForUpdates. Sparkle itself is not linked here: a fake
// updater stands in for SPUUpdater.
import XCTest

@MainActor
final class UpdatesTests: XCTestCase {
    /// Stands in for SPUUpdater: a stored setting like Sparkle's UserDefaults-backed one, and a check counter.
    final class FakeUpdater: UpdaterBackend {
        var automaticallyChecksForUpdates = true   // Info.plist's SUEnableAutomaticChecks
        var canCheckForUpdates = true
        var checks = 0
        func checkForUpdates() { checks += 1 }
        func set(_ on: Bool) { automaticallyChecksForUpdates = on }
    }
    /// An updater that refuses to turn automatic checks off (shows the switch reflects the updater, not the click).
    final class StubbornUpdater: UpdaterBackend {
        var automaticallyChecksForUpdates: Bool { get { true } set { _ = newValue } }
        var canCheckForUpdates = true
        func checkForUpdates() {}
    }

    func testFeedIsTheLatestReleaseAsset() {
        XCTAssertEqual(UpdateFeed.url.absoluteString, "https://github.com/AJs-Creations/nano-cortex-editor-mac/releases/latest/download/appcast.xml")
        XCTAssertEqual(UpdateFeed.url.scheme, "https")
        XCTAssertTrue(UpdateFeed.url.absoluteString.hasPrefix(Links.repository.absoluteString + "/releases/latest/download/"), "the feed is an asset of this repository's latest Release")
        XCTAssertEqual(UpdateFeed.checkInterval, 86_400, "once a day")
    }

    /// Sparkle reads SUFeedURL from Info.plist, generated from project.yml: it must be the same URL as the constant.
    func testInfoPlistFeedMatchesTheConstant() throws {
        let yml = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "project.yml")
        let text = try String(contentsOf: yml, encoding: .utf8)
        func value(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + ":") }
                .map { $0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        XCTAssertEqual(value("SUFeedURL"), UpdateFeed.url.absoluteString)
        XCTAssertEqual(value("SUEnableAutomaticChecks"), "true", "on by default, no permission prompt")
        XCTAssertEqual(value("SUScheduledCheckInterval"), "86400")
        let key = try XCTUnwrap(value("SUPublicEDKey"))
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "an Ed25519 public key")
    }

    func testNoBackgroundChecksInDemoMode() {
        XCTAssertFalse(UpdateFeed.backgroundChecksAllowed(arguments: ["/path/Nano Cortex Editor", "-demo", "-no-dev-remote"]))
        XCTAssertTrue(UpdateFeed.backgroundChecksAllowed(arguments: ["/path/Nano Cortex Editor"]))
        XCTAssertTrue(UpdateFeed.backgroundChecksAllowed(arguments: ["/path/Nano Cortex Editor", "-connect.atLaunch", "NO"]))
    }

    func testLaunchCheck() {
        let now = Date()
        XCTAssertTrue(UpdateFeed.shouldCheckAtLaunch(automaticChecks: true, allowed: true, lastCheck: now.addingTimeInterval(-3600), now: now), "checked an hour ago: check again at launch")
        XCTAssertTrue(UpdateFeed.shouldCheckAtLaunch(automaticChecks: true, allowed: true, lastCheck: nil, now: now))
        XCTAssertFalse(UpdateFeed.shouldCheckAtLaunch(automaticChecks: true, allowed: true, lastCheck: now.addingTimeInterval(-4), now: now), "Sparkle just checked by itself")
        XCTAssertFalse(UpdateFeed.shouldCheckAtLaunch(automaticChecks: false, allowed: true, lastCheck: nil, now: now), "the Settings switch is off")
        XCTAssertFalse(UpdateFeed.shouldCheckAtLaunch(automaticChecks: true, allowed: false, lastCheck: nil, now: now), "demo mode")
    }

    func testSwitchMirrorsAndWritesTheUpdater() {
        let fake = FakeUpdater()
        let updates = Updates()
        XCTAssertFalse(updates.automaticChecks, "off until an updater is attached")
        XCTAssertFalse(updates.canCheck)
        updates.setAutomaticChecks(true)   // no updater: nothing to write, nothing changes
        XCTAssertFalse(updates.automaticChecks)

        updates.attach(fake)
        XCTAssertTrue(updates.automaticChecks, "shows the updater's value (on by default)")
        XCTAssertTrue(updates.canCheck)

        updates.setAutomaticChecks(false)
        XCTAssertFalse(fake.automaticallyChecksForUpdates, "the switch writes through to the updater")
        XCTAssertFalse(updates.automaticChecks)
        updates.setAutomaticChecks(true)
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
        XCTAssertTrue(updates.automaticChecks)

        fake.set(false)                     // changed by the updater itself (e.g. another window)
        XCTAssertTrue(updates.automaticChecks, "not observed until refreshed")
        updates.refresh()
        XCTAssertFalse(updates.automaticChecks)
    }

    func testSwitchShowsWhatTheUpdaterKept() {
        let updates = Updates()
        updates.attach(StubbornUpdater())
        updates.setAutomaticChecks(false)
        XCTAssertTrue(updates.automaticChecks)
    }

    func testCheckForUpdatesOnlyWhenTheUpdaterCan() {
        let fake = FakeUpdater()
        let updates = Updates()
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 0, "no updater attached")
        updates.attach(fake)
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 1)
        fake.canCheckForUpdates = false     // a check is already running
        updates.refresh()
        XCTAssertFalse(updates.canCheck, "the menu item greys out")
        updates.checkForUpdates()
        XCTAssertEqual(fake.checks, 1)
    }
}
