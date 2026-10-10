// Load a capture or cab from the pedal's library into a slot: a searchable
// popover (Factory / Yours, current item marked), then a slot chooser.

import SwiftUI
import NanoCore

/// "Load from library…" (`.btn.ghost.small` in the section head).
struct LibraryButton: View {
    @Environment(PedalStore.self) private var store
    let kind: PedalStore.LibraryKind
    @State private var open = false
    @State private var loading = false
    var body: some View {
        Button(loading ? "Reading library…" : "Load from library…") { openIt() }
        .buttonStyle(ThemedButton(kind: .ghost, small: true)).disabled(loading)
        .help(kind == .capture ? "Load a capture from the pedal’s library into a slot" : "Load a cab or IR from the pedal’s library into a slot")
        .popover(isPresented: $open, arrowEdge: .bottom) { LibraryPopover(kind: kind, close: { open = false }) }
        .onChange(of: store.libraryOpen) { _, k in if k == kind { store.libraryOpen = nil; openIt() } }   // from a context menu
    }
    private func openIt() {
        if store.library != nil { open = true; return }
        loading = true
        Task { let l = await store.ensureLibrary(); loading = false; if l != nil { open = true } else { store.toast("The pedal didn’t send its library. Try again.") } }
    }
}

private struct Row: Identifiable {
    let id: String; let name: String; let sub: String; let factory: Bool; let index: Int; let current: Bool
    var icons: [CaptureKind.Icon] = []   // type + instrument, shown before `sub` (the author)
    var words = ""                       // the raw type/instrument words: searched, and the row's tooltip
}

/// `.pop` with the library: search, then Factory / Yours groups.
struct LibraryPopover: View {
    @Environment(PedalStore.self) private var store
    let kind: PedalStore.LibraryKind
    let close: () -> Void
    @State private var query = ""

    private var rows: [(String, [Row])] {
        guard let l = store.library else { return [] }
        let cur = kind == .capture ? store.captureName : store.cab.name
        func cap(_ list: [LibraryCapture], _ factory: Bool) -> [Row] {
            list.map { Row(id: "\(factory)-\($0.index)", name: $0.name, sub: $0.author, factory: factory, index: $0.index, current: $0.name == cur,
                           icons: CaptureKind.icons(type: $0.type, instrument: $0.instrument), words: [$0.type, $0.instrument].filter { !$0.isEmpty }.joined(separator: " · ")) }
        }
        func ir(_ list: [NanoCore.LibraryItem], _ factory: Bool) -> [Row] { list.map { Row(id: "\(factory)-\($0.index)", name: $0.name, sub: "", factory: factory, index: $0.index, current: $0.name == cur) } }
        let groups: [(String, [Row])] = kind == .capture
            ? [("Factory captures", cap(l.factoryCaptures, true)), ("Your captures", cap(l.userCaptures, false))]
            : [("Factory cabs", ir(l.factoryIRs, true)), ("Your IRs", ir(l.userIRs, false))]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return groups.map { ($0.0, q.isEmpty ? $0.1 : $0.1.filter { $0.name.lowercased().contains(q) || $0.sub.lowercased().contains(q) || $0.words.lowercased().contains(q) }) }.filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(prompt: kind == .capture ? "Search captures" : "Search cabs and IRs", text: $query, accent: true).padding(10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text(store.library == nil ? "No library yet." : query.isEmpty ? "The pedal’s library is empty." : "Nothing matches “\(query)”.").font(Theme.font(13)).foregroundStyle(Theme.faint).padding(14)
                    }
                    ForEach(rows, id: \.0) { group, items in
                        PopGroup(title: group)
                        ForEach(items) { r in
                            PopItem(title: r.name, subtitle: r.sub, icons: r.icons, tooltip: [r.words, r.sub].filter { !$0.isEmpty }.joined(separator: " · "), current: r.current) {
                                close()
                                let choice = PedalStore.SlotChoice(kind: kind, name: r.name, factory: r.factory, index: r.index)
                                if let slot = store.libraryTarget { store.libraryTarget = nil; store.pick(choice, slot: slot) } else { store.slotChooser = choice }
                            }
                        }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 8)
            }
            .frame(height: 380)
        }
        .frame(width: 340).background(Theme.pop).foregroundStyle(Theme.text)
        .presentationBackground(Theme.pop)
    }
}

