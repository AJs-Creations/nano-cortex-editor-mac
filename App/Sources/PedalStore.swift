// App-side state: owns the transport and the current session, mirrors the
// session's events into observable properties, keeps per-slot effect state and
// the Activity log. Every edit goes live to the pedal; `save()` commits.

import Foundation
import Observation
import NanoCore

@MainActor @Observable
final class PedalStore {
    enum Link: Equatable { case off, scanning, connecting, connected, reconnecting }
    enum Stage: String, CaseIterable { case gate, pre1, pre2, capture, cab, post1, post2, post3
        var title: String { switch self { case .gate: "Gate"; case .capture: "Capture"; case .cab: "Cab / IR"; default: Slot(rawValue: rawValue)!.title } }
        var short: String { switch self { case .gate: "Gate"; case .capture: "Capture"; case .cab: "Cab"; case .pre1: "Pre 1"; case .pre2: "Pre 2"; case .post1: "Post 1"; case .post2: "Post 2"; case .post3: "Post 3" } }
        var slot: Slot? { Slot(rawValue: rawValue) }
    }
    struct Block { var model: ModelDef?; var on: Bool; var values: [Double] }   // values in parameter units
    struct CabState { var on: Bool; var slot: Int; var fromLibrary = false; var name: String; var mic: String; var position: Int; var libraryIndex: Int?; var levelDb: Double; var highPassHz: Double; var lowPassHz: Double; var loaded: Bool }

    var link: Link = .off
    var pedalName = "Nano Cortex"
    var metadata: Metadata?
    var state: StateDump?
    var blocks: [Slot: Block] = [:]
    var cab = CabState(on: false, slot: 0, name: "", mic: "Dynamic 57", position: 1, libraryIndex: nil, levelDb: 0, highPassHz: 20, lowPassHz: 20000, loaded: false)
    var gateOn = false
    var gateReduction = 50
    var amp: [AmpKnob: Int] = [:]
    var captureVolumeDb = 0.0
    var captureOn = false
    var captureSlot: Int? = nil
    var captureFromLibrary = false     // the preset references its capture from the library, not a slot
    var cabPositionFromRecord: Int?    // hardware-pass comparison of the two position encodings
    var cabFullName = ""
    var cabMics: [String] = []         // from the pedal's cab settings reply
    var captureName = ""
    var dirty = false          // reported by the pedal
    var edited = false         // edits made here since the last save / preset change
    var library: Library?
    /// The current preset's tempo (state field 56, the pedal's 145 echo, or our own writes); nil until read.
    var presetTempo: Int?
    var tunerOn = false
    var tunerReading: TunerReading?
    var log: [String] = []
    var error: String?
    /// Why a connect in progress is not getting anywhere (Bluetooth off or not allowed, no pedal found yet); nil otherwise.
    /// The connect card shows it with a Troubleshooting link while it keeps trying.
    var linkProblem: String?
    var demo = false
    var selectedStage: Stage = .capture { didSet { expressionOpen = false } }   // a node click leaves the Expression panel
    /// Expression pedal assignments of `expressionPreset` (nil until read). Read on connect and on every preset load.
    var expression: ExpressionAssignments?
    var expressionPreset: Int?
    var expressionOpen = false             // the inspector shows the Expression pedal panel (EXP pill in the chain)
    var expressionError: String?
    private var expressionQueued: (index: Int, set: ExpressionAssignments)?
    private var expressionWriting = false
    /// The Activity drawer. Only Developer tools open it (the dev remote's `/drawer` can force it for screenshots).
    var showLog = AppSettings.shared.showLogAtLaunch && AppSettings.shared.devTools
    var notice: String?                    // transient toast
    var pendingPreset: Int?                // preset switch waiting on the "save changes?" prompt
    var slotChooser: SlotChoice?           // library item waiting for a slot
    enum Tab { case editor, cloud }
    var tab: Tab = .editor
    var pendingSend: CaptureBundle?        // Cloud capture waiting for "Send?"
    var uploading = false
    var offerSlot: SlotChoice?             // after an upload: "load into a slot now?"
    var confirmSignOut = false
    var saveAsOpen = false                 // "Save as…" sheet
    var deleteTarget: Int? = nil           // "Delete preset N?" confirmation
    var renameRequested = false            // a menu asked for the rename sheet
    var saveAsTarget: Int? = nil           // preselected slot for Save as (from a preset row's menu)
    var modelPickerOpen = false            // open the effect list for the selected stage (from a node's menu)
    var libraryOpen: LibraryKind? = nil    // open the library popover (from a slot cell's menu)
    var libraryTarget: Int? = nil          // …and load straight into this slot, skipping the chooser
    var usage: SlotUsage?                  // result of the last slot usage scan
    var scanning: Int? = nil               // presets scanned so far while a scan runs
    struct SlotChoice: Identifiable { let id = UUID(); var kind: LibraryKind; var name: String; var factory: Bool; var index: Int }
    enum LibraryKind { case capture, cab }
    struct SlotUsage { var captures: [Int: [Int]]; var cabs: [Int: [Int]]; var date: Date; var complete: Bool }   // slot → preset indexes
    /// Status bar text after the link state: upload progress, or "Sent: …" (shown only with Developer tools on).
    var lastAction = ""
    var shortcutsOpen = false              // "Keyboard shortcuts" sheet (? or the status bar button)
    /// Session recording (status bar Record): the tap stays installed on every session; the recorder ignores packets while off.
    let recorder = SessionRecorder()
    var recording = false
    // Settings → Device (PROTOCOL-NOTES §13): read when the section opens; writes need a successful read first.
    var deviceInfo: DeviceInfo?
    var deviceSettings: DeviceSettings?
    var deviceReading = false
    var deviceError: String?
    var ledBrightness = 153                // 0–255 as the pedal stores it; the UI shows percent
    var usbVolumeDb = -6.0
    private var devicePending: (Int, Float)?
    private var deviceWriting = false
    /// Capture info popover: which control it hangs off, and what the pedal answered.
    enum InfoAnchor: Equatable { case node, slot(Int) }
    var captureInfoAnchor: InfoAnchor?
    var captureInfo: CaptureDetails?
    var captureInfoError: String?

