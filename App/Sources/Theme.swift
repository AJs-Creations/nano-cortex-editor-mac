// Cortex Control's design language, as in the Electron app: near-black surfaces,
// #2E2E2E lines, white/#ABABAB/#959595 type, purple actions, Quad Cortex category
// colours for effect blocks, IBM Plex Sans.

import SwiftUI
import CoreText
import AppKit
import NanoCore

enum Theme {
    static let ws = Color(hex: 0x121212)
    static let panel = Color(hex: 0x181818)
    static let raised = Color(hex: 0x252525)
    static let raisedHi = Color(hex: 0x2E2E2E)
    static let line = Color(hex: 0x2E2E2E)
    static let lineSoft = Color(hex: 0x232323)
    static let text = Color.white
    static let dim = Color(hex: 0xABABAB)
    static let label = Color(hex: 0x959595)
    static let faint = Color(hex: 0x616161)
    // The accent family follows Settings → Appearance (AppSettings.accent; purple by default). Views that read these
    // during `body` re-render when the accent changes, because AppSettings is @Observable.
    @MainActor static var accent: Color { AppSettings.shared.accent.color }
    @MainActor static var accentHi: Color { AppSettings.shared.accent.hi.color }
    /// Text on an accent fill (near-black on the bright accents).
    @MainActor static var onAccent: Color { AppSettings.shared.accent.onAccent }
    static let ok = Color(hex: 0x45F862)
    static let warn = Color(hex: 0xFF7000)
    static let danger = Color(hex: 0xE44A5D)

    static let gate = Color(hex: 0x959595)
    static let capture = Color(hex: 0xE44A5D)
    static let cab = Color(hex: 0xFF7000)
    /// Quad Cortex category palette (upstream FX_COLORS), with the two hues that are too dark lifted, and Reverb soft pink
    /// (upstream gives it Delay's #00FFDD, so a delay next to a reverb looked the same). Electron: `READABLE` in pro/ui.js.
    static let category: [String: Color] = [
        "Overdrive": Color(hex: 0xFF7000), "Compressor": Color(hex: 0x45F862), "Utility/EQ": Color(hex: 0x4A9EFF),
        "Wah/Filter": Color(hex: 0x87DAFF), "Modulation": Color(hex: 0x8F78FF), "Delay": Color(hex: 0x00FFDD),
        "Reverb": Color(hex: 0xF570D6), "Pitch": Color(hex: 0xFFD236), "Utility": Color.white,
    ]
    static let none = Color(hex: 0x5C5C5C)

    // Literal values from pro/ui.css that have no variable there.
    static let groove = Color(hex: 0x373737)      // knob arc track, switch track, LED off, stomp ring
    static let grooveHi = Color(hex: 0x525252)    // node hover border, jack highlight
    @MainActor static var activeRow: Color { AppSettings.shared.accent.activeRow.color }   // .preset-row.active (#2A2456)
    @MainActor static var activeNum: Color { AppSettings.shared.accent.activeNum.color }   // .preset-row.active .n (#B9AFFF)
    @MainActor static var focus: Color { AppSettings.shared.accent.focus.color }           // #9D8DFF
    static let pop = Color(hex: 0x262A31)         // .pop, .ctx
    static let popHi = Color(hex: 0x33405A)       // .pop-item.hl
    static let tabBar = Color(hex: 0x0E0E0E)      // src/toolbar.html
    static let drawer = Color(hex: 0x0F0F0F)
    static let drawerText = Color(hex: 0xAEB5C0)
    @MainActor static var tx: Color { AppSettings.shared.accent.tx.color }                 // #A89BFF

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        // PostScript names inside the bundled TTFs (not the file names): a wrong one silently falls back to SF.
        switch weight { case .medium: name = "IBMPlexSans-Medm"; case .semibold: name = "IBMPlexSans-SmBld"; case .bold: name = "IBMPlexSans-Bold"; default: name = "IBMPlexSans" }
        return .custom(name, size: size)
    }
    static func mono(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
    /// CSS letter-spacing in em → points.
    static func em(_ e: CGFloat, _ size: CGFloat) -> CGFloat { e * size }

    /// Registers the bundled Plex files once (works whatever folder XcodeGen flattened them into).
    static func registerFonts() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []) + (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// Tracked uppercase section label, as in Cortex Control.
struct SectionLabel: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(Theme.font(11, .semibold)).tracking(Theme.em(0.12, 11)).foregroundStyle(Theme.label) }
}

