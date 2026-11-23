// The MCP contract's pure half (mcp/PROTOCOL.md §1–§4): the contract model, argument validation, loudness limits, the
// tone plan, the result builders, the endpoint and token rules, the hello and the setup lines. These are the spec of the
// native editor's AI-assistant side; AgentBridge only runs what they decide.
import XCTest
@testable import NanoCore

enum MCPFixture {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let contract: MCPContract = try! MCPContract(data: Data(contentsOf: repo.appending(path: "mcp/tools.json")))
    static var safety: MCPContract.Safety { contract.safety }
    static var messages: MCPContract.Messages { contract.messages }
    /// tools.json as plain JSON (what the file says, independent of MCPContract's loader).
    nonisolated(unsafe) static let file: [String: Any] = try! JSONSerialization.jsonObject(with: Data(contentsOf: repo.appending(path: "mcp/tools.json"))) as! [String: Any]
    static func schema(_ tool: String) -> JSONValue { contract.tool(tool)!.schema }
    static func validate(_ tool: String, _ args: JSONValue) -> String? { MCPValidator.validate(args, schema: schema(tool)) }
    static func model(_ name: String, _ slot: Slot) -> ModelDef { Models.list(for: slot.rawValue).first { $0.name == name }! }
    /// A demo-like preset: amp at 5, capture 0 dB, cab 0 dB, Hall in Post FX 3 (Mix 50), Chief BD2 in Pre FX 1 (Volume 5).
    static func state() -> MCPToneState {
        MCPToneState(amp: [.gain: 128, .bass: 128, .mid: 128, .treble: 128, .level: 128], captureVolumeDb: 0, cabLevelDb: 0, gateOn: true, gateReduction: 50,
                     effects: [.pre1: .init(model: model("Chief BD2", .pre1), on: true), .post3: .init(model: model("Hall", .post3), on: true)],
                     captureNames: ["Plexi", "Rectifier", ""] + Array(repeating: "Cap", count: 22), irNames: ["412 Brit", "", "212 Blue", "", ""])
    }
}

