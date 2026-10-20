// Demo-mode smoke test: the app launched with -demo connects to the fake pedal;
// we switch a preset, select a chain stage, toggle it, and save. Developer tools are off (the default), so the
// status bar has no Record or Activity; a second launch with them on shows both.
import XCTest

@MainActor final class SmokeTests: XCTestCase {
    /// Every launch: demo pedal, no dev remote, a window that fits the CI display (1024×768), and no window
    /// restoration. Each launch is killed by the next one, and AppKit saves the window state about 30 s into a run;
    /// restoring that state gave the next launch no window at all (seen 2026-10-20), so each test starts fresh.
    static let base = ["-demo", "-no-dev-remote", "-window", "1000x660", "-ApplePersistenceIgnoreState", "YES"]

    func testDemoRoundTrip() {
        let app = XCUIApplication()
        // `-ui.devTools NO` pins the default whatever this Mac's own setting is (argument domain, nothing is written).
        app.launchArguments = Self.base + ["-ui.devTools", "NO"]
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
        // Metronome → Sounds: one row per role with its sound menu and ▶ (picking a sample needs the open panel: not on CI).
        app.descendants(matching: .any)["settings-metronome"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Main beat"].firstMatch.waitForExistence(timeout: 5), "Settings → Metronome → Sounds")
        for role in ["accent", "main", "sub"] {
            XCTAssertTrue(app.descendants(matching: .any)["sound-\(role)"].firstMatch.exists, "sound menu: \(role)")
            XCTAssertTrue(app.descendants(matching: .any)["sound-\(role)-play"].firstMatch.exists, "▶: \(role)")
        }
        app.descendants(matching: .any)["settings-appearance"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForNonExistence(timeout: 5))
    }

    /// Updates (Sparkle): "Check for Updates…" in the app menu and the Settings → Advanced switch. Under -demo the
    /// updater is not started (no check, no Sparkle window), so the item exists but is greyed out.
    func testUpdatesMenuAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        XCTAssertTrue(app.menuBars.menuItems["Check for Updates…"].firstMatch.waitForExistence(timeout: 5), "app menu: Check for Updates…")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings-advanced"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Check for updates automatically"].firstMatch.waitForExistence(timeout: 5), "Settings → Advanced: updates switch")
        XCTAssertTrue(app.descendants(matching: .any)["settings-auto-updates"].firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Check for updates automatically"].firstMatch.waitForNonExistence(timeout: 5), "Settings closed")
        app.terminate()
    }

    /// A demo pedal on a newer firmware with an effect id the editor doesn't know: the one-time notice shows under the
    /// header (demo mode remembers it in memory only), and Post FX 2 reads "Unknown effect" with the inspector note.
    func testNewerFirmwareAndUnknownEffect() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "NO",
                               "-demo.firmware", "2.3.0", "-demo.unknownFX", "post2=7E"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        let notice = "This firmware is newer than the editor has been tested with. Some new effects may not be editable until this app is updated."
        XCTAssertTrue(app.staticTexts[notice].firstMatch.waitForExistence(timeout: 10), "newer-firmware notice")

        XCTAssertTrue(app.staticTexts["Unknown effect"].firstMatch.waitForExistence(timeout: 5), "unknown model in the chain")
        XCTAssertTrue(app.staticTexts["Newer firmware?"].firstMatch.exists)
        XCTAssertTrue(clickSettled(app.descendants(matching: .any)["node-post2"].firstMatch,
                                   until: app.descendants(matching: .any)["unknownEffectNote"].firstMatch), "inspector note instead of knobs")

        app.descendants(matching: .any)["firmwareNoticeDismiss"].firstMatch.click()
        XCTAssertTrue(app.staticTexts[notice].firstMatch.waitForNonExistence(timeout: 5), "dismissed")
        app.terminate()
    }

    /// Ported from the Electron edition's #14: the header's Mute (Mute Input) turns on and off, Settings → Device has
    /// both Monitoring switches, and a preset row dragged onto another moves that preset there (the demo pedal answers
    /// 143 with 144, and the list is read back from it).
    func testMuteMonitoringAndPresetMove() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")

        let mute = app.descendants(matching: .any)["muteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 10), "header Mute beside Tuner")
        XCTAssertTrue(waitFor(10) { mute.isEnabled }, "Mute is ready once the pedal's settings were read at connect")
        mute.click()
        XCTAssertTrue(waitFor(5) { (mute.value as? String) == "on" }, "Mute Input on")
        mute.click()
        XCTAssertTrue(waitFor(5) { (mute.value as? String) == "off" }, "Mute Input off again")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ACCENT COLOUR"].waitForExistence(timeout: 5))
        app.descendants(matching: .any)["settings-device"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Mute Guitar Input"].firstMatch.waitForExistence(timeout: 5), "Settings → Device → Monitoring")
        XCTAssertTrue(app.staticTexts["Mute Guitar Output"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["device-mute-input"].firstMatch.exists, "Mute Input switch")
        XCTAssertTrue(app.descendants(matching: .any)["device-mute-output"].firstMatch.exists, "Mute Outputs 1L/2R switch")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Mute Guitar Input"].firstMatch.waitForNonExistence(timeout: 5), "Settings closed")

        // Drag "5 VH4 Ambient Lead" onto "2 JP2C Lead": it becomes preset 2 and 2…4 shift down by one.
        let from = app.descendants(matching: .any)["preset-4"].firstMatch, to = app.descendants(matching: .any)["preset-1"].firstMatch
        XCTAssertTrue(from.waitForExistence(timeout: 5) && to.exists, "preset rows")
        XCTAssertTrue(from.label.contains("VH4 Ambient Lead"), from.label)
        XCTAssertTrue(app.staticTexts["Preset 2"].firstMatch.exists, "the current preset is 2, JP2C Lead")
        from.click(forDuration: 0.6, thenDragTo: to)
        XCTAssertTrue(waitFor(10) { to.label.contains("VH4 Ambient Lead") }, "the dragged preset is now in row 2: \(to.label)")
        XCTAssertTrue(app.descendants(matching: .any)["preset-2"].firstMatch.label.contains("JP2C Lead"), "the one it was dropped on moved down")
        XCTAssertTrue(app.staticTexts["Preset 3"].firstMatch.waitForExistence(timeout: 5), "the current preset moved with it (read back from the pedal)")
        app.terminate()
    }

    /// Polls `condition` (UI state that changes after an async round trip) until it holds or `seconds` pass.
    private func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func testDeveloperToolsShowRecordAndActivity() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "YES"]
        app.launch()
        app.activate()
        // A second launch in the same run is slower on CI runners: give the demo sync more time (flaked at 15 s).
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        XCTAssertTrue(app.descendants(matching: .any)["recordButton"].firstMatch.waitForExistence(timeout: 10), "Record with Developer tools on")
        XCTAssertTrue(app.descendants(matching: .any)["activityButton"].firstMatch.waitForExistence(timeout: 10), "Activity with Developer tools on")
        app.terminate()
    }

    /// Clicks `element` once its frame has stopped moving, and again (up to three times) until `done` appears. The
    /// chain can still shift while the firmware notice settles; a click on the frame read a moment earlier once
    /// selected Post FX 3 instead of Post FX 2 (CI, 2026-10-20).
    private func clickSettled(_ element: XCUIElement, until done: XCUIElement) -> Bool {
        for _ in 0..<3 {
            var last = element.frame
            for _ in 0..<10 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                let now = element.frame
                if now == last { break }
                last = now
            }
            element.click()
            if done.waitForExistence(timeout: 3) { return true }
        }
        return false
    }
}
