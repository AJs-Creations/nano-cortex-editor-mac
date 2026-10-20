// App settings (⌘,): accent colour (and the Dock icon / header mark recoloured to it),
// metronome defaults and sound, connection at launch, Developer tools and the Activity log options.
// Everything lives in UserDefaults; an untouched install looks and behaves as before
// (blue accent — the Electron app keeps purple so the two Dock icons differ, DECISION #14 — and the
// remembered metronome output and volume carried over).

import SwiftUI
import AppKit
import CoreAudio

/// The Cortex Control palette, plus blue. Purple is the app's original accent.
enum Accent: String, CaseIterable, Identifiable {
    case purple, teal, green, orange, yellow, red, blue
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .purple: 0x6954FF
        case .teal: 0x00FFDD
        case .green: 0x45F862
        case .orange: 0xFF7000
        case .yellow: 0xFFD236
        case .red: 0xE44A5D
        case .blue: 0x4A9EFF
        }
    }
    var rgb: RGB { RGB(hex: hex) }
    var color: Color { rgb.color }
    /// Hover/highlight: ~8% lighter (mixing 12% white reproduces the original #7B68FF from #6954FF exactly).
    var hi: RGB { self == .purple ? RGB(hex: 0x7B68FF) : rgb.mix(.white, 0.12) }
    /// `.preset-row.active` background: the accent at ~28% over the workspace (#2A2456 for purple).
    var activeRow: RGB { self == .purple ? RGB(hex: 0x2A2456) : RGB(hex: 0x121212).mix(rgb, 0.28) }
    /// `.preset-row.active .n` (#B9AFFF for purple).
    var activeNum: RGB { self == .purple ? RGB(hex: 0xB9AFFF) : rgb.mix(.white, 0.53) }
    /// Focus rings (#9D8DFF for purple).
    var focus: RGB { self == .purple ? RGB(hex: 0x9D8DFF) : rgb.mix(.white, 0.34) }
    /// TX lines in the Activity drawer (#A89BFF for purple).
    var tx: RGB { self == .purple ? RGB(hex: 0xA89BFF) : rgb.mix(.white, 0.42) }
    /// Text on an accent fill: white, or near-black on the bright accents (teal, green, yellow).
    var onAccent: Color { rgb.luminance > 0.5 ? Color(hex: 0x121212) : .white }
    /// The icon's LED ring gradient (dark, mid, light). Blue keeps the asset icon's own stops.
    var ledStops: (String, String, String) {
        if self == .blue { return ("#2f6fc4", "#4a9eff", "#9ccaff") }
        return (rgb.mix(.black, 0.28).css, rgb.css, rgb.mix(.white, 0.35).css)
    }
}

