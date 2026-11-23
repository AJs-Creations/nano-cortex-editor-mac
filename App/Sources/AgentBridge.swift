// AI assistants (MCP), the editor's side (mcp/PROTOCOL.md §4): every tool of mcp/tools.json mapped onto PedalStore's
// existing actions, the same ones the UI and the dev remote's /amp, /fxmodel, /fxparam, /capture, /cab, /gate, /preset,
// /save, /rename, /footswitch, /pick, /scan, /audition, /cloud, /send … routes use, so every write goes through the real
// packet builders. NanoCore decides (validation, loudness limits, the tone plan, the result shapes: MCP*.swift); this
// file runs it. Calls arrive one at a time (AgentServer's queue). Confirmation tools open the editor's own dialogs and
// wait for the click; the confirming click runs exactly what the user's own click would. No tool runs code, sends raw
// packets, touches files or reaches the dev remote (DECISIONS #45).

import AppKit
import NanoCore

/// A confirmation in the editor's style for an assistant's call (AgentPromptSheet, ContentView).
struct AgentPrompt: Identifiable, Equatable {
    let id = UUID()
    let tool: String
    let askedBy: String
    let title: String
    let lines: [String]
    let confirm: String
}

enum AgentWaitKind: Equatable { case prompt, saveAs, rename, send }
enum AgentOutcome: Equatable { case confirmed, cancelled, saved(Int, String), renamed(Int, String), sent(String), failed(String) }
/// The one dialog an assistant's call is waiting on.
struct AgentWait {
    let kind: AgentWaitKind
    var confirmed = false
    let answer: CheckedContinuation<AgentOutcome, Never>
}

extension PedalStore {
    /// Waits for the dialog of `kind` (opened by the caller) to be answered.
    func waitForAgent(_ kind: AgentWaitKind) async -> AgentOutcome {
        if let old = agentWait { agentWait = nil; old.answer.resume(returning: .cancelled) }
        return await withCheckedContinuation { agentWait = AgentWait(kind: kind, answer: $0) }
    }
    /// The answer (only for the dialog an assistant is waiting on).
    func resolveAgent(_ kind: AgentWaitKind, _ outcome: AgentOutcome) {
        guard let w = agentWait, w.kind == kind else { return }
        agentWait = nil
        if kind == .prompt { agentPrompt = nil }
        agentAskedBy = nil
        w.answer.resume(returning: outcome)
    }
    /// A sheet closed: Cancel, Escape or closing it is a cancel, unless its confirming click already went through.
    func agentSheetClosed(_ kind: AgentWaitKind) {
        guard let w = agentWait, w.kind == kind, !w.confirmed else { return }
        resolveAgent(kind, .cancelled)
    }
    func answerAgentPrompt(_ confirm: Bool) { resolveAgent(.prompt, confirm ? .confirmed : .cancelled) }
}

@MainActor
final class AgentBridge {
    let store: PedalStore
    let cloud: CloudController
    let contract: MCPContract?
    weak var server: AgentServer?

    init(store: PedalStore, cloud: CloudController) {
        self.store = store; self.cloud = cloud
        contract = Self.loadContract()
    }

    /// The copy the app bundles (Contents/Resources/mcp/tools.json), the same file its helper serves.
    static func loadContract() -> MCPContract? {
        guard let url = Bundle.main.url(forResource: "tools", withExtension: "json", subdirectory: "mcp"), let data = try? Data(contentsOf: url) else { return nil }
        return try? MCPContract(data: data)
    }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    typealias Outcome = Result<JSONValue, MCPRefusal>

    // MARK: - one call

    /// Validates, checks the link and the busy state, runs the tool and logs one Activity line.
    func call(_ name: String, args: JSONValue, client raw: String) async -> Outcome {
        let client = MCPClientNames.display(raw)
        guard let contract else { return .failure(MCPRefusal("The editor's tool list is missing from the app; reinstall Nano Cortex Editor.")) }
        let outcome: Outcome
        do {
            guard let tool = contract.tool(name) else { throw MCPRefusal("Unknown tool: \(name).") }
            if let why = MCPValidator.validate(args, schema: tool.schema) { throw MCPRefusal(why) }
            let a = args.objectValue ?? [:]
            if name != "get_status" && tool.kind != .cloud && (!store.connected || store.state == nil) { throw MCPRefusal(contract.errors.notConnected) }
            if tool.kind == .live || tool.kind == .confirm || (name == "get_slot_usage" && a["scan"]?.boolValue == true), await userBusy() {
                throw MCPRefusal(contract.errors.busy)
            }
            let (result, summary) = try await run(name, a, client: client, tool: tool)
            store.append("Assistant: \(summary)")
            outcome = .success(result)
        } catch let r as MCPRefusal {
            outcome = .failure(r)
            if r.message == contract.errors.cancelled { store.append("Assistant: \(name) cancelled in the editor's dialog") }
            else { store.append("Assistant: refused \(name): \(r.message)") }
        } catch {
            outcome = .failure(MCPRefusal("\(error)"))
            store.append("Assistant: refused \(name): \(error)")
        }
        return outcome
    }

