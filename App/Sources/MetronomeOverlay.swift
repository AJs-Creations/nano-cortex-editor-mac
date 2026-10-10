// The metronome overlay: a Simple / Advanced switch in the header. Simple is the original overlay;
// Advanced adds the time signature, accent cells, subdivisions with swing, count-in, the tempo and gap
// trainers, the bar counter with sub pips, and a Levels… popover.

import SwiftUI
import CoreAudio

/// Layout tokens for the overlay: one control height for every row (the header buttons' 30), an 8-point rhythm.
enum MetroLayout {
    static let control: CGFloat = 30
    static let labelGap: CGFloat = 8      // section label → its control
    static let columnGap: CGFloat = 24
    static let rowGap: CGFloat = 16
    static let sectionGap: CGFloat = 20   // either side of a divider
}

struct MetronomeOverlay: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        ZStack {
            Color.black.opacity(0.53).ignoresSafeArea().onTapGesture { metro.close() }
            VStack(spacing: 0) {
                // Title left, mode switch right, centred on one line.
                HStack(alignment: .center) {
                    SectionLabel(text: "Metronome")
                    Spacer()
                    MetronomeModeSwitch()
                }
                .padding(.bottom, MetroLayout.rowGap)
                if metro.mode == .simple { SimpleMetronome() } else { AdvancedMetronome() }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24).frame(width: metro.mode == .simple ? 520 : 640)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.8), radius: 30, y: 24)
        }
        .foregroundStyle(Theme.text)
    }
}

/// Simple / Advanced, as a pill group the overlay's control height (on the workspace colour, since the panel is #181818).
struct MetronomeModeSwitch: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        HStack(spacing: 2) {
            ForEach(MetronomeMode.allCases) { m in
                Button(m.title) { metro.mode = m }.buttonStyle(BarButton(selected: metro.mode == m, height: MetroLayout.control - 6)).accessibilityIdentifier("metro-mode-\(m.rawValue)")
            }
        }
        .padding(3).background(Theme.ws, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A section label over its control; every control in a row is `MetroLayout.control` tall, so labels share a line
/// and controls share a centre line.
private struct MetroField<C: View, A: View>: View {
    let title: String
    @ViewBuilder var accessory: A
    @ViewBuilder var content: C
    var body: some View {
        VStack(alignment: .leading, spacing: MetroLayout.labelGap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) { SectionLabel(text: title); accessory }
            content.frame(height: MetroLayout.control)
        }
    }
}
extension MetroField where A == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> C) { self.title = title; accessory = EmptyView(); self.content = content() }
}
extension MetroField {
    init(_ title: String, @ViewBuilder accessory: () -> A, @ViewBuilder content: () -> C) { self.title = title; self.accessory = accessory(); self.content = content() }
}

/// A full-width hairline between the overlay's big sections.
private struct MetroDivider: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, MetroLayout.sectionGap) }
}

/// The big tempo: − / field / +, "BPM" (with the trainer status), and the slider.
private struct TempoControl: View {
    @Environment(Metronome.self) private var metro
    @State private var bpmText = ""
    @FocusState private var bpmFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button { metro.set(bpm: metro.bpm - 1) } label: { Image(systemName: "minus") }.buttonStyle(ThemedButton())
                TextField("", text: $bpmText, onCommit: { if let v = Int(bpmText) { metro.set(bpm: v) }; bpmText = "\(metro.bpm)" })
                    .textFieldStyle(.plain).font(Theme.font(56, .semibold)).monospacedDigit().foregroundStyle(metro.running ? Theme.accentHi : Theme.text).multilineTextAlignment(.center)
                    .frame(width: 136, height: 64)
                    .focused($bpmFocused)
                    .onExitCommand { bpmText = "\(metro.bpm)"; bpmFocused = false }
                    .onChange(of: bpmFocused) { _, f in metro.editingField = f ? "bpm" : (metro.editingField == "bpm" ? nil : metro.editingField) }
                    .onAppear { bpmText = "\(metro.bpm)" }.onChange(of: metro.bpm) { _, v in bpmText = "\(v)" }
                Button { metro.set(bpm: metro.bpm + 1) } label: { Image(systemName: "plus") }.buttonStyle(ThemedButton())
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel(text: "BPM")
                if let r = metro.rampStatus { Text(r).font(Theme.font(12)).monospacedDigit().foregroundStyle(metro.running ? Theme.accentHi : Theme.dim).accessibilityIdentifier("rampStatus") }
                if metro.tempoFollowsPreset { Text("♩ follows preset").font(Theme.font(12)).foregroundStyle(Theme.dim).help("Settings → Metronome → Follow the preset tempo").accessibilityIdentifier("metroFollowsPreset") }
            }
            .frame(height: 16)
            // No `step:`: on macOS a stepped Slider draws a tick mark per step (270 here), the stray line under the track.
            Slider(value: Binding(get: { Double(metro.bpm) }, set: { metro.set(bpm: Int($0.rounded())) }), in: 30...300)
                .tint(Theme.accent).frame(width: 320).padding(.top, MetroLayout.rowGap)
        }
    }
}

