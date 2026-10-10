// The Expression pedal panel: the current preset's assignments (types 60–63, PROTOCOL-NOTES §12), shown in the
// inspector when the chain's EXP pill is selected. Every edit replaces the whole set on the pedal with one type 62
// (the store coalesces while a knob is dragged); Save commits it like any other edit.

import SwiftUI
import NanoCore

typealias ExpRange = ExpressionAssignments.RangeTarget
typealias ExpBypass = ExpressionAssignments.BypassTarget

/// A row's target: a sweep (heel → toe) or an on/off switch.
enum ExpTarget: Hashable {
    case range(ExpRange)
    case bypass(ExpBypass)
    static let all: [ExpTarget] = ExpRange.allCases.sorted().map { .range($0) } + ExpBypass.allCases.sorted().map { .bypass($0) }
}

extension PedalStore {
    func expTitle(_ t: ExpTarget) -> String {
        switch t {
        case .range(let r):
            switch r {
            case .gain, .bass, .mid, .treble: r.key.capitalized
            case .level: "Capture volume"
            case .gate: "Gate reduction"
            default: r.slot!.title + " amount"
            }
        case .bypass(let b):
            switch b {
            case .capture: "Capture on/off"
            case .cab: "Cab / IR on/off"
            case .gate: "Gate on/off"
            default: b.slot!.title + " on/off"
            }
        }
    }
    /// What the target currently holds (the effect in an FX slot, the capture, the cab).
    func expDetail(_ t: ExpTarget) -> String {
        let slot: Slot? = switch t { case .range(let r): r.slot; case .bypass(let b): b.slot }
        if let slot { return blocks[slot]?.model?.name ?? "Empty slot" }
        switch t {
        case .range(.gain), .range(.bass), .range(.mid), .range(.treble), .range(.level), .bypass(.capture): return captureName.isEmpty ? "Capture" : captureName
        case .bypass(.cab): return cab.name.isEmpty ? "Cab / IR" : cab.name
        default: return "Noise gate"
        }
    }
    func expColor(_ t: ExpTarget) -> Color {
        switch t {
        case .range(let r): r.slot.map { color(for: Stage(rawValue: $0.rawValue)!) } ?? (r == .gate ? Theme.gate : Theme.capture)
        case .bypass(let b): b.slot.map { color(for: Stage(rawValue: $0.rawValue)!) } ?? (b == .gate ? Theme.gate : b == .cab ? Theme.cab : Theme.capture)
        }
    }
    /// Heel/toe in the parameter's units: amp knobs, FX amount and gate as a percentage of 0–255 (as the inspector
    /// shows the amp knobs), capture volume in dB on the capture-volume curve (unverified for expression ranges).
    func expFormat(_ r: ExpRange, _ raw: Double) -> String {
        r == .level ? Fmt.db(Capture.rawToDb(Int(raw.rounded()))) : "\(Int((raw / 255 * 100).rounded()))%"
    }
    func expParse(_ r: ExpRange, _ text: String) -> Double? {
        let s = text.replacingOccurrences(of: "dB", with: "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        guard let v = Double(s) else { return nil }
        return r == .level ? Double(Capture.dbToRaw(v)) : v / 100 * 255
    }

    /// Assigns `target` (keeping the row's settings when it replaces a target of the same kind).
    func expAssign(_ target: ExpTarget, replacing old: ExpTarget? = nil) {
        var set = expression ?? ExpressionAssignments()
        var keptRange: ExpressionAssignments.Range?, keptBypass: ExpressionAssignments.Bypass?
        switch old {
        case .range(let r)?: keptRange = set.ranges.removeValue(forKey: r)
        case .bypass(let b)?: keptBypass = set.bypasses.removeValue(forKey: b)
        case nil: break
        }
        switch target {
        case .range(let r): set.ranges[r] = keptRange ?? .init()
        case .bypass(let b): set.bypasses[b] = keptBypass ?? .default
        }
        setExpression(set)
    }
    func expRemove(_ target: ExpTarget) {
        guard var set = expression else { return }
        switch target { case .range(let r): set.ranges[r] = nil; case .bypass(let b): set.bypasses[b] = nil }
        setExpression(set)
    }
    func expAssigned(_ t: ExpTarget) -> Bool {
        switch t { case .range(let r): expression?.ranges[r] != nil; case .bypass(let b): expression?.bypasses[b] != nil }
    }
}

struct ExpressionPanel: View {
    @Environment(PedalStore.self) private var store
    static let emptyText = "No expression assignments. Plug an expression pedal into EXP/MIDI and assign a knob here."

