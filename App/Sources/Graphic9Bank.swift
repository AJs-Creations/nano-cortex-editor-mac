// Graphic 9 in the inspector (Electron #31, pro/ui.js `graphic9BandSection`, pro/ui.css `.graphic9-*`): the nine bands
// as vertical faders with their gain above (click to type; Enter applies, Escape cancels) and the band below, a zero
// line and ticks; double-click a fader for 0 dB, arrow keys step 0.1 dB. HPF, LPF and Output are knobs under the bank.
// Writes go through `PedalStore.setFXParam` like any knob, so each carries the band's wire index.

import SwiftUI
import NanoCore

struct Graphic9Bank: View {
    @Environment(PedalStore.self) private var store
    let slot: Slot
    let model: ModelDef
    let block: PedalStore.Block
    let color: Color
    let extras: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: Graphic9.modelName).frame(minHeight: 15, alignment: .leading).padding(.bottom, 10)
            // `.graphic9-surface`: fit to the bank, 12 / 10 / 8 padding, #202020 → #171717, soft line, 8-point corners.
            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(0..<Graphic9.bandCount, id: \.self) { i in
                            Graphic9Band(slot: slot, index: i, param: model.params[i], value: i < block.values.count ? block.values[i] : model.params[i].defaultValue,
                                         locked: !block.on, color: color)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(width: Graphic9Band.bankWidth)
                extras.padding(.top, 8).frame(width: Graphic9Band.bankWidth)
            }
            .padding(.top, 12).padding(.horizontal, 10).padding(.bottom, 8)
            .background(LinearGradient(colors: [Color(hex: 0x202020), Color(hex: 0x171717)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.lineSoft))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("graphic9")
    }
}

/// One band (`.graphic9-band`): readout, fader, frequency; rows 16 / 264 / 16 points, 7 apart, 44 wide.
private struct Graphic9Band: View {
    @Environment(PedalStore.self) private var store
    let slot: Slot
    let index: Int
    let param: ParamDef
    let value: Double
    let locked: Bool
    let color: Color

    static let width: CGFloat = 44, faderHeight: CGFloat = 264, thumbLength: CGFloat = 24, thumbWidth: CGFloat = 10
    static let bankWidth = width * CGFloat(Graphic9.bandCount) + 2 * CGFloat(Graphic9.bandCount - 1)

    @State private var editing = false
    @State private var text = ""
    @State private var hoverValue = false
    @State private var dragOffset: CGFloat?        // thumb centre minus the press point, while dragging
    @State private var lastPress = Date.distantPast
    @State private var dragChanged = false
    @FocusState private var textFocused: Bool
    @FocusState private var faderFocused: Bool

    private var label: String { Graphic9.label(param.name) }