/// The overlay's Output field.
private struct OutputPicker: View {
    var width: CGFloat = 200
    var body: some View { MetroField("Output") { OutputMenu(width: width) } }
}

/// The output device as a themed drop-down (the system pop-up is light grey and 22 points tall). Also in Settings.
struct OutputMenu: View {
    @Environment(Metronome.self) private var metro
    var width: CGFloat = 200
    var body: some View {
        @Bindable var m = metro
        Menu {
            Picker("", selection: $m.outputID) {
                Text("System default").tag(AudioDeviceID(0))
                ForEach(metro.outputs) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            MenuField(title: metro.outputs.first { $0.id == metro.outputID }?.name ?? "System default", width: width)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("metro-output")
        .onAppear { metro.refreshOutputs() }
    }
}

/// The closed look of a themed drop-down: workspace fill, hairline border, chevron at the right.
struct MenuField: View {
    let title: String
    var width: CGFloat? = nil
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.font(13)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 10).frame(width: width, height: MetroLayout.control)
        .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
        .foregroundStyle(Theme.text)
        .contentShape(Rectangle())
    }
}

private struct VolumeField: View {
    @Environment(Metronome.self) private var metro
    var width: CGFloat = 140
    var body: some View {
        @Bindable var m = metro
        MetroField("Volume", accessory: { PercentText(value: metro.volume) }) {
            Slider(value: $m.volume, in: 0...1).tint(Theme.accent).frame(width: width)
        }
    }
}

private struct PercentText: View {
    let value: Double
    var body: some View { Text("\(Int((value * 100).rounded()))%").font(Theme.font(11)).monospacedDigit().foregroundStyle(Theme.faint) }
}

private struct TransportButtons: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        HStack(spacing: 8) {
            Button("Tap tempo") { metro.tap() }.buttonStyle(ThemedButton())
            Button(metro.running ? "Stop" : "Start") { metro.toggle() }.buttonStyle(ThemedButton(kind: metro.running ? .normal : .primary)).keyboardShortcut(metro.editingField == nil ? KeyboardShortcut(.space, modifiers: []) : nil)
            Button("Close") { metro.close() }.buttonStyle(ThemedButton(kind: .ghost)).keyboardShortcut(metro.editingField == nil ? .cancelAction : nil)
        }
    }
}

private struct ErrorLine: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        if let e = metro.error { Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn).padding(.top, MetroLayout.rowGap) }
    }
}

// MARK: - Simple (the original overlay)

private struct SimpleMetronome: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(0..<metro.beats, id: \.self) { i in
                    Circle().fill(metro.running && metro.beat == i ? (i == 0 ? Theme.ok : Theme.accent) : Theme.raisedHi).frame(width: 14, height: 14).scaleEffect(metro.running && metro.beat == i ? 1.25 : 1)   // .metro-beats
                        .animation(.linear(duration: 0.05), value: metro.beat)
                }
            }
            .frame(height: 20).padding(.top, 8).padding(.bottom, MetroLayout.rowGap)
            TempoControl()
            MetroDivider()
            HStack(alignment: .top, spacing: MetroLayout.columnGap) {
                MetroField("Beats") { MiniStepper(value: metro.beats, range: 1...12, id: "metro-simple-beats") { metro.set(beats: $0) } }
                VolumeField(width: 120)
                OutputPicker(width: 220)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ErrorLine()
            TransportButtons().padding(.top, MetroLayout.sectionGap + 4)
        }
    }
}

// MARK: - Advanced

