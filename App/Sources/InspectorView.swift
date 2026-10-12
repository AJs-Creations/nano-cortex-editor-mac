// The inspector for the selected stage: model/slot pickers and knobs.
// Layout follows pro/ui.css `.inspector`, `.insp-head`, `.section`, `.params`, `.slots`.

import SwiftUI
import NanoCore

struct InspectorView: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if store.expressionOpen {
                    ExpressionPanel()
                } else {
                    head.padding(.bottom, 18)
                    switch store.selectedStage {
                    case .gate: gate
                    case .capture: capture
                    case .cab: cabView
                    default: fx(store.selectedStage.slot!)
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var head: some View {
        let stage = store.selectedStage, color = store.color(for: stage), on = store.isOn(stage)
        return HStack(spacing: 12) {
            Text(stage.title).font(Theme.font(18, .semibold)).tracking(-0.27)
            if let slot = stage.slot { ModelPicker(slot: slot) }
            Spacer(minLength: 0)
            PresetTempoControl()
            // `.switch`: track + label in one control; the label is a separate text for the UI test.
            HStack(spacing: 8) {
                Switch(on: on, color: color, enabled: store.hasContent(stage)) { store.toggle(stage) }.accessibilityIdentifier("stageToggle")
                Text(on ? "On" : "Bypassed").font(Theme.font(12)).foregroundStyle(on ? Theme.text : Theme.dim).fixedSize()
                    .onTapGesture { if store.hasContent(stage) { store.toggle(stage) } }
            }
            .padding(4)
        }
    }

    /// `.params`: auto-fill columns of at least 92 points, 18 × 12 gaps.
    private var paramColumns: [GridItem] { [GridItem(.adaptive(minimum: 92), spacing: 12, alignment: .top)] }

    // MARK: gate
    private var gate: some View {
        VStack(alignment: .leading, spacing: 0) {
            Note("The adaptive gate sits at the input, before everything else in the chain.")
            LazyVGrid(columns: paramColumns, alignment: .leading, spacing: 18) {
                Knob(label: "Reduction", color: Theme.gate, min: 0, max: 100, step: 1, defaultValue: 50, locked: !store.gateOn,
                     value: Double(store.gateReduction), format: { "\(Int($0))%" },
                     live: { store.setGateReduction(Int($0), commit: false) }, commit: { store.setGateReduction(Int($0), commit: true) })
            }
        }
    }

    // MARK: capture
    private var capture: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section("Amp") {
                LazyVGrid(columns: paramColumns, alignment: .leading, spacing: 18) {
                    ForEach([AmpKnob.gain, .bass, .mid, .treble, .level], id: \.self) { k in
                        Knob(label: k.rawValue.capitalized, color: Theme.capture, min: 0, max: 255, step: 1, defaultValue: 128, locked: !store.captureOn,
                             value: Double(store.amp[k] ?? 128), format: { "\(Int(($0 / 255 * 100).rounded()))%" }, parse: { Double($0.replacingOccurrences(of: "%", with: "")).map { $0 / 100 * 255 } },
                             live: { store.setAmp(k, Int($0), commit: false) }, commit: { store.setAmp(k, Int($0), commit: true) })
                    }
                    Knob(label: "Capture volume", color: Theme.capture, min: -24, max: 12, step: 0.1, defaultValue: 0, locked: !store.captureOn,
                         value: store.captureVolumeDb, format: { Fmt.db($0) },
                         live: { store.setCaptureVolume($0, commit: false) }, commit: { store.setCaptureVolume($0, commit: true) })
                }
            }
            Section("Captures on the pedal", first: false) {
                usageMenu
                LibraryButton(kind: .capture)
            } content: {
                if store.captureFromLibrary { Note("This preset uses \(store.captureName) straight from the library.") }
                SlotGrid(count: store.captureSlotCount, names: store.metadata?.captureNames ?? [], selected: store.captureSlot, color: Theme.capture, label: { PedalStore.slotLabel($0) }, used: { store.usage?.captures[$0]?.count }) { store.setCapture(slot: $0) }
            }
        }
    }
    /// Slot usage: an explicit scan (it flips through every preset on the pedal), then a summary for the current slot.
    private var usageMenu: some View {
        Menu {
            if let u = store.usage {
                Text((u.complete ? "Scanned " : "Partial scan ") + u.date.formatted(date: .omitted, time: .shortened))
                if let slot = store.captureSlot {
                    let users = u.captures[slot] ?? []
                    Text(users.isEmpty ? "Slot \(bankLabel(slot)) is used by no saved preset" : "Slot \(bankLabel(slot)) feeds: " + users.map { "\($0 + 1) \(store.presetName($0))" }.joined(separator: ", "))
                }
                if let lib = u.captures[0], !lib.isEmpty { Text("Straight from the library (no slot): " + lib.map { "\($0 + 1) \(store.presetName($0))" }.joined(separator: ", ")) }
                let free = (1...store.captureSlotCount).filter { (u.captures[$0] ?? []).isEmpty }
                Text(free.isEmpty ? "Every capture slot is used by a preset" : "Free capture slots: " + free.map(bankLabel).joined(separator: " "))
                Divider()
            }
            Button(store.scanning == nil ? "Scan slot usage…" : "Scanning \(store.scanning!)/\(store.presetNames.count)…") { Task { await store.scanSlotUsage() } }
                .disabled(store.scanning != nil || store.edited || store.dirty)
            if store.edited || store.dirty { Text("Save or discard your edits first; the scan switches presets.") }
        } label: {
            Text(store.scanning == nil ? "Usage…" : "Scanning…")
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ThemedButton(kind: .ghost, small: true)).fixedSize()
        .help("Which presets use each capture slot (scans every preset on the pedal)")
    }
    private func bankLabel(_ slot: Int) -> String { PedalStore.slotLabel(slot) }

    // MARK: cab
    private static let mics = ["Condenser 184", "Condenser 414", "Dynamic 421", "Dynamic 57", "Ribbon 160"]
    private var cabView: some View {
        let mics = store.cabMics.isEmpty ? Self.mics : store.cabMics
        let micsOn = store.cab.on && store.cab.slot > 0
        return VStack(alignment: .leading, spacing: 0) {
            Section("Tone") {
                LazyVGrid(columns: paramColumns, alignment: .leading, spacing: 18) {
                    Knob(label: "Level", color: Theme.cab, min: -96, max: 12, step: 0.1, defaultValue: 0, locked: !store.cab.on,
                         value: store.cab.levelDb, format: { Fmt.db($0) },
                         live: { store.setCabLevel($0, commit: false) }, commit: { store.setCabLevel($0, commit: true) })
                    Knob(label: "High pass", color: Theme.cab, min: 20, max: 800, step: 1, defaultValue: 20, logScale: true, locked: !store.cab.on,
                         value: store.cab.highPassHz, format: { Fmt.hz($0) },
                         live: { store.setCabHighPass($0, commit: false) }, commit: { store.setCabHighPass($0, commit: true) })
                    Knob(label: "Low pass", color: Theme.cab, min: 1000, max: 20000, step: 1, defaultValue: 20000, logScale: true, locked: !store.cab.on,
                         value: store.cab.lowPassHz, format: { Fmt.hz($0) },
                         live: { store.setCabLowPass($0, commit: false) }, commit: { store.setCabLowPass($0, commit: true) })
                }
            }
            Section("Microphone", first: false) {
                if micsOn {
                    // DECISION #11: mic and position belong to the cab slot on the pedal, not to the preset.
                    Note("Mic and position are stored in cab slot \(store.cab.slot) itself: changing them changes every preset that uses this slot, and no save is needed.")
                }
                if store.cab.on, !store.cab.loaded { Note("Reading cab settings from the pedal…") }
                // `.params.wide`: flex row, 14 × 28 gaps.
                HStack(alignment: .top, spacing: 28) {
                    Choice(label: "Mic", locked: !micsOn) {
                        Segmented(items: mics, selected: store.cab.mic, color: Theme.cab) { store.setCabMic($0, position: store.cab.position) }
                    }
                    Choice(label: "Position", locked: !micsOn) {
                        Segmented(items: (1...6).map(String.init), selected: "\(store.cab.position)", color: Theme.cab) { store.setCabMic(store.cab.mic, position: Int($0) ?? 1) }
                    }
                }
                .padding(.horizontal, -4)
            }
            Section("Cabs and IRs on the pedal", first: false) {
                Button(store.cab.on ? "Bypass cab" : "No cab") { if store.cab.on { store.selectCab(slot: 0) } }.buttonStyle(ThemedButton(kind: .ghost, small: true)).disabled(!store.cab.on)
                LibraryButton(kind: .cab)
            } content: {
                if store.cab.fromLibrary { Note("This preset uses \(store.cab.name) straight from the library.") }
                SlotGrid(count: store.cabSlotCount, names: store.metadata?.irNames ?? [], selected: store.cab.slot > 0 ? store.cab.slot : nil, color: Theme.cab, kind: .cab, label: { "\($0)" }, used: { store.usage?.cabs[$0]?.count }) { store.selectCab(slot: $0) }
            }
        }
    }

    // MARK: fx
    private func fx(_ slot: Slot) -> some View {
        let block = store.blocks[slot], model = block?.model, color = store.color(for: store.selectedStage)
        return VStack(alignment: .leading, spacing: 0) {
            if let model, let block {
                LazyVGrid(columns: paramColumns, alignment: .leading, spacing: 18) {
                    ForEach(Array(model.params.enumerated()), id: \.offset) { i, p in
                        let v = i < block.values.count ? block.values[i] : p.defaultValue
                        switch p.meta {
                        case .options(let opts)?:
                            Choice(label: p.name, locked: !block.on, centered: true) {
                                Picker("", selection: Binding(get: { Int(v) }, set: { store.setFXParam(slot, index: i, value: Double($0), commit: true) })) {
                                    ForEach(Array(opts.enumerated()), id: \.offset) { j, o in Text(o).tag(j) }
                                }.labelsHidden().frame(maxWidth: 140)
                            }
                        case .range(let lo, let hi, let step, let unit, let dec)?:
                            Knob(label: p.name, color: color, min: lo, max: hi, step: step > 0 ? step : 0.1, defaultValue: p.defaultValue, logScale: unit == "Hz" && lo > 0 && hi / lo > 20, locked: !block.on,
                                 value: v, format: { Fmt.unit($0, unit: unit, decimals: dec ?? 1) },
                                 live: { store.setFXParam(slot, index: i, value: $0, commit: false) }, commit: { store.setFXParam(slot, index: i, value: $0, commit: true) })
                        case nil:
                            Knob(label: p.name, color: color, min: 0, max: 10, step: 0.1, defaultValue: p.defaultValue, locked: !block.on,
                                 value: v, format: { String(format: "%.1f", $0) },
                                 live: { store.setFXParam(slot, index: i, value: $0, commit: false) }, commit: { store.setFXParam(slot, index: i, value: $0, commit: true) })
                        }
                    }
                }
            } else if block?.unknownId != nil {
                // A model id Models.swift doesn't list (newer firmware): no knobs, no parameter writes.
                (Text(Compatibility.unknownEffectTitle + ". ").font(Theme.font(13, .semibold)).foregroundColor(Theme.text)
                 + Text(Compatibility.unknownEffectNote).font(Theme.font(13)).foregroundColor(Theme.dim))
                    .lineSpacing(3).frame(maxWidth: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.vertical, 28)
                    .accessibilityIdentifier("unknownEffectNote")
            } else {
                // `.empty-block`
                (Text("\(store.selectedStage.title) is empty. ").font(Theme.font(13, .semibold)).foregroundColor(Theme.text)
                 + Text("Pick an effect to add it to the chain. " + emptyHint(slot)).font(Theme.font(13)).foregroundColor(Theme.dim))
                    .lineSpacing(3).frame(maxWidth: 330, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.vertical, 28)
            }
        }
    }
    private func emptyHint(_ slot: Slot) -> String {
        switch store.selectedStage {
        case .pre1, .pre2: "Pre slots sit before the capture: drives, compressors, wahs, EQ and pitch."
        case .post1: "This slot takes modulation and EQ/utility effects."
        case .post2: "This slot takes delays and EQ/utility effects."
        default: "This slot takes reverbs and EQ/utility effects."
        }
    }
}