private struct HoverHighlight: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View { content.background(hover ? Theme.popHi : .clear, in: RoundedRectangle(cornerRadius: 5)).onHover { hover = $0 } }
}
extension View { func hoverHighlight() -> some View { modifier(HoverHighlight()) } }

/// "Which slot should hold X?" — the slot grid with the current names; whatever is in the chosen slot is replaced.
struct SlotChooserSheet: View {
    @Environment(PedalStore.self) private var store
    let choice: PedalStore.SlotChoice
    @State private var selected: Int = 1
    var body: some View {
        let isCap = choice.kind == .capture, count = isCap ? store.captureSlotCount : store.cabSlotCount
        let names = isCap ? (store.metadata?.captureNames ?? []) : (store.metadata?.irNames ?? [])
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Which slot should hold \(choice.name)?").padding(.bottom, 8)
            ModalText("Whatever is in that slot on the pedal is replaced. Presets that use the slot will play the new \(isCap ? "capture" : "cab").").padding(.bottom, 18)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: isCap ? 3 : 2), spacing: 6) {
                    ForEach(1...count, id: \.self) { i in
                        let used = (isCap ? store.usage?.captures[i] : store.usage?.cabs[i])?.count
                        SlotCell(number: isCap ? bank(i) : "\(i)", name: names[safe: i - 1] ?? "", on: selected == i, color: Theme.accent, used: used) { selected = i }
                    }
                }
            }.frame(maxHeight: 300).padding(.bottom, 16)
            HStack(spacing: 8) {
                if store.usage == nil { Text("Tip: Usage… scans which presets each slot feeds.").font(Theme.font(12)).foregroundStyle(Theme.faint) }
                Spacer()
                Button("Cancel") { store.slotChooser = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Load into slot \(isCap ? bank(selected) : "\(selected)")") { store.pick(choice, slot: selected) }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel(width: 560)
        .onAppear { selected = isCap ? (store.captureSlot ?? 1) : max(1, store.cab.slot) }
    }
    private func bank(_ slot: Int) -> String { PedalStore.slotLabel(slot) }
}

/// "Save changes to X?" when switching presets with unsaved edits.
/// "Save changes to X?" before a footswitch assignment: the pedal reloads the stored preset when it assigns.
struct AssignPrompt: View {
    @Environment(PedalStore.self) private var store
    let pending: PedalStore.PendingAssignment
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Save changes to \(store.presetName(store.presetIndex))?").padding(.bottom, 8)
            ModalText("Assigning preset \(pending.index + 1) to footswitch \(pending.slot.label) makes the pedal reload this preset, which discards edits that haven’t been saved.").padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.resolveAssignment("cancel") }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Don’t save") { store.resolveAssignment("discard") }.buttonStyle(ThemedButton())
                Button("Save and assign") { store.resolveAssignment("save") }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel(width: 420)
    }
}

struct SwitchPrompt: View {
    @Environment(PedalStore.self) private var store
    let target: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Save changes to \(store.presetName(store.presetIndex))?").padding(.bottom, 8)
            ModalText("Switching presets discards edits that haven’t been saved to the pedal.").padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.pendingPreset = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Don’t save") { store.switchPreset(target) }.buttonStyle(ThemedButton())
                Button("Save and switch") { store.saveAndSwitch(target) }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel(width: 420)
    }
}

