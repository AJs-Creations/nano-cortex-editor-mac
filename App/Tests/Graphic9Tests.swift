// The Graphic 9 fader bank's pure rules (Graphic9Math.swift, compiled into this bundle); Electron: pro/ui.js
// `graphic9BandSection` and the UX test's "Graphic 9: …" checks.
import XCTest
import NanoCore

final class Graphic9Tests: XCTestCase {
    private let g9 = Models.pre1.first { $0.name == "Graphic 9" }!
    private var band: ParamMeta? { g9.params[0].meta }

    func testTheBandsAreTheFaderBankAndTheRestStayKnobs() {
        XCTAssertTrue(Graphic9.isBank(g9))
        XCTAssertFalse(Graphic9.isBank(Models.pre1.first { $0.name == "Parametric 3" }!))
        XCTAssertEqual(g9.params.prefix(Graphic9.bandCount).map { Graphic9.label($0.name) }, ["65 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"])
        XCTAssertEqual(g9.params.dropFirst(Graphic9.bandCount).map(\.name), ["HPF", "LPF", "Output"])
    }

    func testReadoutAndTypedValues() {
        XCTAssertEqual(Graphic9.readout(3.5), "+3.5")
        XCTAssertEqual(Graphic9.readout(0), "0.0")
        XCTAssertEqual(Graphic9.readout(-0.0), "0.0")
        XCTAssertEqual(Graphic9.readout(-6.2), "-6.2")
        XCTAssertEqual(Graphic9.typed("3.46", meta: band), 3.5, "0.1 dB steps")
        XCTAssertEqual(Graphic9.typed("-2,5", meta: band), -2.5)
        XCTAssertEqual(Graphic9.typed("+1 dB", meta: band), 1)
        XCTAssertEqual(Graphic9.typed("40", meta: band), 12, "clamped to the band's range")
        XCTAssertNil(Graphic9.typed("", meta: band), "empty: nothing changes")
        XCTAssertNil(Graphic9.typed("loud", meta: band))
    }

    func testFaderPositions() {
        // An HTML range input: the thumb's centre travels from 12 to 252 on a 264-point track with a 24-point thumb.
        XCTAssertEqual(Graphic9.value(atY: 12, length: 264, thumb: 24, meta: band), 12)
        XCTAssertEqual(Graphic9.value(atY: 252, length: 264, thumb: 24, meta: band), -12)
        XCTAssertEqual(Graphic9.value(atY: 132, length: 264, thumb: 24, meta: band), 0)
        XCTAssertEqual(Graphic9.value(atY: -50, length: 264, thumb: 24, meta: band), 12, "clamped")
        XCTAssertEqual(Graphic9.y(of: 0, length: 264, thumb: 24, meta: band), 132)
        XCTAssertEqual(Graphic9.y(of: 6, length: 264, thumb: 24, meta: band), 72)
        for v in stride(from: -12.0, through: 12, by: 0.1) {
            let r = FXParams.roundToStep(v, 0.1)
            XCTAssertEqual(Graphic9.value(atY: Graphic9.y(of: r, length: 264, thumb: 24, meta: band), length: 264, thumb: 24, meta: band), r, accuracy: 1e-9)
        }
    }
}