/// `.section`: 22 points above (none for the first), an 11/600 tracked heading 10 points above the content,
/// with optional right-aligned actions (`.section-head`).
/// The preset's tempo in the inspector's top row: drag the label to scrub, − / + to step, type a number, or Tap.
/// Steps, drags and taps write live (the pedal plays it, the preset stays clean); one write into the preset follows
/// on release, Enter or when the steps/taps settle, which marks the preset edited. Save keeps it (PROTOCOL-NOTES §11).
struct PresetTempoControl: View {
    @Environment(PedalStore.self) private var store
    @State private var text = ""
    @State private var dragFrom: Int?
    @State private var cursorPushed = false
    @FocusState private var focused: Bool
    var body: some View {
        let value = store.presetTempo ?? 120, enabled = store.connected && store.presetTempo != nil
        HStack(spacing: 8) {
            SectionLabel(text: "Tempo")
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside, enabled, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
                    else if !inside, cursorPushed { NSCursor.pop(); cursorPushed = false }
                }
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { g in
                        guard enabled else { return }
                        let from = dragFrom ?? value; dragFrom = from
                        let v = max(30, min(300, from + Int((g.translation.width / 4).rounded())))
                        if v != store.presetTempo { store.setTempo(v, live: true) }
                    }
                    .onEnded { _ in if let v = store.presetTempo, dragFrom != nil { store.setTempo(v, live: false) }; dragFrom = nil })
                .help("Drag sideways to change the preset tempo")
            HStack(spacing: 0) {
                Button { store.nudgeTempo(value - 1) } label: { Image(systemName: "minus") }.buttonStyle(StepButton()).disabled(!enabled || value <= 30)
                    .accessibilityIdentifier("tempoMinus")
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(Theme.font(13, .semibold)).monospacedDigit().multilineTextAlignment(.center)
                    .frame(width: 36, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(focused ? Theme.panel : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.focus : .clear))
                    .focused($focused)
                    .onSubmit { commitText(); focused = false }
                    .onExitCommand { text = "\(value)"; focused = false }
                    .onChange(of: focused) { _, f in if !f { commitText() } }
                    .onAppear { text = store.presetTempo.map(String.init) ?? "–" }
                    .onChange(of: store.presetTempo) { _, v in if !focused { text = v.map(String.init) ?? "–" } }
                    .accessibilityIdentifier("tempoField")
                Button { store.nudgeTempo(value + 1) } label: { Image(systemName: "plus") }.buttonStyle(StepButton()).disabled(!enabled || value >= 300)
                    .accessibilityIdentifier("tempoPlus")
            }
            .padding(.horizontal, 2).frame(height: 30)
            .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            Text("BPM").font(Theme.font(12)).foregroundStyle(Theme.dim)
            Button("Tap") { store.tapTempo() }.buttonStyle(ThemedButton(small: true)).disabled(!enabled).accessibilityIdentifier("tempoTap")
                .help("Tap the beat; the preset gets the tempo when you stop")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
        .padding(.trailing, 8)
    }
    private func commitText() {
        guard let v = TypedNumber.commit(text, range: 30...300) else { text = store.presetTempo.map(String.init) ?? "–"; return }
        if v != store.presetTempo { store.setTempo(v, live: false) }
        text = "\(v)"
    }
}