private struct AdvancedMetronome: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        @Bindable var m = metro
        let s = metro.setup
        VStack(alignment: .leading, spacing: 0) {
            // Bar counter and signature on one baseline, the pips right under them.
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metro.barLabel).font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(metro.barKind == .muted && metro.running ? Theme.dim : Theme.text).accessibilityIdentifier("barLabel")
                    Spacer()
                    Text("\(s.beats)/\(s.noteValue)" + (s.subdivision > 1 ? "  ·  \(subName(s.subdivision))" : "")).font(Theme.font(12)).monospacedDigit().foregroundStyle(Theme.dim)
                }
                BeatPips()
            }
            TempoControl().frame(maxWidth: .infinity).padding(.top, MetroLayout.rowGap)
            MetroDivider()
            // Rhythm: one grid so both control rows share their columns.
            Grid(alignment: .topLeading, horizontalSpacing: MetroLayout.columnGap, verticalSpacing: MetroLayout.rowGap) {
                GridRow {
                    MetroField("Beats") { MiniStepper(value: s.beats, range: MetronomeSetup.beatsRange, id: "metro-beats") { v in metro.setup.setBeats(v) } }
                    MetroField("Note value") { Pills(options: [4, 8, 16].map { ($0, "\($0)") }, selection: s.noteValue, height: MetroLayout.control) { metro.setup.noteValue = $0 } }
                    MetroField("Pattern") { PatternMenu() }
                }
                GridRow {
                    MetroField("Accents", accessory: { Text("Click a beat to cycle accent, normal, soft, mute").font(Theme.font(11)).foregroundStyle(Theme.faint) }) { AccentCells() }
                        .gridCellColumns(3)
                }
                GridRow {
                    MetroField("Subdivision") { Pills(options: [(1, "None"), (2, "2"), (3, "3"), (4, "4")], selection: s.subdivision, height: MetroLayout.control) { metro.setup.subdivision = $0 } }
                    MetroField("Swing", accessory: { PercentText(value: s.swing) }) {
                        Slider(value: Binding(get: { metro.setup.swing }, set: { metro.setup.swing = $0 }), in: 0...1).tint(Theme.accent).frame(width: 140)
                            .disabled(s.subdivision != 2 && s.subdivision != 4)
                    }
                    MetroField("Count-in") { Pills(options: [(0, "Off"), (1, "1 bar"), (2, "2 bars")], selection: s.countIn, height: MetroLayout.control) { metro.setup.countIn = $0 } }
                }
            }
            // Trainers: switch + name, then the sentence; both rows on the same columns.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    trainerName("Tempo trainer", on: s.rampOn) { metro.setup.rampOn.toggle() }
                    word("to", on: s.rampOn).gridColumnAlignment(.trailing)
                    MiniStepper(value: s.rampTarget, range: MetronomeSetup.rampTargetRange, id: "ramp-target") { metro.setup.rampTarget = $0 }.opacity(dim(s.rampOn))
                    word("BPM, +", on: s.rampOn).gridColumnAlignment(.trailing)
                    MiniStepper(value: s.rampStep, range: MetronomeSetup.rampStepRange, id: "ramp-step") { metro.setup.rampStep = $0 }.opacity(dim(s.rampOn))
                    word("every", on: s.rampOn).gridColumnAlignment(.trailing)
                    MiniStepper(value: s.rampEvery, range: MetronomeSetup.barsRange, id: "ramp-every") { metro.setup.rampEvery = $0 }.opacity(dim(s.rampOn))
                    word(s.rampEvery == 1 ? "bar" : "bars", on: s.rampOn)
                }
                GridRow {
                    trainerName("Gap trainer", on: s.gapOn) { metro.setup.gapOn.toggle() }
                    word("play", on: s.gapOn)
                    MiniStepper(value: s.gapPlay, range: MetronomeSetup.barsRange, id: "gap-play") { metro.setup.gapPlay = $0 }.opacity(dim(s.gapOn))
                    word("mute", on: s.gapOn)
                    MiniStepper(value: s.gapMute, range: MetronomeSetup.barsRange, id: "gap-mute") { metro.setup.gapMute = $0 }.opacity(dim(s.gapOn))
                    word(s.gapMute == 1 ? "bar, repeat" : "bars, repeat", on: s.gapOn).gridCellColumns(3)
                }
            }
            .padding(.top, MetroLayout.sectionGap)
            MetroDivider()
            HStack(alignment: .bottom, spacing: MetroLayout.columnGap) {
                VolumeField(width: 140)
                OutputPicker(width: 210)
                Spacer(minLength: 0)
                Button { metro.levelsOpen.toggle() } label: { Label("Levels…", systemImage: "slider.horizontal.3") }
                    .buttonStyle(ThemedButton()).accessibilityIdentifier("metro-levels")
                    .popover(isPresented: $m.levelsOpen, arrowEdge: .bottom) { LevelsPanel() }
            }
            ErrorLine()
            TransportButtons().frame(maxWidth: .infinity).padding(.top, MetroLayout.sectionGap + 4)
        }
    }
    private func subName(_ n: Int) -> String { ["", "", "eighths", "triplets", "sixteenths"][n] }
    private func dim(_ on: Bool) -> Double { on ? 1 : 0.45 }
    private func trainerName(_ title: String, on: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Switch(on: on, color: Theme.accent, action: toggle)
            Text(title).font(Theme.font(13)).foregroundStyle(on ? Theme.text : Theme.dim).fixedSize()
        }
        .frame(width: 150, height: MetroLayout.control, alignment: .leading)
    }
    private func word(_ t: String, on: Bool) -> some View { Text(t).font(Theme.font(13)).foregroundStyle(Theme.dim).fixedSize().opacity(dim(on)) }
}