    /// The metronome sync listens here (`attach`).
    var onPresetTempo: ((Int) -> Void)?
    private var tempoCommit: Task<Void, Never>?
    private var tempoWrittenAt = Date.distantPast
    private var tempoUncommitted = false   // a live tempo the preset does not have yet
    private var tempoTaps = TapTempo()

    private var transport: (any NanoTransport)?
    /// The fake pedal in demo mode (the dev remote simulates pedal-side actions on it).
    var demoPedal: FakePedal? { transport as? FakePedal }
    private var ble: BluetoothTransport?
    private var session: Session?
    private var eventTask: Task<Void, Never>?

    var connected: Bool { link == .connected }
    var presetNames: [String] { metadata?.presetNames ?? [] }
    var presetIndex: Int { state?.presetIndex ?? 0 }
    /// Footswitch slots IA, IB, IIA, IIB (0-based presets), from the state dump and footswitch presses.
    var footswitch: Footswitches? { state?.footswitch }
    var captureSlotCount: Int { max(25, metadata?.captureNames.count ?? 0) }
    var cabSlotCount: Int { max(5, metadata?.irNames.count ?? 0) }
    /// Hardware-style label: banks 1–5 × A–E for the first 25, plain numbers beyond.
    static func slotLabel(_ slot: Int) -> String { slot <= 25 ? "\((slot - 1) / 5 + 1)\(["A", "B", "C", "D", "E"][(slot - 1) % 5])" : "\(slot)" }
    func presetName(_ i: Int) -> String { i < presetNames.count && !presetNames[i].isEmpty ? presetNames[i] : "Empty" }

    static let logFile: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appending(path: "Logs/Nano Cortex Editor/activity.log")
    /// Written for every user, Developer tools or not; rotates to `activity.1.log` past ~2 MB (DECISION #21).
    /// Help → Show Log File and Settings → Advanced reveal it (`revealLogFile`, Settings.swift).
    @ObservationIgnored let logWriter = RotatingLogFile(url: PedalStore.logFile)
    private var noticeTask: Task<Void, Never>?
    func toast(_ text: String) {
        notice = text; noticeTask?.cancel()
        noticeTask = Task { try? await Task.sleep(for: .seconds(3.5)); if !Task.isCancelled { notice = nil } }
    }