    var body: some View {
        VStack(spacing: 7) {
            readout.frame(height: 16)
            fader
            Text(label).font(Theme.font(10)).foregroundStyle(Theme.dim).lineLimit(1).fixedSize().frame(height: 16)
        }
        .frame(width: Self.width)
        .opacity(locked ? 0.38 : 1)
        .help(label + " · " + Fmt.unit(value, unit: "dB", decimals: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + " gain")
        .accessibilityValue(Fmt.unit(value, unit: "dB", decimals: 1))
        .accessibilityIdentifier("g9-band-\(index)")
        .accessibilityAdjustableAction { dir in step(dir == .increment ? 1 : -1) }
    }

    // `.graphic9-value` / `.graphic9-value-input`: 44 × 18, 10-point tabular text; the field takes the readout's place.
    @ViewBuilder private var readout: some View {
        if editing {
            TextField("", text: $text)
                .textFieldStyle(.plain).font(Theme.font(10)).monospacedDigit().multilineTextAlignment(.center)
                .frame(width: Self.width - 6, height: 16).padding(.horizontal, 2)
                .background(Theme.ws, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.focus))
                .focused($textFocused)
                .onSubmit { finish(apply: true) }
                .onExitCommand { finish(apply: false) }
                .onChange(of: textFocused) { _, f in if !f, editing { finish(apply: true) } }
                .onAppear { textFocused = true }
                .accessibilityIdentifier("g9-input-\(index)")
        } else {
            Text(Graphic9.readout(value)).font(Theme.font(10)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1)
                .frame(width: Self.width - 4, height: 16).padding(.horizontal, 2)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(hoverValue && !locked ? Theme.line : .clear))
                .contentShape(Rectangle())
                .onHover { hoverValue = $0 }
                .onTapGesture { guard !locked else { return }; text = String(format: "%.1f", value + 0); editing = true }
                .help("Click to type this band gain")
        }
    }
    private func finish(apply: Bool) {
        guard editing else { return }
        editing = false
        if apply, let v = Graphic9.typed(text, meta: param.meta) { set(v, commit: true) }
    }

    // `.graphic9-fader`: ticks every 11 points (5 in from both ends, .7), the zero line (#ABABAB, .8), a 4-point groove
    // (#3B3B3B, #555 edge) and a 10 × 24 thumb in the slot's colour.
    private var fader: some View {
        let h = Self.faderHeight, thumbY = Graphic9.y(of: value, length: h, thumb: Self.thumbLength, meta: param.meta)
        return ZStack(alignment: .top) {
            Canvas { ctx, size in
                var y = size.height - 5 - 11
                while y >= 5 {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Theme.line.opacity(0.7)))
                    y -= 11
                }
                ctx.fill(Path(CGRect(x: 0, y: size.height / 2, width: size.width, height: 1)), with: .color(Theme.dim.opacity(0.8)))
            }
            RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x3B3B3B))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(hex: 0x555555)))
                .frame(width: 6, height: h)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(stops: [.init(color: Color(hex: 0xF0EAF1), location: 0), .init(color: color, location: 0.55), .init(color: Color(hex: 0x806D84), location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(faderFocused ? Theme.focus : Color(hex: 0x171717), lineWidth: faderFocused ? 2 : 1))
                .frame(width: Self.thumbWidth, height: Self.thumbLength)
                .shadow(color: .black.opacity(0.67), radius: 2, x: 2, y: 0)
                .offset(y: thumbY - Self.thumbLength / 2)
        }
        .frame(width: Self.width, height: h)
        .contentShape(Rectangle())
        .gesture(locked ? nil : DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragOffset == nil {
                    // A press on the thumb keeps its offset; one beside it jumps there, as an HTML range input does.
                    let onThumb = abs(g.startLocation.y - thumbY) <= Self.thumbLength / 2
                    dragOffset = onThumb ? thumbY - g.startLocation.y : 0
                    dragChanged = false
                    NSCursor.resizeUpDown.push()
                }
                if set(Graphic9.value(atY: g.location.y + (dragOffset ?? 0), length: h, thumb: Self.thumbLength, meta: param.meta), commit: false) { dragChanged = true }
            }
            .onEnded { g in
                NSCursor.pop()
                dragOffset = nil
                let now = Date(), still = abs(g.translation.height) < 2 && abs(g.translation.width) < 2
                if still, now.timeIntervalSince(lastPress) < 0.5 { lastPress = .distantPast; set(0, commit: true); return }   // double-click: 0 dB
                lastPress = still ? now : .distantPast
                if dragChanged { store.setFXParam(slot, index: index, value: value, commit: true) }   // the gesture ends (live sync's hold)
            })
        .focusable(!locked)
        .focusEffectDisabled()
        .focused($faderFocused)
        .onKeyPress(.upArrow) { step(1); return .handled }
        .onKeyPress(.downArrow) { step(-1); return .handled }
        .help(locked ? "" : label + " band · drag or use arrow keys to adjust; double-click to reset to 0 dB")
    }

    private func step(_ dir: Double) {
        guard !locked else { return }
        set(value + dir * Graphic9.range(param.meta).step, commit: true)
    }
    /// Snapped to the band's range and step; nothing is sent when it doesn't change (`setBandValue`).
    @discardableResult
    private func set(_ v: Double, commit: Bool) -> Bool {
        let next = Graphic9.snap(v, meta: param.meta)
        guard next != value else { return false }
        store.setFXParam(slot, index: index, value: next, commit: commit)
        return true
    }
}
