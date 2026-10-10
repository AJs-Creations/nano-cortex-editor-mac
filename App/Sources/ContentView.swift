// The window: tab bar, editor header, preset sidebar, signal chain, inspector for the
// selected stage, Activity drawer, status bar. Mirrors the Electron pro UI (pro/ui.css,
// src/toolbar.html); sizes in comments are the CSS ones.

import SwiftUI
import NanoCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(PedalStore.self) private var store
    @Environment(CloudController.self) private var cloud
    @Environment(Metronome.self) private var metro
    @State private var filter = ""
    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            TabBar()
            if store.tab == .editor {
                HeaderBar(renaming: $renaming, newName: $newName)
                Rectangle().fill(Theme.line).frame(height: 1)
            }
            HStack(spacing: 0) {
                if store.tab == .editor {
                    Sidebar(filter: $filter).frame(width: 248)
                    Rectangle().fill(Theme.line).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if store.tab == .cloud {
                        CloudTab()
                    } else if store.state != nil {
                        ChainView().frame(maxWidth: .infinity)
                        Rectangle().fill(Theme.line).frame(height: 1)
                        InspectorView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ConnectCard().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // grid-template-areas "side main" / "side drawer": the drawer sits under the main column only.
                    if store.showLog {
                        Rectangle().fill(Theme.line).frame(height: 1)
                        LogDrawer().frame(height: 180)
                    }
                }
                .background(Theme.ws)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            StatusBar(showLog: $store.showLog)
        }
        .background(Theme.ws)
        .font(Theme.font(13))
        .foregroundStyle(Theme.text)
        .overlay(alignment: .bottom) { if let n = store.notice { Toast(text: n).padding(.bottom, store.showLog ? 222 : 40).animation(.easeOut(duration: 0.16), value: store.notice) } }
        .overlay { if store.tunerOn { TunerOverlay() } }
        .overlay { if metro.open { MetronomeOverlay() } }
        .sheet(isPresented: $renaming) { renameSheet }
        .onChange(of: store.renameRequested) { _, v in if v { store.renameRequested = false; newName = store.presetName(store.presetIndex); renaming = true } }
        .sheet(item: $store.slotChooser) { SlotChooserSheet(choice: $0) }
        .sheet(item: $store.pendingSend) { SendSheet(bundle: $0) }
        .sheet(isPresented: $store.saveAsOpen) { SaveAsSheet() }
        .sheet(isPresented: $store.discardRequested) { DiscardSheet() }
        .sheet(isPresented: Binding(get: { store.deleteTarget != nil }, set: { if !$0 { store.deleteTarget = nil } })) { if let i = store.deleteTarget { DeleteSheet(index: i) } }
        .sheet(item: $store.offerSlot) { OfferSlotSheet(offer: $0) }
        .sheet(isPresented: $store.shortcutsOpen) { ShortcutsSheet() }
        .confirmationDialog("Sign out of Cortex Cloud?", isPresented: $store.confirmSignOut) {
            Button("Sign out", role: .destructive) { Task { await cloud.signOut() } }
        } message: { Text("Clears the saved Cortex Cloud session from this app.") }
        .sheet(isPresented: Binding(get: { store.pendingAssignment != nil }, set: { if !$0 { store.pendingAssignment = nil } })) { if let p = store.pendingAssignment { AssignPrompt(pending: p) } }
        .sheet(isPresented: Binding(get: { store.pendingPreset != nil }, set: { if !$0 { store.pendingPreset = nil } })) { if let t = store.pendingPreset { SwitchPrompt(target: t) } }
        .background(Shortcuts(showLog: $store.showLog))
        .background(QuestionMarkKey { if !store.tunerOn && !metro.open { store.shortcutsOpen = true } }.frame(width: 0, height: 0))
        .background(TrafficLightCentering().frame(width: 0, height: 0))
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Rename preset \(store.presetIndex + 1)").padding(.bottom, 8)
            ModalText("At least 4 characters. The pedal renames the stored preset immediately.").padding(.bottom, 14)
            SearchField(prompt: "Preset name", text: $newName, onSubmit: commitRename).padding(.bottom, 16)
            if let e = renameError { ModalText(e, color: Theme.danger).padding(.bottom, 14) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { renaming = false }.buttonStyle(ThemedButton())
                Button("Rename") { commitRename() }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel()
    }
    private func commitRename() {
        Task { if let e = await store.rename(newName) { renameError = e } else { renameError = nil; renaming = false } }
    }
}