struct RGB: Equatable {
    var r, g, b: Double   // 0…1, sRGB
    static let white = RGB(r: 1, g: 1, b: 1), black = RGB(r: 0, g: 0, b: 0)
    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) { r = Double((hex >> 16) & 0xff) / 255; g = Double((hex >> 8) & 0xff) / 255; b = Double(hex & 0xff) / 255 }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t) }
    var hex: UInt32 { (UInt32((r * 255).rounded()) << 16) | (UInt32((g * 255).rounded()) << 8) | UInt32((b * 255).rounded()) }
    var css: String { String(format: "#%06x", hex) }
    var color: Color { Color(hex: hex) }
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
}

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()
    enum Key {
        static let accent = "ui.accent", dockIcon = "ui.dockIconFollowsAccent", showLog = "ui.showLogAtLaunch"
        static let connectAtLaunch = "connect.atLaunch"
        static let pedalIdentifier = "pedal.identifier", pedalName = "pedal.name"   // written once a pedal is ready (DefaultsPedalMemory, PedalLink.swift)
        static let metroVolume = "metro.volume", metroOutput = "metro.output", metroSound = "metro.sound"
        static let metroBPM = "metro.defaultBPM", metroBeats = "metro.defaultBeats"
        static let legacyBPM = "metro.bpm", legacyBeats = "metro.beats"   // the metronome's last tempo before settings existed
        static let metroOpensIn = "metro.opensIn", metroSetup = "metro.setup", metroFollowsPreset = "metro.followsPreset"
        static let metroLevelAccent = "metro.levelAccent", metroLevelMain = "metro.levelMain", metroLevelSub = "metro.levelSub"
    }
    enum Section: String, CaseIterable { case appearance, metronome, connection, device, advanced, about
        var title: String { rawValue.capitalized }
    }

    private let d = UserDefaults.standard
    // No clamping or re-assignment inside didSet (with @Observable that re-enters the setter); clamp at the call site.
    var accent: Accent { didSet { if oldValue != accent { d.set(accent.rawValue, forKey: Key.accent); AppIcon.apply() } } }
    var dockIconFollowsAccent: Bool { didSet { if oldValue != dockIconFollowsAccent { d.set(dockIconFollowsAccent, forKey: Key.dockIcon); AppIcon.apply() } } }
    var metroVolume: Double { didSet { d.set(metroVolume, forKey: Key.metroVolume) } }
    var metroOutput: AudioDeviceID { didSet { d.set(Int(metroOutput), forKey: Key.metroOutput) } }
    var metroSound: ClickSound { didSet { d.set(metroSound.rawValue, forKey: Key.metroSound) } }
    var metroDefaultBPM: Int { didSet { d.set(metroDefaultBPM, forKey: Key.metroBPM) } }
    var metroDefaultBeats: Int { didSet { d.set(metroDefaultBeats, forKey: Key.metroBeats) } }
    /// Which mode the metronome overlay starts in each launch.
    var metroOpensIn: MetronomeMode { didSet { d.set(metroOpensIn.rawValue, forKey: Key.metroOpensIn) } }
    /// The last-used Advanced setup (pattern, subdivision, count-in, trainers). Settings edits the same one.
    var metroSetup: MetronomeSetup { didSet { if oldValue != metroSetup, let data = try? JSONEncoder().encode(metroSetup) { d.set(data, forKey: Key.metroSetup) } } }
    /// Levels…: accent, main ticks, subdivisions (0…1 each). Defaults reproduce the original accent/click mix.
    var metroLevels: MetronomeLevels {
        didSet { d.set(metroLevels.accent, forKey: Key.metroLevelAccent); d.set(metroLevels.main, forKey: Key.metroLevelMain); d.set(metroLevels.sub, forKey: Key.metroLevelSub) }
    }
    /// The metronome follows (and writes) the connected pedal's preset tempo. Off by default (DECISION #17).
    var metroFollowsPreset: Bool { didSet { d.set(metroFollowsPreset, forKey: Key.metroFollowsPreset) } }
    var connectAtLaunch: Bool { didSet { d.set(connectAtLaunch, forKey: Key.connectAtLaunch) } }
    var showLogAtLaunch: Bool { didSet { d.set(showLogAtLaunch, forKey: Key.showLog) } }
    /// Settings → Advanced → Developer tools: Record, Activity, ⌘L, raw device fields, hashes. Off by default (DECISION #21).
    var devTools: Bool { didSet { if oldValue != devTools { d.set(devTools, forKey: DevTools.key); onDevToolsChanged?(devTools) } } }
    /// The store stops a recording and closes the Activity drawer when Developer tools turn off.
    var onDevToolsChanged: ((Bool) -> Void)?
    /// Not persisted: which settings section is showing, the remembered pedal as last read, the dev-remote port.
    var section: Section = .appearance
    private(set) var rememberedPedal: String?
    private(set) var hasRememberedPedal = false
    var devRemotePort: Int?
    /// SwiftUI's openSettings action, captured from the main window so the dev remote can open the window.
    var openSettings: (() -> Void)?

    private init() {
        let d = UserDefaults.standard
        let lv = MetronomeLevels()
        d.register(defaults: [Key.dockIcon: true, Key.connectAtLaunch: true, Key.showLog: false, Key.metroVolume: 0.6,
                              Key.metroLevelAccent: lv.accent, Key.metroLevelMain: lv.main, Key.metroLevelSub: lv.sub])
        accent = d.string(forKey: Key.accent).flatMap(Accent.init(rawValue:)) ?? .blue   // DECISION #14: blue here, purple in Electron
        dockIconFollowsAccent = d.bool(forKey: Key.dockIcon)
        metroVolume = d.double(forKey: Key.metroVolume)
        metroOutput = AudioDeviceID(d.integer(forKey: Key.metroOutput))
        metroSound = d.string(forKey: Key.metroSound).flatMap(ClickSound.init(rawValue:)) ?? .click
        let bpm = d.object(forKey: Key.metroBPM) != nil ? d.integer(forKey: Key.metroBPM) : d.object(forKey: Key.legacyBPM) != nil ? d.integer(forKey: Key.legacyBPM) : 100   // fresh install: 100 BPM (Anup, 2026-10-09)
        let beats = d.object(forKey: Key.metroBeats) != nil ? d.integer(forKey: Key.metroBeats) : d.object(forKey: Key.legacyBeats) != nil ? d.integer(forKey: Key.legacyBeats) : 4
        metroDefaultBPM = max(30, min(300, bpm))
        metroDefaultBeats = max(1, min(12, beats))
        metroOpensIn = d.string(forKey: Key.metroOpensIn).flatMap(MetronomeMode.init(rawValue:)) ?? .simple
        metroSetup = d.data(forKey: Key.metroSetup).flatMap { try? JSONDecoder().decode(MetronomeSetup.self, from: $0) } ?? MetronomeSetup()
        metroLevels = MetronomeLevels(accent: d.double(forKey: Key.metroLevelAccent), main: d.double(forKey: Key.metroLevelMain), sub: d.double(forKey: Key.metroLevelSub))
        metroFollowsPreset = d.bool(forKey: Key.metroFollowsPreset)
        connectAtLaunch = d.bool(forKey: Key.connectAtLaunch)
        showLogAtLaunch = d.bool(forKey: Key.showLog)
        devTools = DevTools.isOn(in: d)
        refreshRemembered()
    }

    func refreshRemembered() {
        hasRememberedPedal = d.string(forKey: Key.pedalIdentifier) != nil
        rememberedPedal = hasRememberedPedal ? d.string(forKey: Key.pedalName) : nil
    }
    func forgetRememberedPedal() {
        d.removeObject(forKey: Key.pedalIdentifier); d.removeObject(forKey: Key.pedalName)
        refreshRemembered()
    }
}