/// Beat pips (accent-coloured on the sounding beat, green on beat 1) with smaller sub pips between them.
private struct BeatPips: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        let s = metro.setup
        let subs = s.subdivision
        let groupW = (592 - CGFloat(s.beats - 1) * 6) / CGFloat(s.beats)
        let d = min(14, max(6, (groupW - CGFloat(subs - 1) * 3 - 4) / (1 + 0.45 * CGFloat(subs - 1))))
        let sd = max(4, d * 0.45)
        HStack(spacing: 6) {
            ForEach(0..<s.beats, id: \.self) { b in
                HStack(spacing: 3) {
                    pip(beat: b, sub: 0, size: d, muted: b < s.accents.count && s.accents[b] == .mute)
                    ForEach(1..<max(1, subs), id: \.self) { k in pip(beat: b, sub: k, size: sd, muted: false) }
                }
                .frame(width: groupW, height: 20)
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.05), value: metro.sub)
    }
    private func pip(beat b: Int, sub k: Int, size: CGFloat, muted: Bool) -> some View {
        let lit = metro.running && metro.beat == b && metro.sub == k
        let colour: Color = metro.barKind == .muted ? Theme.label : metro.barKind == .countIn ? Theme.warn : (b == 0 && k == 0 ? Theme.ok : Theme.accent)
        return Circle()
            .fill(lit ? colour : Theme.raisedHi)
            .overlay(Circle().strokeBorder(muted && !lit ? Theme.faint : .clear, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
            .frame(width: size, height: size).scaleEffect(lit ? 1.25 : 1)
    }
}

/// One cell per beat, the overlay's control height; the fill strength shows the level, a click cycles it. A muted cell is
/// empty with a dashed border, like a muted pip.
private struct AccentCells: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        let s = metro.setup
        let w = min(44, (592 - CGFloat(s.beats - 1) * 4) / CGFloat(s.beats))
        HStack(spacing: 4) {
            ForEach(0..<s.beats, id: \.self) { b in
                let level = b < s.accents.count ? s.accents[b] : .normal
                let lit = metro.running && metro.beat == b && metro.barKind == .play
                Button { var a = metro.setup; if b < a.accents.count { a.accents[b] = level.next; metro.setup = a } } label: {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.ws)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.accent.opacity(opacity(level))).padding(2)
                        Text("\(b + 1)").font(Theme.font(12, .semibold)).monospacedDigit()
                            .foregroundStyle(level == .accent ? Theme.onAccent : level == .mute ? Theme.faint : Theme.text)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(width: w, height: MetroLayout.control)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(lit ? Theme.accentHi : level == .mute ? Theme.faint : Theme.line,
                                                                             style: StrokeStyle(lineWidth: 1, dash: level == .mute && !lit ? [2, 2] : [])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(level.rawValue.capitalized).accessibilityIdentifier("beat-cell-\(b)")
            }
        }
    }
    /// Accent full, normal and soft fainter, mute empty (a partial-height fill cut through the beat number at 30 points).
    private func opacity(_ l: MetronomePattern.Level) -> Double { switch l { case .accent: 1; case .normal: 0.45; case .soft: 0.2; case .mute: 0 } }
}