/// Invisible view carrying the window-level shortcuts (⌘S save, ⌘L log, ⇧⌘S save as).
private struct Shortcuts: View {
    @Environment(PedalStore.self) private var store
    @Binding var showLog: Bool
    var body: some View {
        Group {
            Button("") { Task { _ = await store.save() } }.keyboardShortcut("s").disabled(!store.connected)
            Button("") { showLog.toggle() }.keyboardShortcut("l")
            Button("") { store.saveAsOpen = true }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.connected)
        }.opacity(0).frame(width: 0, height: 0)
    }
}

/// Row 1 (src/toolbar.html): the Editor / Cortex Cloud switch, the per-tab controls, the caption.
/// It is the window's drag region and looks the same on both tabs.
struct TabBar: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        HStack(spacing: 12) {
            TabSwitch()
            if store.tab == .cloud { CloudToolbar() }
            Spacer(minLength: 8)
            Text("NANO CORTEX EDITOR · UNOFFICIAL").font(Theme.font(10)).tracking(Theme.em(0.18, 10)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            if store.tab == .cloud { Button("Sign out") { store.confirmSignOut = true }.buttonStyle(BarButton()) }
        }
        .padding(.leading, 84).padding(.trailing, 12).frame(height: 44)
        .background(WindowDragArea().background(Theme.tabBar))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

/// Row-1 buttons: dim text, 6×12 padding, radius 7, #1E1E1E on hover, .35 when disabled; `selected` is the active tab.
struct BarButton: ButtonStyle {
    var selected = false
    var primary = false   // accent-filled while enabled (Send to Nano on a capture page)
    var height: CGFloat = 30
    func makeBody(configuration: Configuration) -> some View { Styled(selected: selected, primary: primary, height: height, configuration: configuration) }
    private struct Styled: View {
        let selected: Bool
        let primary: Bool
        let height: CGFloat
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let lit = primary && enabled
            configuration.label
                .font(Theme.font(13, lit ? .semibold : .regular)).lineLimit(1).fixedSize()
                .foregroundStyle(lit ? AppSettings.shared.accent.onAccent : (selected || (hover && enabled) ? Theme.text : Theme.dim))
                .padding(.horizontal, 12).frame(height: height)
                .background(lit ? (hover ? Theme.accentHi : Theme.accent) : selected ? Theme.raisedHi : (hover && enabled ? Color(hex: 0x1E1E1E) : .clear), in: RoundedRectangle(cornerRadius: height < 30 ? 4 : 7))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Lets the window be dragged (and zoomed by a double-click) from the empty parts of the tab bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Centres the traffic lights in the 44-point tab bar (Electron's `hiddenInset` look). AppKit lays the title bar
/// out again on resize, key changes and full-screen transitions, so the frames are re-applied after each.
struct TrafficLightCentering: NSViewRepresentable {
    static let barHeight: CGFloat = 44
    final class Hook: NSView {
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                                              NSWindow.didEndLiveResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification]
            observers = names.map { NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            } }
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview else { return }
            let h = TrafficLightCentering.barHeight
            // Make the title bar container as tall as the tab bar, so the moved buttons stay inside it (and clickable).
            if container.frame.height != h || container.frame.maxY != window.frame.height {
                container.frame = NSRect(x: container.frame.minX, y: window.frame.height - h, width: container.frame.width, height: h)
            }
            if bar.frame != container.bounds { bar.frame = container.bounds }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = window.standardWindowButton(kind) else { continue }
                let y = ((h - b.frame.height) / 2).rounded()
                if b.frame.minY != y { b.setFrameOrigin(NSPoint(x: b.frame.minX, y: y)) }
            }
        }
    }
    func makeNSView(context: Context) -> Hook { Hook() }
    func updateNSView(_ nsView: Hook, context: Context) { nsView.apply() }
}