    var body: some View {
        let set = store.expression
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Expression pedal").font(Theme.font(18, .semibold)).tracking(-0.27)
                Text("Preset \(store.presetIndex + 1) · \(store.presetName(store.presetIndex))").font(Theme.font(13)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            .padding(.bottom, 18)

            HStack(alignment: .center, spacing: 10) {
                SectionLabel(text: "Assignments")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    addMenu
                    Button("Clear all") { store.clearExpression() }
                        .buttonStyle(ThemedButton(kind: .ghost, small: true)).disabled(set?.isEmpty ?? true)
                        .accessibilityIdentifier("expClear")
                }
            }
            .frame(minHeight: 15).padding(.bottom, 10)
            Text("Sweeps follow the pedal from heel to toe; switches turn a block on or off. Edits are live on the pedal: Save (⌘S) keeps them in the preset.")
                .font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.top, -4).padding(.bottom, 10)

            if let set {
                if set.isEmpty {
                    Text(Self.emptyText).font(Theme.font(13)).foregroundStyle(Theme.dim).lineSpacing(3)
                        .frame(maxWidth: 360, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(.vertical, 28)
                        .accessibilityIdentifier("expEmpty")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(ExpTarget.all.filter { store.expAssigned($0) }, id: \.self) { ExpressionRow(target: $0) }
                    }
                }
            } else {
                Text(store.expressionError ?? "Reading the assignments from the pedal…").font(Theme.font(13)).foregroundStyle(Theme.faint).padding(.vertical, 28)
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("expressionPanel")
    }

    private var addMenu: some View {
        Menu {
            Section("Sweep (heel → toe)") {
                ForEach(ExpRange.allCases.sorted(), id: \.self) { r in
                    Button(store.expTitle(.range(r))) { store.expAssign(.range(r)) }.disabled(store.expAssigned(.range(r)))
                }
            }
            Section("Switch on / off") {
                ForEach(ExpBypass.allCases.sorted(), id: \.self) { b in
                    Button(store.expTitle(.bypass(b))) { store.expAssign(.bypass(b)) }.disabled(store.expAssigned(.bypass(b)))
                }
            }
        } label: { Text("Add assignment") }
            .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ThemedButton(kind: .ghost, small: true)).fixedSize()
            .disabled(store.expression == nil || store.expression?.count == ExpTarget.all.count)
            .accessibilityIdentifier("expAdd")
    }
}

/// One assignment: target menu, heel/toe (or switch mode, delay, latch), invert, Remove. `.exp-row` in upstream's CSS.
private struct ExpressionRow: View {
    @Environment(PedalStore.self) private var store
    let target: ExpTarget

