// The knob: drag up/down (Shift = fine), double-click resets, arrow keys when
// focused, click the value to type one. Writes `live` while dragging and
// `commit` on release, like the Electron app.

import SwiftUI

struct Knob: View {
    let label: String
    let color: Color
    var min: Double = 0, max: Double = 1, step: Double = 0.01
    var defaultValue: Double? = nil
    var logScale = false
    var locked = false
    let value: Double
    let format: (Double) -> String
    var parse: ((String) -> Double?)? = nil
    let live: (Double) -> Void
    let commit: (Double) -> Void

    @State private var dragStart: (y: CGFloat, norm: Double)? = nil
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    private var norm: Double { toNorm(value) }
    private func toNorm(_ v: Double) -> Double {
        let c = Swift.max(min, Swift.min(max, v))
        if logScale, min > 0 { return (log(c) - log(min)) / (log(max) - log(min)) }
        return (c - min) / (max - min)
    }
    private func fromNorm(_ n: Double) -> Double {
        let c = Swift.max(0, Swift.min(1, n))
        let raw = logScale && min > 0 ? exp(log(min) + c * (log(max) - log(min))) : min + c * (max - min)
        return step > 0 ? (raw / step).rounded() * step : raw
    }

    @State private var hoverValue = false

    /// pro/ui.js knobControl: 54-point dial, arc radius 21 at 4 points on a #373737 track, starting at 0 for
    /// ranges that cross it; 15-point cap with a radial gradient; pointer from 5 to 12.5 points.
    var body: some View {
        VStack(spacing: 4) {
            Text(label).font(Theme.font(12)).foregroundStyle(Theme.dim).lineLimit(2).lineSpacing(0).multilineTextAlignment(.center).frame(minHeight: 15)
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2), r = 21.0
                let a0 = 135.0, sweep = 270.0
                let zero = min < 0 && max > 0 ? toNorm(0) : 0
                var track = Path(); track.addArc(center: c, radius: r, startAngle: .degrees(a0), endAngle: .degrees(a0 + sweep), clockwise: false)
                ctx.stroke(track, with: .color(Theme.groove), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                let from = a0 + sweep * Swift.min(zero, norm), to = a0 + sweep * Swift.max(zero, norm)
                if to - from > 0.01 {
                    var arc = Path(); arc.addArc(center: c, radius: r, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                    ctx.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                let cap = 15.0, capRect = CGRect(x: c.x - cap, y: c.y - cap, width: cap * 2, height: cap * 2)
                // radialGradient cx 40% cy 32% r 75% of the cap's box
                ctx.fill(Path(ellipseIn: capRect), with: .radialGradient(Gradient(colors: [Color(hex: 0x3D3D3D), Color(hex: 0x1C1C1C)]),
                                                                         center: CGPoint(x: capRect.minX + capRect.width * 0.4, y: capRect.minY + capRect.height * 0.32), startRadius: 0, endRadius: capRect.width * 0.75))
                ctx.stroke(Path(ellipseIn: capRect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.ws), lineWidth: 1)
                let a = (a0 + sweep * norm) * .pi / 180
                var ptr = Path(); ptr.move(to: CGPoint(x: c.x + cos(a) * 5, y: c.y + sin(a) * 5)); ptr.addLine(to: CGPoint(x: c.x + cos(a) * 12.5, y: c.y + sin(a) * 12.5))
                ctx.stroke(ptr, with: .color(Color(hex: 0xF3F5F8)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            .frame(width: 54, height: 54)
            .contentShape(Rectangle())
            .gesture(locked ? nil : DragGesture(minimumDistance: 1).onChanged { g in
                if dragStart == nil { dragStart = (g.startLocation.y, norm) }
                let fine = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
                let n = dragStart!.norm + Double(dragStart!.y - g.location.y) / (160 * fine)
                live(fromNorm(n))
            }.onEnded { _ in dragStart = nil; commit(value) })
            .onTapGesture(count: 2) { if let d = defaultValue, !locked { commit(d) } }
            .focusable(!locked)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.upArrow) { nudge(+1); return .handled }
            .onKeyPress(.downArrow) { nudge(-1); return .handled }
            if editing {
                TextField("", text: $text, onCommit: { if let v = (parse ?? { Double($0) })(text) { commit(Swift.max(min, Swift.min(max, v))) }; editing = false })
                    .textFieldStyle(.plain).font(Theme.font(12)).multilineTextAlignment(.center).frame(width: 62).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.ws, in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.focus))
                    .onExitCommand { editing = false }
            } else {
                Text(format(value)).font(Theme.font(12)).monospacedDigit().foregroundStyle(Theme.text).lineLimit(1).frame(minWidth: 52)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hoverValue && !locked ? Theme.line : .clear))
                    .contentShape(Rectangle())
                    .onHover { hoverValue = $0 }
                    .onTapGesture { if !locked { text = format(value); editing = true } }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 6)
        .frame(minWidth: 92, maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.focus : .clear, lineWidth: 2))
        .opacity(locked ? 0.38 : 1)
        .help(locked ? "" : "Drag to adjust. Shift for fine control. Double-click to reset.")
    }

    private func nudge(_ dir: Double) {
        let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1.0
        commit(Swift.max(min, Swift.min(max, value + dir * Swift.max(step, (max - min) / 100) * fine)))
    }
}