/// Row 2 (`.head`, Editor tab only): wordmark, preset, link pill, actions, Save.
struct HeaderBar: View {
    @Environment(PedalStore.self) private var store
    @Environment(Metronome.self) private var metro
    @Binding var renaming: Bool
    @Binding var newName: String
    @State private var saving = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(level: 0)
            row(level: 1)
            row(level: 2)
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(Theme.panel)
    }

    /// Level 1 drops the wordmark text, the pill's label and the ⌘S hint; level 2 also drops the text buttons
    /// (they stay in the menu bar) so the header fits a 1000-point window.
    private func row(level: Int) -> some View {
        let compact = level >= 1
        let dirty = store.dirty || store.edited
        return HStack(spacing: 10) {
            Wordmark(iconOnly: compact)
            if store.state != nil {
                Rectangle().fill(Theme.line).frame(width: 1, height: 18).padding(.horizontal, 4)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Preset \(store.presetIndex + 1)").font(Theme.font(12)).foregroundStyle(Theme.dim).fixedSize()
                    Text(store.presetName(store.presetIndex)).font(Theme.font(15, .semibold)).tracking(-0.15).lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: compact ? 160 : 260, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("presetName").accessibilityValue(store.presetName(store.presetIndex))
                        .onTapGesture(count: 2) { newName = store.presetName(store.presetIndex); renaming = true }
                    if dirty { Text(compact ? "Unsaved" : "Unsaved changes").font(Theme.font(12)).foregroundStyle(Theme.warn).fixedSize() }
                }
            }
            Spacer(minLength: 8)
            if store.state != nil, level < 2 {
                Button("Tuner") { store.tuner(on: !store.tunerOn) }.buttonStyle(ThemedButton(kind: store.tunerOn ? .primary : .ghost))
                Button(metro.running ? "♩ \(metro.bpm)" : "Metronome") { metro.open.toggle() }.buttonStyle(ThemedButton(kind: metro.running ? .primary : .ghost)).help("Metronome (⌘M)")
                Button("Rename") { newName = store.presetName(store.presetIndex); renaming = true }.buttonStyle(ThemedButton(kind: .ghost))
                Button("Save as…") { store.saveAsOpen = true }.buttonStyle(ThemedButton(kind: .ghost)).help("Save the current sound into another preset slot (⇧⌘S)")
                if level == 0 { Button("Refresh") { store.refresh() }.buttonStyle(ThemedButton(kind: .ghost)).help("Re-read everything from the pedal (⇧⌘R)") }
            }
            Button(connectLabel) { Task { if store.link == .off { await store.connect() } else { await store.disconnect() } } }
                .buttonStyle(ThemedButton())
            if store.state != nil {
                // Discard sits next to Save, outlined rather than filled so it never competes with it; only shown
                // while there is something to discard.
                if dirty { Button("Discard") { store.discardRequested = true }.buttonStyle(ThemedButton()).help("Throw away the unsaved edits and reload the preset as saved on the pedal").accessibilityIdentifier("discard") }
                // As in Electron: Save turns purple only when there is something to save.
                Button { saving = true; Task { _ = await store.save(); saving = false } } label: {
                    HStack(spacing: 7) { Text(saving ? "Saving…" : "Save").fixedSize(); if !compact { Kbd("⌘S") } }
                }.buttonStyle(ThemedButton(kind: dirty ? .primary : .normal)).disabled(saving).help("Commit the live edits to the preset")
            }
        }
    }
    private var connectLabel: String {
        switch store.link { case .off: "Connect"; case .scanning: "Scanning… cancel"; case .connecting: "Connecting… cancel"; case .connected: store.demo ? "Exit demo" : "Disconnect"; case .reconnecting: "Stop waiting" }
    }
}

/// `.led`: 8-point dot, green with a glow when on, orange while busy, #373737 when off.
struct Led: View {
    var on: Bool
    var busy = false
    var body: some View {
        Circle().fill(on ? Theme.ok : busy ? Theme.warn : Theme.groove).frame(width: 8, height: 8)
            .shadow(color: on ? Theme.ok.opacity(0.53) : .clear, radius: 3)
    }
}

/// `.btn kbd`: the shortcut hint inside a button, in the button's colour at .65.
struct Kbd: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).font(Theme.font(11)).opacity(0.65) }
}

/// The Editor / Cortex Cloud pill group (toolbar.html `.tabs`): #181818, 3-point padding, radius 9.
struct TabSwitch: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        HStack(spacing: 2) {
            Button("Editor") { store.tab = .editor }.buttonStyle(BarButton(selected: store.tab == .editor))
            Button("Cortex Cloud") { store.tab = .cloud }.buttonStyle(BarButton(selected: store.tab == .cloud))
        }
        .padding(3).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Brand mark (LED ring in the accent, see AppIcon) with an accent glow, then "NANO CORTEX" 12/600 and "EDITOR" 10
