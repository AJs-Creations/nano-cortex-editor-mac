// The eight-node signal chain. Click a node to inspect it; the small switch bypasses it.

import SwiftUI
import NanoCore

extension PedalStore {
    func color(for stage: Stage) -> Color {
        switch stage {
        case .gate: Theme.gate
        case .capture: Theme.capture
        case .cab: Theme.cab
        default: blocks[stage.slot!]?.model.map { Theme.category[$0.category] ?? Theme.none } ?? Theme.none
        }
    }
    func isOn(_ stage: Stage) -> Bool {
        switch stage { case .gate: gateOn; case .capture: captureOn; case .cab: cab.on; default: blocks[stage.slot!]?.on ?? false }
    }
    func hasContent(_ stage: Stage) -> Bool {
        switch stage { case .gate: true; case .capture: captureSlot != nil || !captureName.isEmpty; case .cab: cab.slot > 0 || !cab.name.isEmpty; default: blocks[stage.slot!]?.model != nil }
    }
    /// Main line of a node: what is in it.
    func subtitle(_ stage: Stage) -> String {
        switch stage {
        case .gate: "Noise gate"
        case .capture: captureName.isEmpty ? "No capture" : captureName
        case .cab: cab.name.isEmpty ? "No cab" : cab.name
        default: blocks[stage.slot!]?.model?.name ?? "Empty"
        }
    }
    /// Second line: the detail (reduction, slot, mic, category).
    func detail(_ stage: Stage) -> String {
        switch stage {
        case .gate: gateOn ? "Reduction \(gateReduction)%" : "Bypassed"
        case .capture: captureFromLibrary ? "From the library" : captureSlot.map { "Slot \(PedalStore.slotLabel($0))" } ?? (captureName.isEmpty ? "Pick a capture" : "No slot")
        case .cab: cab.on ? "\(shortMic(cab.mic)), pos \(cab.position)" : (cab.name.isEmpty ? "Pick a cab" : "Bypassed")
        default: blocks[stage.slot!]?.model?.category ?? "Add effect"
        }
    }
    private func shortMic(_ m: String) -> String { m.replacingOccurrences(of: "Dynamic", with: "Dyn").replacingOccurrences(of: "Condenser", with: "Cond").replacingOccurrences(of: "Ribbon", with: "Rib") }
    func toggle(_ stage: Stage) {
        switch stage {
        case .gate: setGate(on: !gateOn)
        case .capture: toggleCapture()
        case .cab: selectCab(slot: cab.on ? 0 : max(1, cab.slot))
        default: if let s = stage.slot, blocks[s]?.model != nil { setFX(s, on: !(blocks[s]?.on ?? false)) }
        }
    }
}

/// `.chain-wrap`: IN ─[node]─[node]─ … ─ OUT on one cable, under a soft radial glow. Scrolls sideways when the
/// eight 104-point nodes, their gaps and the IN/OUT tags (about 1090 points; CSS says min-width 1010 but its grid
/// overflows that the same way) don't fit.
struct ChainView: View {
    static let minRowWidth: CGFloat = 1160   // + the EXP pill
    @Environment(PedalStore.self) private var store
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            row
                .containerRelativeFrame(.horizontal) { len, _ in max(Self.minRowWidth, len - 44) }
                .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.leading)
        .background { ChainGlow().background(Theme.ws) }
    }
    private var row: some View {
        HStack(spacing: 18) {
            ExpPill()   // before IN so it stays visible when the chain scrolls sideways
            HStack(spacing: 12) {
                IOPill("IN")
                HStack(spacing: 22) {
                    ForEach(PedalStore.Stage.allCases, id: \.self) { stage in
                        ChainNode(stage: stage).frame(minWidth: 104, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                IOPill("OUT")
            }
            .background { Cable().padding(.horizontal, 14) }
        }
    }
}

/// `radial-gradient(ellipse at 50% -40%, #262626 0%, transparent 65%)` (farthest-corner ellipse).
private struct ChainGlow: View {
    var body: some View {
        Canvas { ctx, size in
            let rx = 0.5 * size.width * 2.0.squareRoot(), ry = 1.4 * size.height * 2.0.squareRoot()
            ctx.translateBy(x: size.width / 2, y: -0.4 * size.height)
            ctx.scaleBy(x: rx, y: ry)
            ctx.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                     with: .radialGradient(Gradient(stops: [.init(color: Color(hex: 0x262626), location: 0), .init(color: Color(hex: 0x262626, alpha: 0), location: 0.65)]),
                                           center: .zero, startRadius: 0, endRadius: 1))
        }
        .allowsHitTesting(false)
    }
}

/// `.chain-row::before`: the 5-point cable with its shading.
private struct Cable: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(stops: [.init(color: Color(hex: 0x0D0D0D), location: 0), .init(color: Color(hex: 0x3A3A3A), location: 0.45),
                                         .init(color: Color(hex: 0x222222), location: 0.7), .init(color: Color(hex: 0x0D0D0D), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 5)
            .shadow(color: .black.opacity(0.44), radius: 2, y: 2)
    }
}

/// `.io`: tracked IN / OUT tag sitting on the cable.
private struct IOPill: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(Theme.font(10)).tracking(Theme.em(0.12, 10)).foregroundStyle(Theme.label)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.ws, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line)).fixedSize()
    }
}