/// `.btn` (30 tall, 13 side padding, radius 5), `.btn.primary`, `.btn.ghost`, `.btn.small`.
struct ThemedButton: ButtonStyle {
    enum Kind { case normal, primary, ghost }
    var kind: Kind = .normal
    var small = false
    var large = false   // `.veil-card .row .btn`: 34 tall, 16 side padding
    func makeBody(configuration: Configuration) -> some View {
        Styled(kind: kind, small: small, large: large, configuration: configuration)
    }
    private struct Styled: View {
        let kind: Kind
        let small: Bool
        let large: Bool
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let h = hover && enabled
            configuration.label
                .lineLimit(1).fixedSize()
                .font(Theme.font(small ? 12 : 13, kind == .primary ? .semibold : .regular))
                .padding(.horizontal, small ? 9 : large ? 16 : 13).frame(height: small ? 24 : large ? 34 : 30)
                .background(background(h), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(kind == .normal ? Theme.line : .clear))
                .foregroundStyle(kind == .primary ? Theme.onAccent : kind == .ghost && !h ? Theme.dim : Theme.text)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
        private func background(_ h: Bool) -> Color {
            switch kind {
            case .primary: h ? Theme.accentHi : Theme.accent
            case .normal: h ? Theme.raisedHi : Theme.raised
            case .ghost: h ? Theme.raised : .clear
            }
        }
    }
}

/// `.switch`: 32×18 track (#373737, the stage colour when on) with a 14-point knob (#cdcdcd, white when on).
struct Switch: View {
    let on: Bool
    let color: Color
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? color : Theme.groove).frame(width: 32, height: 18)
                Circle().fill(on ? Color.white : Color(hex: 0xCDCDCD)).frame(width: 14, height: 14).padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: on)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
}

/// `.search`: 28 tall, 9 side padding, workspace background, faint placeholder.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var accent = false
    var onSubmit: () -> Void = {}
    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.faint)).textFieldStyle(.plain).font(Theme.font(13))
                .onSubmit(onSubmit)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
        }
        .padding(.horizontal, 9).frame(height: 28)
        .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent ? Theme.focus : Theme.line))
    }
}

/// `.modal` contents: 16-point title, dim 13-point body, buttons right-aligned with 8-point gaps.
struct ModalTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(Theme.font(16, .bold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true) }
}
struct ModalText: View {
    let text: String
    var color: Color = Theme.dim
    init(_ t: String, color: Color = Theme.dim) { text = t; self.color = color }
    var body: some View { Text(text).font(Theme.font(13)).foregroundStyle(color).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
}
extension View {
    /// `.modal`: panel background, 22-point padding.
    func modalPanel(width: CGFloat = 400) -> some View {
        padding(22).frame(width: width, alignment: .leading).background(Theme.panel).foregroundStyle(Theme.text)
    }
}

extension Links {
    /// Opens a link in the default browser, never in the app's web view.
    @MainActor static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// A quiet text link (`.link` in pro/ui.css): dim, white on hover, no accent. Opens the browser via `Links.open`.
struct LinkStyle: ButtonStyle {
    var size: CGFloat = 13
    func makeBody(configuration: Configuration) -> some View { Styled(size: size, configuration: configuration) }
    private struct Styled: View {
        let size: CGFloat
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label.font(Theme.font(size)).foregroundStyle(hover ? Theme.text : Theme.dim).underline(hover)
                .contentShape(Rectangle()).onHover { hover = $0 }
        }
    }
}