/// faint, both tracked .18em. The SVG's rounded square fills 896 of its 1024 units, so a 39-point frame draws a
/// ~34-point mark, centred in the 48-point header row.
struct Wordmark: View {
    var iconOnly = false
    var body: some View {
        HStack(spacing: 8) {
            if let img = AppIcon.mark {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 39, height: 39)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 3)
            }
            if !iconOnly {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("NANO CORTEX").font(Theme.font(12, .semibold)).tracking(Theme.em(0.18, 12)).fixedSize()
                    Text("EDITOR").font(Theme.font(10)).tracking(Theme.em(0.18, 10)).foregroundStyle(Theme.faint).fixedSize()
                }
            }
        }
    }
}

/// `.side`: "PRESETS" head with the filter, then 28-point rows.
struct Sidebar: View {
    @Environment(PedalStore.self) private var store
    @Binding var filter: String
    @State private var renameTarget: Int? = nil

    private var rows: [Int] {
        let all = Array(0..<max(64, store.presetNames.count))
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { store.presetName($0).lowercased().contains(q) || String($0 + 1) == q }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "Presets")
                    Spacer()
                    Text("\(store.presetNames.filter { !$0.isEmpty }.count) of 64").font(Theme.font(11)).foregroundStyle(Theme.faint)
                }
                SearchField(prompt: "Filter presets", text: $filter)
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.self) { i in
                            PresetRow(index: i, name: store.presetName(i), empty: i >= store.presetNames.count || store.presetNames[i].isEmpty, selected: i == store.presetIndex && store.state != nil)
                                .id(i)
                                .onTapGesture { store.selectPreset(i) }
                                .contextMenu {
                                    Button(i == store.presetIndex ? "Current preset" : "Load") { store.selectPreset(i) }.disabled(i == store.presetIndex)
                                    Button("Rename…") { if i == store.presetIndex { store.renameRequested = true } else { renameTarget = i; store.selectPreset(i) } }.disabled(i != store.presetIndex && (store.edited || store.dirty))
                                    Divider()
                                    Button(store.presetName(i) == "Empty" ? "Save current sound here…" : "Save current sound over this preset…") { store.saveAs(into: i) }.disabled(i == store.presetIndex)
                                    Divider()
                                    ForEach(FootswitchSlot.allCases, id: \.self) { slot in
                                        Button("Assign to footswitch \(slot.label)") { store.requestAssignment(slot, index: i) }.disabled(store.footswitch?[slot] == i)
                                    }
                                    Divider()
                                    Button("Delete…", role: .destructive) { store.deleteTarget = i }.disabled(store.presetName(i) == "Empty")
                                }
                                .accessibilityElement(children: .combine).accessibilityIdentifier("preset-\(i)")
                        }
                        if rows.isEmpty {
                            Text("No presets match “\(filter)”.").font(Theme.font(13)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 16)
                        }
                    }.padding(.horizontal, 6).padding(.bottom, 10)
                }
                .onChange(of: store.presetIndex) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) }; if renameTarget == i { renameTarget = nil; store.renameRequested = true } }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            FootswitchStrip()
        }
        .background(Theme.panel)
        .disabled(store.state == nil)
        .opacity(store.state == nil ? 0.5 : 1)
    }
}

/// The four footswitch slots of 4-Preset mode (I / II × A / B) under the preset list: `.fs-strip` in the Electron
/// app. Click loads the slot's preset; right-click assigns (PROTOCOL-NOTES §10).
struct FootswitchStrip: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Footswitches")
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { cell(.ia); cell(.ib) }
                GridRow { cell(.iia); cell(.iib) }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 12)
        .accessibilityElement(children: .contain).accessibilityIdentifier("footswitches")
    }
    private func cell(_ slot: FootswitchSlot) -> some View {
        let i = store.footswitch?[slot]
        return FootswitchCell(slot: slot, index: i, name: i.map { store.presetName($0) }, current: i != nil && i == store.presetIndex && store.state != nil)
    }
}

