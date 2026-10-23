// Capture kind words → icons (CaptureKind.swift, compiled into this bundle). A real pedal reports combos as
// "amp_combo"; the table only knew "combo", so those captures had no icon.
import XCTest

final class CaptureKindTests: XCTestCase {
    func testAmpComboIsACombo() {
        XCTAssertEqual(CaptureKind.icons(type: "amp_combo", instrument: "guitar"), [.init(key: "combo", label: "Combo"), .init(key: "guitar", label: "Guitar")])
        XCTAssertEqual(CaptureKind.icons(type: "amp_combo", instrument: "guitar"), CaptureKind.icons(type: "combo", instrument: "guitar"))
        XCTAssertNotNil(CaptureKind.image("combo"))
    }

    func testKnownAndBlankWords() {
        XCTAssertEqual(CaptureKind.icons(type: "amp_head", instrument: "bass").map(\.label), ["Amp head", "Bass"])
        XCTAssertEqual(CaptureKind.icons(type: "default", instrument: "instrument_not_set"), [])
        XCTAssertEqual(CaptureKind.icons(type: "mystery_box", instrument: ""), [], "unknown words get no icon")
    }
}