    func append(_ line: String) {
        let entry = "\(Date().formatted(date: .omitted, time: .standard))  \(line)"
        log.append(entry)
        recorder.note(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
        if line.hasPrefix("TX ") { lastAction = "Sent: " + line.dropFirst(3) }
        logWriter.append(entry)
    }

    /// Developer tools turned off: close the Activity drawer and end a recording in progress (saved to the default
    /// recording folder, so nothing is lost).
    func devToolsChanged(_ on: Bool) {
        guard !on else { return }
        showLog = false
        guard recording else { return }
        let started = recorder.startDate ?? Date()
        if let rec = stopRecording() { _ = write(rec, to: Self.recordingFolder.appending(path: SessionRecorder.fileName(for: started))) }
    }

    // MARK: connect / disconnect

    func connect(demo: Bool = false) async {
        guard link == .off else { append("Connect ignored: already \(link)"); return }
        error = nil
        linkProblem = nil
        self.demo = demo
        if demo {
            transport = FakePedal()
            link = .connected
            pedalName = "Demo pedal"
            await startSession()
            return
        }
        let ble = self.ble ?? BluetoothTransport()
        self.ble = ble
        transport = ble
        ble.onLog = { [weak self] line in Task { @MainActor in self?.append(line) } }
        ble.onPhase = { [weak self] phase in Task { @MainActor in self?.apply(phase) } }
        ble.onLinkLost = { [weak self] in Task { @MainActor in await self?.sessionLost() } }
        ble.onReconnected = { [weak self] in Task { @MainActor in await self?.startSession() } }
        ble.onProblem = { [weak self] problem in Task { @MainActor in self?.linkProblem = problem } }
        link = .scanning
        do {
            try await ble.connect()
            await startSession()
        } catch {
            self.error = "Could not connect: \(error)"
            linkProblem = nil
            link = .off
        }
    }

    func disconnect() async {
        await session?.disconnect()
        await transport?.disconnect()
        session = nil; transport = nil
        link = .off
        state = nil; metadata = nil; library = nil; dirty = false; edited = false; blocks = [:]; demo = false
        deviceInfo = nil; deviceSettings = nil; deviceError = nil; captureInfoAnchor = nil; captureInfo = nil
        tempoCommit?.cancel(); presetTempo = nil; tempoUncommitted = false
        expression = nil; expressionPreset = nil; expressionQueued = nil
        lastAction = ""
    }

    /// Settings → Connection: drop the remembered pedal (the next Connect scans) and end a real connection.
    func forgetPedal() async {
        if link != .off, !demo { await disconnect() }
        AppSettings.shared.forgetRememberedPedal()
        append("Forgot the remembered pedal; the next Connect scans for one.")
    }

    private func apply(_ phase: BluetoothTransport.Phase) {
        switch phase {
        case .off: link = .off; linkProblem = nil
        case .scanning: link = .scanning
        case .connecting(let n): link = .connecting; pedalName = n
        case .connected(let n): link = .connected; pedalName = n; linkProblem = nil; AppSettings.shared.refreshRemembered()
        case .reconnecting(let n): link = .reconnecting; pedalName = n
        }
    }

    private func sessionLost() async {
        eventTask?.cancel()
        await session?.linkLost()
        session = nil
        append("Link lost; waiting for the pedal to advertise again…")
    }

    private func startSession() async {
        guard let transport else { return }
        let s = Session(transport: transport, tap: recorder.tap)
        session = s
        eventTask?.cancel()
        eventTask = Task { [weak self] in for await e in s.events { await self?.handle(e) } }
        do {
            let (meta, st) = try await s.connect()
            metadata = meta
            await applyState(st, presetLoad: true)
            append("Synced: \(meta.presetNames.filter { !$0.isEmpty }.count) presets, firmware \(st.firmware ?? "?"), preset \(st.presetIndex + 1)")
        } catch {
            self.error = "Sync failed: \(error)"
            append("Sync failed: \(error)")
        }
    }

    // MARK: state

    private func applyState(_ st: StateDump, presetLoad: Bool) async {
        let previous = state
        state = st
        dirty = st.dirty
        amp = [.gain: st.gain, .level: st.level, .bass: st.bass, .mid: st.mid, .treble: st.treble]
        captureVolumeDb = st.captureVolumeDb
        captureOn = st.captureOn
        captureSlot = st.captureSlot
        captureFromLibrary = st.captureFromLibrary
        captureName = st.captureName
        gateOn = st.gateOn
        if let g = st.gateReductionPercent { gateReduction = g }
        // Field 56 is the preset's tempo buffer; a live tempo not committed yet stays on screen until a preset load.
        if presetLoad { tempoCommit?.cancel(); tempoUncommitted = false }
        if presetLoad || !tempoUncommitted { adoptTempo(st.tempo) }
        cab.on = st.cabOn; cab.slot = st.cabFromLibrary ? 0 : st.cabSlot; cab.fromLibrary = st.cabFromLibrary; cab.name = st.irShortName
        if let mp = st.cabMicAndPosition { cab.mic = mp.mic; cab.position = mp.position }
        for slot in Slot.allCases {
            let fx = st.fx[slot.rawValue]
            let model = fx?.modelIdHex.flatMap { Models.byId($0, in: slot.rawValue) }
            let previous = blocks[slot]
            let keep = !presetLoad && previous?.model?.name == model?.name
            blocks[slot] = Block(model: model, on: fx?.on ?? false, values: keep ? previous!.values : (model?.params.map(\.defaultValue) ?? []))
        }
        guard let session else { return }
        if presetLoad || st.presetIndex != expressionPreset { Task { await readExpression() } }
        // Parameters only come from the refresh replies; ask for them on a preset load and whenever a block's model changed.
        if st.cabOn, st.cabSlot > 0, !st.cabFromLibrary, presetLoad || previous?.cabSlot != st.cabSlot { cab.loaded = false; await session.refreshCab(slot: st.cabSlot) }
        for slot in Slot.allCases where blocks[slot]?.model != nil && (presetLoad || previous?.fx[slot.rawValue]?.modelIdHex != st.fx[slot.rawValue]?.modelIdHex) {
            await session.refreshFXParams(slot)
        }
    }

    private func handle(_ e: SessionEvent) async {
        switch e {
        case .metadata(let m): metadata = m
        case .state(let s): await applyState(s, presetLoad: false)
        case .dirty(let d): dirty = d
        case .presetChangedOnDevice(let i, let slots): append("Preset changed on the pedal: \(i + 1)"); edited = false; state?.footswitch = slots
        case .library(let l): library = l
        case .fxParams(let slot, let floats):
            guard var b = blocks[slot], let m = b.model else { return }
            b.values = m.params.enumerated().map { i, p in i < floats.count ? FXParams.value(floats[i], meta: p.meta) : p.defaultValue }
            blocks[slot] = b
        case .cab(let c):
            cab.loaded = true; cab.libraryIndex = c.libraryIndex ?? cab.libraryIndex; cabPositionFromRecord = c.positionFromRecord; cabFullName = c.fullName; if !c.mics.isEmpty { cabMics = c.mics }
            if let m = c.mic { cab.mic = m }; if let p = c.position { cab.position = p }
            cab.levelDb = c.levelDb; cab.highPassHz = c.highPassHz; cab.lowPassHz = c.lowPassHz
        case .tempo(let bpm):
            // Our own live writes echo back; only a change made on the pedal (tap on footswitch I) is news.
            guard Date().timeIntervalSince(tempoWrittenAt) > 1, Int(bpm.rounded()) != presetTempo else { return }
            append("Tempo changed on the pedal: \(Int(bpm.rounded())) BPM")
            adoptTempo(bpm)
        case .tuner(let r): tunerReading = r
        case .tunerMode(let on): tunerOn = on
        case .log(let line): append(line)
        case .disconnected: append("Session ended")
        }
    }

    // MARK: presets

    /// Switches presets; with unsaved edits it asks first (`pendingPreset` drives the prompt).
    func selectPreset(_ index: Int) {
        guard session != nil, index != presetIndex else { return }
        if edited || dirty { pendingPreset = index; return }
        switchPreset(index)
    }
    func switchPreset(_ index: Int) {
        guard let session else { return }
        pendingPreset = nil
        Task {
            do { let st = try await session.selectPreset(index: index); edited = false; await applyState(st, presetLoad: true) }
            catch { append("Preset change failed: \(error)") }
        }
    }
    /// An assignment waiting on the "save changes?" prompt (the pedal drops unsaved edits on an assignment).
    struct PendingAssignment: Equatable { var slot: FootswitchSlot; var index: Int }
    var pendingAssignment: PendingAssignment?
    /// Footswitch assignment from the UI: with unsaved edits it asks first, like a preset switch.
    func requestAssignment(_ slot: FootswitchSlot, index: Int) {
        guard session != nil else { return }
        if edited || dirty { pendingAssignment = PendingAssignment(slot: slot, index: index); return }
        Task { await assignFootswitch(slot, index: index) }
    }
    /// The prompt's answer: "save" saves first, "discard" assigns anyway, anything else cancels.
    func resolveAssignment(_ choice: String) {
        guard let p = pendingAssignment else { return }
        pendingAssignment = nil
        switch choice {
        case "save": Task { if await save() { await assignFootswitch(p.slot, index: p.index) } else { toast("Save failed; nothing assigned.") } }
        case "discard": Task { await assignFootswitch(p.slot, index: p.index) }
        default: break
        }
    }
    /// Puts preset `index` on footswitch `slot` (type 29 with field 4 = −1, PROTOCOL-NOTES §10). The pedal reloads
    /// the current preset as stored, dropping unsaved edits (seen in the phone trace), so callers ask first
    /// (`requestAssignment`). Only from an explicit user action.
    func assignFootswitch(_ slot: FootswitchSlot, index: Int) async {
        guard let session else { return }
        do {
            let st = try await session.assignFootswitch(slot: slot, presetIndex: index)
            edited = false
            await applyState(st, presetLoad: true)
            append("Assigned preset \(index + 1) to footswitch \(slot.label)")
            toast("Preset \(index + 1) on footswitch \(slot.label)")
        } catch { append("Footswitch assignment failed: \(error)"); toast("The pedal didn’t take the footswitch assignment.") }
    }
    /// "Assign…" popover target (from a footswitch cell's menu).
    var footswitchPicker: FootswitchSlot? = nil

    /// Throws away the live edits: re-selecting the current slot makes the pedal reload the preset as saved
    /// (the delete flow in the Electron app relies on the same reload). Only from an explicit user action.
    var discardRequested = false
    func discardEdits() async {
        guard let session, state != nil else { return }
        let index = presetIndex
        do {
            let st = try await session.selectPreset(index: index)
            edited = false
            await applyState(st, presetLoad: true)
            append("Discarded the edits to preset \(index + 1)")
            toast("Edits discarded; preset \(index + 1) reloaded")
        } catch { append("Discard failed: \(error)") }
    }
    func saveAndSwitch(_ index: Int) { Task { if await save() { switchPreset(index) } else { pendingPreset = nil; toast("Save failed; staying on this preset.") } } }
    func save() async -> Bool {
        guard let session, let st = state else { return false }
        do {
            let ok = try await session.save(index: st.presetIndex, name: presetName(st.presetIndex) == "Empty" ? "Preset \(st.presetIndex + 1)" : presetName(st.presetIndex))
            append(ok ? "Saved preset \(st.presetIndex + 1)" : "Save refused by the pedal")
            if ok { dirty = false; edited = false }
            return ok
        } catch { append("Save failed: \(error)"); return false }
    }
    /// Writes the live state into another preset slot under `name`, then switches to it. The original keeps
    /// its saved state (the pedal drops the unsaved edits on the switch). Only ever from an explicit user action.
    func saveAs(index: Int, name: String) async -> String? {
        guard let session else { return "Not connected" }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 4 { return "Preset name must have at least 4 characters." }
        if trimmed.utf8.count > 64 { return "Preset name is too long." }
        do {
            guard try await session.save(index: index, name: trimmed) else { return "The pedal refused to save." }
            metadata?.presetNames[index] = trimmed
            append("Saved the live state as preset \(index + 1) \"\(trimmed)\"")
            toast("Saved as preset \(index + 1), \(trimmed).")
            edited = false; dirty = false
            usage = nil
            switchPreset(index)
            return nil
        } catch { return "Save failed: \(error)" }
    }

    /// Empties a preset slot on the pedal (type 50, PROTOCOL-NOTES §9). Confirmed by the user in a sheet first.
    func deletePreset(index: Int) async -> String? {
        guard let session else { return "Not connected" }
        do {
            guard try await session.deletePreset(index: index) else { return "The pedal refused to delete preset \(index + 1)." }
            append("Deleted preset \(index + 1)")
            if let m = try? await session.requestMetadata() { metadata = m } else { metadata?.presetNames[index] = "" }
            usage = nil
            if index == presetIndex { if let st = try? await session.requestState() { await applyState(st, presetLoad: true) } }
            toast("Preset \(index + 1) deleted.")
            return nil
        } catch { return "Delete failed: \(error)" }
    }

    func rename(_ name: String) async -> String? {
        guard let session, let st = state else { return "Not connected" }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.count < 4 { return "Preset name must have at least 4 characters." }
        if trimmed.utf8.count > 64 { return "Preset name is too long." }
        do {
            guard try await session.rename(index: st.presetIndex, name: trimmed) else { return "The pedal refused the new name." }
            metadata?.presetNames[st.presetIndex] = trimmed
            return nil
        } catch { return "Rename failed: \(error)" }
    }
    /// Re-reads everything from the pedal (names and the current state), like the initial sync. Read-only.
    func refresh() {
        guard let session else { return }
        toast("Reading presets and captures from the pedal")
        Task {
            do { let (m, s) = try await session.readAll(); metadata = m; library = nil; await applyState(s, presetLoad: true) }
            catch { append("Refresh failed: \(error)") }
        }
    }
    /// ⌘↑ / ⌘↓: the neighbouring preset (asks first when there are unsaved edits).
    func stepPreset(_ delta: Int) { guard state != nil else { return }; selectPreset(max(0, min(max(64, presetNames.count) - 1, presetIndex + delta))) }

    func requestState() { guard let session else { return }; Task { if let s = try? await session.requestState() { await applyState(s, presetLoad: false) } } }

    // MARK: tempo (type 145, PROTOCOL-NOTES §11)

    private func adoptTempo(_ bpm: Double) {
        let v = Int(bpm.rounded())
        presetTempo = v
        onPresetTempo?(v)
    }
    /// `live`: the pedal plays the tempo and the preset stays clean (while a control moves). Not live: written into
    /// the preset too, which marks it edited; Save keeps it.
    func setTempo(_ bpm: Int, live: Bool) {
        let v = max(30, min(300, bpm))
        presetTempo = v
        onPresetTempo?(v)
        guard let session else { return }
        tempoWrittenAt = Date()
        tempoCommit?.cancel()
        tempoUncommitted = live
        if !live { touch() }
        Task { await session.setTempo(bpm: Double(v), live: live) }
    }
    /// A step, a tap or a metronome change: live now, committed into the preset once it has settled for `settle` s.
    func nudgeTempo(_ bpm: Int, settle: Double = 0.8) {
        setTempo(bpm, live: true)
        guard session != nil else { return }
        tempoCommit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard let self, !Task.isCancelled, let v = self.presetTempo else { return }
            self.setTempo(v, live: false)
        }
    }
    /// The inspector's Tap: each tap plays the new tempo; it is committed when the taps stop.
    func tapTempo() { if let v = tempoTaps.tap() { nudgeTempo(v, settle: 2.6) } }

