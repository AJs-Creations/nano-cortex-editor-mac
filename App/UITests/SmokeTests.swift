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
        XCTAssertTrue(app.staticTexts["Preset 2"].firstMatch.exists, "the current preset is 2, JP2C Lead")
        from.click(forDuration: 0.6, thenDragTo: to)
        // The current preset (JP2C Lead) moved down one place, as the pedal's state read says.
        XCTAssertTrue(app.staticTexts["Preset 3"].firstMatch.waitForExistence(timeout: 10), "the current preset moved with it (read back from the pedal)")
        // Row 2 now loads the dragged preset.
        let name = app.descendants(matching: .any)["presetName"].firstMatch
        func current() -> String { (name.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.label }
        XCTAssertEqual(current(), "JP2C Lead")
        to.click()
        XCTAssertTrue(waitFor(5) { current() == "VH4 Ambient Lead" }, "row 2 is the moved preset: \(current())")
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

    /// The Cab / IR inspector's "From the library": the search box and the demo pedal's factory cabs and IRs, each with
    /// its ▶ audition button (the audition itself is checked over the dev remote and in the core tests).
    func testCabLibrarySection() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        XCTAssertTrue(clickSettled(app.descendants(matching: .any)["node-cab"].firstMatch,
                                   until: app.descendants(matching: .any)["cabLibrary"].firstMatch), "Cab / IR inspector with its library section")
        XCTAssertTrue(app.staticTexts["FROM THE LIBRARY"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["cab-lib-search"].firstMatch.exists, "search box")
        XCTAssertTrue(app.descendants(matching: .any)["libitem-factory-0"].firstMatch.waitForExistence(timeout: 10), "the library is read and listed")
        XCTAssertTrue(app.descendants(matching: .any)["libpreview-factory-0"].firstMatch.exists, "▶ on a factory cab")
        XCTAssertTrue(app.descendants(matching: .any)["libpreview-user-0"].firstMatch.exists, "▶ on one of your IRs")
        app.terminate()
    }

    /// Capture Info on a capture whose description is its Cortex Cloud ID (the demo pedal's slot 3): no ID text, an
    /// "Open in Cortex Cloud" button that switches to the Cortex Cloud tab. Nothing is written to the pedal.
    func testOpenInCortexCloudFromCaptureInfo() {
        let app = XCUIApplication()
        app.launchArguments = Self.base + ["-ui.devTools", "NO"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 40), "demo pedal should sync")
        let slot = app.descendants(matching: .any)["slot-capture-3"].firstMatch
        XCTAssertTrue(clickSettled(app.descendants(matching: .any)["node-capture"].firstMatch, until: slot), "Capture inspector with its slots")
        slot.rightClick()
        let info = app.menuItems["Info…"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "the slot's context menu")
        info.click()
        let open = app.descendants(matching: .any)["captureInfo-cloud"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Open in Cortex Cloud in place of the description")
        XCTAssertFalse(app.staticTexts["00000000-0000-4000-8000-00000000c10d"].exists, "the bare ID isn't shown")
        open.click()
        XCTAssertTrue(app.buttons["Send to Nano Cortex"].firstMatch.waitForExistence(timeout: 10), "the Cortex Cloud tab is showing")
        XCTAssertTrue(open.waitForNonExistence(timeout: 5), "the popover closed")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["node-capture"].firstMatch.waitForExistence(timeout: 10), "back on the editor")
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