private struct Section<Actions: View, Content: View>: View {
    let title: String
    var first = true
    @ViewBuilder let actions: Actions
    @ViewBuilder let content: Content
    init(_ title: String, first: Bool = true, @ViewBuilder actions: () -> Actions, @ViewBuilder content: () -> Content) {
        self.title = title; self.first = first; self.actions = actions(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                SectionLabel(text: title)
                Spacer(minLength: 0)
                HStack(spacing: 4) { actions }
            }
            .frame(minHeight: 15).padding(.bottom, 10)
            content
        }
        .padding(.top, first ? 0 : 22)
    }
}
extension Section where Actions == EmptyView {
    init(_ title: String, first: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, first: first, actions: { EmptyView() }, content: content)
    }
}

/// `.section .note`: faint 12-point line under a heading.
private struct Note: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.top, -4).padding(.bottom, 10) }
}

/// `.choice`: a label over a segmented control or menu; .38 when locked.
private struct Choice<Content: View>: View {
    let label: String
    var locked = false
    var centered = false
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 7) {
            Text(label).font(Theme.font(12)).foregroundStyle(Theme.dim).multilineTextAlignment(centered ? .center : .leading)
            content
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .frame(maxWidth: centered ? .infinity : nil)
        .disabled(locked).opacity(locked ? 0.38 : 1)
    }
}