    /// Two-way sync with the metronome (Settings → Metronome → Follow the preset tempo).
    func attach(_ metro: Metronome) {
        metro.presetLinked = { [weak self] in self?.connected == true && self?.presetTempo != nil }
        metro.onTempoChanged = { [weak self, weak metro] v, commit in
            guard let self, metro?.tempoFollowsPreset == true else { return }
            commit ? self.nudgeTempo(v, settle: 1.5) : self.setTempo(v, live: true)
        }
        onPresetTempo = { [weak metro] v in metro?.adopt(presetTempo: v) }
    }

    // MARK: live edits
    // Knob writes go out while dragging (the session coalesces same-key writes while the link is busy), so the
    // pedal follows the knob instead of jumping on release. `commit` only marks the end of a gesture.

    private func touch() { edited = true }
    func setAmp(_ knob: AmpKnob, _ value: Int, commit: Bool) {
        amp[knob] = value
        guard let session else { return }
        touch(); Task { await session.setAmp(knob, value) }
    }
    func setCaptureVolume(_ db: Double, commit: Bool) {
        captureVolumeDb = db
        guard let session else { return }
        touch(); Task { await session.setCaptureVolume(db: db) }
    }
    func setCapture(slot: Int) {
        guard let session else { return }
        captureOn = true; captureSlot = slot; captureName = metadata?.captureNames[slot - 1] ?? ""
        touch(); Task { await session.selectCapture(slot: slot); try? await Task.sleep(for: .milliseconds(300)); requestState() }
    }
    func toggleCapture() {
        guard let session else { return }
        if captureOn { captureOn = false; touch(); Task { await session.bypassCapture() } } else { setCapture(slot: captureSlot ?? 1) }
    }
    func setGate(on: Bool) { guard let session else { return }; gateOn = on; touch(); Task { await session.setGate(on: on) } }
    func setGateReduction(_ pct: Int, commit: Bool) { gateReduction = pct; guard let session else { return }; touch(); Task { await session.setGateReduction(percent: pct) } }

