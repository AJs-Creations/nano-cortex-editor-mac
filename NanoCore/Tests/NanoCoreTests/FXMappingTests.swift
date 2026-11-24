import XCTest
@testable import NanoCore

/// Electron #31 (from @itsbreaded): wire order, value curves, Cab/IR curves, saved values for effects that are off and
/// the FX read drain. Expected numbers come from the Electron edition's pro/core.js (`normalizedToParamValue`,
/// `paramValueToNormalized`, `cabIR…`), and the checks mirror its UX test after "FX parameter companion report does not
/// trigger a full preset refresh".
final class FXMappingTests: XCTestCase {
    private func model(_ name: String, _ list: [ModelDef] = Models.pre1) -> ModelDef { list.first { $0.name == name }! }
    private func param(_ model: ModelDef, _ name: String) -> ParamDef { model.params.first { $0.name == name }! }
    private var g9: ModelDef { model("Graphic 9") }
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    // MARK: metadata

    func testGraphic9WireOrderIsHPFFirst() {
        XCTAssertEqual(g9.params.map(\.name), ["65Hz", "125Hz", "250Hz", "500hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz", "HPF", "LPF", "Output"])
        XCTAssertEqual(g9.params.map(\.wireIndex), [1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 10, 11])
        for list in [Models.pre1, Models.post1, Models.post2, Models.post3] { XCTAssertEqual(model("Graphic 9", list).params.map(\.wireIndex), g9.params.map(\.wireIndex)) }
        XCTAssertEqual(g9.param(wire: 0)?.def.name, "HPF")
        XCTAssertEqual(g9.param(wire: 1)?.index, 0)
        // NanOS 2.3.0 sweep (DECISIONS #40): the classic reverbs keep Mix first in the UI, but it is their last wire index.
        let reverbs: [String: [Int]] = ["Hall": [4, 0, 1, 2, 3], "Room": [4, 0, 1, 2, 3], "Ambience": [4, 0, 1, 2, 3],
                                        "Cave": [5, 0, 1, 2, 3, 4], "Modulated": [6, 0, 1, 2, 3, 4, 5]]
        for (name, wires) in reverbs {
            let m = model(name, Models.post3)
            XCTAssertEqual(m.params.first?.name, "Mix", name)
            XCTAssertEqual(m.params.map(\.wireIndex), wires, name)
            XCTAssertEqual(m.param(wire: wires.count - 1)?.def.name, "Mix", name)
        }
        // Every other model's wire order is its UI order (Mind Hall, Blossom and Shimmer included).
        for m in Models.pre1 + Models.post1 + Models.post2 + Models.post3 where m.name != "Graphic 9" && reverbs[m.name] == nil {
            XCTAssertEqual(m.params.map(\.wireIndex), m.params.map(\.index), m.name)
        }
    }

    func testRangesAndCurves() {
        // NanOS 2.3.0: HPF 20–500 Hz skew 0.6 (sweep of 2026-11-24), LPF 1000–20000 Hz skew 0.6.
        XCTAssertEqual(param(g9, "HPF").meta, .range(min: 20, max: 500, step: 1, unit: "Hz", decimals: 0, skew: 0.6))
        XCTAssertEqual(param(g9, "LPF").meta, .range(min: 1000, max: 20000, step: 1, unit: "Hz", decimals: 0, skew: 0.6))
        for name in ["Graphic 9", "Low-High Cut", "Parametric 3"] {
            XCTAssertEqual(param(model(name), "Output").meta, .range(min: -20, max: 20, step: 0.1, unit: "dB", decimals: 1), name)
        }
        // Electron: "Parametric 3: band frequencies are 20 Hz to 20 kHz, not the Q range".
        let p3 = model("Parametric 3")
        XCTAssertEqual(param(p3, "2 Freq").meta, .range(min: 20, max: 20000, step: 1, unit: "Hz", decimals: 0, curve: .power(10.0 / 3)))
        if case .range(_, let hi, _, _, _, _, _)? = param(p3, "2 Q").meta { XCTAssertEqual(hi, 10) } else { XCTFail("Q") }
        let lhc = model("Low-High Cut")
        // NanOS 2.3.0 (handoff item 3): both 20–20000 Hz, skew 0.3.
        XCTAssertEqual(param(lhc, "HPF Freq").meta, .range(min: 20, max: 20000, step: 1, unit: "Hz", decimals: 0, skew: 0.3))
        XCTAssertEqual(param(lhc, "LPF Freq").meta, .range(min: 20, max: 20000, step: 1, unit: "Hz", decimals: 0, skew: 0.3))
        XCTAssertEqual(param(model("Envelope Filter"), "Sens").meta, .range(min: 0, max: 54, step: 0.1, unit: "dB", decimals: 1))
    }