    /// A transfer, a scan, an audition starting or stopping, a preset move, or one of the user's own dialogs.
    func userBusy() async -> Bool {
        let s = store
        if s.uploading || s.scanning != nil || s.auditions.capture.busy || s.auditions.ir.busy || s.reorder.moving { return true }
        if s.saveAsOpen || s.renameOpen || s.slotChooser != nil || s.pendingSend != nil || s.pendingPreset != nil || s.pendingAssignment != nil
            || s.discardRequested || s.deleteTarget != nil || s.offerSlot != nil || s.auditions.irSend != nil || s.auditions.irDelete != nil
            || s.confirmSignOut || s.reorder.prompt != nil || s.agentPrompt != nil { return true }
        if let session = s.session, await session.streamBusy != nil { return true }
        return false
    }

    private var errors: MCPContract.Errors { contract!.errors }
    private var safety: MCPContract.Safety { contract!.safety }

    // swiftlint:disable:next cyclomatic_complexity
    private func run(_ name: String, _ a: [String: JSONValue], client: String, tool: MCPContract.Tool) async throws -> (JSONValue, String) {
        switch name {
        // MARK: read
        case "get_status": return (status(), "read the status")
        case "get_current_preset": return (currentPreset(), "read the current preset")
        case "list_presets":
            return (MCPResults.listPresets(names: store.presetNames, current: store.state?.presetIndex, footswitch: store.footswitch), "listed the presets")
        case "list_library":
            let kind = a["kind"]?.stringValue ?? "capture"
            guard let lib = await store.ensureLibrary() else { throw MCPRefusal("The pedal did not send its library. Try again in a moment.") }
            let names = kind == "cab" ? Array((store.metadata?.irNames ?? []).prefix(store.cabSlotCount)) : Array((store.metadata?.captureNames ?? []).prefix(store.captureSlotCount))
            return (MCPResults.library(kind: kind, slotNames: names, library: lib, instrument: a["instrument"]?.stringValue, type: a["type"]?.stringValue, query: a["query"]?.stringValue),
                    "listed the \(kind) library")
        case "list_effects":
            return (MCPResults.listEffects(slot: a["slot"]?.stringValue.flatMap(Slot.init(rawValue:))), "listed the effects")
        case "get_slot_usage":
            if a["scan"]?.boolValue == true {
                if store.dirtyForPrompt { throw MCPRefusal(errors.unsavedEdits) }
                await store.scanSlotUsage()
            }
            let u = store.usage
            return (MCPResults.slotUsage(captures: u?.captures, cabs: u?.cabs), a["scan"]?.boolValue == true ? "scanned which presets use which slots" : "read the slot usage")

        // MARK: live
        case "apply_tone": return try await applyTone(a)
        case "set_amp":
            var p = MCPTonePlan()
            try MCPTone.planAmp(a, state: toneState(), safety: safety, into: &p)
            guard !p.isEmpty else { throw MCPRefusal("Give at least one of gain, bass, mid, treble, level, volume_db.") }
            execute(p)
            return (["summary": .string(p.lines.joined(separator: "; ")), "amp": ampJSON()], p.lines.joined(separator: "; "))
        case "set_effect":
            guard let slot = a["slot"]?.stringValue.flatMap(Slot.init(rawValue:)) else { throw MCPRefusal("slot is required.") }
            guard a["model"] != nil || a["on"] != nil else { throw MCPRefusal("Give model, on, or both.") }
            var p = MCPTonePlan()
            try MCPTone.planEffect(slot: slot, model: a["model"]?.stringValue, params: [:], on: a["on"]?.boolValue, state: toneState(), safety: safety, into: &p)
            await execute(p, settle: true)
            let summary = p.isEmpty ? "\(slot.title) unchanged" : p.lines.joined(separator: "; ")
            let b = store.blocks[slot]
            return (["summary": .string(summary), "slot": .string(slot.rawValue), "model": .string(b?.model?.name ?? (b?.unknownId != nil ? "Unknown effect" : "None")), "on": .bool(b?.on ?? false)], summary)
        case "set_effect_param":
            guard let slot = a["slot"]?.stringValue.flatMap(Slot.init(rawValue:)), let param = a["param"]?.stringValue, let value = a["value"] else { throw MCPRefusal("slot, param and value are required.") }
            var p = MCPTonePlan()
            try MCPTone.planEffect(slot: slot, model: nil, params: [param: value], on: nil, state: toneState(), safety: safety, into: &p)
            execute(p)
            let c = p.effects.first?.params.first
            var shown: JSONValue = .null
            if let c, let def = store.blocks[slot]?.model?.params.first(where: { $0.index == c.index }) {
                if case .options(let o)? = def.meta, o.indices.contains(Int(c.value)) { shown = .string(o[Int(c.value)]) } else { shown = .number(c.value) }
            }
            return (["summary": .string(p.lines.joined(separator: "; ")), "slot": .string(slot.rawValue), "param": .string(c?.name ?? param),
                     "value": shown, "display": .string(c?.display ?? "")], p.lines.joined(separator: "; "))
        case "set_gate":
            var p = MCPTonePlan()
            MCPTone.planGate(a, into: &p)
            guard !p.isEmpty else { throw MCPRefusal("Give on, reduction, or both.") }
            execute(p)
            return (["summary": .string(p.lines.joined(separator: "; ")), "gate": ["on": .bool(store.gateOn), "reduction": .number(Double(store.gateReduction))]], p.lines.joined(separator: "; "))
        case "set_cab_tone":
            guard store.cab.on else { throw MCPRefusal("The preset's cab/IR is off; choose a cab slot first (use_cab_slot).") }
            var p = MCPTonePlan()
            try MCPTone.planCabTone(a, state: toneState(), safety: safety, into: &p)
            guard !p.isEmpty else { throw MCPRefusal("Give at least one of level_db, high_pass_hz, low_pass_hz.") }
            execute(p)
            let c = store.cab
            return (["summary": .string(p.lines.joined(separator: "; ")), "cab": ["level_db": .number((c.levelDb * 10).rounded() / 10), "high_pass_hz": .number(c.highPassHz.rounded()), "low_pass_hz": .number(c.lowPassHz.rounded())]],
                    p.lines.joined(separator: "; "))
        case "use_capture_slot": return try await useCaptureSlot(a)
        case "use_cab_slot": return try await useCabSlot(a)
        case "set_tempo":
            let bpm = a["bpm"]?.numberValue ?? 120
            if store.tempoLocked { throw MCPRefusal("An external MIDI clock sets the tempo right now, so it can't be changed.") }
            let r = store.tempoRange
            guard r.contains(bpm) else { throw MCPRefusal("This pedal takes \(MCPValidator.format(r.lowerBound))–\(MCPValidator.format(r.upperBound)) BPM.") }
            store.setTempo(bpm, live: false)
            try? await Task.sleep(for: .milliseconds(200))
            let shown = store.presetTempo ?? bpm
            let summary = "tempo \(MCPValidator.format(shown)) BPM"
            return (["summary": .string(summary), "tempo": ["bpm": .number(shown)]], summary)
        case "select_preset":
            let index = (a["number"]?.intValue ?? 1) - 1
            if store.dirtyForPrompt {
                store.toast("\(client) wanted to load preset \(index + 1). Save or discard your edits first.")
                throw MCPRefusal(errors.unsavedEdits)
            }
            if index != store.presetIndex {
                store.selectPreset(index)
                guard await until(seconds: 6, { self.store.presetIndex == index && self.store.state != nil }) else { throw MCPRefusal("The pedal did not switch to preset \(index + 1).") }
            }
            let summary = "loaded preset \(index + 1) “\(store.presetName(index))”"
            return (["summary": .string(summary), "preset": ["number": .number(Double(index + 1)), "name": .string(store.presetName(index))]], summary)
        case "discard_edits":
            if store.refuseIfPresetUnknown() { throw MCPRefusal(PresetKnowledge.message) }
            await store.discardEdits()
            let summary = "discarded the unsaved edits of preset \(store.presetIndex + 1)"
            return (["summary": .string(summary), "preset": ["number": .number(Double(store.presetIndex + 1)), "name": .string(store.presetName(store.presetIndex)), "unsaved": .bool(store.dirtyForPrompt)]], summary)
        case "preview_cab":
            let factory = a["source"]?.stringValue != "user", wanted = a["name"]?.stringValue ?? ""
            guard let lib = await store.ensureLibrary() else { throw MCPRefusal("The pedal did not send its library. Try again in a moment.") }
            guard let item = (factory ? lib.factoryIRs : lib.userIRs).first(where: { IRTransfer.sameName($0.name, wanted) || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
                throw MCPRefusal("There is no \(factory ? "factory cab" : "user IR") named “\(wanted)”. list_library kind=cab lists them.")
            }
            guard await store.startIRPreview(IRRef(factory: factory, index: item.index, name: item.name)) else { throw MCPRefusal("The pedal did not start the preview of \(item.name).") }
            let summary = "previewing \(factory ? "cab" : "IR") \(item.name)"
            return (["summary": .string(summary), "audition": ["kind": "cab", "name": .string(item.name)]], summary)
        case "stop_preview":
            var stopped: [String] = []
            if store.auditions.capture.phase == .active {
                guard await store.stopCapturePreview() else { throw MCPRefusal("The pedal did not confirm stopping the Live Preview; it may still be playing.") }
                stopped.append("the Live Preview")
            }
            if store.auditions.ir.active != nil {
                guard await store.stopIRPreview() else { throw MCPRefusal("The pedal did not confirm stopping the cab preview; it may still be playing.") }
                stopped.append("the cab preview")
            }
            let summary = stopped.isEmpty ? "stop_preview: nothing was playing" : "stopped " + stopped.joined(separator: " and ")
            return (["summary": .string(summary), "stopped": .bool(!stopped.isEmpty)], summary)

        // MARK: confirm
        case "save": return try await save(client)
        case "save_as": return try await saveAs(a, client)
        case "rename": return try await rename(a, client)
        case "load_capture_into_slot", "load_cab_into_slot": return try await loadIntoSlot(a, cab: name == "load_cab_into_slot", client)
        case "set_cab_mic": return try await setCabMic(a, client)
        case "assign_footswitch": return try await assignFootswitch(a, client)

        // MARK: Cortex Cloud
        case "cloud_search": return try await cloudSearch(a)
        case "cloud_open":
            let id = a["product_id"]?.stringValue?.lowercased() ?? ""
            guard let url = CaptureText.cloudURL(id) else { throw MCPRefusal("product_id is not a Cortex Cloud product id.") }
            cloud.go(url)
            store.tab = .cloud
            bringToFront()
            let summary = "opened Cortex Cloud capture \(id) in the Cloud tab"
            return (["summary": .string(summary), "opened": true, "product_id": .string(id), "url": .string(url.absoluteString)], summary)
        case "cloud_preview":
            let id = a["product_id"]?.stringValue?.lowercased() ?? ""
            if let why = await store.startCapturePreview(fetch: { try await self.fetchBundle(id) }) { throw MCPRefusal(why) }
            let name = store.auditions.capture.name
            let summary = "Live Preview of \(name)"
            return (["summary": .string(summary), "previewing": true, "name": .string(name), "product_id": .string(id)], summary)
        case "cloud_send": return try await cloudSend(a, client)
        default: throw MCPRefusal("Unknown tool: \(name).")
        }
    }

    // MARK: - state as JSON

    func status() -> JSONValue {
        let connected = store.connected && store.state != nil
        let a = store.auditions
        let audition: JSONValue = a.capture.phase != .idle ? ["kind": "capture", "name": .string(a.capture.name)]
            : a.ir.active.map { ["kind": "cab", "name": .string($0.name)] } ?? .null
        return ["editor": ["edition": "native", "version": .string(Self.version)],
                "connected": .bool(connected),
                "pedal": connected ? ["name": .string(store.demo ? "Demo pedal" : store.pedalName), "firmware": store.state?.firmware.map(JSONValue.string) ?? .null] : .null,
                "preset": connected ? ["number": .number(Double(store.presetIndex + 1)), "name": .string(store.presetName(store.presetIndex)), "unsaved": .bool(store.dirtyForPrompt)] : .null,
                "audition": audition,
                "cloud": ["signedIn": store.demo ? true : cloud.signedIn.map(JSONValue.bool) ?? .null],
                "assistants": ["clients": .array((server?.clientNames ?? []).map(JSONValue.string))]]
    }

    func ampJSON() -> JSONValue {
        func k(_ knob: AmpKnob) -> JSONValue { .number(MCPToneState.knob(store.amp[knob] ?? 0)) }
        return ["gain": k(.gain), "bass": k(.bass), "mid": k(.mid), "treble": k(.treble), "level": k(.level), "volume_db": .number((store.captureVolumeDb * 10).rounded() / 10)]
    }

    func currentPreset() -> JSONValue {
        let s = store, c = s.cab, factoryCab = s.state?.cabMicAndPosition != nil
        let i = s.presetIndex
        return ["number": .number(Double(i + 1)), "name": .string(s.presetName(i)), "unsaved": .bool(s.dirtyForPrompt),
                "amp": ampJSON(),
                "capture": ["on": .bool(s.captureOn), "slot": s.captureFromLibrary ? .null : s.captureSlot.map { .number(Double($0)) } ?? .null,
                            "name": .string(s.captureName), "fromLibrary": .bool(s.captureFromLibrary)],
                "cab": ["on": .bool(c.on), "slot": c.fromLibrary || c.slot == 0 ? .null : .number(Double(c.slot)), "name": .string(c.name), "factory": .bool(factoryCab),
                        "mic": factoryCab ? .string(c.mic) : .null, "position": factoryCab ? .number(Double(c.position)) : .null,
                        "mics": .array((factoryCab ? s.cabMicChoices : []).map(JSONValue.string)), "level_db": .number((c.levelDb * 10).rounded() / 10), "high_pass_hz": .number(c.highPassHz.rounded()),
                        "low_pass_hz": .number(c.lowPassHz.rounded()), "fromLibrary": .bool(c.fromLibrary)],
                "gate": ["on": .bool(s.gateOn), "reduction": .number(Double(s.gateReduction))],
                "effects": .array(Slot.allCases.map { MCPResults.effect(slot: $0, block: s.blocks[$0], preset: i) }),
                "tempo": ["bpm": s.presetTempo.map(JSONValue.number) ?? .null]]
    }

    /// The values the loudness limits compare with: what the editor shows before the call.
    func toneState() -> MCPToneState {
        var fx: [Slot: MCPToneState.Effect] = [:]
        for slot in Slot.allCases {
            let b = store.blocks[slot]
            fx[slot] = MCPToneState.Effect(model: b?.model, unknown: b?.unknownId != nil, on: b?.on ?? false, values: b?.values)
        }
        let caps = Array((store.metadata?.captureNames ?? []).prefix(store.captureSlotCount))
        let irs = Array((store.metadata?.irNames ?? []).prefix(store.cabSlotCount))
        return MCPToneState(amp: store.amp, captureVolumeDb: store.captureVolumeDb, cabLevelDb: store.cab.levelDb, gateOn: store.gateOn, gateReduction: store.gateReduction,
                            effects: fx, captureNames: caps, irNames: irs)
    }

    // MARK: - live edits

    /// Runs a plan through PedalStore's own actions, in the documented order. `settle`: after a model change, give
    /// the pedal a moment to load it before its parameters (as a person would).
    func execute(_ p: MCPTonePlan, settle: Bool = false) {
        if let n = p.captureSlot { store.setCapture(slot: n) }
        if let n = p.cabSlot { store.selectCab(slot: n) }
        for c in p.amp { store.setAmp(c.knob, c.raw, commit: true) }
        if let v = p.volumeDb { store.setCaptureVolume(v, commit: true) }
        if let on = p.gateOn { store.setGate(on: on) }
        if let r = p.gateReduction { store.setGateReduction(r, commit: true) }
        if let v = p.cabLevelDb { store.setCabLevel(v, commit: true) }
        if let v = p.cabHighPassHz { store.setCabHighPass(v, commit: true) }
        if let v = p.cabLowPassHz { store.setCabLowPass(v, commit: true) }
        for e in p.effects { executeEffect(e) }
    }
    func execute(_ p: MCPTonePlan, settle: Bool) async {
        execute(p)
        if settle, p.effects.contains(where: { $0.model != nil }) { try? await Task.sleep(for: .milliseconds(300)) }
    }
    private func executeEffect(_ e: MCPTonePlan.EffectChange) {
        switch e.model {
        case .empty?: store.setFXModel(e.slot, nil)
        case .model(let m)?: store.setFXModel(e.slot, m)
        case nil: break
        }
        for p in e.params { store.setFXParam(e.slot, index: p.index, value: p.value, commit: true) }
        if let on = e.on, store.blocks[e.slot]?.on != on { store.setFX(e.slot, on: on) }
    }

    /// Everything checked first (nothing changes when any part is refused), then applied in order, then the pedal's
    /// state read back (at most ~3 s).
    private func applyTone(_ a: [String: JSONValue]) async throws -> (JSONValue, String) {
        var plan: MCPTonePlan
        switch MCPTone.plan(applyTone: a, state: toneState(), safety: safety) { case .success(let p): plan = p; case .failure(let r): throw r }
        if plan.cabLevelDb != nil || plan.cabHighPassHz != nil || plan.cabLowPassHz != nil, !store.cab.on, plan.cabSlot == nil {
            throw MCPRefusal("The preset's cab/IR is off; add cab_slot to choose one before cab_tone.")
        }
        // Slots and amp first, then each effect with its model change given time to load before its parameters.
        var head = plan; head.effects = []
        execute(head)
        for e in plan.effects {
            executeEffect(MCPTonePlan.EffectChange(slot: e.slot, model: e.model, params: [], on: nil))
            if e.model != nil, !e.params.isEmpty || e.on != nil { try? await Task.sleep(for: .milliseconds(300)) }
            executeEffect(MCPTonePlan.EffectChange(slot: e.slot, model: nil, params: e.params, on: e.on))
        }
        plan.lines = plan.lines.isEmpty ? ["nothing to change"] : plan.lines
        // Let the edit writes go out, then read the pedal back (the reply also triggers the effect reads).
        _ = await until(seconds: 1.5) { !self.store.live.edits.pending(now: Date()) }
        try? await Task.sleep(for: .milliseconds(250))
        let read = Task { await self.store.refreshState() }
        let waited = Task { try? await Task.sleep(for: .seconds(3)); read.cancel() }
        await read.value
        waited.cancel()
        try? await Task.sleep(for: .milliseconds(300))
        return (["changes": .array(plan.lines.map(JSONValue.string)), "preset": currentPreset()], "apply_tone: " + plan.lines.joined(separator: "; "))
    }

    private func useCaptureSlot(_ a: [String: JSONValue]) async throws -> (JSONValue, String) {
        let slot = a["slot"]?.intValue, on = a["on"]?.boolValue
        guard slot != nil || on != nil else { throw MCPRefusal("Give slot, on, or both.") }
        var line: String
        if on == false {
            guard slot == nil else { throw MCPRefusal("slot and on: false contradict each other; give one of them.") }
            if store.captureOn { store.toggleCapture() }
            line = "capture off"
        } else if let slot {
            var p = MCPTonePlan()
            try MCPTone.planCaptureSlot(slot, state: toneState(), into: &p)
            store.setCapture(slot: slot)
            line = p.lines[0]
        } else {
            if !store.captureOn { store.toggleCapture() }
            line = "capture on (slot \(store.captureSlot ?? 1))"
        }
        try? await Task.sleep(for: .milliseconds(450))   // setCapture reads the state back after 300 ms
        return (["summary": .string(line), "capture": ["on": .bool(store.captureOn), "slot": store.captureSlot.map { .number(Double($0)) } ?? .null, "name": .string(store.captureName)]], line)
    }

    private func useCabSlot(_ a: [String: JSONValue]) async throws -> (JSONValue, String) {
        let slot = a["slot"]?.intValue, on = a["on"]?.boolValue
        guard slot != nil || on != nil else { throw MCPRefusal("Give slot, on, or both.") }
        var line: String
        if on == false {
            guard slot == nil else { throw MCPRefusal("slot and on: false contradict each other; give one of them.") }
            if store.cab.on { if store.cab.slot > 0 { store.auditions.lastCabSlot = store.cab.slot }; store.selectCab(slot: 0) }
            line = "cab off"
        } else if let slot {
            var p = MCPTonePlan()
            try MCPTone.planCabSlot(slot, state: toneState(), into: &p)
            store.selectCab(slot: slot)
            line = p.lines[0]
        } else {
            let back = store.auditions.lastCabSlot ?? max(1, store.cab.slot)
            if !store.cab.on { store.selectCab(slot: back) }
            line = "cab on (slot \(store.cab.slot))"
        }
        try? await Task.sleep(for: .milliseconds(450))
        let c = store.cab
        return (["summary": .string(line), "cab": ["on": .bool(c.on), "slot": c.slot > 0 && !c.fromLibrary ? .number(Double(c.slot)) : .null, "name": .string(c.name)]], line)
    }

    // MARK: - confirmations

    /// Shows the editor's confirmation for an assistant's call and waits for the answer.
    private func confirm(_ tool: String, askedBy: String, title: String, lines: [String], button: String) async -> Bool {
        store.agentPrompt = AgentPrompt(tool: tool, askedBy: askedBy, title: title, lines: lines, confirm: button)
        store.tab = .editor
        bringToFront()
        return await store.waitForAgent(.prompt) == .confirmed
    }

    private func save(_ client: String) async throws -> (JSONValue, String) {
        if store.refuseIfPresetUnknown() { throw MCPRefusal(PresetKnowledge.message) }
        let i = store.presetIndex, name = store.presetName(i)
        guard await confirm("save", askedBy: client, title: "Save changes to preset \(i + 1) “\(name)”?",
                            lines: ["The unsaved edits are written into this preset on the pedal, replacing what it has stored."], button: "Save")
        else { throw MCPRefusal(errors.cancelled) }
        guard await store.save() else { throw MCPRefusal("The pedal did not save the preset (see the editor's message).") }
        let summary = "saved preset \(i + 1) “\(store.presetName(i))”"
        return (["saved": true, "number": .number(Double(i + 1)), "name": .string(store.presetName(i))], summary)
    }

    private func saveAs(_ a: [String: JSONValue], _ client: String) async throws -> (JSONValue, String) {
        if store.refuseIfPresetUnknown() { throw MCPRefusal(PresetKnowledge.message) }
        let name = a["name"]?.stringValue ?? ""
        guard name.trimmingCharacters(in: .whitespaces).count >= 4 else { throw MCPRefusal("name must have at least 4 characters (not counting spaces at the ends).") }
        let count = max(64, store.presetNames.count)
        var target: Int
        if let n = a["number"]?.intValue {
            target = n - 1
            guard target != store.presetIndex else { throw MCPRefusal("Preset \(n) is the current preset; save_as writes to another one (use save to overwrite this one).") }
        } else {
            target = (0..<count).first { $0 != store.presetIndex && store.presetName($0) == "Empty" } ?? (store.presetIndex + 1) % count
        }
        store.agentSaveAs = (target, name)
        store.saveAsTarget = target
        store.saveAsPrefill = name
        store.agentAskedBy = client
        store.tab = .editor
        store.saveAsOpen = true
        bringToFront()
        let outcome = await store.waitForAgent(.saveAs)
        store.agentSaveAs = nil; store.saveAsPrefill = nil
        guard case .saved(let number, let saved) = outcome else { throw MCPRefusal(errors.cancelled) }
        return (["saved": true, "number": .number(Double(number)), "name": .string(saved)], "saved the live state as preset \(number) “\(saved)”")
    }

    private func rename(_ a: [String: JSONValue], _ client: String) async throws -> (JSONValue, String) {
        if store.refuseIfPresetUnknown() { throw MCPRefusal(PresetKnowledge.message) }
        let name = a["name"]?.stringValue ?? ""
        store.renamePrefill = name
        store.agentAskedBy = client
        store.tab = .editor
        store.renameRequested = true
        bringToFront()
        let outcome = await store.waitForAgent(.rename)
        store.renamePrefill = nil
        guard case .renamed(let number, let renamed) = outcome else { throw MCPRefusal(errors.cancelled) }
        return (["renamed": true, "number": .number(Double(number)), "name": .string(renamed)], "renamed preset \(number) to “\(renamed)”")
    }

    private func loadIntoSlot(_ a: [String: JSONValue], cab: Bool, _ client: String) async throws -> (JSONValue, String) {
        let factory = a["source"]?.stringValue != "user", wanted = a["name"]?.stringValue ?? "", slot = a["slot"]?.intValue ?? 1
        let count = cab ? store.cabSlotCount : store.captureSlotCount
        let kindWord = cab ? "cab/IR slot" : "capture slot"
        guard slot <= count else { throw MCPRefusal("slot must be between 1 and \(count) (the pedal's \(kindWord)s).") }
        guard let lib = await store.ensureLibrary() else { throw MCPRefusal("The pedal did not send its library. Try again in a moment.") }
        let items: [(index: Int, name: String)] = cab ? (factory ? lib.factoryIRs : lib.userIRs).map { ($0.index, $0.name) }
                                                      : (factory ? lib.factoryCaptures : lib.userCaptures).map { ($0.index, $0.name) }
        guard let item = items.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) ?? items.first(where: { IRTransfer.sameName($0.name, wanted) }) else {
            throw MCPRefusal("There is no \(factory ? "factory" : "user") \(cab ? "cab or IR" : "capture") named “\(wanted)”. list_library kind=\(cab ? "cab" : "capture") lists them.")
        }
        let names = cab ? store.metadata?.irNames ?? [] : store.metadata?.captureNames ?? []
        let holds = slot - 1 < names.count ? names[slot - 1] : ""
        var lines = [holds.isEmpty ? "\(cab ? "Cab/IR" : "Capture") slot \(slot) is empty now." : "\(cab ? "Cab/IR" : "Capture") slot \(slot) holds “\(holds)” now."]
        if let usage = store.usage {
            let users = ((cab ? usage.cabs : usage.captures)[slot] ?? []).sorted().map { String($0 + 1) }
            lines.append(users.isEmpty ? "No preset uses it (last slot scan)." : "Preset\(users.count == 1 ? "" : "s") \(users.joined(separator: ", ")) use\(users.count == 1 ? "s" : "") it (last slot scan).")
        } else {
            lines.append("Which presets use it is not known (no slot scan yet).")
        }
        lines.append("The slot changes for every preset that uses it.")
        guard await confirm(cab ? "load_cab_into_slot" : "load_capture_into_slot", askedBy: client, title: "Load “\(item.name)” into \(kindWord) \(slot)?", lines: lines, button: "Load")
        else { throw MCPRefusal(errors.cancelled) }
        let choice = PedalStore.SlotChoice(kind: cab ? .cab : .capture, name: item.name, factory: factory, index: item.index)
        guard await store.loadPicked(choice, slot: slot) else { throw MCPRefusal("The pedal refused to load \(item.name).") }
        return (["loaded": true, "slot": .number(Double(slot)), "name": .string(item.name)], "loaded \(item.name) into \(kindWord) \(slot)")
    }