    func setFX(_ slot: Slot, on: Bool) {
        guard let session, var b = blocks[slot], b.model != nil else { return }
        b.on = on; blocks[slot] = b; touch()
        Task { await session.setFX(slot, on: on); if on { try? await Task.sleep(for: .milliseconds(120)); await session.refreshFXParams(slot) } }
    }
    func setFXModel(_ slot: Slot, _ model: ModelDef?) {
        guard let session, var b = blocks[slot] else { return }
        if let model {
            b.model = model; b.values = model.params.map(\.defaultValue); blocks[slot] = b; touch()
            Task { await session.setFXModel(slot, model); if b.on { try? await Task.sleep(for: .milliseconds(120)); await session.refreshFXParams(slot) } }
        } else {
            b.model = nil; b.values = []; let wasOn = b.on; b.on = false; blocks[slot] = b; touch()
            if wasOn { Task { await session.setFX(slot, on: false) } }
        }
    }
    func setFXParam(_ slot: Slot, index: Int, value: Double, commit: Bool) {
        guard var b = blocks[slot], let m = b.model, index < m.params.count else { return }
        if b.values.count < m.params.count { b.values = m.params.map(\.defaultValue) }
        b.values[index] = value; blocks[slot] = b
        guard let session else { return }
        touch(); Task { await session.setFXParam(slot, index: index, normalized: FXParams.normalized(value, meta: m.params[index].meta)) }
    }

