import SwiftUI
import AppKit
import NanoCore

@main
struct NanoCortexEditorApp: App {
    @State private var store = PedalStore()
    @State private var cloud = CloudController()
    @State private var metro = Metronome()
    /// Held here so the menus observe it (Developer tools show or hide View → Activity Log).
    @State private var settings = AppSettings.shared
    /// "Check for Updates…" and Settings → Advanced (Sparkle, DECISIONS #23).
    @State private var updates = Updates.shared
    #if DEBUG
    @State private var remote: DevRemote?
    #endif

    init() {
        Theme.registerFonts()
        // Grayscale antialiasing without stem darkening, like the Electron app's -webkit-font-smoothing: antialiased
        // (light text on near-black otherwise renders a weight heavier than the reference).
        UserDefaults.standard.register(defaults: ["AppleFontSmoothing": 0])
        SparkleUpdater.shared.start()   // daily checks plus one a few seconds after launch (none under -demo)
    }

    var body: some Scene {
        let devTools = settings.devTools   // read here so a change rebuilds the menus
        WindowGroup("Nano Cortex Editor") {
            ContentView()
                .environment(store)
                .environment(cloud)
                .environment(metro)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(.dark)
                .ignoresSafeArea()
                .background(SettingsOpener())
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    AppIcon.apply()   // the Dock icon in the accent (Settings → Appearance)
                    store.attach(metro)   // metronome ↔ preset tempo (Settings → Metronome)
                    AppSettings.shared.onDevToolsChanged = { [weak store] on in store?.devToolsChanged(on) }
                    SparkleUpdater.shared.log = { [weak store] line in store?.append(line) }   // update checks in the Activity log
                    #if DEBUG
                    if remote == nil, !args.contains("-no-dev-remote") { remote = DevRemote(store: store, cloud: cloud, metro: metro) }
                    #endif
                    // `-window 1000x660` sizes the window (UI tests on small CI displays, screenshots).
                    if let i = args.firstIndex(of: "-window"), i + 1 < args.count, let x = args[i + 1].firstIndex(of: "x"),
                       let w = Double(args[i + 1][..<x]), let h = Double(args[i + 1][args[i + 1].index(after: x)...]) {
                        NSApp.windows.first { $0.canBecomeMain }?.setContentSize(NSSize(width: w, height: h))
                        // Window restoration can apply the saved frame after this first pass; size it again once that's done.
                        try? await Task.sleep(for: .milliseconds(400))
                        NSApp.windows.first { $0.canBecomeMain }?.setContentSize(NSSize(width: w, height: h))
                    }
                    if args.contains("-demo") {
                        if store.link == .off { await store.connect(demo: true) }   // UI tests and screenshots
                    } else if AppSettings.shared.connectAtLaunch, AppSettings.shared.hasRememberedPedal, store.link == .off {
                        await store.connect()   // Settings → Connection; only a pedal we have connected to before, never a fresh scan
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsView().environment(store).environment(metro)
        }
        MenuBarExtra("Nano Cortex", systemImage: store.connected ? "waveform.circle.fill" : "waveform.circle") {
            MenuBarContent().environment(store).environment(metro)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // The standard About panel, with a credits line and the links (they open the browser).
            CommandGroup(replacing: .appInfo) {
                Button("About Nano Cortex Editor") { AboutPanel.show() }
                // Sparkle's standard check: the update alert, "You're up to date", or an error (DECISIONS #23).
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheck)
            }
            CommandGroup(replacing: .help) {
                Button("Nano Cortex Editor Manual") { Links.open(Links.manual) }
                Button("GitHub Repository") { Links.open(Links.repository) }
                Button("Report an Issue") { Links.open(Links.newIssue) }
                Button("Show Log File") { store.revealLogFile() }   // everyone: attach activity.log to a bug report
                Divider()
                Button("Support the Project…") { Links.open(Links.support) }
            }
            // Explicit app-menu entry: SwiftUI's automatic "Settings…" did not show up in every build.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppSettings.shared.openSettings?() }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Editor") { store.tab = .editor }.keyboardShortcut("1")
                Button("Cortex Cloud") { store.tab = .cloud }.keyboardShortcut("2")
                Divider()
                if devTools { Button("Activity Log") { if settings.devTools { store.showLog.toggle() } }.keyboardShortcut("l") }   // Developer tools only
                Button("Keyboard Shortcuts") { store.shortcutsOpen = true }
            }
            CommandMenu("Pedal") {
                Button(store.link == .off ? "Connect" : "Disconnect") { Task { if store.link == .off { await store.connect() } else { await store.disconnect() } } }.keyboardShortcut("k")
                Button("Demo mode") { Task { await store.connect(demo: true) } }.disabled(store.link != .off)
                Divider()
                Button("Discard Edits…") { store.discardRequested = true }.disabled(!store.connected || !(store.edited || store.dirty))
                Button("Save As…") { store.saveAsOpen = true }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.connected)
                Button("Previous preset") { store.stepPreset(-1) }.keyboardShortcut(.upArrow).disabled(!store.connected)
                Button("Next preset") { store.stepPreset(+1) }.keyboardShortcut(.downArrow).disabled(!store.connected)
                Button("Delete Preset…") { store.deleteTarget = store.presetIndex }.disabled(!store.connected || store.presetName(store.presetIndex) == "Empty")
                Divider()
                Button("Refresh from the pedal") { store.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!store.connected)
                Button("Tuner") { store.tuner(on: !store.tunerOn) }.keyboardShortcut("t").disabled(!store.connected)
                Button("Metronome") { metro.open.toggle(); if !metro.open { metro.stop() } }.keyboardShortcut("m")
            }
        }
    }
}

