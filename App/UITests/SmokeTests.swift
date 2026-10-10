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

        // Settings (⌘,) opens on Appearance with the accent swatches; ⌘W closes it.
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["accent-purple"].firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForNonExistence(timeout: 5))
    }

    func testDeveloperToolsShowRecordAndActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-no-dev-remote", "-window", "1000x660", "-ui.devTools", "YES"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 15), "demo pedal should sync")
        XCTAssertTrue(app.descendants(matching: .any)["recordButton"].firstMatch.waitForExistence(timeout: 5), "Record with Developer tools on")
        XCTAssertTrue(app.descendants(matching: .any)["activityButton"].firstMatch.exists, "Activity with Developer tools on")
        app.terminate()
    }
}
