import XCTest
@testable import NanoCore

/// Firmware version checks and unknown effect ids (a newer firmware can add effects Models.swift doesn't list).
final class CompatibilityTests: XCTestCase {
    func testTestedFirmware() {
        XCTAssertEqual(Compatibility.testedFirmware, "2.3.0")
    }

    func testVersionComparison() {
        XCTAssertEqual(Compatibility.compare("2.2.1", "2.2.1"), .orderedSame)
        XCTAssertEqual(Compatibility.compare("2.2.2", "2.2.1"), .orderedDescending)
        XCTAssertEqual(Compatibility.compare("2.3.0", "2.2.1"), .orderedDescending)
        XCTAssertEqual(Compatibility.compare("3.0", "2.2.1"), .orderedDescending)
        XCTAssertEqual(Compatibility.compare("3.0", "3.0.0"), .orderedSame, "missing components count as 0")
        XCTAssertEqual(Compatibility.compare("2.2.1+abc", "2.2.1"), .orderedSame, "build suffix ignored")
        XCTAssertEqual(Compatibility.compare("2.2.1+06d34443", "2.2.1"), .orderedSame)
        XCTAssertEqual(Compatibility.compare("2.10.0", "2.9.9"), .orderedDescending, "numeric, not lexical")
        XCTAssertEqual(Compatibility.compare("2.1.9", "2.2.1"), .orderedAscending)
        XCTAssertNil(Compatibility.compare("garbage", "2.2.1"))
        XCTAssertNil(Compatibility.compare("", "2.2.1"))
        XCTAssertNil(Compatibility.compare("2..1", "2.2.1"))
    }

    func testNewerThanTested() {
        XCTAssertFalse(Compatibility.isNewerThanTested("2.3.0"))
        XCTAssertFalse(Compatibility.isNewerThanTested("2.2.1"), "the previously tested firmware")
        XCTAssertTrue(Compatibility.isNewerThanTested("2.3.1"))
        XCTAssertTrue(Compatibility.isNewerThanTested("2.4.0"))
        XCTAssertTrue(Compatibility.isNewerThanTested("3.0"))
        XCTAssertFalse(Compatibility.isNewerThanTested("2.3.0+abc"))
        XCTAssertTrue(Compatibility.isNewerThanTested("2.10.0"))
        XCTAssertFalse(Compatibility.isNewerThanTested("2.1.0"))
        XCTAssertFalse(Compatibility.isNewerThanTested("garbage"))
        XCTAssertFalse(Compatibility.isNewerThanTested(nil))
    }

    func testWarnedOnce() {
        XCTAssertTrue(Compatibility.shouldWarn(firmware: "2.4.0", lastWarned: nil))
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "2.4.0", lastWarned: "2.4.0"), "already warned for this version")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "2.4.0+abc", lastWarned: "2.4.0"), "a new build of the same version")
        XCTAssertTrue(Compatibility.shouldWarn(firmware: "2.5.0", lastWarned: "2.4.0"), "a newer version warns again")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "2.3.0", lastWarned: nil), "tested version: nothing")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "2.2.1", lastWarned: nil), "older: nothing")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "2.0.0", lastWarned: nil), "older: nothing")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: nil, lastWarned: nil), "unknown: nothing")
        XCTAssertFalse(Compatibility.shouldWarn(firmware: "beta", lastWarned: nil), "unreadable: nothing")
        XCTAssertEqual(Compatibility.core("2.4.0+abc"), "2.4.0", "what gets remembered")
    }

    /// NanOS 2.3.0's five effects (ids from upstream V1.14–V1.18, each confirmed on Anup's pedal on 2026-11-17, see the
    /// Electron edition's docs/HANDOFF-NANOS-2.3.md): Pitch ones in the Pre FX list, reverbs in Post FX 3 only.
    func testNanOS23Effects() {
        let pre: [(String, [UInt8])] = [("Poly Octaver", [0xD4, 0x8C, 0x01]), ("Wham", [0xD6, 0x8C, 0x01]), ("Chief OC2", [0xDE, 0x8C, 0x01])]
        let post3: [(String, [UInt8])] = [("Blossom (ST)", [0xDE, 0x3E]), ("Shimmer", [0xCA, 0x3E])]
        for (name, id) in pre {
            let m = Models.pre1.first { $0.name == name }
            XCTAssertEqual(m?.id, id, name); XCTAssertEqual(m?.category, "Pitch", name)
            XCTAssertFalse(m?.params.isEmpty ?? true, name)
            for slot in ["pre1", "pre2"] { XCTAssertEqual(Models.byId(m!.idHex!, in: slot)?.name, name, slot) }
            for slot in ["post1", "post2", "post3"] { XCTAssertNil(Models.list(for: slot).first { $0.name == name }, "\(name) in \(slot)") }
        }
        for (name, id) in post3 {
            let m = Models.post3.first { $0.name == name }
            XCTAssertEqual(m?.id, id, name); XCTAssertEqual(m?.category, "Reverb", name)
            XCTAssertFalse(m?.params.isEmpty ?? true, name)
            XCTAssertEqual(Models.byId(m!.idHex!, in: "post3")?.name, name)
            for slot in ["pre1", "post1", "post2"] { XCTAssertNil(Models.list(for: slot).first { $0.name == name }, "\(name) in \(slot)") }
        }
        // Ids stay unique per slot list.
        for slot in ["pre1", "post1", "post2", "post3"] {
            let ids = Models.list(for: slot).compactMap(\.idHex)
            XCTAssertEqual(ids.count, Set(ids).count, slot)
        }
        XCTAssertEqual(Models.post3.first { $0.name == "Blossom (ST)" }?.params.map(\.name),
                       ["Mix", "Decay", "Pre Delay", "High Pass", "Low Pass", "Extra E.R.", "E.R. Length", "Diffusion", "Bass", "Treble", "Ducking", "Modulation"])
    }

    func testUnknownModelId() {
        XCTAssertNil(Models.byId("7E", in: "post2"))
        for slot in Slot.allCases { XCTAssertNil(Models.byId("7E", in: slot.rawValue), slot.rawValue) }
        XCTAssertNotNil(Models.byId("1B", in: "pre1"), "Green 808 is known")
    }

    /// The pedal reports an id we don't know: the state dump keeps the raw id so the app can show "Unknown effect".
    func testUnknownModelIdSurvivesTheStateDump() async throws {
        var s = DemoState.demo()
        s.firmware = "2.4.0"
        s.fxModel[.post2] = .some([0x7E])
        let d = StateDump.parse(StateEncoder.dump(s, withLists: false))
        XCTAssertEqual(d.firmware, "2.4.0")
        XCTAssertEqual(d.fx["post2"]?.modelIdHex, "7E")
        XCTAssertNil(Models.byId(d.fx["post2"]!.modelIdHex!, in: "post2"))

        let pedal = FakePedal()
        await pedal.setModelOnPedal(.post1, id: [0x7E])
        let st = await pedal.state
        XCTAssertEqual(st.fxModel[.post1] ?? nil, [0x7E])
    }
}