    func selectCab(slot: Int) {   // 0 = bypass
        guard let session else { return }
        cab.on = slot > 0; cab.slot = slot; cab.name = slot > 0 ? (metadata?.irNames[slot - 1] ?? "") : cab.name; touch()
        Task { await session.selectCab(slot: slot); try? await Task.sleep(for: .milliseconds(300)); requestState() }
    }
    func refreshCab() { guard let session, cab.slot > 0 else { return }; Task { await session.refreshCab(slot: cab.slot) } }
    func setCabLevel(_ db: Double, commit: Bool) { cab.levelDb = db; guard let session else { return }; touch(); Task { await session.setCabLevel(db: db) } }
    func setCabHighPass(_ hz: Double, commit: Bool) { cab.highPassHz = hz; guard let session else { return }; touch(); Task { await session.setCabHighPass(hz: hz) } }
    func setCabLowPass(_ hz: Double, commit: Bool) { cab.lowPassHz = hz; guard let session else { return }; touch(); Task { await session.setCabLowPass(hz: hz) } }
    func setCabMic(_ mic: String, position: Int) {
        guard let session else { return }
        cab.mic = mic; cab.position = position; touch()
        Task {
            // The write needs the cab's index in the pedal's IR library: from the cab settings reply, else from the library list.
            var index = cab.libraryIndex
            if index == nil { index = await ensureLibrary()?.factoryIRs.first(where: { $0.name == cab.name })?.index }
            guard let index else { append("Cab mic/position ignored: the cab's library index is unknown"); toast("Couldn't find this cab in the pedal's library."); return }
            await session.setCabMic(libraryIndex: index, cabName: cab.name, mic: mic, position: position)
        }
    }

    // MARK: expression pedal (types 60–63, PROTOCOL-NOTES §12)

    /// Reads the current preset's assignments. A reply for a preset that is no longer current is dropped.
    func readExpression() async {
        guard let session, let index = state?.presetIndex else { return }
        if expressionPreset != index { expression = nil; expressionPreset = index }
        do {
            let set = try await session.readExpression(index: index)
            guard state?.presetIndex == index else { return }
            expression = set; expressionError = nil
            append("Expression assignments of preset \(index + 1): " + (set.isEmpty ? "none" : describe(set)))
        } catch {
            guard state?.presetIndex == index else { return }
            expressionError = "The pedal did not send its expression assignments."
            append("Expression assignments request failed: \(error)")
        }
    }
    /// Replaces the whole set on the pedal (one type 62). While a write is in flight only the latest set waits,
    /// so dragging a heel/toe knob sends one 62 per round trip, never a backlog. Live; Save commits (unverified).
    func setExpression(_ set: ExpressionAssignments) {
        guard session != nil, let index = state?.presetIndex else { return }
        expression = set; expressionPreset = index; touch()
        expressionQueued = (index, set)
        guard !expressionWriting else { return }
        expressionWriting = true
        Task {
            while let next = expressionQueued, let session {
                expressionQueued = nil
                do {
                    if !(try await session.saveExpression(index: next.index, next.set)) { append("The pedal refused the expression assignments"); toast("The pedal refused the expression assignments.") }
                } catch { append("Expression assignments write failed: \(error)") }
            }
            expressionWriting = false
        }
    }
    func clearExpression() {
        guard let set = expression, !set.isEmpty else { return }
        setExpression(ExpressionAssignments())
        toast("Expression assignments cleared. Save to keep the change.")
    }
    private func describe(_ set: ExpressionAssignments) -> String {
        (set.ranges.keys.sorted().map { t in let r = set.ranges[t]!; return "\(t.key) \(r.min)–\(r.max)\(r.inverted ? " inverted" : "")" }
         + set.bypasses.keys.sorted().map { "\($0.key) bypass \(set.bypasses[$0]!.modeKey)" }).joined(separator: ", ")
    }