/// The meter presets; the label shows the matching preset or "Custom".
struct PatternMenu: View {
    @Environment(Metronome.self) private var metro
    var body: some View {
        Menu {
            ForEach(MetronomePattern.presets) { p in Button(p.name) { var s = metro.setup; s.apply(p); metro.setup = s } }
            Divider()
            Button("Reset accents") { var s = metro.setup; s.accents = MetronomePattern.defaultAccents(s.beats); metro.setup = s }
        } label: {
            MenuField(title: metro.setup.presetName ?? "Custom", width: 128)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityIdentifier("metro-pattern")
    }
}

/// [−] value [+] in one field the overlay's control height (workspace fill, hairline border). The value is typeable
/// like the big tempo: click it, type, Enter or leaving the field commits (clamped to the range), Esc reverts.
struct MiniStepper: View {
    @Environment(Metronome.self) private var metro
    let value: Int
    let range: ClosedRange<Int>
    var id: String? = nil
    let set: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 0) {
            Button { set(max(range.lowerBound, value - 1)) } label: { Image(systemName: "minus") }.buttonStyle(StepButton()).disabled(value <= range.lowerBound)
            TextField("", text: $text)
                .textFieldStyle(.plain).font(Theme.font(13, .semibold)).monospacedDigit().multilineTextAlignment(.center)
                .frame(width: 36, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(focused ? Theme.panel : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.focus : .clear))
                .focused($focused)
                .onSubmit { commit(); focused = false }
                .onExitCommand { text = "\(value)"; focused = false }
                .onChange(of: focused) { _, f in
                    if f { metro.editingField = id ?? "stepper" } else { commit(); if metro.editingField == (id ?? "stepper") { metro.editingField = nil } }
                }
                .onAppear { text = "\(value)" }
                .onChange(of: value) { _, v in if !focused { text = "\(v)" } }
                .onChange(of: metro.focusRequest) { _, r in if let id, r == id { focused = true; metro.focusRequest = nil } }
                .accessibilityIdentifier(id ?? "")
            Button { set(min(range.upperBound, value + 1)) } label: { Image(systemName: "plus") }.buttonStyle(StepButton()).disabled(value >= range.upperBound)
        }
        .padding(.horizontal, 2).frame(height: MetroLayout.control)
        .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
    }
    private func commit() {
        let v = TypedNumber.commit(text, range: range)
        if let v, v != value { set(v) }
        text = "\(v ?? value)"
    }
}

/// The − / + inside a `MiniStepper`: a 24-point square that lights on hover.
struct StepButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration) }
    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hover && enabled ? Theme.text : Theme.dim)
                .frame(width: 24, height: 24)
                .background(hover && enabled ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// A pill group of options (BarButton style on the workspace colour), `height` tall overall.
struct Pills<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    var height: CGFloat = 36
    let set: (T) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { set(options[i].0) }.buttonStyle(BarButton(selected: selection == options[i].0, height: height - 6))
            }
        }
        .padding(3).background(Theme.ws, in: RoundedRectangle(cornerRadius: height < 36 ? 7 : 9))
    }
}

/// Levels…: accent, main ticks and subdivisions, each 0–100% (persisted; the overall volume is separate).
struct LevelSliders: View {
    @Environment(Metronome.self) private var metro
    var sliderWidth: CGFloat = 150
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Accent", \.accent)
            row("Main ticks", \.main)
            row("Subdivisions", \.sub)
        }
    }
    private func row(_ title: String, _ k: WritableKeyPath<MetronomeLevels, Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.font(13)).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { metro.levels[keyPath: k] }, set: { var l = metro.levels; l[keyPath: k] = $0; metro.levels = l }), in: 0...1).tint(Theme.accent).frame(width: sliderWidth)
            Text("\(Int((metro.levels[keyPath: k] * 100).rounded()))%").font(Theme.font(12)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
        }
        .frame(height: MetroLayout.control)
    }
}

private struct LevelsPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: MetroLayout.labelGap) {
            SectionLabel(text: "Levels")
            LevelSliders()
            Text("Soft beats play at \(Int(MetronomeLevels.softFactor * 100))% of the main level.").font(Theme.font(11)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16).padding(.vertical, 16).background(Theme.panel).foregroundStyle(Theme.text).preferredColorScheme(.dark)
    }
}