/// "About Nano Cortex Editor": AppKit's standard panel plus credits (made by, the links, the support link).
@MainActor
enum AboutPanel {
    static var credits: NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]
        let s = NSMutableAttributedString(string: "Made by AJs Creations. Free and open source (MIT).\n", attributes: base)
        func link(_ title: String, _ url: URL) { var a = base; a[.link] = url; s.append(NSAttributedString(string: title, attributes: a)) }
        link("GitHub", Links.repository)
        s.append(NSAttributedString(string: " · ", attributes: base))
        link("Manual", Links.manual)
        s.append(NSAttributedString(string: "\nIf this editor saves you time, you can ", attributes: base))
        link("buy me a coffee", Links.support)
        s.append(NSAttributedString(string: ".", attributes: base))
        return s
    }
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Hands SwiftUI's openSettings action to AppSettings so the dev remote can open the Settings window.
private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View { Color.clear.frame(width: 0, height: 0).onAppear { AppSettings.shared.openSettings = { openSettings() } } }
}

/// The menu bar extra: link state, current preset with previous/next, tuner and metronome.
struct MenuBarContent: View {
    @Environment(PedalStore.self) private var store
    @Environment(Metronome.self) private var metro
    var body: some View {
        Text(store.connected ? (store.demo ? "Demo pedal" : store.pedalName) : "Not connected")
        if store.state != nil {
            Text("\(store.presetIndex + 1)  \(store.presetName(store.presetIndex))" + (store.dirty || store.edited ? "  •" : ""))
            Button("Previous preset") { store.selectPreset(max(0, store.presetIndex - 1)) }.keyboardShortcut("[")
            Button("Next preset") { store.selectPreset(min(63, store.presetIndex + 1)) }.keyboardShortcut("]")
            Divider()
            Button(store.tunerOn ? "Tuner off" : "Tuner") { store.tuner(on: !store.tunerOn) }
        } else {
            Button("Connect") { Task { await store.connect() } }.disabled(store.link != .off)
        }
        Button(metro.running ? "Stop metronome (\(metro.bpm) BPM)" : "Start metronome (\(metro.bpm) BPM)") { metro.toggle() }
        Divider()
        Button("Show Nano Cortex Editor") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