/// One slot: label and preset number on top, the preset name under it; the current one like `.preset-row.active`.
private struct FootswitchCell: View {
    @Environment(PedalStore.self) private var store
    let slot: FootswitchSlot, index: Int?, name: String?, current: Bool
    @State private var hover = false
    @State private var picking = false
    var body: some View {
        let empty = name == nil || name == "Empty"
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text(slot.label).font(Theme.font(10.5, .semibold)).tracking(Theme.em(0.08, 10.5)).foregroundStyle(current ? Theme.activeNum : Theme.label)
                Spacer(minLength: 4)
                Text(index.map { "\($0 + 1)" } ?? "—").font(Theme.font(11)).foregroundStyle(current ? Theme.activeNum : Theme.faint)
            }
            Text(name ?? "—").font(Theme.font(12)).foregroundStyle(empty ? Theme.faint : (current || hover ? Theme.text : Theme.dim)).italic(empty && name != nil)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 9).padding(.trailing, 8).padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(current ? Theme.activeRow : hover ? Theme.raisedHi : Theme.raised)
                .overlay(alignment: .leading) { if current { Rectangle().fill(Theme.accent).frame(width: 2) } }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(current ? .clear : Theme.line))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let index { store.selectPreset(index) } }
        .help("Footswitch \(slot.label) · click to load, right-click to change")
        .contextMenu {
            Button("Assign current preset") { store.requestAssignment(slot, index: store.presetIndex) }.disabled(index == store.presetIndex)
            Button("Assign…") { picking = true }
        }
        .popover(isPresented: $picking, arrowEdge: .trailing) { FootswitchPicker(slot: slot, assigned: index) { picking = false } }
        .onChange(of: store.footswitchPicker) { _, s in if s == slot { store.footswitchPicker = nil; picking = true } }
        .accessibilityElement(children: .combine).accessibilityIdentifier("footswitch-\(slot.label.lowercased())")
    }
}

/// "Assign…": the 64 presets, named ones first, in the `.pop` list style; the assigned one marked Current.
private struct FootswitchPicker: View {
    @Environment(PedalStore.self) private var store
    let slot: FootswitchSlot, assigned: Int?
    let close: () -> Void
    @State private var query = ""
    private var groups: [(String, [Int])] {
        let all = Array(0..<max(64, store.presetNames.count))
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? all : all.filter { store.presetName($0).lowercased().contains(q) || String($0 + 1) == q }
        let named = hits.filter { store.presetName($0) != "Empty" }, empty = hits.filter { store.presetName($0) == "Empty" }
        return [("Presets", named), ("Empty", empty)].filter { !$0.1.isEmpty }
    }
    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: "Preset for footswitch \(slot.label)", text: $query, accent: true).padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groups.isEmpty { Text("Nothing matches “\(query)”.").font(Theme.font(13)).foregroundStyle(Theme.faint).padding(14) }
                    ForEach(groups, id: \.0) { title, items in
                        PopGroup(title: title)
                        ForEach(items, id: \.self) { i in
                            PopItem(title: "\(i + 1)  \(store.presetName(i))", current: i == assigned) {
                                close()
                                if i != assigned { store.requestAssignment(slot, index: i) }
                            }
                        }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
            .frame(height: 340)
        }
        .frame(width: 280).background(Theme.pop).foregroundStyle(Theme.text)
        .presentationBackground(Theme.pop)
    }
}