final class MCPContractTests: XCTestCase {
    func testLoadsTheSharedContract() {
        let c = MCPFixture.contract
        XCTAssertEqual(c.contractVersion, 1)
        XCTAssertEqual(c.serverName, "nano-cortex")
        XCTAssertEqual(c.tools.count, 30)
        XCTAssertEqual(c.tools.filter { $0.kind == .confirm }.map(\.name), ["save", "save_as", "rename", "load_capture_into_slot", "load_cab_into_slot", "set_cab_mic", "assign_footswitch", "cloud_send"])
        XCTAssertEqual(c.tool("discard_edits")?.destructive, true)
        XCTAssertTrue(c.errors.notConnected.hasPrefix("The editor is not connected"))
        XCTAssertEqual(c.safety.ampLevelStep, 2)
        XCTAssertEqual(c.safety.effectLevelStepShare, 0.25)
    }
    func testRefsAreInlined() {
        XCTAssertEqual(MCPFixture.schema("set_amp")["properties"]?["gain"]?["maximum"], 10)
        XCTAssertEqual(MCPFixture.schema("list_effects")["properties"]?["slot"]?["enum"]?.arrayValue?.count, 5)
        XCTAssertEqual(MCPFixture.schema("list_effects")["properties"]?["slot"]?["description"], "One slot only (default: all five).")
        XCTAssertFalse(MCPFixture.schema("apply_tone").compact.contains("$ref"))
    }
    /// Every text in tools.json → messages is loaded (MCPContract.Messages carries exactly the file's keys), and the
    /// fill helpers put the values where the contract's placeholders are.
    func testSharedTexts() {
        let file = (MCPFixture.file["messages"] as! [String: String]).filter { $0.key != "$comment" }
        XCTAssertEqual(Set(file.keys), Set(MCPContract.Messages.keys))
        let m = MCPFixture.messages
        let loaded: [String: String] = ["askedBy": m.askedBy, "anotherEditor": m.anotherEditor, "contractMismatch": m.contractMismatch, "nothingToSave": m.nothingToSave,
                                        "captureSlotRange": m.captureSlotRange, "cabSlotRange": m.cabSlotRange, "slotOrOff": m.slotOrOff, "tempoRange": m.tempoRange,
                                        "connected": m.connected, "statusWaiting": m.statusWaiting, "statusConnected": m.statusConnected, "pill": m.pill,
                                        "aiSwitch": m.aiSwitch, "aiExplain": m.aiExplain, "addClaude": m.addClaude, "addChatGPT": m.addChatGPT,
                                        "otherAssistants": m.otherAssistants, "dialogExpired": m.dialogExpired]
        XCTAssertEqual(loaded, file)
        XCTAssertEqual(m.askedBy(client: "Claude Code"), "Asked by Claude Code.")
        XCTAssertEqual(m.connected(client: "Codex"), "Codex connected")
        XCTAssertEqual(m.statusConnected(clients: ["Claude Code", "Codex"]), "Connected: Claude Code, Codex")
        XCTAssertEqual(m.nothingToSave(number: 7), "Preset 7 has no unsaved edits, so there is nothing to save.")
        XCTAssertEqual(m.tempoRange(40...240), "This pedal takes 40–240 BPM.")
        // PROTOCOL.md "What the user sees" quotes these.
        XCTAssertEqual(m.aiSwitch, "AI assistants")   // the one switch (PROTOCOL.md §4)
        XCTAssertEqual(m.statusWaiting, "On, waiting for an assistant"); XCTAssertEqual(m.pill, "Assistant connected")
        XCTAssertEqual(m.addClaude, "Add to Claude Desktop…"); XCTAssertEqual(m.addChatGPT, "Add to ChatGPT…")
    }
    func testLevelParamNames() {
        let s = MCPFixture.safety
        for n in ["Level", "volume", "OUTPUT", "Out Level", "Vol"] { XCTAssertTrue(s.isLevelParam(n), n) }
        for n in ["Mix", "Level 2", "Dry Level", "Volume Boost"] { XCTAssertFalse(s.isLevelParam(n), n) }
    }
    func testJSONValueKeepsTypes() throws {
        let v = try JSONValue.parse(#"{"a":true,"b":1,"c":1.5,"d":"x","e":null,"f":[0,false]}"#)
        XCTAssertEqual(v["a"], .bool(true)); XCTAssertEqual(v["b"], .number(1)); XCTAssertEqual(v["c"], .number(1.5))
        XCTAssertEqual(v["e"], .null); XCTAssertEqual(v["f"], [0, false])
        XCTAssertEqual(v.compact, #"{"a":true,"b":1,"c":1.5,"d":"x","e":null,"f":[0,false]}"#)
    }
}

final class MCPValidatorTests: XCTestCase {
    func v(_ tool: String, _ args: JSONValue) -> String? { MCPFixture.validate(tool, args) }

    func testEnumSentenceNamesTheField() {
        XCTAssertEqual(v("set_effect", ["slot": "pre3"]), "slot must be one of pre1, pre2, post1, post2, post3.")
        XCTAssertEqual(v("list_library", ["kind": "amp"]), "kind must be one of capture, cab.")
    }
    func testRequiredAndUnknownKeys() {
        XCTAssertEqual(v("set_effect", [:]), "slot is required.")
        XCTAssertEqual(v("set_effect_param", ["slot": "pre1", "param": "Gain"]), "value is required.")
        XCTAssertEqual(v("set_amp", ["gian": 5]), "gian is not a known argument (allowed: bass, gain, level, mid, treble, volume_db).")
        XCTAssertEqual(v("get_status", ["x": 1]), "x is not a known argument (this tool takes none).")
        XCTAssertEqual(v("set_gate", .array([])), "The arguments must be an object.")
    }
    func testTypesAndRanges() {
        XCTAssertEqual(v("set_amp", ["gain": "5"]), "gain must be a number.")
        XCTAssertEqual(v("set_amp", ["gain": 11]), "gain must be between 0 and 10.")
        XCTAssertEqual(v("set_amp", ["volume_db": -25]), "volume_db must be between -24 and 12.")
        XCTAssertEqual(v("select_preset", ["number": 2.5]), "number must be a whole number.")
        XCTAssertEqual(v("select_preset", ["number": 65]), "number must be between 1 and 64.")
        XCTAssertEqual(v("set_effect", ["slot": "pre1", "on": "yes"]), "on must be true or false.")
        XCTAssertEqual(v("set_effect_param", ["slot": "pre1", "param": "Gain", "value": true]), "value must be a number or a string.")
        XCTAssertEqual(v("get_slot_usage", ["scan": 1]), "scan must be true or false.")
    }
    func testLengthsAndPatterns() {
        XCTAssertEqual(v("save_as", ["name": "abc"]), "name must be 4 to 64 characters long.")
        XCTAssertEqual(v("cloud_search", ["query": "x"]), "query must be 2 to 100 characters long.")
        XCTAssertNil(v("cloud_open", ["product_id": "3F2B9C1E-0000-4000-8000-000000000001"]))
        XCTAssertEqual(v("cloud_open", ["product_id": "nope"]), "product_id must be a Cortex Cloud product id (a UUID such as 3f2b9c1e-…), as cloud_search returns it.")
    }
    func testNestedPaths() {
        XCTAssertEqual(v("apply_tone", ["amp": ["level": 12]]), "amp.level must be between 0 and 10.")
        XCTAssertEqual(v("apply_tone", ["effects": [["slot": "post3", "params": ["Mix": true]]]]), "effects[0].params.Mix must be a number or a string.")
        XCTAssertEqual(v("apply_tone", ["effects": [["model": "Hall"]]]), "effects[0].slot is required.")
        XCTAssertEqual(v("apply_tone", ["effects": [["slot": "post3", "mix": 1]]]), "effects[0].mix is not a known argument (allowed: model, on, params, slot).")
        XCTAssertEqual(v("apply_tone", ["effects": .array(Array(repeating: ["slot": "pre1"], count: 6))]), "effects may have at most 5 entries.")
        XCTAssertEqual(v("apply_tone", ["cab_tone": ["low_pass_hz": 500]]), "cab_tone.low_pass_hz must be between 1000 and 20000.")
    }
    /// One valid call per tool: the schemas accept what the documentation promises.
    func testEveryToolAcceptsAValidCall() {
        let id: JSONValue = "3f2b9c1e-0000-4000-8000-000000000001"
        let calls: [String: JSONValue] = [
            "get_status": [:], "get_current_preset": [:], "list_presets": [:], "list_library": ["kind": "capture", "instrument": "guitar", "query": "plexi"],
            "list_effects": ["slot": "post3"], "get_slot_usage": ["scan": false],
            "apply_tone": ["capture_slot": 1, "cab_slot": 1, "amp": ["gain": 4.5], "gate": ["on": true, "reduction": 30], "cab_tone": ["level_db": -3],
                           "effects": [["slot": "post3", "model": "Hall", "on": true, "params": ["Mix": 25, "Decay": "3"]]]],
            "set_amp": ["gain": 4.5, "volume_db": -3], "set_effect": ["slot": "pre1", "model": "None"], "set_effect_param": ["slot": "post3", "param": "Mix", "value": 25],
            "set_gate": ["on": false], "set_cab_tone": ["high_pass_hz": 80], "use_capture_slot": ["slot": 2], "use_cab_slot": ["on": false], "set_tempo": ["bpm": 120.5],
            "select_preset": ["number": 3], "discard_edits": [:], "preview_cab": ["source": "factory", "name": "412 Brit"], "stop_preview": [:], "save": [:],
            "save_as": ["name": "Glassy clean", "number": 40], "rename": ["name": "Glassy clean"], "load_capture_into_slot": ["source": "user", "name": "X", "slot": 3],
            "load_cab_into_slot": ["source": "factory", "name": "X", "slot": 2], "set_cab_mic": ["mic": "Dynamic 57", "position": 2],
            "assign_footswitch": ["footswitch": "IIA", "preset": 7], "cloud_search": ["query": "plexi crunch", "page": 2], "cloud_open": ["product_id": id],
            "cloud_preview": ["product_id": id], "cloud_send": ["product_id": id],
        ]
        XCTAssertEqual(Set(calls.keys), Set(MCPFixture.contract.tools.map(\.name)))
        for (tool, args) in calls { XCTAssertNil(v(tool, args), tool) }
    }
}

final class MCPLoudnessTests: XCTestCase {
    let s = MCPFixture.safety
    func testAmpLevelStep() {
        XCTAssertNil(MCPLoudness.ampLevel(before: 5, after: 7, safety: s))
        XCTAssertEqual(MCPLoudness.ampLevel(before: 5, after: 7.1, safety: s), "Raise Level in smaller steps (at most 2 per call) so the user can check the volume between steps.")
        XCTAssertNil(MCPLoudness.ampLevel(before: 9, after: 1, safety: s))   // down is always fine
    }
    func testCaptureVolumeStepAndMax() {
        XCTAssertNil(MCPLoudness.captureVolume(before: -3, after: 3, safety: s))
        XCTAssertEqual(MCPLoudness.captureVolume(before: -6, after: 0.5, safety: s), "Raise volume_db in smaller steps (at most 6 dB per call) so the user can check the volume between steps.")
        XCTAssertEqual(MCPLoudness.captureVolume(before: 3, after: 7, safety: s), "volume_db is limited to +6 dB when an assistant sets it; the user can go higher in the editor.")
        XCTAssertNil(MCPLoudness.captureVolume(before: 10, after: 8, safety: s))    // above the cap: may go down
        XCTAssertNil(MCPLoudness.captureVolume(before: 10, after: 10, safety: s))   // … or stay
    }
    func testCabLevel() {
        XCTAssertEqual(MCPLoudness.cabLevel(before: 0, after: 6.5, safety: s), "cab level_db is limited to +6 dB when an assistant sets it; the user can go higher in the editor.")
        XCTAssertEqual(MCPLoudness.cabLevel(before: -20, after: -10, safety: s), "Raise cab level_db in smaller steps (at most 6 dB per call) so the user can check the volume between steps.")
    }
    func testEffectLevelParams() {
        let bd2 = MCPFixture.model("Chief BD2", .pre1), volume = bd2.params[2]
        XCTAssertNil(MCPLoudness.effectParam(slot: .pre1, param: volume, before: 5, after: 7.5, safety: s))   // a quarter of 0–10
        XCTAssertEqual(MCPLoudness.effectParam(slot: .pre1, param: volume, before: 5, after: 7.6, safety: s),
                       "Raise Pre FX 1 Volume in smaller steps (at most 25 % of its range per call) so the user can check the volume between steps.")
        let hall = MCPFixture.model("Hall", .post3), mix = hall.params.first { $0.name == "Mix" }!
        XCTAssertNil(MCPLoudness.effectParam(slot: .post3, param: mix, before: 0, after: 100, safety: s))   // Mix isn't a level
    }
}

final class MCPToneTests: XCTestCase {
    let s = MCPFixture.safety
    func plan(_ args: JSONValue, state: MCPToneState = MCPFixture.state()) -> Result<MCPTonePlan, MCPRefusal> {
        MCPTone.plan(applyTone: args.objectValue!, state: state, safety: s, messages: MCPFixture.messages)
    }

    func testOrderAndLines() throws {
        let p = try plan(["effects": [["slot": "post3", "model": "Room", "params": ["mix": 25], "on": true]], "amp": ["gain": 4.5, "level": 6], "capture_slot": 2,
                          "gate": ["reduction": 30], "cab_tone": ["level_db": -3, "high_pass_hz": 80], "cab_slot": 3]).get()
        XCTAssertEqual(p.lines, ["capture slot 2 (Rectifier)", "cab slot 3 (212 Blue)", "amp Gain 4.5, Level 6.0", "gate reduction 30 %",
                                 "cab level -3.0 dB, high-pass 80 Hz", "Post FX 3 → Room", "Post FX 3 Mix → 25 %", "Post FX 3 on"])
        XCTAssertEqual(p.amp, [.init(knob: .gain, raw: 115), .init(knob: .level, raw: 153)])
        XCTAssertEqual(p.effects.count, 1)
        XCTAssertEqual(p.effects[0].model, .model(MCPFixture.model("Room", .post3)))
        XCTAssertEqual(p.effects[0].params.map(\.name), ["Mix"])
    }
    func testAnyRefusedPartChangesNothing() {
        // The amp part is fine; the level step is not: the whole call is refused.
        XCTAssertEqual(plan(["amp": ["gain": 3, "level": 9]]), .failure(MCPRefusal("Raise Level in smaller steps (at most 2 per call) so the user can check the volume between steps.")))
        XCTAssertEqual(plan(["amp": ["gain": 3], "effects": [["slot": "post1", "model": "Hall"]]]),
                       .failure(MCPRefusal("Post FX 1 has no effect named “Hall”. list_effects lists the models each slot takes (or \"None\" to empty it).")))
    }
    func testEffectNamesAndValues() throws {
        // Case-insensitive model and parameter names; a switch by its text or its index; a range by number or numeric text.
        let p = try plan(["effects": [["slot": "post1", "model": "chorus 229t", "params": ["SYNC": "on", "Sync Note": 3, "rate": "1.234"]]]]).get()
        XCTAssertEqual(p.effects[0].params.map(\.value), [1.23, 1, 3])
        XCTAssertEqual(p.lines, ["Post FX 1 → Chorus 229T", "Post FX 1 Rate → 1.23 Hz", "Post FX 1 Sync → On", "Post FX 1 Sync Note → 1/4"])
        XCTAssertEqual(plan(["effects": [["slot": "post3", "params": ["Size": 3]]]]).failureMessage?.hasPrefix("Post FX 3 Hall has no parameter “Size”. Its parameters: Mix, "), true)
        XCTAssertEqual(plan(["effects": [["slot": "post3", "params": ["Mix": 120]]]]).failureMessage, "Post FX 3 Mix must be between 0 and 100 %.")
        XCTAssertEqual(plan(["effects": [["slot": "post1", "model": "Chorus 229T", "params": ["Sync": "maybe"]]]]).failureMessage, "Post FX 1 Sync must be one of Off, On (or its index 0–1).")
    }
    func testPreFX2TakesNoPitch() {
        XCTAssertNotNil(MCPEffects.choice("Transpose", in: .pre1))
        XCTAssertNil(MCPEffects.choice("Transpose", in: .pre2))
    }
    func testEmptySlotsAndNone() throws {
        XCTAssertEqual(plan(["effects": [["slot": "post2", "params": ["Mix": 3]]]]).failureMessage, "Post FX 2 is empty; choose a model for it first (list_effects).")
        XCTAssertEqual(plan(["effects": [["slot": "post2", "on": true]]]).failureMessage, "Post FX 2 is empty (None), so it cannot be switched on; choose a model first.")
        XCTAssertEqual(plan(["effects": [["slot": "post3", "model": "None", "params": ["Mix": 3]]]]).failureMessage, "Post FX 3 is empty; choose a model for it first (list_effects).")
        let p = try plan(["effects": [["slot": "post3", "model": "none"]]]).get()
        XCTAssertEqual(p.effects[0].model, MCPEffects.Choice.empty)
        XCTAssertEqual(p.lines, ["Post FX 3 emptied (None)"])
        XCTAssertEqual(plan(["effects": [["slot": "pre1"], ["slot": "pre1"]]]).failureMessage, "effects lists pre1 more than once.")
    }
    func testSameModelKeepsItsValues() throws {
        // Hall again is no model change; its Mix step compares with the current 50, not a default.
        let p = try plan(["effects": [["slot": "post3", "model": "HALL", "params": ["Mix": 80]]]]).get()
        XCTAssertNil(p.effects[0].model)
        XCTAssertEqual(p.lines, ["Post FX 3 Mix → 80 %"])
    }
    func testEffectLevelComparedWithTheNewModelsDefault() {
        // A new model starts from its defaults: Chief OD1's Level default is 50 % → at most 75 %.
        XCTAssertNil(plan(["effects": [["slot": "pre1", "model": "Chief OD1", "params": ["Level": 75]]]]).failureMessage)
        XCTAssertEqual(plan(["effects": [["slot": "pre1", "model": "Chief OD1", "params": ["Level": 76]]]]).failureMessage,
                       "Raise Pre FX 1 Level in smaller steps (at most 25 % of its range per call) so the user can check the volume between steps.")
    }
    func testSlots() {
        XCTAssertEqual(plan(["capture_slot": 3]).failureMessage, "Capture slot 3 is empty. list_library kind=capture lists the slots and what they hold.")
        // Above what the pedal has: messages.captureSlotRange / cabSlotRange, the field filled in (PROTOCOL.md §4).
        XCTAssertEqual(plan(["capture_slot": 30]).failureMessage, "capture_slot must be between 1 and 25 (the capture slots on this pedal).")
        XCTAssertEqual(plan(["cab_slot": 6]).failureMessage, "cab_slot must be between 1 and 5 (the cab/IR slots on this pedal).")
        XCTAssertEqual(plan(["cab_slot": 2]).failureMessage, "Cab/IR slot 2 is empty. list_library kind=cab lists the slots and what they hold.")
        var p = MCPTonePlan()
        XCTAssertThrowsError(try MCPTone.planCaptureSlot(26, field: "slot", state: MCPFixture.state(), messages: MCPFixture.messages, into: &p)) {
            XCTAssertEqual(($0 as? MCPRefusal)?.message, "slot must be between 1 and 25 (the capture slots on this pedal).")
        }
    }
    /// Review #2: a cab level the editor has not read (another slot, a library cab, not loaded yet) can't be stepped
    /// from, so level_db is refused instead of being compared with a stale value; the filters still go.
    func testCabLevelUnknownIsRefused() {
        var st = MCPFixture.state(); st.cabLevelDb = nil
        XCTAssertEqual(plan(["cab_slot": 1, "cab_tone": ["level_db": 6]], state: st).failureMessage, MCPTone.cabLevelUnknown)
        XCTAssertEqual(plan(["cab_tone": ["level_db": -30]], state: st).failureMessage, MCPTone.cabLevelUnknown)
        XCTAssertNil(plan(["cab_slot": 1, "cab_tone": ["high_pass_hz": 90]], state: st).failureMessage)
        st.cabLevelDb = -20
        XCTAssertEqual(plan(["cab_tone": ["level_db": 6]], state: st).failureMessage,
                       "Raise cab level_db in smaller steps (at most 6 dB per call) so the user can check the volume between steps.")
    }
    func testVolumeAndCabLimits() {
        XCTAssertEqual(plan(["amp": ["volume_db": 7]]).failureMessage, "volume_db is limited to +6 dB when an assistant sets it; the user can go higher in the editor.")
        XCTAssertEqual(plan(["cab_tone": ["level_db": 6.5]]).failureMessage, "cab level_db is limited to +6 dB when an assistant sets it; the user can go higher in the editor.")
        XCTAssertNil(plan(["amp": ["volume_db": 6], "cab_tone": ["level_db": 6]]).failureMessage)
    }
    func testDisplay() {
        XCTAssertEqual(MCPEffects.display(25, meta: .range(min: 0, max: 100, step: 0.1, unit: "%", decimals: 1)), "25 %")
        XCTAssertEqual(MCPEffects.display(6.5, meta: .range(min: -20, max: 20, step: 0.1, unit: "dB", decimals: 1)), "6.5 dB")
        XCTAssertEqual(MCPEffects.display(1, meta: .options(["Off", "On"])), "On")
        XCTAssertEqual(MCPEffects.display(5.5, meta: .range(min: 0, max: 10, step: 0.1, unit: "", decimals: 1)), "5.5")
        XCTAssertEqual(MCPToneState.knob(128), 5.0); XCTAssertEqual(MCPToneState.raw(4.5), 115)
    }
}

extension Result where Failure == MCPRefusal { var failureMessage: String? { if case .failure(let r) = self { return r.message }; return nil } }

final class MCPResultsTests: XCTestCase {
    func testListEffects() {
        let all = MCPResults.listEffects(slot: nil)["slots"]!.arrayValue!
        XCTAssertEqual(all.map { $0["slot"]!.stringValue! }, ["pre1", "pre2", "post1", "post2", "post3"])
        let pre2 = all[1]["models"]!.arrayValue!.map { $0["name"]!.stringValue! }
        XCTAssertFalse(pre2.contains("None")); XCTAssertFalse(pre2.contains("Transpose")); XCTAssertTrue(pre2.contains("Chief BD2"))
        let hall = MCPResults.listEffects(slot: .post3)["slots"]![0]!["models"]!.arrayValue!.first { $0["name"] == "Hall" }!
        XCTAssertEqual(hall["params"]![0], ["name": "Mix", "unit": "%", "min": 0, "max": 100, "step": 0.1])
        let chorus = MCPResults.listEffects(slot: .post1)["slots"]![0]!["models"]!.arrayValue!.first { $0["name"] == "Chorus 229T" }!
        XCTAssertEqual(chorus["params"]!.arrayValue!.first { $0["name"] == "Sync" }, ["name": "Sync", "options": ["Off", "On"]])
    }
    func testEffectEntry() {
        var b = FXSlotState(model: MCPFixture.model("Chorus 229T", .post1), on: true, preset: 2)
        b.applyRead(MCPFixture.model("Chorus 229T", .post1).defaultWireFloats, preset: 2)
        let e = MCPResults.effect(slot: .post1, block: b, preset: 2)
        XCTAssertEqual(e["model"], "Chorus 229T"); XCTAssertEqual(e["valuesKnown"], true); XCTAssertEqual(e["known"], true)
        XCTAssertEqual(e["params"]![0]!["display"], "50 %")
        XCTAssertEqual(e["params"]!.arrayValue!.first { $0["name"] == "Sync" }!["value"], "Off")
        XCTAssertEqual(MCPResults.effect(slot: .post1, block: b, preset: 3)["valuesKnown"], false)
        XCTAssertEqual(MCPResults.effect(slot: .pre2, block: nil, preset: 0)["model"], "None")
        XCTAssertEqual(MCPResults.effect(slot: .pre2, block: FXSlotState(model: nil, on: true, unknownId: "7E"), preset: 0)["known"], false)
    }
    func testPresetsAndUsage() {
        let r = MCPResults.listPresets(names: ["Clean", "", "Lead"], current: 2, footswitch: Footswitches(ia: 0, ib: 2, iia: 5, iib: 63))
        XCTAssertEqual(r["current"], 3)
        XCTAssertEqual(r["presets"]!.arrayValue!.count, 64)
        XCTAssertEqual(r["presets"]![1], ["number": 2, "name": nil, "empty": true])
        XCTAssertEqual(r["footswitches"], ["IA": 1, "IB": 3, "IIA": 6, "IIB": 64])
        XCTAssertEqual(MCPResults.slotUsage(captures: nil, cabs: nil), ["scanned": false, "capture": nil, "cab": nil])
        // Key "0": the presets that play straight from the library (PROTOCOL.md §4).
        XCTAssertEqual(MCPResults.slotUsage(captures: [1: [3, 0], 0: [5]], cabs: [2: [1]]), ["scanned": true, "capture": ["1": [1, 4], "0": [6]], "cab": ["2": [2]]])
    }
    func testLibraryFilters() {
        let lib = Library(factoryCaptures: [LibraryCapture(index: 0, hash: "a", name: "Plexi Crunch", type: "amp_head", tags: [], instrument: "guitar", author: "", description: "Bright", corrupted: false),
                                            LibraryCapture(index: 1, hash: "b", name: "Bass DI", type: "pedal", tags: [], instrument: "bass", author: "", description: "", corrupted: false)],
                          userCaptures: [], factoryIRs: [LibraryItem(index: 0, name: "412 Brit")], userIRs: [LibraryItem(index: 0, name: "My IR")])
        let caps = MCPResults.library(kind: "capture", slotNames: ["Plexi Crunch", ""], library: lib, instrument: "guitar")
        XCTAssertEqual(caps["slots"], [["slot": 1, "name": "Plexi Crunch"], ["slot": 2, "name": nil]])
        XCTAssertEqual(caps["library"], [["source": "factory", "name": "Plexi Crunch", "type": "amp_head", "instrument": "guitar", "description": "Bright"]])
        XCTAssertEqual(MCPResults.library(kind: "capture", slotNames: [], library: lib, query: "bright")["library"]!.arrayValue!.count, 1)
        XCTAssertEqual(MCPResults.library(kind: "capture", slotNames: [], library: lib, type: "PEDAL")["library"]!.arrayValue!.map { $0["name"]! }, ["Bass DI"])
        XCTAssertEqual(MCPResults.library(kind: "cab", slotNames: ["412 Brit"], library: lib)["library"], [["source": "factory", "name": "412 Brit"], ["source": "user", "name": "My IR"]])
    }
    func testCloudSearchMapping() throws {
        let reply = try JSONValue.parse(#"""
        {"numberOfResults": 41, "numberOfPages": 3, "data": [
          {"productId": "11111111-2222-4333-8444-555555555555", "name": "Glassy Clean", "hash": "ABC", "tags": ["clean", {"name": "jazz"}], "authorUsername": "maker",
           "downloads": 120, "likes": 7, "description": "A bright clean.", "metadata": {"instrument": "guitar", "device": "amp_head", "gain": "clean"}},
          {"productId": "11111111-2222-4333-8444-666666666666", "name": "Other", "hash": "def", "description": "\#(String(repeating: "x", count: 400))"}]}
        """#)
        let r = try XCTUnwrap(MCPResults.cloudSearch(reply, query: "clean", page: 1, libraryHashes: ["abc"]))
        XCTAssertEqual(r["total"], 41); XCTAssertEqual(r["pages"], 3); XCTAssertEqual(r["page"], 1)
        let first = r["results"]![0]!
        XCTAssertEqual(first, ["product_id": "11111111-2222-4333-8444-555555555555", "name": "Glassy Clean", "author": "maker", "tags": ["clean", "jazz"], "instrument": "guitar",
                               "device": "amp_head", "gain": "clean", "downloads": 120, "likes": 7, "description": "A bright clean.", "onPedal": true])
        XCTAssertEqual(r["results"]![1]!["onPedal"], false)
        XCTAssertEqual(r["results"]![1]!["description"]!.stringValue!.count, 300)
        XCTAssertEqual(MCPResults.cloudSearch(reply, query: "clean", page: 1, libraryHashes: nil)!["results"]![0]!["onPedal"], .null)
        XCTAssertNil(MCPResults.cloudSearch(["error": "x"], query: "q", page: 1, libraryHashes: nil))
    }
}

final class MCPEndpointTests: XCTestCase {
    func tempDir() -> String {
        let d = FileManager.default.temporaryDirectory.appending(path: "ncmcp-\(UUID().uuidString.prefix(8))").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: d) }
        return d
    }
    func testPath() {
        XCTAssertEqual(MCPEndpoint.current(environment: [:]).socket, "/tmp/nano-cortex-\(getuid())/editor.sock")
        XCTAssertEqual(MCPEndpoint.current(environment: ["NANO_MCP_DIR": "/tmp/x/../y"]).token, "/tmp/y/token")
    }
    func testPrivateFolder() throws {
        let d = tempDir()
        XCTAssertEqual(MCPEndpoint.checkPrivateDir(d), "the folder \(d) does not exist")
        XCTAssertNil(MCPEndpoint.checkPrivateDir(d, create: true))
        var st = stat(); lstat(d, &st); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        chmod(d, 0o755)
        XCTAssertEqual(MCPEndpoint.checkPrivateDir(d), "\(d) is not private (mode 755, expected 700)")
        chmod(d, 0o700)
        let link = d + "-link"
        symlink(d, link); defer { unlink(link) }
        XCTAssertEqual(MCPEndpoint.checkPrivateDir(link), "\(link) is a symbolic link")
        FileManager.default.createFile(atPath: d + "/f", contents: Data())
        XCTAssertEqual(MCPEndpoint.checkPrivateDir(d + "/f"), "\(d)/f is not a folder")
    }
    func testToken() throws {
        let d = tempDir()
        XCTAssertNil(MCPEndpoint.checkPrivateDir(d, create: true))
        let file = d + "/token"
        let t = try MCPEndpoint.writeToken(file)
        XCTAssertEqual(t.count, 64)
        XCTAssertEqual(MCPEndpoint.readToken(file), t)
        var st = stat(); lstat(file, &st); XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertNotEqual(try MCPEndpoint.writeToken(file), t)   // a new one each time
        chmod(file, 0o644)
        XCTAssertNil(MCPEndpoint.readToken(file))   // others could read it
        XCTAssertTrue(MCPEndpoint.sameToken(t, t)); XCTAssertFalse(MCPEndpoint.sameToken(t, String(t.reversed()))); XCTAssertFalse(MCPEndpoint.sameToken("", ""))
    }
    func testLineBuffer() {
        var b = MCPLineBuffer()
        var r = b.feed(Data("{\"a\":1}\n{\"b\"".utf8))
        XCTAssertEqual(r.items, [.message(["a": 1])])
        r = b.feed(Data(":2}\n\nnot json\n".utf8))
        XCTAssertEqual(r.items, [.message(["b": 2]), .bad]); XCTAssertFalse(r.overflow)
        // After a line that isn't JSON nothing more is read (the connection closes; endpoint.js lineReader, 275d8cc).
        XCTAssertTrue(b.ended)
        XCTAssertEqual(b.feed(Data("{\"c\":3}\n".utf8)).items, [])
        var long = MCPLineBuffer()
        XCTAssertTrue(long.feed(Data(repeating: 0x61, count: MCPLineBuffer.maxLine + 1)).overflow)
        XCTAssertEqual(long.feed(Data("\n{\"d\":4}\n".utf8)).items, [])   // the rest of the long line is never read as a message
    }
    /// Review #10 / 275d8cc: a line over 1 MiB is refused even when its newline arrives in the same chunk; the lines
    /// before it still count.
    func testLineLimitWithTheNewlineInTheSameChunk() {
        var b = MCPLineBuffer()
        let pad = String(repeating: "x", count: MCPLineBuffer.maxLine)
        let r = b.feed(Data("{\"a\":1}\n{\"p\":\"\(pad)\"}\n{\"b\":2}\n".utf8))
        XCTAssertEqual(r.items, [.message(["a": 1])]); XCTAssertTrue(r.overflow)
        // Exactly 1 MiB is still a message.
        var ok = MCPLineBuffer()
        let body = "{\"p\":\"" + String(repeating: "x", count: MCPLineBuffer.maxLine - 8) + "\"}"
        XCTAssertEqual(body.utf8.count, MCPLineBuffer.maxLine)
        let r2 = ok.feed(Data((body + "\n").utf8))
        XCTAssertFalse(r2.overflow); XCTAssertEqual(r2.items.count, 1)
    }
    func testHello() {
        let token = String(repeating: "ab", count: 32)
        let mismatch = MCPFixture.messages.contractMismatch
        XCTAssertEqual(MCPHello.check(["type": "hello", "token": .string(token), "contract": 1, "client": ["name": "claude-code", "version": "2.1.0"]], token: token, contract: 1, mismatch: mismatch),
                       .success(.init(name: "claude-code", version: "2.1.0")))
        XCTAssertEqual(MCPHello.check(["type": "hello", "token": .string(token), "contract": 2], token: token, contract: 1, mismatch: mismatch), .failure(MCPRefusal(mismatch)))
        XCTAssertEqual(MCPHello.check(["type": "hello", "token": "f", "contract": 1], token: token, contract: 1, mismatch: mismatch), .failure(MCPRefusal(MCPHello.wrongToken)))
        XCTAssertEqual(MCPHello.check(["type": "call", "id": 1], token: token, contract: 1, mismatch: mismatch), .failure(MCPRefusal(MCPHello.notHello)))
        XCTAssertEqual(MCPHello.accepted(version: "1.3.0", contract: 1)["editor"]?["edition"], "native")
        // tools.json → messages carries it (PROTOCOL.md §2 refers to it by name).
        XCTAssertTrue(mismatch.hasPrefix("This assistant's setup is from another version of Nano Cortex Editor."), mismatch)
    }
    /// Display names come from tools.json → clients (no table in code): every listed name, case-insensitive; control
    /// characters stripped, trimmed, cut to 60; empty or "unknown" → the fallback; anything else as sent.
    func testClientNamesFromTheContract() {
        let c = MCPFixture.contract.clients
        let listed = (MCPFixture.file["clients"] as! [String: Any])["names"] as! [String: String]
        XCTAssertFalse(listed.isEmpty)
        for (raw, shown) in listed {
            XCTAssertEqual(MCPClientNames.display(raw, clients: c), shown, raw)
            XCTAssertEqual(MCPClientNames.display(raw.uppercased(), clients: c), shown, raw)
        }
        XCTAssertEqual(MCPClientNames.display("  Visual Studio Code \n", clients: c), "VS Code")
        XCTAssertEqual(MCPClientNames.display("claude\u{7}-code", clients: c), "Claude Code")
        XCTAssertEqual(MCPClientNames.display("something-new", clients: c), "something-new")
        XCTAssertEqual(MCPClientNames.display(String(repeating: "x", count: 80), clients: c), String(repeating: "x", count: 60))
        XCTAssertEqual(MCPClientNames.display("", clients: c), "your AI assistant")
        XCTAssertEqual(MCPClientNames.display("Unknown", clients: c), c.fallback)
        XCTAssertEqual(c.fallback, (MCPFixture.file["clients"] as! [String: Any])["fallback"] as? String)
    }
}

final class MCPSetupTests: XCTestCase {
    let setup = MCPSetup(appBundle: "/Applications/Nano Cortex Editor.app")
    let helper = "/Applications/Nano Cortex Editor.app/Contents/Helpers/nano-cortex-mcp"
    func testLines() {
        XCTAssertEqual(setup.helper, helper)
        XCTAssertEqual(setup.claudeCode, "claude mcp add -s user nano-cortex -- \"\(helper)\"")
        XCTAssertEqual(setup.codex, "codex mcp add nano-cortex -- \"\(helper)\"")
        XCTAssertEqual(setup.json, "{\"mcpServers\":{\"nano-cortex\":{\"command\":\"\(helper)\"}}}")
        XCTAssertNoThrow(try JSONValue.parse(setup.json))
    }
    // MARK: Add to ChatGPT… (~/.codex/config.toml, PROTOCOL.md §4)

    func testTOMLStrings() {
        XCTAssertEqual(MCPSetup.tomlString("/Applications/A B.app"), #""/Applications/A B.app""#)
        XCTAssertEqual(MCPSetup.tomlString(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(MCPSetup.tomlString("x\ty\nz\u{7}"), #""x\ty\nz\u0007""#)
        XCTAssertEqual(setup.chatGPTTable, "[mcp_servers.nano-cortex]\ncommand = \"\(helper)\"\n")
    }
    func testFindsAnExistingServer() {
        XCTAssertFalse(MCPSetup.codexHasServer(nil))
        XCTAssertFalse(MCPSetup.codexHasServer(Data("[mcp_servers.other]\ncommand = \"x\"\n# [mcp_servers.nano-cortex] in a comment\n".utf8)))
        for t in ["[mcp_servers.nano-cortex]", "  [ mcp_servers . \"nano-cortex\" ]", "[mcp_servers.nano-cortex.env]", "mcp_servers.nano-cortex.command = \"x\""] {
            XCTAssertTrue(MCPSetup.codexHasServer(Data("model = \"o3\"\n\(t)\n".utf8)), t)
        }
        XCTAssertFalse(MCPSetup.codexHasServer(Data("[mcp_servers.nano-cortex-old]\n".utf8)))
    }
    func testAddToAMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: ".codex/config.toml").path
        XCTAssertEqual(try setup.addToCodexConfig(path: path), .added(backup: nil))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), setup.chatGPTTable)
        XCTAssertEqual(try setup.addToCodexConfig(path: path), .alreadyThere)   // a second click changes nothing
    }
    func testAddKeepsTheOtherTablesAndBacksUp() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "config.toml").path
        let before = "model = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"npx\"\nargs = [\"-y\", \"x\"]\n\n[mcp_servers.other.env]\nA = \"1\""   // no newline at the end
        try before.write(toFile: path, atomically: true, encoding: .utf8)
        guard case .added(let backup?) = try setup.addToCodexConfig(path: path, now: Date(timeIntervalSince1970: 0)) else { return XCTFail("not added") }
        XCTAssertEqual(try String(contentsOfFile: backup, encoding: .utf8), before)
        XCTAssertTrue(backup.hasSuffix(".toml") && backup.contains("config.backup-"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before + "\n\n" + setup.chatGPTTable)
    }
    func testAnExistingTableIsLeftAlone() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "config.toml").path
        let before = "[mcp_servers.nano-cortex]\ncommand = \"/old/path\"\n"
        try before.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(try setup.addToCodexConfig(path: path), .alreadyThere)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["config.toml"])   // no backup either
    }
    func testClaudeDesktopMerge() throws {
        let existing = Data(#"{"globalShortcut":"Cmd+Space","mcpServers":{"other":{"command":"x","args":["-y"],"env":{"A":"1"}}},"flag":true}"#.utf8)
        let merged = try JSONValue.parse(setup.mergedClaudeDesktopConfig(existing))
        XCTAssertEqual(merged["globalShortcut"], "Cmd+Space"); XCTAssertEqual(merged["flag"], true)
        XCTAssertEqual(merged["mcpServers"]?["other"], ["command": "x", "args": ["-y"], "env": ["A": "1"]])
        XCTAssertEqual(merged["mcpServers"]?["nano-cortex"], ["command": .string(helper)])
        XCTAssertTrue(setup.claudeDesktopHasEntry(try setup.mergedClaudeDesktopConfig(existing)))
        XCTAssertFalse(setup.claudeDesktopHasEntry(existing))
        XCTAssertEqual(try JSONValue.parse(setup.mergedClaudeDesktopConfig(nil)), ["mcpServers": ["nano-cortex": ["command": .string(helper)]]])
        XCTAssertEqual(try JSONValue.parse(setup.mergedClaudeDesktopConfig(Data("  \n".utf8)))["mcpServers"]?["nano-cortex"], ["command": .string(helper)])
        XCTAssertThrowsError(try setup.mergedClaudeDesktopConfig(Data("{oops".utf8))) { XCTAssertEqual($0 as? MCPSetup.MergeError, .notAnObject) }
        XCTAssertThrowsError(try setup.mergedClaudeDesktopConfig(Data(#"{"mcpServers":[]}"#.utf8))) { XCTAssertEqual($0 as? MCPSetup.MergeError, .serversNotAnObject) }
        XCTAssertEqual(MCPSetup.claudeDesktopConfig(home: "/Users/u"), "/Users/u/Library/Application Support/Claude/claude_desktop_config.json")
    }
}


/// PROTOCOL.md §4's rules outside the tone plan: which tools need a pedal, slot ranges, slot plus off, nothing to save,
/// the tempo range per firmware, preset names the dialogs accept.
final class MCPRulesTests: XCTestCase {
    let m = MCPFixture.messages
    func testWhichToolsNeedAPedal() {
        let without = MCPFixture.contract.tools.map(\.name).filter { !MCPRules.needsPedal($0) }
        XCTAssertEqual(without, ["get_status", "cloud_search", "cloud_open"])   // cloud_preview and cloud_send need one
    }
    func testSlotRange() {
        XCTAssertNil(MCPRules.slotRange(25, field: "slot", count: 25, cab: false, messages: m))
        XCTAssertEqual(MCPRules.slotRange(26, field: "slot", count: 25, cab: false, messages: m)?.message, "slot must be between 1 and 25 (the capture slots on this pedal).")
        XCTAssertEqual(MCPRules.slotRange(9, field: "slot", count: 5, cab: true, messages: m)?.message, "slot must be between 1 and 5 (the cab/IR slots on this pedal).")
    }
    func testSlotOrOff() {
        XCTAssertEqual(MCPRules.useSlot(slot: 2, on: false, messages: m)?.message, "Give either slot or on: false, not both.")
        XCTAssertNil(MCPRules.useSlot(slot: 2, on: true, messages: m))
        XCTAssertNil(MCPRules.useSlot(slot: 2, on: nil, messages: m))
        XCTAssertNil(MCPRules.useSlot(slot: nil, on: false, messages: m))
        XCTAssertEqual(MCPRules.useSlot(slot: nil, on: nil, messages: m)?.message, "Give slot, on, or both.")
    }
    func testNothingToSave() {
        XCTAssertEqual(MCPRules.save(unsaved: false, number: 12, messages: m)?.message, "Preset 12 has no unsaved edits, so there is nothing to save.")
        XCTAssertNil(MCPRules.save(unsaved: true, number: 12, messages: m))
    }
    func testTempoRangePerFirmware() {
        // NanOS 2.3+: 40–240 with one decimal kept; before: 30–300 whole BPM. The schema allows 30–300.
        XCTAssertEqual(MCPFixture.schema("set_tempo")["properties"]?["bpm"]?["minimum"], 30)
        XCTAssertEqual(MCPFixture.schema("set_tempo")["properties"]?["bpm"]?["maximum"], 300)
        XCTAssertEqual(try MCPRules.tempo(120.46, nanos23: true, messages: m).get(), 120.5)
        XCTAssertEqual(MCPRules.tempo(30, nanos23: true, messages: m).failureMessage, "This pedal takes 40–240 BPM.")
        XCTAssertEqual(MCPRules.tempo(250, nanos23: true, messages: m).failureMessage, "This pedal takes 40–240 BPM.")
        XCTAssertEqual(try MCPRules.tempo(30, nanos23: false, messages: m).get(), 30)
        XCTAssertEqual(try MCPRules.tempo(250.4, nanos23: false, messages: m).get(), 250)
        XCTAssertEqual(MCPRules.tempo(29, nanos23: false, messages: m).failureMessage, "This pedal takes 30–300 BPM.")
    }
    /// Review #10: the name is checked as the dialog's own button would check it, before the dialog opens.
    func testPresetName() {
        XCTAssertNil(MCPRules.presetName("Glassy clean"))
        XCTAssertEqual(MCPRules.presetName("   a   ")?.message, "name must have at least 4 characters (not counting spaces at the ends).")
        XCTAssertNil(MCPFixture.validate("rename", ["name": "   a   "]))   // the schema's minLength alone lets it through
        XCTAssertNotNil(MCPRules.presetName(String(repeating: "é", count: 40)))   // 40 characters, 80 bytes
        XCTAssertNil(MCPRules.presetName(String(repeating: "e", count: 64)))
    }
}

/// Review #2: a model the editor chose itself starts from its defaults; saved values never stand in for it.
final class FXChosenModelTests: XCTestCase {
    func testSavedValuesDoNotReplaceAChosenModel() {
        let od1 = MCPFixture.model("Chief OD1", .pre1)
        var saved = FXSavedValues()
        let high = od1.wireFloats(od1.params.map { $0.name == "Level" ? 80 : $0.defaultValue })!
        saved.save(high, pedal: "P", preset: 0, slot: .pre1, model: od1)
        var b = FXSlotState(model: MCPFixture.model("Chief BD2", .pre1), on: false, preset: 0)
        b.choose(od1, preset: 0)
        XCTAssertFalse(b.applySaved(saved.entry(pedal: "P", preset: 0, slot: .pre1, model: od1), preset: 0))
        XCTAssertEqual(b.values, od1.params.map(\.defaultValue))
        XCTAssertFalse(b.fromSaved)
        // After a reset (another preset) saved values may show again, as before.
        b.reset(preset: 1)
        XCTAssertTrue(b.applySaved(saved.entry(pedal: "P", preset: 0, slot: .pre1, model: od1), preset: 1))
    }
}