/// The model button in the inspector head (`.picker-btn`), opening a searchable list grouped by category (`.pop`).
struct ModelPicker: View {
    @Environment(PedalStore.self) private var store
    let slot: Slot
    @State private var open = false
    @State private var query = ""
    @State private var hover = false
    var body: some View {
        let model = store.blocks[slot]?.model, unknown = store.blocks[slot]?.unknownId != nil
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                Text(model?.name ?? (unknown ? Compatibility.unknownEffectTitle : "Choose an effect")).font(Theme.font(13)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                if let model { Text(model.category).font(Theme.font(12)).foregroundStyle(Theme.dim).lineLimit(1) }
                else if unknown { Text(Compatibility.unknownEffectSubtitle).font(Theme.font(12)).foregroundStyle(Theme.dim).lineLimit(1) }
                Text("▾").font(Theme.font(11)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).frame(minWidth: 260).frame(height: 34)
            .background(hover ? Theme.raisedHi : Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Change effect")
        .onChange(of: store.modelPickerOpen) { _, v in if v, store.selectedStage.slot == slot { store.modelPickerOpen = false; open = true } }   // from a node's context menu
        .popover(isPresented: $open, arrowEdge: .bottom) {
            let models = Models.list(for: slot.rawValue).filter { $0.id != nil }
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let hits = q.isEmpty ? models : models.filter { $0.name.lowercased().contains(q) || $0.category.lowercased().contains(q) }
            let cats = hits.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
            VStack(spacing: 0) {
                SearchField(prompt: "Search effects", text: $query, accent: true) { if let m = hits.first { store.setFXModel(slot, m); open = false } }
                    .padding(10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        PopItem(title: "None", current: model == nil && !unknown) { store.setFXModel(slot, nil); open = false }
                        ForEach(cats, id: \.self) { cat in
                            PopGroup(title: cat)
                            ForEach(hits.filter { $0.category == cat }, id: \.name) { m in
                                PopItem(title: m.name, current: m.name == model?.name) { store.setFXModel(slot, m); open = false }
                            }
                        }
                        if hits.isEmpty { Text("Nothing matches “\(query)”.").font(Theme.font(13)).foregroundStyle(Theme.faint).padding(14) }
                    }.padding(.horizontal, 6).padding(.bottom, 8)
                }.frame(height: 360)
            }
            .frame(width: 320).background(Theme.pop).foregroundStyle(Theme.text)
            .presentationBackground(Theme.pop)
            .onAppear { query = "" }
        }
    }
}

/// `.pop-group`: 11/600 faint category heading.
struct PopGroup: View {
    let title: String
    var body: some View {
        Text(title).font(Theme.font(11, .semibold)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }
}

/// `.pop-item`: 28-point row, #33405A on hover, "Current" on the right for the current one.
struct PopItem: View {
    let title: String
    var subtitle: String = ""
    var icons: [CaptureKind.Icon] = []   // capture kind icons before the subtitle
    var tooltip: String = ""
    var current = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.font(13)).lineLimit(1)
                    if !subtitle.isEmpty || !icons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(icons, id: \.self) { KindIcon(icon: $0) }
                            if !subtitle.isEmpty { Text(subtitle).font(Theme.font(11)).lineLimit(1) }
                        }.foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 0)
                if current { Text("Current").font(Theme.font(11)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 9).frame(minHeight: 28).padding(.vertical, subtitle.isEmpty && icons.isEmpty ? 0 : 4)
            .background(hover ? Theme.popHi : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hover = $0 }
    }
}