    private func setCabMic(_ a: [String: JSONValue], _ client: String) async throws -> (JSONValue, String) {
        let c = store.cab
        guard c.on, c.slot > 0, !c.fromLibrary else { throw MCPRefusal("The preset plays no cab from a cab slot, so there is no mic to change.") }
        guard store.state?.cabMicAndPosition != nil else { throw MCPRefusal("Cab slot \(c.slot) holds a user IR; user IRs have no mic.") }
        guard a["mic"] != nil || a["position"] != nil else { throw MCPRefusal("Give mic, position, or both.") }
        var mic = c.mic
        if let wanted = a["mic"]?.stringValue {
            guard let m = store.cabMicChoices.first(where: { $0.caseInsensitiveCompare(wanted.trimmingCharacters(in: .whitespaces)) == .orderedSame }) else {
                throw MCPRefusal("This cab offers these mics: \(store.cabMicChoices.joined(separator: ", ")).")
            }
            mic = m
        }
        let position = a["position"]?.intValue ?? c.position
        guard await confirm("set_cab_mic", askedBy: client, title: "Change the mic of cab slot \(c.slot)?",
                            lines: ["\(c.mic), position \(c.position) → \(mic), position \(position)",
                                    "The mic is stored in the cab slot, so it changes for every preset that uses slot \(c.slot)."], button: "Change")
        else { throw MCPRefusal(errors.cancelled) }
        store.setCabMic(mic, position: position)
        _ = await until(seconds: 2) { !self.store.live.edits.pending(now: Date()) }
        return (["mic": .string(store.cab.mic), "position": .number(Double(store.cab.position))], "cab slot \(c.slot) mic \(mic), position \(position)")
    }