    // MARK: library, tuner

    func ensureLibrary() async -> Library? {
        if let library { return library }
        guard let session else { return nil }
        do { let l = try await session.requestLibrary(); library = l; return l } catch { append("Library request failed: \(error)"); return nil }
    }
    /// From a slot cell's menu: open the library and load the picked item straight into `slot`.
    func openLibrary(_ kind: LibraryKind, into slot: Int?) { libraryTarget = slot; libraryOpen = kind }
    /// From a preset row's menu: Save as with that slot preselected.
    func saveAs(into index: Int) { saveAsTarget = index; saveAsOpen = true }

    func pick(_ choice: SlotChoice, slot: Int) {
        slotChooser = nil
        Task {
            guard let library else { return }
            let ok: Bool
            switch choice.kind {
            case .capture:
                guard let item = (choice.factory ? library.factoryCaptures : library.userCaptures).first(where: { $0.index == choice.index }) else { return }
                ok = await loadLibraryCapture(item, factory: choice.factory, into: slot)
            case .cab:
                guard let item = (choice.factory ? library.factoryIRs : library.userIRs).first(where: { $0.index == choice.index }) else { return }
                ok = await loadLibraryCab(item, factory: choice.factory, into: slot)
            }
            toast(ok ? "\(choice.kind == .capture ? "Capture" : "Cab") \(choice.name) loaded into slot \(slot)" : "The pedal refused to load \(choice.name).")
            if ok { usage = nil }
        }
    }

    /// Walks every non-empty preset to see which capture and cab slots they use. Audible on the pedal, so only on an explicit click.
    func scanSlotUsage() async {
        guard let session, let st = state, scanning == nil else { return }
        let origin = st.presetIndex
        var caps: [Int: [Int]] = [:], cabs: [Int: [Int]] = [:]
        scanning = 0
        var complete = true
        for i in 0..<presetNames.count where !presetNames[i].isEmpty {
            do {
                let s = try await session.selectPreset(index: i)
                if let c = s.captureSlot { caps[c, default: []].append(i) } else if s.captureFromLibrary { caps[0, default: []].append(i) }   // 0 = straight from the library
                if s.cabFromLibrary { cabs[0, default: []].append(i) } else if s.cabSlot > 0 { cabs[s.cabSlot, default: []].append(i) }
            } catch { append("Slot scan stopped at preset \(i + 1): \(error)"); complete = false; break }
            scanning = i + 1
        }
        if let back = try? await session.selectPreset(index: origin) { await applyState(back, presetLoad: true) }
        usage = SlotUsage(captures: caps, cabs: cabs, date: Date(), complete: complete)
        scanning = nil
        append(complete ? "Slot usage scanned: \(caps.count) capture slots and \(cabs.count) cab slots in use" : "Slot usage scan incomplete")
        toast(complete ? "Slot usage scanned." : "The scan stopped early; its results are partial.")
    }

    func loadLibraryCapture(_ item: LibraryCapture, factory: Bool, into slot: Int) async -> Bool {
        guard let session else { return false }
        do {
            let ok = try await session.loadLibraryCapture(slot: slot, factory: factory, index: item.index, name: item.name)
            if ok { metadata?.captureNames[slot - 1] = item.name; setCapture(slot: slot) }
            return ok
        } catch { append("Library load failed: \(error)"); return false }
    }
    func loadLibraryCab(_ item: LibraryItem, factory: Bool, into slot: Int) async -> Bool {
        guard let session else { return false }
        do {
            let ok = try await session.loadLibraryCab(slot: slot, factory: factory, index: item.index, name: item.name)
            if ok { metadata?.irNames[slot - 1] = item.name; selectCab(slot: slot) }
            return ok
        } catch { append("Library load failed: \(error)"); return false }
    }
    // MARK: session recording

