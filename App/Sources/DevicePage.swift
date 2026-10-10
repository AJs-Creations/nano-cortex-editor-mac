// Settings → Device: About (name, firmware, serial; hash with Developer tools) and the two confirmed global settings
// (LED brightness, USB playback volume), plus (Developer tools) a read-only line of the raw settings reply. And the capture "Info…" popover.
// Protocol: PROTOCOL-NOTES §13 (decoded from the phone app's trace of 2026-10-09).

import SwiftUI
import AppKit
import NanoCore

struct DeviceSection: View {
    @Environment(PedalStore.self) private var store
    @State private var rawOpen = false

    private var ready: Bool { store.connected && store.deviceSettings != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "About")
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                about("Name", store.deviceSettings?.name ?? store.deviceInfo?.name)
                about("Firmware", firmware)
                about("Serial", store.deviceInfo?.serial, mono: true)
                if AppSettings.shared.devTools {   // Developer tools only
                    about("Hash", store.deviceInfo?.hash.map(Self.short), mono: true, help: "\(store.deviceInfo?.hash ?? "")\nThe pedal sends a different value on every read.")
                }
            }
            Divider().overlay(Theme.line)
            row("LED brightness", detail: "The pedal's LEDs. The manual's default is 60%.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(DeviceSettings.brightnessPercent(store.ledBrightness)) },
                                          set: { store.setDeviceSettings(brightness: DeviceSettings.brightnessRaw(percent: Int($0.rounded()))) }),
                           in: 0...100).tint(Theme.accent).frame(width: 170).accessibilityIdentifier("device-brightness")
                    Text("\(DeviceSettings.brightnessPercent(store.ledBrightness))%").font(Theme.font(12)).monospacedDigit().foregroundStyle(Theme.dim).padding(.horizontal, 7).frame(width: 64, alignment: .trailing)
                }
            }
            row("USB playback volume", detail: "Audio from the computer over USB. Default −6.0 dB.") {
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { store.usbVolumeDb }, set: { store.setDeviceSettings(usbVolumeDb: $0) }), in: -20...0)
                        .tint(Theme.accent).frame(width: 170).accessibilityIdentifier("device-usb")
                    DbField(value: store.usbVolumeDb) { store.setDeviceSettings(usbVolumeDb: $0) }
                }
            }
            Divider().overlay(Theme.line)
            if AppSettings.shared.devTools { raw }   // Developer tools only
            HStack(spacing: 10) {
                Text(status).font(Theme.font(12)).foregroundStyle(store.deviceError != nil ? Theme.warn : Theme.faint).lineLimit(2)
                Spacer()
                Button(store.deviceReading ? "Reading…" : "Read again") { Task { await store.readDevice() } }
                    .buttonStyle(ThemedButton(small: true)).disabled(!store.connected || store.deviceReading).accessibilityIdentifier("device-read")
            }
        }
        .onAppear { if store.connected { Task { await store.readDevice() } } }
        .onChange(of: store.connected) { _, c in if c { Task { await store.readDevice() } } }
    }

    /// The raw settings reply, collapsed (Developer tools only).
    private var raw: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { rawOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(rawOpen ? 90 : 0))
                    Text("Raw settings").font(Theme.font(12))
                }
                .foregroundStyle(Theme.dim).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("device-raw")
            if rawOpen {
                Text(rawLine).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Field: value from the settings reply (type 66). The others are not decoded yet, so they are read-only here.").font(Theme.font(11)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var firmware: String? {
        guard let f = store.deviceInfo?.firmware ?? store.state?.firmware else { return nil }
        if let b = store.deviceInfo?.firmwareBuild, b.hasPrefix(f) { return b }   // "2.2.1+06d34443"
        return f
    }
    private var status: String {
        if !store.connected { return "Not connected. Connect to the pedal to read and change these." }
        if let e = store.deviceError { return e }
        if store.deviceReading { return "Reading from the pedal…" }
        return store.deviceSettings == nil ? "Not read yet." : "Global settings: they apply on the pedal right away, not per preset."
    }
    private var rawLine: String {
        guard let s = store.deviceSettings else { return "—" }
        return s.raw.map { "\($0.field): \($0.value)" }.joined(separator: " · ")
    }
    static func short(_ hash: String) -> String { hash.count > 16 ? "\(hash.prefix(8))…\(hash.suffix(6))" : hash }

    @ViewBuilder private func about(_ title: String, _ value: String?, mono: Bool = false, help: String? = nil) -> some View {
        GridRow {
            Text(title).font(Theme.font(13)).foregroundStyle(Theme.dim)
            Text(value ?? "—").font(mono ? Theme.mono(12) : Theme.font(13)).foregroundStyle(value == nil ? Theme.faint : Theme.text)
                .textSelection(.enabled).lineLimit(1).help(help ?? "")
        }
    }
    private func row<C: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13))
                if let detail { Text(detail).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control().disabled(!ready).opacity(ready ? 1 : 0.5)
        }
    }
}