/// `.preset-row`: 26-point number column (11, faint), dim name; hover raised; active #2A2456 with a 2-point accent bar.
private struct PresetRow: View {
    let index: Int, name: String, empty: Bool, selected: Bool
    @State private var hover = false
    var body: some View {
        HStack(spacing: 0) {
            Text("\(index + 1)").font(Theme.font(11)).foregroundStyle(selected ? Theme.activeNum : Theme.faint).frame(width: 26, alignment: .leading)
            Text(name).font(Theme.font(13)).foregroundStyle(empty ? Theme.faint : (selected || hover ? Theme.text : Theme.dim)).italic(empty).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: 28)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.activeRow : hover ? Theme.raised : .clear)
                .overlay(alignment: .leading) { if selected { Rectangle().fill(Theme.accent).frame(width: 2) } }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

/// `.status`: 26 tall, 12-point padding, 11.5-point dim text, text buttons on the right.
struct StatusBar: View {
    @Environment(PedalStore.self) private var store
    @Binding var showLog: Bool
    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Led(on: store.link == .connected, busy: store.link != .connected && store.link != .off)
                Text(linkText).foregroundStyle(Theme.dim).lineLimit(1).fixedSize()
            }
            if let fw = store.state?.firmware { Text("Firmware \(fw)").foregroundStyle(Theme.faint).lineLimit(1).fixedSize() }
            if !store.lastAction.isEmpty { Text(store.lastAction).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.tail) }
            Spacer(minLength: 0)
            if store.state != nil {
                Text(store.dirty || store.edited ? "Unsaved edits. Press ⌘S to commit them to the preset." : "Preset matches the pedal.").foregroundStyle(store.dirty || store.edited ? Theme.warn : Theme.faint).lineLimit(1).fixedSize()
            }
            Button("Settings") { AppSettings.shared.openSettings?() }.buttonStyle(StatusButton()).help("Settings (⌘,)")
            Button("Shortcuts") { store.shortcutsOpen = true }.buttonStyle(StatusButton()).help("Keyboard shortcuts (?)")
            RecordButton()
            Button("Activity") { showLog.toggle() }.buttonStyle(StatusButton(on: showLog)).help("Toggle the Activity log (⌘L)")
            // Quiet support link: same style as its neighbours, no accent, opens the browser.
            Button("♥ Support") { Links.open(Links.support) }.buttonStyle(StatusButton())
                .help("Support the project on Buy Me a Coffee (opens your browser)").accessibilityIdentifier("supportButton")
        }
        .font(Theme.font(11.5))
        .padding(.horizontal, 12).frame(height: 26)
        .background(Theme.panel)
    }
    private var linkText: String {
        switch store.link {
        case .off: store.error ?? "Not connected"
        case .scanning: "Scanning for the pedal…"
        case .connecting: "Connecting to \(store.pedalName)…"
        case .connected: store.demo ? "Demo data, nothing is sent" : store.pedalName
        case .reconnecting: "Waiting for \(store.pedalName)…"
        }
    }
}

/// `#recBtn`: "Record", then "Recording N" in red and bold (`.status #recBtn.on`) until clicked again, which saves the JSON.
struct RecordButton: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        Button { toggle() } label: {
            if store.recording {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in Text("Recording \(store.recorder.count)").monospacedDigit() }
            } else { Text("Record") }
        }
        .buttonStyle(StatusButton(alert: store.recording))
        .help("Record every packet sent and received, then save it as JSON")
        .accessibilityIdentifier("recordButton")
    }
    private func toggle() {
        guard store.recording else { store.startRecording(); return }
        let started = store.recorder.startDate ?? Date()
        guard let rec = store.stopRecording() else { return }
        let folder = PedalStore.recordingFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Save session recording"
        panel.message = "\(rec.events.count) packets (\(rec.tx.count) sent, \(rec.rx.count) received) and \(rec.log.count) log lines"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = folder
        panel.nameFieldStringValue = SessionRecorder.fileName(for: started)
        if panel.runModal() == .OK, let url = panel.url { _ = store.write(rec, to: url) } else { store.toast("Recording discarded.") }
    }
}

/// `.status button`: dim, 2×6 padding, radius 4; raised background on hover. `alert`: danger red, semibold.
struct StatusButton: ButtonStyle {
    var on = false
    var alert = false
    func makeBody(configuration: Configuration) -> some View { Styled(on: on, alert: alert, configuration: configuration) }
    private struct Styled: View {
        let on: Bool
        let alert: Bool
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label.font(Theme.font(11.5, alert ? .semibold : .regular)).foregroundStyle(alert ? Theme.danger : on || hover ? Theme.text : Theme.dim)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(hover ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle()).onHover { hover = $0 }
        }
    }
}

/// `.drawer`: #0F0F0F, 11.5-point monospace at 1.55 line height; TX purple, RX green, errors red, timestamps faint.
struct LogDrawer: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(store.log.enumerated()), id: \.offset) { i, line in
                        styled(line).font(Theme.mono(11.5)).lineSpacing(6).padding(.vertical, 3).textSelection(.enabled).id(i)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            .onAppear { proxy.scrollTo(store.log.count - 1, anchor: .bottom) }
        }
        .background(Theme.drawer)
    }
    /// "12:34:56.789  TX …": the leading timestamp (if any) in faint, the rest coloured by kind.
    private func styled(_ line: String) -> Text {
        if let r = line.range(of: "  "), line.first?.isNumber == true {
            return Text(line[..<r.upperBound]).foregroundColor(Theme.faint) + Text(line[r.upperBound...]).foregroundColor(color(for: line))
        }
        return Text(line).foregroundColor(color(for: line))
    }
    private func color(for line: String) -> Color {
        if line.contains("  TX ") { return Theme.tx }
        if line.contains("  RX ") { return Theme.ok }
        if line.lowercased().contains("fail") || line.lowercased().contains("error") || line.contains("refused") { return Theme.danger }
        return Theme.drawerText
    }
}