    private func assignFootswitch(_ a: [String: JSONValue], _ client: String) async throws -> (JSONValue, String) {
        guard let fs = a["footswitch"]?.stringValue.flatMap({ FootswitchSlot(label: $0) }), let number = a["preset"]?.intValue else { throw MCPRefusal("footswitch and preset are required.") }
        let index = number - 1
        var lines: [String] = []
        if let now = store.footswitch?[fs] { lines.append("Footswitch \(fs.label) plays preset \(now + 1) “\(store.presetName(now))” now.") }
        if store.dirtyForPrompt { lines.append("The current preset has unsaved edits; the editor asks about them next (the pedal reloads it when it assigns).") }
        guard await confirm("assign_footswitch", askedBy: client, title: "Assign preset \(number) “\(store.presetName(index))” to footswitch \(fs.label)?", lines: lines, button: "Assign")
        else { throw MCPRefusal(errors.cancelled) }
        // The path of the user's click: with unsaved edits the editor's own prompt first (requestAssignment).
        store.lastAssignmentChoice = nil
        if store.dirtyForPrompt {
            store.requestAssignment(fs, index: index)
            _ = await until(seconds: 600) { self.store.pendingAssignment == nil }
            if store.lastAssignmentChoice == "cancel" || store.lastAssignmentChoice == nil { throw MCPRefusal(errors.cancelled) }
        } else {
            await store.assignFootswitch(fs, index: index)
        }
        guard await until(seconds: 6, { self.store.footswitch?[fs] == index }) else { throw MCPRefusal("The pedal didn't take the footswitch assignment.") }
        return (["assigned": true, "footswitch": .string(fs.label), "preset": .number(Double(number))], "assigned preset \(number) to footswitch \(fs.label)")
    }