    func testDisplayValuesMatchElectron() {
        func v(_ m: ModelDef, _ p: String, _ n: Double) -> Double { FXParams.value(n, meta: param(m, p).meta) }
        let lhc = model("Low-High Cut"), p3 = model("Parametric 3"), ef = model("Envelope Filter"), tr = model("Transpose")
        // Electron: "Low-High Cut: Cortex Cloud's 665 Hz high pass reads back as 665 Hz (wire 0.357)" (still so with
        // NanOS 2.3.0's 20–20000 Hz, skew 0.3).
        XCTAssertEqual(v(lhc, "HPF Freq", 0.357), 665)
        XCTAssertEqual(v(lhc, "LPF Freq", 0.863), 12246)
        XCTAssertEqual(v(g9, "LPF", 0.615), 9450)
        XCTAssertEqual(v(g9, "HPF", 0), 20)
        XCTAssertEqual(v(g9, "HPF", 0.5), 171)
        XCTAssertEqual(v(p3, "2 Freq", 0.5), 2002)
        XCTAssertEqual(v(ef, "Freq", 0.5), 1010)
        XCTAssertEqual(v(ef, "Attack", 0.5), 505)
        XCTAssertEqual(v(tr, "High Pass", 0.5), 216)
        XCTAssertEqual(v(tr, "Low Pass", 0.5), 2154)
        XCTAssertEqual(v(model("Hall", Models.post3), "Low Pass", 0.5), 4328)
        XCTAssertEqual(Double(FXParams.normalized(665, meta: param(lhc, "HPF Freq").meta)), 0.3570173065587045, accuracy: 1e-6)
        XCTAssertEqual(Double(FXParams.normalized(1000, meta: param(p3, "1 Freq").meta)), 0.4047521622867309, accuracy: 1e-6)
        // Every curve round-trips on its step.
        for (m, p, x) in [(lhc, "HPF Freq", 665.0), (lhc, "LPF Freq", 12205), (g9, "LPF", 9451), (p3, "3 Freq", 440), (ef, "Decay", 250.5), (tr, "Low Pass", 2154)] {
            XCTAssertEqual(FXParams.value(Double(FXParams.normalized(x, meta: param(m, p).meta)), meta: param(m, p).meta), x, accuracy: 1, "\(m.name) \(p)")
        }
    }

    // MARK: value scaling (NanOS 2.3.0: upstream's PARAM_SKEW next to #31's fitted curves)

    /// Expected numbers: the Electron edition's pro/core.js (feature/nanos-2.3, upstream V1.18.0 plus editor/patches)
    /// evaluated in node's vm sandbox the way scripts/gen-models.js loads it, then `normalizedToParamValue(param, n)`
    /// for the value, `paramValueToNormalized({...param, value})` for the travel, and normalizedToParamValue of that
    /// travel (as a Float32, like the wire) for the round trip. Each row: travel in, value shown, travel written back.
    private func assertScaling(_ m: ModelDef, _ p: String, _ rows: [(n: Double, value: Double, travel: Double)], file: StaticString = #filePath, line: UInt = #line) {
        let meta = param(m, p).meta
        for r in rows {
            let v = FXParams.value(r.n, meta: meta)
            XCTAssertEqual(v, r.value, "\(m.name) \(p) at \(r.n)", file: file, line: line)
            let t = FXParams.normalized(r.value, meta: meta)
            XCTAssertEqual(Double(t), r.travel, accuracy: 1e-6, "\(m.name) \(p) travel of \(r.value)", file: file, line: line)
            XCTAssertEqual(FXParams.value(Double(t), meta: meta), r.value, "\(m.name) \(p) round trip of \(r.value)", file: file, line: line)
        }
    }

    func testSkewMetadata() {
        // Skew only (no fitted curve): upstream's value wins.
        XCTAssertEqual(param(model("Tremolo", Models.post1), "Rate").meta, .range(min: 0.1, max: 20, step: 0.1, unit: "Hz", decimals: 1, skew: 0.6))
        XCTAssertEqual(param(model("Hall", Models.post3), "Decay").meta, .range(min: 1, max: 10, step: 0.01, unit: "s", decimals: 2, skew: 0.6))
        // Both upstream's skew and a #31 fit: the generator keeps only the skew, which wins (NanOS 2.3.0, DECISIONS #40).
        XCTAssertEqual(param(model("Analog Delay", Models.post2), "High Pass").meta, .range(min: 20, max: 800, step: 1, unit: "Hz", decimals: 0, skew: 0.6))
        // A fit without a skew stays (Parametric 3, Envelope Filter Reso and Freq).
        XCTAssertEqual(param(model("Envelope Filter"), "Freq").meta, .range(min: 20, max: 10000, step: 1, unit: "Hz", decimals: 0, curve: .power(10.0 / 3)))
        // Dual Reverse Delay Low Pass is measured now: 1000–20000 Hz, skew 0.6 (sweep of 2026-11-24).
        XCTAssertEqual(param(model("Dual Reverse Delay", Models.post2), "Low Pass").meta, .range(min: 1000, max: 20000, step: 1, unit: "Hz", decimals: 0, skew: 0.6))
        // Neither: linear, as before.
        XCTAssertEqual(param(model("Green 808"), "Overdrive").meta, .range(min: 0, max: 10, step: 0.1, unit: "", decimals: 1))
        // A switch never carries a skew (Blossom's "Extra E.R." is an Off/On picker).
        XCTAssertEqual(param(model("Blossom (ST)", Models.post3), "Extra E.R.").meta, .options(["Off", "On"]))
    }