/// `.slots`: auto-fill columns of at least 210 points, 6-point gaps; `.slot` 34 tall with a 24-point number column.
struct SlotGrid: View {
    @Environment(PedalStore.self) private var store
    let count: Int, names: [String], selected: Int?, color: Color
    var kind: PedalStore.LibraryKind = .capture
    let label: (Int) -> String
    let used: (Int) -> Int?
    let pick: (Int) -> Void
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 6)], spacing: 6) {
            ForEach(1...count, id: \.self) { i in
                let name = names[safe: i - 1] ?? ""
                SlotCell(number: label(i), name: name, on: selected == i, color: color, used: used(i)) { pick(i) }
                    .contextMenu {
                        Button(selected == i ? "Loaded in this preset" : "Load into this preset") { pick(i) }.disabled(selected == i)
                        Button("Put a library \(kind == .capture ? "capture" : "cab") in slot \(label(i))…") { store.openLibrary(kind, into: i) }
                        if kind == .capture { Button("Info…") { store.showCaptureInfo(slot: i, anchor: .slot(i)) }.disabled(name.isEmpty) }
                        if let n = used(i) { Divider(); Text("Used by \(n) preset\(n == 1 ? "" : "s")") }
                    }
                    .popover(isPresented: Binding(get: { kind == .capture && store.captureInfoAnchor == .slot(i) }, set: { if !$0 { store.captureInfoAnchor = nil } }), arrowEdge: .bottom) {
                        CaptureInfoPopover(slot: i)
                    }
            }
        }
    }
}