    // MARK: - Cortex Cloud

    private func cloudSearch(_ a: [String: JSONValue]) async throws -> (JSONValue, String) {
        let query = a["query"]?.stringValue ?? "", page = a["page"]?.intValue ?? 1
        let reply: JSONValue
        if store.demo { reply = DemoCloud.searchReply }
        else {
            switch await cloud.search(query: query, page: page) {
            case .success(let r): reply = r
            case .failure(let e): throw MCPRefusal(e.message)
            }
        }
        var hashes: Set<String>?
        if store.connected, let lib = await store.ensureLibrary() { hashes = Set((lib.factoryCaptures + lib.userCaptures).map { $0.hash.lowercased() }) }
        guard let result = MCPResults.cloudSearch(reply, query: query, page: page, libraryHashes: hashes) else {
            throw MCPRefusal("Cortex Cloud's search answered in a shape the editor doesn't know. The other tools keep working.")
        }
        return (result, "searched Cortex Cloud for “\(query)” (\(result["results"]?.arrayValue?.count ?? 0) results)")
    }

    /// The capture download with the Cloud tab's session; in demo mode one of the three made-up demo captures.
    func fetchBundle(_ id: String) async throws -> CaptureBundle {
        if store.demo { return try DemoCloud.bundle(id) }
        return try await cloud.fetchBundle(id: id)
    }