    func testShareAndTravelPrecedence() {
        // The skew beats a fitted curve in both directions (share = travel^(1/skew)); a curve applies only without a
        // skew; else linear (Electron's travelToShare / shareToTravel since editor/patches/0002).
        XCTAssertEqual(FXParams.share(travel: 0.5, curve: .power(2), skew: 0.5), 0.25, accuracy: 1e-12)
        XCTAssertEqual(FXParams.share(travel: 0.25, curve: .reversePower(2), skew: 2), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FXParams.share(travel: 0.5, curve: .power(2), skew: nil), 0.25, accuracy: 1e-12)
        XCTAssertEqual(FXParams.share(travel: 0.5, curve: .reversePower(2), skew: nil), 0.75, accuracy: 1e-12)
        XCTAssertEqual(FXParams.share(travel: 0.5, curve: .linear, skew: 0.5), 0.25, accuracy: 1e-12)
        XCTAssertEqual(FXParams.share(travel: 0.5, curve: .linear, skew: nil), 0.5)
        XCTAssertEqual(FXParams.travel(share: 0.25, curve: .linear, skew: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FXParams.travel(share: 0.25, curve: .power(2), skew: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FXParams.travel(share: 0.25, curve: .power(2), skew: nil), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FXParams.travel(share: 0.75, curve: .reversePower(2), skew: nil), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FXParams.travel(share: 2, curve: .linear, skew: 0.6), 1, "clamped")
        for n in stride(from: 0.0, through: 1.0, by: 0.125) {
            for (c, k) in [(ParamCurve.linear, 0.6), (.linear, 2.375), (.power(1.98), 0.3), (.reversePower(3.98), 0.3)] as [(ParamCurve, Double?)] {
                XCTAssertEqual(FXParams.travel(share: FXParams.share(travel: n, curve: c, skew: k), curve: c, skew: k), n, accuracy: 1e-9)
            }
        }
    }

    func testFitOnlyParameterMatchesElectron() {
        // Parametric 3 "1 Freq": normalizedPower 10/3, no skew. Unchanged by NanOS 2.3.0.
        assertScaling(model("Parametric 3"), "1 Freq", [(0.25, 217, 0.25012737345710895), (0.5, 2002, 0.4999797900915324), (0.75, 7678, 0.7499908473574899)])
    }

    func testSkewOnlyParametersMatchElectron() {
        assertScaling(model("Tremolo", Models.post1), "Rate", [(0.25, 2.1, 0.25194523646498795), (0.5, 6.4, 0.5015248813262644), (0.75, 12.4, 0.7492577107018852)])
        assertScaling(model("Hall", Models.post3), "Decay", [(0.25, 1.89, 0.24951031145807026), (0.5, 3.83, 0.4994894913722434), (0.75, 6.57, 0.7498382862469055)])
        assertScaling(model("Analog Delay", Models.post2), "Delay Time", [(0.25, 289.3, 0.25001459938996184), (0.5, 483.5, 0.5000187985863994), (0.75, 757.2, 0.7499998197004604)])
        // New in 2.3.0: Blossom's skews (2.375 bends the other way) and Shimmer's.
        assertScaling(model("Blossom (ST)", Models.post3), "Bass", [(0.25, -4.6, 0.25053718708101674), (0.5, -0.1, 0.4983382806916364), (0.75, 3.3, 0.7531818728195121)])
        assertScaling(model("Blossom (ST)", Models.post3), "Decay", [(0.25, 1.11, 0.2501025325616298), (0.5, 3.95, 0.5001655707823197), (0.75, 10, 0.7500247546583937)])
        assertScaling(model("Shimmer", Models.post3), "Pre Delay", [(0.25, 21, 0.25194523646498795), (0.5, 64, 0.5015248813262644), (0.75, 124, 0.7492577107018851)])
    }

    /// NanOS 2.3.0, measured in the official app (handoff "Model corrections" item 2): the skew wins where both exist.
    func testSkewWinsOverTheFittedCurve() {
        let ad = model("Analog Delay", Models.post2), lhc = model("Low-High Cut")
        // App: Analog Delay 99 Hz / 2490 Hz at 0.253 / 0.25 (#31 gave 28 / 1148); the skew gives 99 / 2488.
        XCTAssertEqual(FXParams.value(0.253, meta: param(ad, "High Pass").meta), 99)
        XCTAssertEqual(FXParams.value(0.25, meta: param(ad, "Low Pass").meta), 2488)
        assertScaling(ad, "High Pass", [(0.25, 97, 0.24925143853612386), (0.5, 266, 0.5003850233214896), (0.75, 503, 0.7500867896460977)])
        assertScaling(ad, "Low Pass", [(0.25, 2488, 0.24998100129821407), (0.5, 5725, 0.5000187985863994), (0.75, 10287, 0.7500159717701458)])
        // Low-High Cut: 20–20000 Hz, skew 0.3 → 217 / 2002 / 7678 Hz at 0.25 / 0.5 / 0.75 (both filters); 86 Hz at 0.18, 568 Hz at 0.34.
        for p in ["HPF Freq", "LPF Freq"] {
            assertScaling(lhc, p, [(0.25, 217, 0.25012737345710895), (0.5, 2002, 0.4999797900915324), (0.75, 7678, 0.7499908473574899)])
        }
        XCTAssertEqual(FXParams.value(0.18, meta: param(lhc, "HPF Freq").meta), 86)
        XCTAssertEqual(FXParams.value(0.34, meta: param(lhc, "LPF Freq").meta), 568)
        // Other delays the app agreed with the skew on.
        func v(_ m: String, _ p: String, _ t: Double) -> Double { FXParams.value(t, meta: param(model(m, Models.post2), p).meta) }
        XCTAssertEqual([v("Dual Delay", "High Pass", 0.329), v("Dual Delay", "Low Pass", 0.367), v("Dual Reverse Delay", "High Pass", 0.71), v("Tape Delay", "Low Pass", 0.5)], [142, 3822, 461, 2438])
    }

    /// The other corrected ranges (handoff items 4–9), as Electron's checks give them.
    func testNanOS23CorrectedRanges() {
        func v(_ m: String, _ list: [ModelDef], _ p: String, _ t: Double) -> Double { FXParams.value(t, meta: param(model(m, list), p).meta) }
        // Graphic 9: LPF 6985 Hz at 0.5, 14.8 kHz at 0.827; HPF 30 Hz at 0.1 (the app read 29).
        XCTAssertEqual(v("Graphic 9", Models.pre1, "LPF", 0.5), 6985)
        XCTAssertEqual((v("Graphic 9", Models.pre1, "LPF", 0.827) / 100).rounded(), 148)
        XCTAssertEqual(v("Graphic 9", Models.pre1, "HPF", 0.1), 30)
        // Blossom E.R. Length is linear: 50 % at 0.5 and at 0.504 (skew 0.4 gave 18 %).
        XCTAssertEqual([v("Blossom (ST)", Models.post3, "E.R. Length", 0.5), v("Blossom (ST)", Models.post3, "E.R. Length", 0.504)], [50, 50])
        // Envelope Filter: Attack / Decay 10–1000 ms and Freq Depth −10000…+10000 Hz linear; Level −60…+12 dB (skew 3.8).
        let ef = { (p: String, t: Double) in v("Envelope Filter", Models.pre1, p, t) }
        XCTAssertEqual([ef("Attack", 0.18), ef("Freq Depth", 0.58), ef("Decay", 0.26), ef("Decay", 0.5), ef("Level", 0), ef("Level", 1), ef("Freq Depth", 0), ef("Freq Depth", 1)],
                       [188.2, 1600, 267.4, 505, -60, 12, -10000, 10000])
        // Dyn Depth 0–60 dB, skew 0.6: 15.4 dB at 0.443, 20.1 dB at 0.519, in all three delays.
        for m in ["Digital Delay (ST)", "Dual Delay", "Dual Reverse Delay"] {
            XCTAssertEqual(v(m, Models.post2, "Dyn Depth", 0.443), 15.4, m)
            XCTAssertEqual(v(m, Models.post2, "Dyn Depth", 0.519), 20.1, m)
            if case .range(_, _, _, let unit, _, _, _)? = param(model(m, Models.post2), "Dyn Depth").meta { XCTAssertEqual(unit, "dB", m) } else { XCTFail(m) }
        }
        XCTAssertEqual(v("Dual Reverse Delay", Models.post2, "Trig Threshold", 0.405), -23.8)
        // Circular Delay: Feedback 0–95 %; Delay Time linear; High / Low Pass two-point fits (±1 %).
        XCTAssertEqual(v("Circular Delay", Models.post2, "Feedback", 0.318), 30.21)
        XCTAssertEqual(v("Circular Delay", Models.post2, "Delay Time", 0.245), 510.4, accuracy: 0.05)
        for (p, t, hz) in [("High Pass", 0.464, 3630.0), ("High Pass", 0.499, 4098), ("Low Pass", 0.536, 7183), ("Low Pass", 0.5, 6416)] {
            XCTAssertEqual(v("Circular Delay", Models.post2, p, t), hz, accuracy: hz * 0.01, "\(p) at \(t)")
        }
        // Room Pre Delay 0.1–100 ms (Hall 1–100).
        if case .range(let lo, let hi, _, _, _, _, let k)? = param(model("Room", Models.post3), "Pre Delay").meta { XCTAssertEqual([lo, hi, k ?? 0], [0.1, 100, 0.6]) } else { XCTFail("Room") }
    }

    /// Second NanOS 2.3.0 sweep (2026-11-24): Cal presets at 0 / 0.25 / 0.5 / 0.75 / 1, each control read in Cortex Cloud.
    /// Same table as Electron's check "NanOS 2.3.0 sweep of 2026-11-24".
    func testNanOS23Sweep20261124() {
        let sweep: [(String, [ModelDef], String, [Double])] = [
            ("Envelope Filter", Models.pre1, "Freq", [20, 118, 1010, 3845, 10000]), ("Envelope Filter", Models.pre1, "Level", [-60, -10, 0, 6.8, 12]),
            ("Graphic 9", Models.pre1, "HPF", [20, 67, 171, 317, 500]), ("Circular Delay", Models.post2, "High Pass", [20, 1308, 4108, 8056, 13000]),
            ("Circular Delay", Models.post2, "Low Pass", [170, 2137, 6416, 12400, 20000]), ("Circular Delay", Models.post2, "Mod Rate", [0.01, 0.11, 1, 3.84, 10]),
            ("Room", Models.post3, "Pre Delay", [0.1, 10, 31.6, 61.9, 100]), ("Mind Hall", Models.post3, "Pre Delay", [1, 13.4, 50.8, 112.9, 200]), ("Dual Reverse Delay", Models.post2, "Low Pass", [1000, 2885, 6985, 12700, 20000]),
        ]
        for (m, list, p, want) in sweep {
            for (i, t) in [0, 0.25, 0.5, 0.75, 1].enumerated() {
                let got = FXParams.value(t, meta: param(model(m, list), p).meta)
                XCTAssertEqual(got, want[i], accuracy: max(abs(want[i]) * 0.012, want[i] == want[i].rounded() ? 1 : 0.06), "\(m) \(p) at \(t)")
            }
        }
        // Mind Hall Decay is 0–100 % (it fell into the Hall seconds range); Shimmer Decay has two decimals.
        XCTAssertEqual(FXParams.value(0.23, meta: param(model("Mind Hall", Models.post3), "Decay").meta), 23)
        XCTAssertEqual(FXParams.value(0.86, meta: param(model("Shimmer", Models.post3), "Decay").meta), 16.44)
    }

    // MARK: the classic reverbs' wire order (NanOS 2.3.0 sweep presets, read in the official app)

    /// The pedal's floats in wire order through the real read path → the values the UI shows, by name.
    private func readback(_ name: String, _ floats: [Float]) -> [String: Double] {
        let m = model(name, Models.post3)
        var b = FXSlotState(model: m, on: true)
        b.applyRead(floats, preset: 0)
        return Dictionary(uniqueKeysWithValues: zip(m.params.map(\.name), b.values))
    }

    func testClassicReverbsReadMixFromTheLastWireIndex() {
        let sweep: [Float] = [0.10, 0.18, 0.26, 0.34, 0.42, 0.50, 0.58]
        XCTAssertEqual(readback("Hall", Array(sweep.prefix(5))), ["Mix": 42, "Decay": 1.19, "Pre Delay": 6.7, "High Pass": 103, "Low Pass": 2655])
        let room = readback("Room", Array(sweep.prefix(5)))
        XCTAssertEqual(room["Decay"], 0.14); XCTAssertEqual(room["Pre Delay"] ?? 0, 5.8, accuracy: 0.1 + 1e-9)
        XCTAssertEqual(room["High Pass"], 103); XCTAssertEqual(room["Low Pass"], 2655); XCTAssertEqual(room["Mix"], 42)
        XCTAssertEqual(readback("Cave", Array(sweep.prefix(6))), ["Mix": 50, "Decay": 5.32, "Pre Delay": 12.4, "Damping": 26, "High Pass": 149, "Low Pass": 2496])
        XCTAssertEqual(readback("Modulated", sweep), ["Mix": 58, "Decay": 1.19, "Pre Delay": 12.4, "Mod Speed": 0.62, "Mod Depth": 34, "High Pass": 204, "Low Pass": 4328])
        // Ambience: Size is an option list (index 0 = Small).
        XCTAssertEqual(readback("Ambience", [0.10, 1.0, 0.26, 0.34, 0.42]), ["Mix": 42, "Size": 0, "Pre Delay": 100, "High Pass": 103, "Low Pass": 2655])
        XCTAssertEqual(model("Hall", Models.post3).params.map(\.name), ["Mix", "Decay", "Pre Delay", "High Pass", "Low Pass"], "the UI still lists Mix first")
    }

    func testClassicReverbWritesCachesAndReportsUseTheWireIndex() {
        let hall = model("Hall", Models.post3)
        // Electron: "Hall: a Mix write of 42.0 % goes out on wire index 4".
        let mix = param(hall, "Mix")
        XCTAssertEqual(hex(Writes.fxParam(.post3, index: mix.wireIndex, normalized: FXParams.normalized(42, meta: mix.meta))),
                       "0F C0 08 01 18 04 20 04 2D 3D 0A D7 3E 63 00 00 00")
        XCTAssertEqual(param(hall, "Decay").wireIndex, 0, "the Decay knob writes wire index 0")
        // Saved values come back on the same controls (they are kept in wire order).
        var b = FXSlotState(model: hall, on: true)
        b.applyRead([0.10, 0.18, 0.26, 0.34, 0.42], preset: 2)
        var saved = FXSavedValues()
        saved.save(b.floatsToSave!, pedal: "Nano", preset: 2, slot: .post3, model: hall, at: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(saved.entry(pedal: "Nano", preset: 2, slot: .post3, model: hall)?.floats.last ?? 0, 0.42, accuracy: 1e-6, "Mix is the last float")
        var c = FXSlotState(model: hall, on: false, preset: 2)
        XCTAssertTrue(c.applySaved(saved.entry(pedal: "Nano", preset: 2, slot: .post3, model: hall), preset: 2))
        XCTAssertEqual(c.values, [42, 1.19, 6.7, 103, 2655])
        // A live report (99) for wire index 4 is Mix, not Low Pass (PedalStore.applyFXParam looks it up the same way).
        XCTAssertEqual(hall.param(wire: 4)?.index, 0)
        XCTAssertEqual(hall.param(wire: 4).map { FXParams.value(191.0 / 255, meta: $0.def.meta) }, 74.9)
    }

    /// The fake pedal stores a reverb's parameters in wire order, so its read reply puts Mix last too.
    func testFakePedalKeepsTheReverbWireOrder() async throws {
        var s = DemoState.demo()
        s.fxModel[.post3] = .some(model("Hall", Models.post3).id); s.fxOn[.post3] = true
        let pedal = FakePedal(state: s)
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let mix = param(model("Hall", Models.post3), "Mix")
        await session.setFXParam(.post3, index: mix.wireIndex, normalized: 0.42)
        let stored = await pedal.state.fxParams[.post3]
        XCTAssertEqual(stored?.count, 5)
        XCTAssertEqual(Double(stored?[4] ?? 0), 0.42, accuracy: 1e-6)
        XCTAssertEqual(Double(stored?[0] ?? 0), Double(FXParams.normalized(5.5, meta: param(model("Hall", Models.post3), "Decay").meta)), accuracy: 1e-6, "Decay keeps its default on wire 0")
    }

    /// Handoff item 10: the official app offers no Pitch effect in Pre FX 2 and the pedal refuses one there; Pre FX 1
    /// keeps them, and one the pedal reports in Pre FX 2 still shows (it stays in the list and in its own picker).
    func testNoPitchInThePreFX2Picker() {
        let pitch = Models.pre1.filter { $0.category == "Pitch" }
        XCTAssertFalse(pitch.isEmpty)
        XCTAssertFalse(Models.pickerList(for: .pre2, current: nil).contains { $0.category == "Pitch" })
        XCTAssertEqual(Models.pickerList(for: .pre1, current: nil).filter { $0.category == "Pitch" }.map(\.name), pitch.map(\.name))
        XCTAssertEqual(Set(Models.pickerList(for: .pre2, current: nil).map(\.category)), Set(Models.pre1.filter { $0.id != nil && $0.category != "Pitch" }.map(\.category)))
        let wham = model("Wham")
        XCTAssertEqual(Models.byId(wham.idHex!, in: "pre2")?.name, "Wham", "a reported one still displays")
        XCTAssertEqual(Models.pickerList(for: .pre2, current: wham).filter { $0.category == "Pitch" }.map(\.name), ["Wham"])
        for slot in [Slot.post1, .post2, .post3] { XCTAssertEqual(Models.pickerList(for: slot, current: nil).count, Models.list(for: slot.rawValue).filter { $0.id != nil }.count) }
    }

    // MARK: writes and reads by wire index

    func testGraphic9WritesCarryTheWireIndex() {
        // Electron: "Graphic 9: the 65 Hz fader writes wire index 1" (Up from 0 dB = +0.1 dB, Pre FX 2 = slot 1).
        let b65 = param(g9, "65Hz")
        XCTAssertEqual(hex(Writes.fxParam(.pre2, index: b65.wireIndex, normalized: FXParams.normalized(0.1, meta: b65.meta))),
                       "0F C0 08 01 18 01 20 01 2D 11 11 01 3F 63 00 00 00")
        // "Graphic 9: HPF writes wire index 0" (the varint 0 is written, not left out).
        let hpf = param(g9, "HPF")
        let w = Writes.fxParam(.pre2, index: hpf.wireIndex, normalized: FXParams.normalized(110, meta: hpf.meta))
        XCTAssertEqual(hex(Array(w.prefix(9))), "0F C0 08 01 18 01 20 00 2D")
    }

    func testReadbackLandsByWireIndex() {
        // Electron: "a readback lands by wire index (float 0 is HPF, float 1 is 65 Hz)".
        var f = [Float](repeating: 0.5, count: 12); f[0] = 0; f[1] = 0
        var b = FXSlotState(model: g9, on: true)
        b.applyRead(f, preset: 3)
        let by = { (n: String) in b.values[self.g9.params.firstIndex { $0.name == n }!] }
        XCTAssertEqual(by("HPF"), 20)
        XCTAssertEqual(by("65Hz"), -12)
        XCTAssertEqual(by("125Hz"), 0)
        XCTAssertEqual(by("LPF"), 6985)
        XCTAssertTrue(b.valuesKnown(preset: 3))
        XCTAssertNil(b.readNote)
        // And back: the values as floats in wire order.
        XCTAssertEqual(g9.wireFloats(b.values)?.prefix(2).map { Double($0) }, [0, 0])
        XCTAssertEqual(g9.defaultWireFloats.count, 12)
    }

    func testCabCurves() {
        XCTAssertEqual(Cab.levelDbToNormalized(-4), 0.5700149100366717, accuracy: 1e-9)
        XCTAssertEqual(Cab.levelDbToNormalized(-7.5), 0.49728136028203157, accuracy: 1e-9)
        XCTAssertEqual(Cab.levelDbToNormalized(6), 0.831061095, accuracy: 1e-9)
        XCTAssertEqual(Cab.levelNormalizedToDb(0.5), -7.362796067459385, accuracy: 1e-9)
        XCTAssertEqual(Cab.levelNormalizedToDb(Cab.levelDbToNormalized(-30)), -30, accuracy: 1e-9)
        XCTAssertEqual(Cab.highPassToNormalized(100), 0.2578141658288563, accuracy: 1e-9)
        XCTAssertEqual(Cab.normalizedToHighPass(0.5), 263)
        XCTAssertEqual(Cab.normalizedToLowPass(0.5), 6930)
        XCTAssertEqual(Cab.lowPassToNormalized(5000), 0.3955543680682174, accuracy: 1e-9)
        XCTAssertEqual(Double(ProtoFields.parse(Frame.body(of: Writes.cabHighPass(hz: 100)) ?? []).first(6)?.float32 ?? 0), 0.2578141658288563, accuracy: 1e-6)
        XCTAssertEqual(Double(ProtoFields.parse(Frame.body(of: Writes.cabLowPass(hz: 5000)) ?? []).first(7)?.float32 ?? 0), 0.3955543680682174, accuracy: 1e-6)
    }

    // MARK: saved values

    func testSavedValuesAreShownButNeverKnown() {
        // Electron: "saved values are restored for a bypassed effect, but never as its Original or as known".
        var saved = FXSavedValues()
        let floats = [Float](repeating: 0.25, count: g9.params.count)
        saved.save(floats, pedal: "Nano", preset: 4, slot: .pre2, model: g9, at: Date(timeIntervalSince1970: 1000))
        var b = FXSlotState(model: g9, on: false, preset: 4)
        XCTAssertEqual(b.readNote, "No parameter readback yet. The pedal does not return bypassed effect values.")
        XCTAssertTrue(b.applySaved(saved.entry(pedal: "Nano", preset: 4, slot: .pre2, model: g9), preset: 4))
        XCTAssertTrue(b.loaded); XCTAssertTrue(b.fromSaved)
        XCTAssertFalse(b.valuesKnown(preset: 4))
        XCTAssertEqual(b.savedAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(b.values[g9.params.firstIndex { $0.name == "65Hz" }!], -6)
        // "a bypassed effect with saved values says so".
        XCTAssertEqual(b.readNote, "Showing cached values; they may be stale while this effect is bypassed.")
        b.on = true
        XCTAssertEqual(b.readNote, "Showing cached values until a fresh pedal readback replaces them.")
        // "one knob turned on a saved set keeps the rest marked as saved".
        b.set(3, at: 0, preset: 4)
        XCTAssertTrue(b.fromSaved); XCTAssertFalse(b.valuesKnown(preset: 4)); XCTAssertEqual(b.values[0], 3)
        XCTAssertNotNil(b.floatsToSave)
        // A full live read replaces them and clears the mark.
        b.applyRead(floats, preset: 4)
        XCTAssertFalse(b.fromSaved); XCTAssertTrue(b.valuesKnown(preset: 4)); XCTAssertNil(b.savedAt); XCTAssertNil(b.readNote)
        XCTAssertFalse(b.valuesKnown(preset: 5), "values of another preset are not known")
        // Unread and on.
        b.reset(preset: 5)
        XCTAssertEqual(b.readNote, "Reading current effect values from the pedal…")
        XCTAssertNil(b.floatsToSave, "defaults are never saved")
    }

    func testSavedValuesKeyLimitAndStorage() {
        var saved = FXSavedValues()
        let lhc = model("Low-High Cut")
        let five = [Float](repeating: 0.5, count: lhc.params.count)
        saved.save(five, pedal: "A", preset: 0, slot: .pre1, model: lhc, at: Date(timeIntervalSince1970: -1))
        XCTAssertNotNil(saved.entry(pedal: "A", preset: 0, slot: .pre1, model: lhc))
        XCTAssertNil(saved.entry(pedal: "B", preset: 0, slot: .pre1, model: lhc), "per pedal")
        XCTAssertNil(saved.entry(pedal: "A", preset: 1, slot: .pre1, model: lhc), "per preset")
        XCTAssertNil(saved.entry(pedal: "A", preset: 0, slot: .pre2, model: lhc), "per slot")
        XCTAssertNil(saved.entry(pedal: "A", preset: 0, slot: .pre1, model: g9), "per model")
        saved.save([0.5], pedal: "A", preset: 2, slot: .pre1, model: lhc)
        XCTAssertNil(saved.entry(pedal: "A", preset: 2, slot: .pre1, model: lhc), "a set missing parameters isn't kept")
        // An entry for another model under the same key (a renamed effect) isn't shown.
        var b = FXSlotState(model: g9, on: false)
        XCTAssertFalse(b.applySaved(FXSavedValues.Entry(model: "Low-High Cut", floats: five, savedAt: Date()), preset: 0))
        XCTAssertFalse(b.fromSaved)
        // The newest 500 stay.
        for i in 0..<510 { saved.save(five, pedal: "A", preset: i, slot: .post1, model: lhc, at: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(saved.entries.count, FXSavedValues.limit)
        XCTAssertNotNil(saved.entry(pedal: "A", preset: 509, slot: .post1, model: lhc))
        XCTAssertNil(saved.entry(pedal: "A", preset: 0, slot: .pre1, model: lhc), "the oldest went")
        XCTAssertEqual(FXSavedValues(data: saved.encoded()), saved)
        XCTAssertEqual(FXSavedValues(data: Data("not json".utf8)).entries.count, 0)
        XCTAssertEqual(FXSavedValues(data: nil).entries.count, 0)
    }

    // MARK: the read drain

    private func waitFor(_ what: String, timeout: TimeInterval = 3, _ check: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !(await check()) {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func reads(_ pedal: FakePedal) async -> [UInt64] {
        await pedal.writes.filter { Frame.type(of: $0) == 137 }.map { ProtoFields.parse(Frame.body(of: $0) ?? []).int(3) ?? 0 }
    }
    private func fxReply(_ floats: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []; for x in floats { bytes += LE.bytes(x.bitPattern) }
        return ProtoWriter().int(1, 6).bytes(4, bytes).build()
    }

    func testAReplyLateAfterACancelNeverLandsOnTheNextRead() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        let got = FXReplyLog()
        let listener = Task { for await e in session.events { if case .fxParams(let s, let f) = e { got.add(s, f) } } }
        defer { listener.cancel() }
        var h = FakePedal.Hooks(); h.dropFXReads = true; await pedal.setHooks(h)
        await session.readFXParams([.pre1])
        try await waitFor("the pre1 read") { await self.reads(pedal) == [0] }
        // A preset change cancels it; the next read waits for the drain.
        await session.cancelFXParamReads()
        await session.readFXParams([.post2])
        var r = await session.fxReads
        XCTAssertTrue(r.draining); XCTAssertNil(r.pending); XCTAssertEqual(r.queued, [.post2])
        try await Task.sleep(for: .milliseconds(100))
        let sent = await reads(pedal)
        XCTAssertEqual(sent, [0], "nothing is read while draining")
        // pre1's late reply is dropped, and post2's read starts at once.
        await pedal.setHooks(FakePedal.Hooks())
        await pedal.notifyAsPedal(type: 138, body: fxReply([0.9, 0.9, 0.9]))
        try await waitFor("post2's reply") { got.items.count == 1 }
        XCTAssertEqual(got.items.first?.0, .post2)
        XCTAssertNotEqual(got.items.first?.1.first, 0.9, "the late reply didn't land on Post FX 2")
        r = await session.fxReads
        XCTAssertFalse(r.draining); XCTAssertNil(r.pending)
        let bypassed = await pedal.bypassedReads
        XCTAssertEqual(bypassed, 0)
    }

    func testATimedOutReadHoldsTheQueueThenGoesOn() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        var h = FakePedal.Hooks(); h.dropFXReads = true; await pedal.setHooks(h)
        await session.readFXParams([.pre1, .post2])
        try await waitFor("the timeout", timeout: 2) { await session.fxReads.draining }
        let r = await session.fxReads
        XCTAssertNil(r.pending); XCTAssertEqual(r.queued, [.post2])
        let busy = await session.isBusy
        XCTAssertTrue(busy, "a queued read keeps the session busy")
        await pedal.setHooks(FakePedal.Hooks())
        // After 300 ms without a late reply the queue goes on.
        try await waitFor("post2's read", timeout: 2) { await self.reads(pedal) == [0, 3] }
        try await waitFor("an idle session", timeout: 2) { await !session.isBusy }
    }

    func testAPresetChangeCancelsTheReadInFlight() async throws {
        let pedal = FakePedal()
        let session = Session(transport: pedal)
        _ = try await session.connect()
        var h = FakePedal.Hooks(); h.dropFXReads = true; await pedal.setHooks(h)
        await session.readFXParams([.pre1, .post3])
        try await waitFor("the pre1 read") { await self.reads(pedal) == [0] }
        _ = try await session.selectPreset(index: 5)
        let r = await session.fxReads
        XCTAssertTrue(r.draining); XCTAssertEqual(r.queued, [], "the old preset's queue is gone")
    }
}

/// Thread-safe list of FX replies seen by a listener task.
final class FXReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Slot, [Float])] = []
    func add(_ s: Slot, _ f: [Float]) { lock.lock(); list.append((s, f)); lock.unlock() }
    var items: [(Slot, [Float])] { lock.lock(); defer { lock.unlock() }; return list }
}