/// `.slot`: raised, #232323 border, dim text; hover #2E2E2E; on: border and number in the stage colour.
struct SlotCell: View {
    let number: String, name: String, on: Bool, color: Color
    var used: Int? = nil
    var dimmed = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(number).font(Theme.font(11)).foregroundStyle(on ? color : Theme.faint).frame(width: 24, alignment: .leading)
                Text(name.isEmpty ? "Empty" : name).font(Theme.font(13)).foregroundStyle(name.isEmpty ? Theme.faint : (on || hover ? Theme.text : Theme.dim)).italic(name.isEmpty).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if let n = used { Text("\(n)").font(Theme.font(11)).monospacedDigit().foregroundStyle(Theme.faint).help("Used by \(n) preset\(n == 1 ? "" : "s")") }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(on || hover ? Theme.raisedHi : Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? color : Theme.lineSoft))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .opacity(dimmed ? 0.45 : 1)
    }
}

/// `.seg`: workspace-coloured strip, 2-point padding; the selected item raised with a 2-point underline in the stage colour.
struct Segmented: View {
    let items: [String], selected: String, color: Color
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                SegItem(title: item, on: item == selected, color: color) { pick(item) }
            }
        }
        .padding(2).background(Theme.ws, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
        .fixedSize()
    }
    private struct SegItem: View {
        let title: String, on: Bool, color: Color
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            Button(action: action) {
                Text(title).font(Theme.font(12)).foregroundStyle(on || hover ? Theme.text : Theme.dim)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 4).fill(Theme.raisedHi)
                                .overlay(alignment: .bottom) { Rectangle().fill(color).frame(height: 2) }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

enum Fmt {
    static func db(_ v: Double) -> String { String(format: "%@%.1f dB", v > 0 ? "+" : "", v) }
    static func hz(_ v: Double) -> String { v >= 10000 ? String(format: "%.1f kHz", v / 1000) : "\(Int(v.rounded())) Hz" }
    static func unit(_ v: Double, unit: String, decimals: Int) -> String {
        if unit == "Hz" { return hz(v) }
        let s = String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? s : unit == "%" ? s + "%" : s + " " + unit
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