    private func cloudSend(_ a: [String: JSONValue], _ client: String) async throws -> (JSONValue, String) {
        let id = a["product_id"]?.stringValue?.lowercased() ?? ""
        let bundle: CaptureBundle
        do { bundle = try await fetchBundle(id) } catch { throw MCPRefusal("Could not fetch the capture from Cortex Cloud: \(error.localizedDescription)") }
        store.agentAskedBy = client
        store.offerSend(bundle)
        guard store.pendingSend != nil else { store.agentAskedBy = nil; throw MCPRefusal(store.notice ?? "The editor could not offer the capture for sending.") }
        bringToFront()
        switch await store.waitForAgent(.send) {
        case .sent(let name): return (["sent": true, "name": .string(name)], "sent \(name) to the pedal's library")
        case .failed(let why): throw MCPRefusal(why)
        default: throw MCPRefusal(errors.cancelled)
        }
    }

    // MARK: - helpers

    /// True once `condition` holds (checked every 50 ms), false after `seconds`.
    func until(seconds: Double, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// The editor window comes to the front (un-minimised) for a confirmation. `-ai.noActivate YES` (argument domain)
    /// keeps a hidden test instance in the background (CLAUDE.md: never activate it).
    func bringToFront() {
        guard !UserDefaults.standard.bool(forKey: "ai.noActivate") else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
        }
    }
}