/// Confirms a Discard: the preset reloads as last saved on the pedal.
struct DiscardSheet: View {
    @Environment(PedalStore.self) private var store
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Discard edits to \(store.presetName(store.presetIndex))?").padding(.bottom, 8)
            ModalText("The preset reloads as it was last saved on the pedal. The unsaved edits are lost.").padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.discardRequested = false }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button(busy ? "Discarding…" : "Discard") { busy = true; Task { await store.discardEdits(); store.discardRequested = false } }
                    .buttonStyle(ThemedButton(kind: .primary)).disabled(busy).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel(width: 420)
    }
}

/// `.toast`: transient message at the bottom of the window.
struct Toast: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.font(13)).foregroundStyle(Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.groove))
            .shadow(color: .black.opacity(0.56), radius: 15, y: 10)
            .transition(.offset(y: 6).combined(with: .opacity))
    }
}

/// "Save as…": the live state into another slot under a new name; the current preset keeps its saved state.
struct SaveAsSheet: View {
    @Environment(PedalStore.self) private var store
    @State private var name = ""
    @State private var target = 0
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        let count = max(64, store.presetNames.count)
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Save as a new preset").padding(.bottom, 8)
            ModalText("Writes the current sound, including unsaved edits, into the slot you pick. Preset \(store.presetIndex + 1) keeps what it had.").padding(.bottom, 14)
            HStack(spacing: 10) {
                Text("NAME").font(Theme.font(11)).tracking(Theme.em(0.12, 11)).foregroundStyle(Theme.label).fixedSize()
                SearchField(prompt: "Preset name", text: $name, onSubmit: commit)
            }.padding(.top, 4).padding(.bottom, 2)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        let n = store.presetName(i), current = i == store.presetIndex
                        SlotCell(number: "\(i + 1)", name: n == "Empty" ? "" : n, on: target == i, color: Theme.accent, dimmed: current) { target = i }
                            .disabled(current)
                    }
                }
            }.frame(height: 320).padding(.top, 10)
            if store.presetName(target) != "Empty", target != store.presetIndex {
                ModalText("Preset \(target + 1) “\(store.presetName(target))” will be overwritten.", color: Theme.warn).padding(.top, 10)
            }
            if let error { ModalText(error, color: Theme.danger).padding(.top, 10) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.saveAsOpen = false }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button(busy ? "Saving…" : "Save to preset \(target + 1)") { commit() }.buttonStyle(ThemedButton(kind: .primary)).disabled(busy || target == store.presetIndex).keyboardShortcut(.defaultAction)
            }.padding(.top, 18)
        }
        .modalPanel(width: 640)
        .onAppear {
            name = store.presetName(store.presetIndex) == "Empty" ? "Preset \(store.presetIndex + 1) copy" : store.presetName(store.presetIndex) + " copy"
            target = store.saveAsTarget ?? (0..<count).first { $0 != store.presetIndex && store.presetName($0) == "Empty" } ?? (store.presetIndex + 1) % count
            store.saveAsTarget = nil
        }
    }
    private func commit() {
        busy = true
        Task { if let e = await store.saveAs(index: target, name: name) { error = e; busy = false } else { busy = false; store.saveAsOpen = false } }
    }
}

/// "Delete preset N?" — empties the slot on the pedal; cannot be undone from here.
struct DeleteSheet: View {
    @Environment(PedalStore.self) private var store
    let index: Int
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete preset \(index + 1), “\(store.presetName(index))”?").font(Theme.font(15, .semibold))
            Text("The slot on the pedal becomes empty. There is no undo; if you might want it back, use Save as… to copy it to a free slot first.").font(Theme.font(12)).foregroundStyle(Theme.label).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(Theme.font(12)).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Cancel") { store.deleteTarget = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button(busy ? "Deleting…" : "Delete") { busy = true; Task { if let e = await store.deletePreset(index: index) { error = e; busy = false } else { store.deleteTarget = nil } } }
                    .buttonStyle(ThemedButton(kind: .primary)).disabled(busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 440).background(Theme.panel).foregroundStyle(Theme.text)
    }
}
