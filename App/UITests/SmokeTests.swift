// Demo-mode smoke test: the app launched with -demo connects to the fake pedal;
// we switch a preset, select a chain stage, toggle it, and save. Developer tools are off (the default), so the
// status bar has no Record or Activity; a second launch with them on shows both.
import XCTest

@MainActor final class SmokeTests: XCTestCase {
    func testDemoRoundTrip() {
        let app = XCUIApplication()
        // `-ui.devTools NO` pins the default whatever this Mac's own setting is (argument domain, nothing is written).
        app.launchArguments = ["-demo", "-no-dev-remote", "-window", "1000x660", "-ui.devTools", "NO"]   // the CI display is 1024×768
        app.launch()
        print("UITEST screen \(XCUIScreen.main.screenshot().image.size) window \(app.windows.firstMatch.frame)")

        let chain = app.descendants(matching: .any)["node-capture"].firstMatch
        XCTAssertTrue(chain.waitForExistence(timeout: 15), "demo pedal should sync and show the chain")

        // Switch to preset 3 from the sidebar.
        let row = app.descendants(matching: .any)["preset-2"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        let name = app.descendants(matching: .any)["presetName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(5)
        func current() -> String { (name.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.label }
        while current() != "Jubilee Crunch", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertEqual(current(), "Jubilee Crunch")

        // Inspect Pre 1 and bypass it, then enable it again.
        let node = app.descendants(matching: .any)["node-pre1"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.click()
        XCTAssertTrue(app.staticTexts["Pre FX 1"].waitForExistence(timeout: 5))
        let toggle = app.descendants(matching: .any)["stageToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()
        XCTAssertTrue(app.staticTexts["Bypassed"].firstMatch.waitForExistence(timeout: 5))
        toggle.click()

        // Save (⌘S): the status line goes back to "matches".
        app.typeKey("s", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Preset matches the pedal."].waitForExistence(timeout: 5))

        // The quiet support link sits in the status bar (not clicked: it would open a browser on the runner).
        XCTAssertTrue(app.descendants(matching: .any)["supportButton"].firstMatch.waitForExistence(timeout: 5), "status bar should show ♥ Support")

        // Developer tools off: no Record or Activity in the status bar.
        XCTAssertFalse(app.descendants(matching: .any)["recordButton"].firstMatch.exists, "Record needs Developer tools")
        XCTAssertFalse(app.descendants(matching: .any)["activityButton"].firstMatch.exists, "Activity needs Developer tools")

        // The shortcuts sheet: the status bar button opens it, Done closes it; `?` opens it again.
        app.buttons["Shortcuts"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Keyboard shortcuts"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Keyboard shortcuts"].waitForNonExistence(timeout: 5))
        app.typeKey("?", modifierFlags: .shift)
        XCTAssertTrue(app.staticTexts["Keyboard shortcuts"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Keyboard shortcuts"].waitForNonExistence(timeout: 5))

        // The app menu has "Check for Updates…" (Sparkle). Not clicked: it would contact GitHub. Under -demo the
        // automatic checks are refused too, so this run makes no update request at all.
        XCTAssertTrue(app.menuBars.menuItems["Check for Updates…"].firstMatch.waitForExistence(timeout: 5), "app menu: Check for Updates…")

        // Settings (⌘,) opens on Appearance with the accent swatches; Advanced has the automatic-updates switch; ⌘W closes it.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["accent-purple"].firstMatch.exists)
        app.descendants(matching: .any)["settings-advanced"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Check for updates automatically"].firstMatch.waitForExistence(timeout: 5), "Settings → Advanced: updates switch")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Check for updates automatically"].firstMatch.waitForNonExistence(timeout: 5), "Settings closed")
    }

    /// A demo pedal on a newer firmware with an effect id the editor doesn't know: the one-time notice shows under the
    /// header (demo mode remembers it in memory only), and Post FX 2 reads "Unknown effect" with the inspector note.
    func testNewerFirmwareAndUnknownEffect() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-no-dev-remote", "-window", "1000x660", "-ui.devTools", "NO",
                               "-demo.firmware", "2.3.0", "-demo.unknownFX", "post2=7E"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        let notice = "This firmware is newer than the editor has been tested with. Some new effects may not be editable until this app is updated."
        XCTAssertTrue(app.staticTexts[notice].firstMatch.waitForExistence(timeout: 10), "newer-firmware notice")

        XCTAssertTrue(app.staticTexts["Unknown effect"].firstMatch.waitForExistence(timeout: 5), "unknown model in the chain")
        XCTAssertTrue(app.staticTexts["Newer firmware?"].firstMatch.exists)
        app.descendants(matching: .any)["node-post2"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["unknownEffectNote"].firstMatch.waitForExistence(timeout: 5), "inspector note instead of knobs")

        app.descendants(matching: .any)["firmwareNoticeDismiss"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[notice].firstMatch.waitForNonExistence(timeout: 5), "dismissed")
        app.terminate()
    }

    func testDeveloperToolsShowRecordAndActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-no-dev-remote", "-window", "1000x660", "-ui.devTools", "YES"]
        app.launch()
        app.activate()
        // A second launch in the same run is slower on CI runners: give the demo sync more time (flaked at 15 s).
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        XCTAssertTrue(app.descendants(matching: .any)["recordButton"].firstMatch.waitForExistence(timeout: 10), "Record with Developer tools on")
        XCTAssertTrue(app.descendants(matching: .any)["activityButton"].firstMatch.waitForExistence(timeout: 10), "Activity with Developer tools on")
        app.terminate()
    }
}