/// The expression pedal's entry, off the cable before IN: opens the Expression panel in the inspector; shows how many
/// assignments the preset has.
private struct ExpPill: View {
    @Environment(PedalStore.self) private var store
    @State private var hover = false
    var body: some View {
        let open = store.expressionOpen, n = store.expression?.count ?? 0
        Button { store.expressionOpen.toggle() } label: {
            HStack(spacing: 5) {
                Text("EXP").font(Theme.font(10, .semibold)).tracking(Theme.em(0.12, 10)).foregroundStyle(open || hover ? Theme.text : Theme.label)
                if n > 0 {
                    Text("\(n)").font(Theme.font(10, .semibold)).monospacedDigit().foregroundStyle(Theme.onAccent)
                        .frame(minWidth: 14, minHeight: 14).padding(.horizontal, 2).background(Theme.accent, in: Capsule())
                }
            }
            .padding(.horizontal, 8).frame(height: 22)
            .background(open ? Theme.raisedHi : Theme.ws, in: Capsule())
            .overlay(Capsule().strokeBorder(open ? Theme.focus : hover ? Theme.grooveHi : Theme.line))
            .contentShape(Capsule()).fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(n == 0 ? "Expression pedal: no assignments in this preset" : "Expression pedal: \(n) assignment\(n == 1 ? "" : "s")")
        .accessibilityIdentifier("expPill")
    }
}

/// `.node::before/::after`: the 6×12 jack stubs on both sides of a node.
private struct Jack: View {
    let left: Bool
    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: left ? 2 : 0, bottomLeadingRadius: left ? 2 : 0, bottomTrailingRadius: left ? 0 : 2, topTrailingRadius: left ? 0 : 2)
        shape.fill(LinearGradient(colors: [Theme.grooveHi, Theme.groove], startPoint: .leading, endPoint: .trailing))
            .overlay(shape.strokeBorder(Theme.ws))
            .frame(width: 6, height: 12)
    }
}

/// `.stomp`: the LED bypass switch inside a node.
private struct Stomp: View {
    let lit: Bool
    let color: Color
    @State private var hover = false
    var body: some View {
        ZStack {
            Circle().fill(Theme.ws).overlay(Circle().strokeBorder(hover ? Theme.faint : Theme.groove))
            Circle().fill(lit ? color : Theme.groove).frame(width: 8, height: 8)
                .shadow(color: lit ? color : .clear, radius: 4)
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .onHover { hover = $0 }
    }
}

/// `.node`: a stomp box in the chain. Stage label in the stage colour, model on up to two lines, detail at the bottom.
private struct ChainNode: View {
    @Environment(PedalStore.self) private var store
    let stage: PedalStore.Stage
    @State private var hover = false

    var body: some View {
        let on = store.isOn(stage), has = store.hasContent(stage), color = store.color(for: stage), selected = store.selectedStage == stage && !store.expressionOpen
        let off = !on, none = stage.slot != nil && !has
        let shape = RoundedRectangle(cornerRadius: 8)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(stage.title.uppercased()).font(Theme.font(10, .semibold)).tracking(Theme.em(0.1, 10)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button { store.toggle(stage) } label: { Stomp(lit: on && has, color: color) }
                    .buttonStyle(.plain).disabled(!has).help(on ? "Bypass" : "Enable")
            }
            Text(store.subtitle(stage)).font(Theme.font(13, none ? .medium : .semibold)).lineSpacing(3)
                .foregroundStyle(off || none ? Theme.faint : Theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(store.detail(stage)).font(Theme.font(11)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 11)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(LinearGradient(colors: off ? [Color(hex: 0x202020), Color(hex: 0x1B1B1B)] : [Theme.raisedHi, Theme.raised], startPoint: .top, endPoint: .bottom), in: shape)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.top, 1).padding(.horizontal, 6) }   // inset 0 1px 0 #ffffff0d
        .overlay(shape.strokeBorder(selected ? color : hover ? Theme.grooveHi : Theme.line))
        .overlay { if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(color).padding(-1) } }   // 0 0 0 1px var(--c)
        .overlay(alignment: .leading) { Jack(left: true).offset(x: -6) }
        .overlay(alignment: .trailing) { Jack(left: false).offset(x: 6) }
        .shadow(color: .black.opacity(selected ? 0.53 : 0.4), radius: selected ? 10 : 7, y: selected ? 8 : 6)
        .offset(y: selected ? -2 : 0)
        .animation(.easeOut(duration: 0.12), value: selected)
        .animation(.easeOut(duration: 0.12), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.selectedStage = stage; store.expressionOpen = false }
        .help("\(stage.title) (\((PedalStore.Stage.allCases.firstIndex(of: stage) ?? 0) + 1))")
        .contextMenu {
            Button(on ? "Bypass" : "Enable") { store.toggle(stage) }.disabled(!has)
            if let slot = stage.slot {
                Button(has ? "Change effect…" : "Add an effect…") { store.selectedStage = stage; Task { try? await Task.sleep(for: .milliseconds(150)); store.modelPickerOpen = true } }
                Button("Clear slot") { store.setFXModel(slot, nil) }.disabled(!has)
            } else if stage == .capture {
                Button("Pick a capture from the library…") { store.selectedStage = stage; Task { try? await Task.sleep(for: .milliseconds(150)); store.openLibrary(.capture, into: nil) } }
                Button("Info…") { if let slot = store.captureSlot { store.showCaptureInfo(slot: slot, anchor: .node) } }.disabled(store.captureSlot == nil)
            } else if stage == .cab {
                Button("Pick a cab from the library…") { store.selectedStage = stage; Task { try? await Task.sleep(for: .milliseconds(150)); store.openLibrary(.cab, into: nil) } }
            }
        }
        .popover(isPresented: Binding(get: { stage == .capture && store.captureInfoAnchor == .node }, set: { if !$0 { store.captureInfoAnchor = nil } }), arrowEdge: .bottom) {
            CaptureInfoPopover(slot: store.captureSlot ?? 1)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("node-\(stage.rawValue)")
    }
}