extension PedalStore {
    /// Help → Show Log File and Settings → Advanced: reveals `activity.log` in Finder, creating it if it is missing.
    func revealLogFile() {
        logWriter.ensureExists()
        NSWorkspace.shared.activateFileViewerSelecting([Self.logFile])
    }
}

// MARK: - icon

/// `icon.svg` with the LED ring recoloured to the accent: the Dock icon (when the setting is on) and the header mark.
@MainActor
enum AppIcon {
    private static let svg: String? = Bundle.main.url(forResource: "icon", withExtension: "svg").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static var cache: [Accent: NSImage] = [:]
    private static var original: NSImage? = Bundle.main.url(forResource: "icon", withExtension: "svg").flatMap(NSImage.init(contentsOf:))

    static func svgSource(for accent: Accent) -> String? {
        guard let svg else { return nil }
        let (a, b, c) = accent.ledStops
        // Replace the three stop colours of the `led` gradient whatever they currently are (the asset's own
        // colours changed once already and silently broke a literal replacement).
        guard let gradRange = svg.range(of: "<linearGradient id=\"led\""), let endRange = svg.range(of: "</linearGradient>", range: gradRange.lowerBound..<svg.endIndex) else { return svg }
        var grad = String(svg[gradRange.lowerBound..<endRange.upperBound])
        var i = 0
        let stops = [a, b, c]
        while let r = grad.range(of: "stop-color=\"#[0-9a-fA-F]{6}\"", options: .regularExpression), i < 3 {
            grad.replaceSubrange(r, with: "stop-colour=\"\(stops[i])\"")   // temporary spelling so the next search skips it
            i += 1
        }
        grad = grad.replacingOccurrences(of: "stop-colour=", with: "stop-color=")
        return svg.replacingCharacters(in: gradRange.lowerBound..<endRange.upperBound, with: grad)
    }
    static func image(for accent: Accent) -> NSImage? {
        if let i = cache[accent] { return i }
        guard let src = svgSource(for: accent), let img = NSImage(data: Data(src.utf8)) else { return original }
        cache[accent] = img
        return img
    }
    /// What the header shows: the recoloured mark when the Dock icon follows the accent, the asset icon's blue otherwise.
    static var mark: NSImage? {
        let s = AppSettings.shared
        return s.dockIconFollowsAccent ? image(for: s.accent) : original
    }
    /// Rasterised at `px` (1024 for the Dock).
    static func bitmap(for accent: Accent, px: Int = 1024) -> NSBitmapImageRep? {
        guard let img = image(for: accent), let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    /// Sets (or, with the setting off, clears back to the bundle's icon) the Dock icon.
    static func apply() {
        let s = AppSettings.shared
        guard s.dockIconFollowsAccent, let rep = bitmap(for: s.accent) else { NSApp.applicationIconImage = nil; return }
        let img = NSImage(size: NSSize(width: 1024, height: 1024))
        img.addRepresentation(rep)
        NSApp.applicationIconImage = img
    }
}

// MARK: - window

struct SettingsView: View {
    @Environment(PedalStore.self) private var store
    @Environment(Metronome.self) private var metro
    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AppSettings.Section.allCases, id: \.self) { s in
                    Button(s.title) { settings.section = s }.buttonStyle(BarButton(selected: settings.section == s)).accessibilityIdentifier("settings-\(s.rawValue)")
                }
            }
            .padding(3).background(Theme.ws, in: RoundedRectangle(cornerRadius: 9))
            .padding(.top, 14).padding(.bottom, 12)
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                switch settings.section {
                case .appearance: appearance
                case .metronome: metronome
                case .connection: connection
                case .device: DeviceSection()
                case .advanced: advanced
                case .about: AboutSection()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 560, height: settings.section == .metronome ? 700 : settings.section == .device ? 500 : 420)
        .background(Theme.panel)
        .font(Theme.font(13))
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear { settings.refreshRemembered(); metro.refreshOutputs() }
    }

    // MARK: sections

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "Accent colour").padding(.bottom, 12)
            HStack(spacing: 14) {
                ForEach(Accent.allCases) { a in
                    Button { settings.accent = a } label: {
                        VStack(spacing: 7) {
                            Circle().fill(a.color).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 2.5).opacity(settings.accent == a ? 1 : 0))
                                .padding(3)
                                .overlay(Circle().strokeBorder(settings.accent == a ? Theme.text : Theme.line, lineWidth: settings.accent == a ? 2 : 1))
                            Text(a.title).font(Theme.font(11)).foregroundStyle(settings.accent == a ? Theme.text : Theme.dim)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("accent-\(a.rawValue)").help(a.rgb.css.uppercased())
                }
            }
            .padding(.bottom, 6)
            Text("Primary buttons, the selected preset, focus rings, sliders and the beat indicator.").font(Theme.font(12)).foregroundStyle(Theme.faint).padding(.bottom, 18)
            Divider().overlay(Theme.line).padding(.bottom, 14)
            row("Dock icon follows the accent", detail: "Recolours the LED ring of the Dock icon and the header mark. Off: the app's own blue icon.") {
                Switch(on: settings.dockIconFollowsAccent, color: Theme.accent) { settings.dockIconFollowsAccent.toggle() }
            }
            HStack(spacing: 14) {
                if let img = AppIcon.mark { Image(nsImage: img).resizable().interpolation(.high).frame(width: 64, height: 64) }
                ThemedPreview()
            }
            .padding(.top, 6)
        }
    }

    private var metronome: some View {
        @Bindable var m = metro
        return VStack(alignment: .leading, spacing: 11) {
            row("Opens in", detail: "Advanced adds time signatures, accents, subdivisions and trainers; its last setup is remembered.") {
                Pills(options: MetronomeMode.allCases.map { ($0, $0.title) }, selection: settings.metroOpensIn) { v in
                    settings.metroOpensIn = v; if !metro.running { metro.mode = v }
                }
            }
            row("Output") {
                OutputMenu(width: 210)
            }
            row("Volume") {
                HStack(spacing: 8) {
                    Slider(value: $m.volume, in: 0...1).tint(Theme.accent).frame(width: 170)
                    Text("\(Int((metro.volume * 100).rounded()))%").font(Theme.font(12)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 36, alignment: .trailing)
                }
            }
            row("Default tempo", detail: "The overlay changes the tempo for this session only.") {
                HStack(spacing: 6) {
                    Button { setDefaultBPM(settings.metroDefaultBPM - 1) } label: { Image(systemName: "minus") }.buttonStyle(ThemedButton(small: true))
                    Text("\(settings.metroDefaultBPM) BPM").font(Theme.font(13, .semibold)).monospacedDigit().frame(width: 70)
                    Button { setDefaultBPM(settings.metroDefaultBPM + 1) } label: { Image(systemName: "plus") }.buttonStyle(ThemedButton(small: true))
                }
            }
            row("Follow the preset tempo", detail: "While a pedal is connected, the tempo follows the current preset, and changing it here writes it to the preset (Save keeps it).") {
                Switch(on: settings.metroFollowsPreset, color: Theme.accent) { setFollowsPreset(!settings.metroFollowsPreset) }.accessibilityIdentifier("settings-follow-preset")
            }
            row("Beats per bar (Simple)") {
                MiniStepper(value: settings.metroDefaultBeats, range: 1...12, id: "settings-beats") { v in settings.metroDefaultBeats = v; if !metro.running { metro.set(beats: v) } }
            }
            row("Advanced pattern") { PatternMenu() }
            row("Subdivision") {
                Pills(options: [(1, "None"), (2, "2"), (3, "3"), (4, "4")], selection: settings.metroSetup.subdivision) { settings.metroSetup.subdivision = $0 }
            }
            row("Count-in") {
                Pills(options: [(0, "Off"), (1, "1 bar"), (2, "2 bars")], selection: settings.metroSetup.countIn) { settings.metroSetup.countIn = $0 }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Levels").font(Theme.font(13))
                    Text("Same as the overlay's Levels…").font(Theme.font(12)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 8)
                LevelSliders(sliderWidth: 130)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Click sound").font(Theme.font(13))
                    Spacer()
                    Button("Preview") { metro.preview() }.buttonStyle(ThemedButton(small: true)).disabled(metro.running)
                }
                HStack(spacing: 2) {
                    ForEach(ClickSound.allCases) { s in
                        Button(s.title) { metro.sound = s; if !metro.running { metro.preview() } }.buttonStyle(BarButton(selected: metro.sound == s)).accessibilityIdentifier("sound-\(s.rawValue)")
                    }
                }
                .padding(3).background(Theme.ws, in: RoundedRectangle(cornerRadius: 9))
            }
            if let e = metro.error { Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn) }
        }
    }
    private func setFollowsPreset(_ on: Bool) {
        settings.metroFollowsPreset = on
        metro.adopt(presetTempo: metro.presetTempo)
    }
    private func setDefaultBPM(_ v: Int) {
        settings.metroDefaultBPM = max(30, min(300, v))
        if !metro.running { metro.set(bpm: settings.metroDefaultBPM) }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Connect to the last pedal at launch", detail: "Reconnects to the remembered pedal when the app opens. Off: press Connect yourself.") {
                Switch(on: settings.connectAtLaunch, color: Theme.accent) { settings.connectAtLaunch.toggle() }
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Remembered pedal")
                Text(settings.hasRememberedPedal ? (settings.rememberedPedal ?? "A Nano Cortex (its name shows after the next connection)") : "None. The next Connect scans for a pedal.")
                    .font(Theme.font(13)).foregroundStyle(settings.hasRememberedPedal ? Theme.text : Theme.dim).accessibilityIdentifier("rememberedPedal")
            }
            HStack {
                Button("Forget the remembered pedal") { Task { await store.forgetPedal() } }.buttonStyle(ThemedButton()).disabled(!settings.hasRememberedPedal)
                Spacer()
            }
            Text("Forgetting also disconnects. The pedal accepts one Bluetooth connection, so close the Cortex Cloud phone app first.").font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 14) {
            row("Developer tools", detail: "Shows the Activity log, session recording and protocol details. For troubleshooting and development.") {
                Switch(on: settings.devTools, color: Theme.accent) { settings.devTools.toggle() }.accessibilityIdentifier("settings-devtools")
            }
            if settings.devTools {
                row("Show the Activity drawer at launch", detail: "The protocol log under the editor (⌘L toggles it).") {
                    Switch(on: settings.showLogAtLaunch, color: Theme.accent) { settings.showLogAtLaunch.toggle() }
                }
                row("Activity log file", detail: PedalStore.logFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Reveal in Finder") { store.revealLogFile() }.buttonStyle(ThemedButton())
                }
            }
            #if DEBUG
            row("Dev remote", detail: "Debug builds only.") {
                Text(verbatim: settings.devRemotePort.map { "http://127.0.0.1:" + String($0) } ?? "Off").font(Theme.mono(12)).foregroundStyle(Theme.dim).textSelection(.enabled)
            }
            #endif
        }
    }

    // MARK: building blocks

    private func row<C: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13))
                if let detail { Text(detail).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

/// Settings → About: name and version, who made it, links (all open the browser) and the trademark note.
struct AboutSection: View {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?"
        return (info["CFBundleVersion"] as? String).map { "Version \(v) (\($0))" } ?? "Version \(v)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                if let img = AppIcon.mark { Image(nsImage: img).resizable().interpolation(.high).frame(width: 56, height: 56) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nano Cortex Editor").font(Theme.font(16, .semibold))
                    Text(Self.version).font(Theme.font(12)).foregroundStyle(Theme.dim).textSelection(.enabled).accessibilityIdentifier("aboutVersion")
                    Text("Made by AJs Creations").font(Theme.font(12)).foregroundStyle(Theme.dim)
                }
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 9) {
                link("GitHub repository", Links.repository, id: "about-repo")
                link("Manual", Links.manual, id: "about-manual")
                link("Cross-platform edition (macOS and Windows)", Links.crossPlatform, id: "about-crossplatform")
                link("Buy me a coffee", Links.support, id: "about-support")
            }
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 6) {
                Text("Unofficial. Neural DSP and Nano Cortex are trademarks of Neural DSP Technologies Oy; this project is not affiliated with or endorsed by Neural DSP.")
                Text("Free and open source under the MIT License. © 2026 AJs Creations.")
            }
            .font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func link(_ title: String, _ url: URL, id: String) -> some View {
        Button { Links.open(url) } label: {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
        }
        .buttonStyle(LinkStyle()).help(url.absoluteString).accessibilityIdentifier(id)
    }
}

/// A primary button, a selected preset row and a focus ring in the current accent.
private struct ThemedPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Button("Save") {}.buttonStyle(ThemedButton(kind: .primary))
            HStack(spacing: 0) {
                Text("3").font(Theme.font(11)).foregroundStyle(Theme.activeNum).frame(width: 22, alignment: .leading)
                Text("Jubilee Crunch").font(Theme.font(13)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8).frame(width: 150, height: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.activeRow).overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }.clipShape(RoundedRectangle(cornerRadius: 5)))
            RoundedRectangle(cornerRadius: 6).fill(Theme.ws).frame(width: 34, height: 28).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.focus, lineWidth: 2))
        }
    }
}