/// Demo mode's Cortex Cloud: three made-up captures (no real people or products) and a synthetic download for them.
enum DemoCloud {
    static let ids = ["00000000-0000-4000-8000-00000000d001", "00000000-0000-4000-8000-00000000d002", "00000000-0000-4000-8000-00000000d003"]
    static let searchReply: JSONValue = [
        "numberOfResults": 3, "numberOfPages": 1,
        "data": [
            ["productId": .string(ids[0]), "name": "Glass Pane Clean", "hash": "demo-d001", "tags": ["clean", "bright"], "authorUsername": "demo-maker",
             "downloads": 1520, "likes": 88, "description": "A made-up sparkling clean for demo mode.", "metadata": ["instrument": "guitar", "device": "amp_head", "gain": "clean"]],
            ["productId": .string(ids[1]), "name": "Velvet Crunch", "hash": "demo-d002", "tags": ["crunch", "warm"], "authorUsername": "demo-maker",
             "downloads": 940, "likes": 51, "description": "A made-up warm edge-of-breakup crunch for demo mode.", "metadata": ["instrument": "guitar", "device": "combo", "gain": "crunch"]],
            ["productId": .string(ids[2]), "name": "Iron Low End", "hash": "demo-d003", "tags": ["bass", "drive"], "authorUsername": "demo-bassist",
             "downloads": 310, "likes": 19, "description": "A made-up driven bass tone for demo mode.", "metadata": ["instrument": "bass", "device": "pedal", "gain": "high_gain"]],
        ],
    ]
    /// The synthetic download of NanoCore's tests (1289 made-up bytes), named after the demo capture.
    static let payload = "H4sIAAUWyGoC/+3VZXDUUBAA4MPd3Y/g0CtJLictTlugyBXoFSul5JKXu5Q2d0RKSynu7u7u7u7u7u7ubklph8IffnSmw0z3+/OSfdm3szNvshbSSnCIpiwmE+JMVpZwGAmcNpIWhsMpM241mxGLGMSRtNXhY2IYFlmMCJFWjuIIzuFDeTOCpPsHXGWmqIRV9fdKUgSR9PwrTljMJqNOj+tSgSLJtKiW16VR6dJnyJgpc5as2bLnyJkrd568+fIXKFiocJGixYqXKFmqdBl9Waxc+QoVK1WuUrWal8G7Ok6QRspktlh9fGvUrFW7Tt169f38Axo0bBTYuEnTZrag5i1aBttDWrVu07ZdaPuwDuEdaYd6Zzini4/oFBkluD2dRUlWorvExHaN6xbfvUfPXr379O3Xf8DAQYOHDB02fMTIUaPHjB03fsLESZOnTJ02fcbMWbPnzJ03f8HCRYuXLF22fMXKVavXrF23fsPGTZu3bN22fcfOXbv37N23/8DBQ4ePHD12/MTJU6fPnD13/sLFS5evXL12/cbNW7fv3L13/8HDR4+fPH32/MXLV6/fvH33/sPHT5+/fP32/Qf0D/1D/2m3f1s9W5DBHhBsT6O/f0tK53+E5BZSNv9xE079Of9JHKdImP+pIQ5z0ZIL89VjKb0JmJceE+gopJ1lR5Ks96M9siIiLc5EuhU2JCTQX9skEhlIlcGoMlAqgykZLYlWZJdbDGS1HIX4HbElK4JELc4iiRF5j8y7BW2D42OSCrMommeQPdaTkEFHecJdiGa1HZl2SmosFJPVY7AwNeKkeSHxS0p95QVJFpUoJMhJ6U6FV++KlhyNRCmxGIHF6wAAAAAAAAAAAAAAAAAAAAAA4D/wE7oFPBoAKAAA"
    static func bundle(_ id: String) throws -> CaptureBundle {
        guard let i = ids.firstIndex(of: id.lowercased()), let item = searchReply["data"]?[i] else { throw CloudError.message("Demo mode knows only the three demo captures of cloud_search.") }
        var b = try CaptureBundle.parse(payloadBase64: payload, name: nil, cloudId: id)
        b.record.name = item["name"]?.stringValue ?? b.record.name
        b.record.cloudUUID = id
        b.record.authorName = item["authorUsername"]?.stringValue ?? ""
        return b
    }
}
