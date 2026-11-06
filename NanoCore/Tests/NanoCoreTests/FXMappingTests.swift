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
        // Every other model's wire order is its UI order.
        for m in Models.pre1 + Models.post1 + Models.post2 + Models.post3 where m.name != "Graphic 9" { XCTAssertEqual(m.params.map(\.wireIndex), m.params.map(\.index), m.name) }
    }

    func testRangesAndCurves() {
        XCTAssertEqual(param(g9, "HPF").meta, .range(min: 20, max: 200, step: 1, unit: "Hz", decimals: 0))
        XCTAssertEqual(param(g9, "LPF").meta, .range(min: 1000, max: 16000, step: 1, unit: "Hz", decimals: 0, curve: .power(1.1803)))
        for name in ["Graphic 9", "Low-High Cut", "Parametric 3"] {
            XCTAssertEqual(param(model(name), "Output").meta, .range(min: -20, max: 20, step: 0.1, unit: "dB", decimals: 1), name)
        }
        // Electron: "Parametric 3: band frequencies are 20 Hz to 20 kHz, not the Q range".
        let p3 = model("Parametric 3")
        XCTAssertEqual(param(p3, "2 Freq").meta, .range(min: 20, max: 20000, step: 1, unit: "Hz", decimals: 0, curve: .power(10.0 / 3)))
        if case .range(_, let hi, _, _, _, _)? = param(p3, "2 Q").meta { XCTAssertEqual(hi, 10) } else { XCTFail("Q") }
        let lhc = model("Low-High Cut")
        XCTAssertEqual(param(lhc, "HPF Freq").meta, .range(min: 20, max: 800, step: 1, unit: "Hz", decimals: 0, curve: .reversePower(3.98)))
        XCTAssertEqual(param(lhc, "LPF Freq").meta, .range(min: 1000, max: 16000, step: 1, unit: "Hz", decimals: 0, curve: .power(1.98)))
        XCTAssertEqual(param(model("Envelope Filter"), "Sens").meta, .range(min: 0, max: 54, step: 0.1, unit: "dB", decimals: 1))
    }

    func testDisplayValuesMatchElectron() {
        func v(_ m: ModelDef, _ p: String, _ n: Double) -> Double { FXParams.value(n, meta: param(m, p).meta) }
        let lhc = model("Low-High Cut"), p3 = model("Parametric 3"), ef = model("Envelope Filter"), tr = model("Transpose")
        // Electron: "Low-High Cut: Cortex Cloud's 665 Hz high pass reads back as 665 Hz (wire 0.357)".
        XCTAssertEqual(v(lhc, "HPF Freq", 0.357), 665)
        XCTAssertEqual(v(lhc, "LPF Freq", 0.863), 12205)
        XCTAssertEqual(v(g9, "LPF", 0.615), 9451)
        XCTAssertEqual(v(g9, "HPF", 0), 20)
        XCTAssertEqual(v(g9, "HPF", 0.5), 110)
        XCTAssertEqual(v(p3, "2 Freq", 0.5), 2002)
        XCTAssertEqual(v(ef, "Freq", 0.5), 1197)
        XCTAssertEqual(v(ef, "Attack", 0.5), 507.9)
        XCTAssertEqual(v(tr, "High Pass", 0.5), 216)
        XCTAssertEqual(v(tr, "Low Pass", 0.5), 2154)
        XCTAssertEqual(v(model("Hall", Models.post3), "Low Pass", 0.5), 1911)
        XCTAssertEqual(Double(FXParams.normalized(665, meta: param(lhc, "HPF Freq").meta)), 0.35641960574102727, accuracy: 1e-6)
        XCTAssertEqual(Double(FXParams.normalized(1000, meta: param(p3, "1 Freq").meta)), 0.4047521622867309, accuracy: 1e-6)
        // Every curve round-trips on its step.
        for (m, p, x) in [(lhc, "HPF Freq", 665.0), (lhc, "LPF Freq", 12205), (g9, "LPF", 9451), (p3, "3 Freq", 440), (ef, "Decay", 250.5), (tr, "Low Pass", 2154)] {
            XCTAssertEqual(FXParams.value(Double(FXParams.normalized(x, meta: param(m, p).meta)), meta: param(m, p).meta), x, accuracy: 1, "\(m.name) \(p)")
        }
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
        XCTAssertEqual(by("LPF"), 7619)
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
