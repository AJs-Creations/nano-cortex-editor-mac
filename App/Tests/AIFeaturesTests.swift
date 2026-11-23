// The AI features master switch (AIFeatures.swift, mcp/PROTOCOL.md §4).
import XCTest

final class AIFeaturesTests: XCTestCase {
    enum S: CaseIterable { case appearance, device, assistants, advanced }

    func testOffByDefaultAndReadFromTheKey() {
        let d = UserDefaults(suiteName: "AIFeaturesTests-\(UUID().uuidString)")!
        XCTAssertFalse(AIFeatures.isOn(in: d))
        d.set(true, forKey: "ai.features")
        XCTAssertTrue(AIFeatures.isOn(in: d))
        XCTAssertEqual(AIFeatures.key, "ai.features")
    }
    func testListensOnlyWithBothSwitches() {
        XCTAssertFalse(AIFeatures.listens(features: false, allowed: true))
        XCTAssertFalse(AIFeatures.listens(features: true, allowed: false))
        XCTAssertTrue(AIFeatures.listens(features: true, allowed: true))
    }
    func testTheSectionExistsOnlyWithFeaturesOn() {
        XCTAssertEqual(AIFeatures.visible(S.allCases, ai: .assistants, features: false), [.appearance, .device, .advanced])
        XCTAssertEqual(AIFeatures.visible(S.allCases, ai: .assistants, features: true), S.allCases)
    }
    func testTurningOffFallsBackToTheFirstSection() {
        let off = AIFeatures.visible(S.allCases, ai: .assistants, features: false)
        XCTAssertEqual(AIFeatures.section(S.assistants, in: off), .appearance)
        XCTAssertEqual(AIFeatures.section(S.advanced, in: off), .advanced)
    }
}