/// `.veil-card`: the connect card over the empty workspace.
struct ConnectCard: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((store.link == .off ? "Connect your Nano Cortex" : "Connecting").uppercased()).font(Theme.font(10, .semibold)).tracking(Theme.em(0.18, 10)).foregroundStyle(Theme.accentHi).padding(.bottom, 8)
            Text(store.link == .off ? "Pair over Bluetooth" : headline).font(Theme.font(20, .semibold)).tracking(-0.2).padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 10) {
                step(1, "Make it visible.", "After a power-up, hold EXIT + CAPTURE for a second until the Gain ring lights up. After a plain disconnect it stays reachable.")
                step(2, "Close the phone app.", "The pedal accepts one Bluetooth connection at a time.")
                step(3, "Connect.", "Sync takes about two seconds. Edits go live on the pedal; Save (⌘S) commits them to the preset.")
            }.padding(.bottom, 22)
            // A failed connect (red) or a problem while still trying (Bluetooth off or not allowed, no pedal found yet),
            // with a link to the manual's Troubleshooting section.
            if let e = store.link == .off ? store.error : store.linkProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(e).font(Theme.font(13)).foregroundStyle(store.link == .off ? Theme.danger : Theme.warn).fixedSize(horizontal: false, vertical: true)
                    Button("Troubleshooting") { Links.open(Links.troubleshooting) }.buttonStyle(LinkStyle())
                        .help("The manual's Troubleshooting section (opens your browser)").accessibilityIdentifier("troubleshootingLink")
                }
                .padding(.bottom, 14)
            }
            HStack(spacing: 10) {
                if store.link == .off {
                    Button("Connect") { Task { await store.connect() } }.buttonStyle(ThemedButton(kind: .primary, large: true))
                    Button("Try the demo") { Task { await store.connect(demo: true) } }.buttonStyle(ThemedButton(large: true))
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text("New here?").font(Theme.font(12)).foregroundStyle(Theme.faint)
                        Button("Read the manual") { Links.open(Links.manual) }.buttonStyle(LinkStyle(size: 12))
                            .help("The user manual on GitHub (opens your browser)").accessibilityIdentifier("connectManual")
                    }
                    .fixedSize()
                } else {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { Task { await store.disconnect() } }.buttonStyle(ThemedButton(large: true))
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 24).frame(width: 480, alignment: .leading)
        .background(LinearGradient(colors: [Color(hex: 0x1C1C1C), Color(hex: 0x161616)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0x333333)))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1).padding(.horizontal, 14).padding(.top, 1) }
        .shadow(color: .black.opacity(0.8), radius: 35, y: 30)
    }
    private var headline: String {
        switch store.link { case .scanning: "Looking for the pedal…"; case .connecting: "Connecting to \(store.pedalName)…"; case .reconnecting: "Waiting for \(store.pedalName) to come back…"; default: "Syncing…" }
    }
    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(Theme.font(11, .semibold)).foregroundStyle(Theme.text).frame(width: 22, height: 22)
                .background(Theme.raisedHi, in: Circle()).overlay(Circle().strokeBorder(Color(hex: 0x3A3A3A)))
            (Text(title + " ").font(Theme.font(13, .semibold)).foregroundColor(Theme.text) + Text(body).font(Theme.font(13)).foregroundColor(Theme.dim))
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Full-window tuner (`.tuner-card`). Click outside the card (or press Esc / the Tuner button) to leave tuner mode.
struct TunerOverlay: View {
    @Environment(PedalStore.self) private var store
    @State private var muted = false
    var body: some View {
        let r = store.tunerReading, cents = Double(r?.cents ?? 0), inTune = r.map { abs($0.cents) <= 3 } ?? false
        ZStack {
            Color.black.opacity(0.53).ignoresSafeArea().onTapGesture { store.tuner(on: false) }
            VStack(spacing: 0) {
                Text(r?.note ?? "–").font(Theme.font(64, .semibold)).tracking(-1.3).foregroundStyle(inTune ? Theme.ok : Theme.text).frame(height: 64)
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(stops: [.init(color: Theme.danger, location: 0), .init(color: Theme.raisedHi, location: 0.45), .init(color: Theme.raisedHi, location: 0.55), .init(color: Theme.danger, location: 1)], startPoint: .leading, endPoint: .trailing)).frame(height: 14)
                        Rectangle().fill(Theme.text.opacity(0.6)).frame(width: 2, height: 22).offset(x: w / 2 - 1)
                        if r != nil {
                            RoundedRectangle(cornerRadius: 2).fill(inTune ? Theme.ok : Theme.text).frame(width: 4, height: 26)
                                .offset(x: w / 2 + max(-1, min(1, cents / 50)) * (w / 2) - 2)
                                .animation(.linear(duration: 0.08), value: cents)
                        }
                    }.frame(height: 26)
                }
                .frame(height: 26).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
                Text(r.map { String(format: "%@%.1f ct", $0.cents > 0 ? "+" : "", $0.cents) } ?? "Play a note").font(Theme.font(13)).monospacedDigit().foregroundStyle(Theme.dim).frame(height: 20)
                HStack(spacing: 10) {
                    Toggle("Mute output", isOn: Binding(get: { muted }, set: { muted = $0; store.tuner(on: true, muted: $0) })).toggleStyle(.switch).controlSize(.small).tint(Theme.accent).font(Theme.font(13)).foregroundStyle(Theme.dim)
                    Button("Done") { store.tuner(on: false) }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.cancelAction)
                }.padding(.top, 16)
            }
            .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 18).frame(width: 420)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.8), radius: 30, y: 24)
        }
        .foregroundStyle(Theme.text)
    }
}