/// A typeable dB value (`−6.0 dB`): click, type, Enter or leaving commits (the store clamps to −20…0 in 0.5 steps), Esc reverts.
private struct DbField: View {
    let value: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain).font(Theme.font(12)).monospacedDigit().multilineTextAlignment(.trailing)
            .padding(.horizontal, 6).frame(width: 64, height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(focused ? Theme.ws : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.focus : Theme.line))
            .foregroundStyle(Theme.dim)
            .focused($focused)
            .onSubmit { commit(); focused = false }
            .onExitCommand { text = Self.format(value); focused = false }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
            .accessibilityIdentifier("device-usb-field")
    }
    static func format(_ v: Double) -> String { String(format: "%.1f dB", v).replacingOccurrences(of: "-", with: "−") }
    private func commit() {
        let cleaned = text.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned), abs(v - value) > 0.001 { set(v) }
        text = Self.format(value)
    }
}

// MARK: - capture info

/// The popover behind "Info…" on a capture: name, author, device type and instrument, tags, description, hash.
struct CaptureInfoPopover: View {
    @Environment(PedalStore.self) private var store
    let slot: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(text: "Capture \(PedalStore.slotLabel(slot))")
                Spacer()
            }
            if let d = store.captureInfo {
                Text(d.name).font(Theme.font(16, .semibold)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("captureInfo-name")
                if !d.author.isEmpty { Text("by \(d.author)").font(Theme.font(12)).foregroundStyle(Theme.dim) }
                let kinds = [d.deviceType, d.instrument].filter { !["", "default", "instrument_not_set"].contains($0) }
                if !kinds.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(kinds, id: \.self) { w in
                            HStack(spacing: 5) {
                                if let icon = CaptureKind.icons(type: w == d.deviceType ? w : "", instrument: w == d.instrument ? w : "").first { KindIcon(icon: icon).foregroundStyle(Theme.dim) }
                                Text(Self.label(w)).font(Theme.font(12)).foregroundStyle(Theme.dim)
                            }
                        }
                    }
                }
                if !d.tags.isEmpty { Chips(tags: d.tags) }
                if !d.description.isEmpty { Text(d.description).font(Theme.font(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true) }
                if AppSettings.shared.devTools {   // Developer tools only
                    Divider().overlay(Theme.line)
                    HStack(spacing: 6) {
                        Text("Hash").font(Theme.font(11)).foregroundStyle(Theme.faint)
                        Text(DeviceSection.short(d.hash)).font(Theme.mono(11)).foregroundStyle(Theme.dim).textSelection(.enabled).help(d.hash)
                        Spacer()
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.hash, forType: .string) }.buttonStyle(ThemedButton(kind: .ghost, small: true))
                    }
                }
            } else if let e = store.captureInfoError {
                Text(e).font(Theme.font(13)).foregroundStyle(Theme.faint)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Asking the pedal…").font(Theme.font(13)).foregroundStyle(Theme.faint) }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(Theme.pop).foregroundStyle(Theme.text)
        .presentationBackground(Theme.pop)
    }
    /// "amp_head" → "Amp head" (the icon table's label when it has one).
    static func label(_ word: String) -> String {
        if let i = CaptureKind.icons(type: word, instrument: "").first ?? CaptureKind.icons(type: "", instrument: word).first { return i.label }
        let s = word.replacingOccurrences(of: "_", with: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

/// Tags as small rounded chips, wrapping.
private struct Chips: View {
    let tags: [String]
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                Text(t).font(Theme.font(11)).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            }
        }
    }
}

/// Left-to-right wrapping layout.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += line + spacing; line = 0 }
            x += sz.width + spacing; line = max(line, sz.height)
        }
        return CGSize(width: width, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; line = max(line, sz.height)
        }
    }
}