    var body: some View {
        let color = store.expColor(target)
        HStack(alignment: .center, spacing: 18) {
            targetMenu(color: color).frame(width: 210, alignment: .leading)
            switch target {
            case .range(let r): rangeControls(r, color: color)
            case .bypass(let b): bypassControls(b, color: color)
            }
            Spacer(minLength: 0)
            Button("Remove") { store.expRemove(target) }.buttonStyle(ThemedButton(kind: .ghost, small: true))
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: 860, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func targetMenu(color: Color) -> some View {
        Menu {
            Section("Sweep (heel → toe)") {
                ForEach(ExpRange.allCases.sorted(), id: \.self) { r in
                    Button(store.expTitle(.range(r))) { store.expAssign(.range(r), replacing: target) }.disabled(store.expAssigned(.range(r)))
                }
            }
            Section("Switch on / off") {
                ForEach(ExpBypass.allCases.sorted(), id: \.self) { b in
                    Button(store.expTitle(.bypass(b))) { store.expAssign(.bypass(b), replacing: target) }.disabled(store.expAssigned(.bypass(b)))
                }
            }
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.expTitle(target)).font(Theme.font(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(store.expDetail(target)).font(Theme.font(11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("▾").font(Theme.font(11)).foregroundStyle(Theme.faint)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .help("Change what the pedal controls")
    }

    private func update(_ change: (inout ExpressionAssignments) -> Void) {
        guard var set = store.expression else { return }
        change(&set)
        store.setExpression(set)
    }

    @ViewBuilder private func rangeControls(_ r: ExpRange, color: Color) -> some View {
        let v = store.expression?.ranges[r] ?? .init()
        Knob(label: "Heel", color: color, min: 0, max: 255, step: 1, defaultValue: 0, value: Double(v.min),
             format: { store.expFormat(r, $0) }, parse: { store.expParse(r, $0) },
             live: { x in update { $0.ranges[r]?.min = Int(x) } }, commit: { x in update { $0.ranges[r]?.min = Int(x) } })
            .frame(width: 92)
        Knob(label: "Toe", color: color, min: 0, max: 255, step: 1, defaultValue: 255, value: Double(v.max),
             format: { store.expFormat(r, $0) }, parse: { store.expParse(r, $0) },
             live: { x in update { $0.ranges[r]?.max = Int(x) } }, commit: { x in update { $0.ranges[r]?.max = Int(x) } })
            .frame(width: 92)
        labelledSwitch("Invert", on: v.inverted, color: color) { update { $0.ranges[r]?.inverted.toggle() } }
    }

    @ViewBuilder private func bypassControls(_ b: ExpBypass, color: Color) -> some View {
        let mode = store.expression?.bypasses[b] ?? .default
        VStack(alignment: .leading, spacing: 7) {
            Text("Switches").font(Theme.font(12)).foregroundStyle(Theme.dim)
            Segmented(items: ["Heel-toe", "Switch", "Stop"], selected: ["heelToe": "Heel-toe", "switch": "Switch", "stop": "Stop"][mode.modeKey]!, color: color) { pick in
                update { set in
                    let inv: Bool = switch mode { case .heelToe(let i, _), .toggle(let i, _): i; case .stop: false }
                    let delay: Int = switch mode { case .heelToe(_, let d), .stop(let d): d; case .toggle: 600 }
                    set.bypasses[b] = pick == "Switch" ? .toggle(inverted: inv, latch: false) : pick == "Stop" ? .stop(delayMs: delay) : .heelToe(inverted: inv, delayMs: delay)
                }
            }
        }
        .padding(.horizontal, 4)
        switch mode {
        case .heelToe(let inv, let ms):
            delayKnob(b, ms, color: color) { .heelToe(inverted: inv, delayMs: $0) }
            labelledSwitch("Invert", on: inv, color: color) { update { $0.bypasses[b] = .heelToe(inverted: !inv, delayMs: ms) } }
        case .toggle(let inv, let latch):
            labelledSwitch("Latch", on: latch, color: color) { update { $0.bypasses[b] = .toggle(inverted: inv, latch: !latch) } }
                .help("Latch emulation: each press toggles the block instead of holding it")
            labelledSwitch("Invert", on: inv, color: color) { update { $0.bypasses[b] = .toggle(inverted: !inv, latch: latch) } }
        case .stop(let ms):
            delayKnob(b, ms, color: color) { .stop(delayMs: $0) }
        }
    }

    private func delayKnob(_ b: ExpBypass, _ ms: Int, color: Color, make: @escaping (Int) -> ExpressionAssignments.Bypass) -> some View {
        Knob(label: "Delay", color: color, min: 0, max: Double(ExpressionAssignments.maxDelayMs), step: 1, defaultValue: 600, value: Double(ms),
             format: { "\(Int($0)) ms" }, parse: { Double($0.replacingOccurrences(of: "ms", with: "").trimmingCharacters(in: .whitespaces)) },
             live: { x in update { $0.bypasses[b] = make(Int(x)) } }, commit: { x in update { $0.bypasses[b] = make(Int(x)) } })
            .frame(width: 92)
    }

    private func labelledSwitch(_ label: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        VStack(alignment: .center, spacing: 9) {
            Text(label).font(Theme.font(12)).foregroundStyle(Theme.dim)
            Switch(on: on, color: color == Theme.none ? Theme.accent : color, action: action)   // an empty slot's grey would read as off
        }
        .padding(.horizontal, 4)
    }
}