    func startRecording() {
        recorder.start()
        recording = true
        append("Recording started")
        toast("Recording every packet. Click Record again to save the file.")
    }
    /// Ends the recording; the caller decides where it goes (save panel, or a path from the dev remote).
    func stopRecording() -> SessionRecording? {
        recording = false
        return recorder.stop(demo: demo, device: connected ? pedalName : nil, preset: state.map { $0.presetIndex + 1 })
    }
    func write(_ rec: SessionRecording, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rec.json().write(to: url, options: .atomic)
            append("Saved \(rec.events.count) packets to \(url.path)")
            toast("Saved \(rec.events.count) packets as \(url.lastPathComponent)")
            return true
        } catch { append("Saving the recording failed: \(error)"); toast("Couldn't save the recording."); return false }
    }
    /// `~/Documents/Nano Cortex Editor`; from a debug source build, the checkout's git-ignored `recordings/` folder.
    static var recordingFolder: URL {
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Source builds save into the checkout's git-ignored `recordings/` folder: recordings are never committed.
        if FileManager.default.fileExists(atPath: repo.appending(path: "project.yml").path) { return repo.appending(path: "recordings") }
        #endif
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Nano Cortex Editor")
    }

    // MARK: Cortex Cloud → pedal

    func offerSend(_ bundle: CaptureBundle) {
        guard connected else { toast("Connect your Nano Cortex first, then send \(bundle.record.name) again."); return }
        guard !uploading else { toast("A capture is already being sent."); return }
        pendingSend = bundle
        tab = .editor
    }
    func sendPending() {
        guard let bundle = pendingSend else { return }
        pendingSend = nil
        Task { await send(bundle) }
    }
    /// Streams the capture into the pedal's library, refreshes the library, then offers a slot.
    func send(_ bundle: CaptureBundle) async {
        guard connected, !uploading else { return }
        uploading = true
        let name = bundle.record.name
        defer { uploading = false; lastAction = "" }
        let reply: Messages.UploadReply
        do {
            reply = try await uploadCapture(cns: bundle.cns, record: bundle.record) { [weak self] i, n in Task { @MainActor in self?.lastAction = "Sending \(name): \(i) / \(n)" } }
        } catch { toast("Sending failed: \(error)"); append("Capture upload failed: \(error)"); return }
        guard reply.ok else { toast("The pedal refused \(name)."); append("Capture upload refused: \(reply)"); return }
        toast("\(name) is now in the pedal’s library.")
        append("Capture \"\(reply.name)\" stored as user capture \(reply.userIndex) (\(reply.hash.prefix(8)))")
        let lib = await ensureLibrary()
        let item = lib?.userCaptures.first { $0.hash == reply.hash } ?? lib?.userCaptures.first { $0.name == name }
        offerSlot = SlotChoice(kind: .capture, name: name, factory: false, index: item?.index ?? reply.userIndex)
    }

    func uploadCapture(cns: [UInt8], record: CaptureRecord, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Messages.UploadReply {
        guard let session else { throw TransportError.notConnected }
        let r = try await session.uploadCapture(cns: cns, record: record, progress: progress)
        library = nil
        return r
    }
    // MARK: device page

    /// Reads device info (46/47 + 91/92) and the global settings (65/66).
    func readDevice() async {
        guard let session, !deviceReading else { if session == nil { deviceError = "Connect to the pedal to read its settings." }; return }
        deviceReading = true; deviceError = nil
        defer { deviceReading = false }
        do { deviceInfo = try await session.readDeviceInfo() } catch { append("Device info failed: \(error)") }
        do {
            let s = try await session.readDeviceSettings()
            deviceSettings = s
            if let b = s.ledBrightness { ledBrightness = b }
            if let v = s.usbVolumeDb { usbVolumeDb = Double(v) }
            append("Settings: LED brightness \(s.ledBrightness.map(String.init) ?? "?"), USB volume \(s.usbVolumeDb.map { String(format: "%.1f", $0) } ?? "?") dB")
        } catch {
            deviceSettings = nil
            deviceError = "The pedal didn’t send its settings (\(error))."
            append("Settings request failed: \(error)")
        }
    }

    /// Live write of LED brightness and/or USB volume. Both go in every write (as the phone app does), so nothing is
    /// sent until the settings were read. While one write waits for its 68 ack, newer values replace the queued one.
    func setDeviceSettings(brightness: Int? = nil, usbVolumeDb db: Double? = nil) {
        guard session != nil, deviceSettings != nil else { return }
        if let brightness { ledBrightness = max(0, min(255, brightness)) }
        if let db { usbVolumeDb = max(-20, min(0, (db * 2).rounded() / 2)) }
        devicePending = (ledBrightness, Float(usbVolumeDb))
        guard !deviceWriting else { return }
        deviceWriting = true
        Task {
            defer { deviceWriting = false }
            while let next = devicePending, let session {
                devicePending = nil
                do {
                    if !(try await session.writeDeviceSettings(brightness: next.0, usbVolumeDb: next.1)) { append("The pedal refused the settings write.") }
                } catch { append("Settings write failed: \(error)"); devicePending = nil; return }
            }
        }
    }

    /// Capture details without the popover (dev remote).
    func fetchCaptureInfo(slot: Int) async -> CaptureDetails? {
        guard let session else { return nil }
        do { return try await session.captureDetails(slot: slot) } catch { append("Capture details failed: \(error)"); return nil }
    }

    /// "Info…" on a capture slot (1–25): asks the pedal (17 → 18) and opens the popover on `anchor`.
    func showCaptureInfo(slot: Int, anchor: InfoAnchor) {
        guard let session else { return }
        captureInfo = nil; captureInfoError = nil; captureInfoAnchor = anchor
        Task {
            do {
                let d = try await session.captureDetails(slot: slot)
                guard captureInfoAnchor == anchor else { return }
                if d.ok { captureInfo = d } else { captureInfoError = "Slot \(Self.slotLabel(slot)) is empty." }
            } catch { captureInfoError = "The pedal didn’t answer (\(error))."; append("Capture details failed: \(error)") }
        }
    }

    func tuner(on: Bool, muted: Bool = false, reference: Float = 440) {
        guard let session else { return }
        tunerOn = on; if !on { tunerReading = nil }
        Task { await session.tuner(on: on, baseFrequency: reference, muted: muted) }
    }
}