/// Opens the shortcuts sheet on `?` when no text field has focus and no sheet is up (Electron: `?` when not typing).
struct QuestionMarkKey: NSViewRepresentable {
    let action: @MainActor () -> Void
    final class Hook: NSView {
        var action: @MainActor () -> Void = {}
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.characters == "?", event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                let eventWindow = event.window.map(ObjectIdentifier.init)
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window = self.window, eventWindow == ObjectIdentifier(window), window.attachedSheet == nil,
                          !(window.firstResponder is NSText) else { return false }
                    self.action()
                    return true
                }
                return handled ? nil : event
            }
        }
    }
    func makeNSView(context: Context) -> Hook { let h = Hook(); h.action = action; return h }
    func updateNSView(_ nsView: Hook, context: Context) { nsView.action = action }
}

/// "Keyboard shortcuts" (pro/ui.js showShortcuts, `.modal.wide` + `.keys`): only the shortcuts this app has.
struct ShortcutsSheet: View {
    @Environment(PedalStore.self) private var store
    static let rows: [(String, String)] = [
        ("⌘S", "Save to the current preset"),
        ("⇧⌘S", "Save as a new preset, in another slot"),
        ("⌘,", "Settings: accent colour, metronome sounds, connection"),
        ("⌘↑  /  ⌘↓", "Previous / next preset"),
        ("Pedal menu", "Rename, Discard Edits…, Delete Preset…, Demo mode"),
        ("Right-click", "A preset: load, rename, save here, delete. A node: bypass, change effect, clear. A slot: load, put a library item here"),
        ("⇧⌘R", "Re-read everything from the pedal"),
        ("⌘K", "Connect or disconnect"),
        ("⌘1  /  ⌘2", "Editor / Cortex Cloud"),
        ("⌘L", "Show Bluetooth activity"),
        ("⌘T", "Tuner (Esc closes it)"),
        ("⌘M", "Metronome (Space starts and stops it)"),
        ("?", "This list (Esc closes any sheet or overlay)"),
        ("Drag, arrows", "Adjust a knob. Hold Shift for fine control"),
        ("Double-click a knob", "Reset it"),
        ("Click a value", "Type an exact value"),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Keyboard shortcuts").padding(.bottom, 14)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                ForEach(Self.rows, id: \.0) { key, text in
                    GridRow {
                        Text(key).font(Theme.font(13)).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line))
                        Text(text).font(Theme.font(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.bottom, 18)
            HStack {
                Button("Full manual…") { Links.open(Links.manual) }.buttonStyle(LinkStyle()).help("The user manual on GitHub (opens your browser)").accessibilityIdentifier("shortcutsManual")
                Spacer()
                Button("Done") { store.shortcutsOpen = false }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
                Button("") { store.shortcutsOpen = false }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
        .modalPanel(width: 520)
        .accessibilityIdentifier("shortcutsSheet")
    }
}
