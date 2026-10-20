// "From the library" in the Cab / IR inspector (pro/ui.js `irLibrarySection`, pro/ui.css `.cab-library-section`):
// the pedal's factory cabs and your IRs with a search box. Click an item to choose a slot for it; ▶ auditions it
// without changing any slot (■ stops it); right-click for Preview, Load into slot… and, on your own IRs, Delete….
// Also the two confirmations of this feature set: sending a Cloud IR and deleting a library IR.

import SwiftUI
import NanoCore

struct IRLibrarySection: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        @Bindable var auditions = store.auditions
        VStack(alignment: .leading, spacing: 0) {
            SectionDivider(title: "From the library").padding(.bottom, 8)
            Text("Click a cab or IR to choose a slot. Preview auditions it without changing any slot.")
                .font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            // The query lives on the store and the field's identity never changes, so typing keeps the focus and the
            // caret while the pedal's reports redraw the inspector.
            SearchField(prompt: "Search cabs and IRs", text: $auditions.librarySearch)
                .frame(maxWidth: 1100).padding(.bottom, 10)
                .accessibilityIdentifier("cab-lib-search")
            let groups = self.groups
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.title) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.title.uppercased()).font(Theme.font(10, .semibold)).tracking(Theme.em(0.1, 10)).foregroundStyle(Theme.faint)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 6)], spacing: 6) {
                                ForEach(g.items, id: \.self) { LibraryRow(item: $0, group: g.title) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
            }
            if let empty = emptyText(hasRows: !groups.isEmpty) {
                Text(empty).font(Theme.font(12)).foregroundStyle(Theme.faint).padding(.top, groups.isEmpty ? 2 : 12)
            }
        }
        .padding(.top, 25)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cabLibrary")
        // Read the library when the section shows, and again whenever it was dropped (Refresh, a transfer, a delete).
        .task(id: store.connected && store.library == nil) { if store.connected, store.library == nil { _ = await store.ensureLibrary() } }
    }

    private struct Group { let title: String; let items: [IRKey] }
    private var query: String { store.auditions.librarySearch.trimmingCharacters(in: .whitespaces).lowercased() }
    private var groups: [Group] {
        guard let lib = store.library else { return [] }
        let q = query
        func match(_ name: String, _ title: String) -> Bool { q.isEmpty || "\(name) \(title)".lowercased().contains(q) }
        return [Group(title: "Factory cabs", items: lib.factoryIRs.filter { match($0.name, "Factory cabs") }.map { IRKey(factory: true, index: $0.index, name: $0.name) }),
                Group(title: "Your IRs", items: lib.userIRs.filter { match($0.name, "Your IRs") }.map { IRKey(factory: false, index: $0.index, name: $0.name) })]
            .filter { !$0.items.isEmpty }
    }
    private func emptyText(hasRows: Bool) -> String? {
        guard store.library != nil else { return store.connected ? "Reading the pedal library…" : "Connect your Nano Cortex to read its library." }
        if hasRows { return nil }
        let q = store.auditions.librarySearch.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? "No cabs or IRs are available in the pedal library." : "Nothing matches “\(q)”."
    }
}

/// `.section-divider`: the heading between two soft lines.
private struct SectionDivider: View {
    let title: String
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
            SectionLabel(text: title).fixedSize()
            Rectangle().fill(Theme.lineSoft).frame(height: 1)
        }
    }
}

/// `.library-row`: the name (click: choose a slot) and the ▶ / ■ audition button.
private struct LibraryRow: View {
    @Environment(PedalStore.self) private var store
    let item: IRKey
    let group: String
    @State private var hover = false
    var body: some View {
        let a = store.auditions.ir, active = a.isActive(item), ready = store.connected && store.library != nil
        HStack(spacing: 5) {
            Button { choose() } label: {
                Text(item.name).font(Theme.font(13)).foregroundStyle(hover || active ? Theme.text : Theme.dim)
                    .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!ready).opacity(ready ? 1 : 0.5)
            .help(group).accessibilityLabel("Choose a slot for \(item.name)")
            .accessibilityIdentifier("libitem-\(item.factory ? "factory" : "user")-\(item.index)")
            PreviewButton(item: item)
        }
        .padding(.leading, 9).padding(.trailing, 4).frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: 5).fill(active ? Theme.raised : (hover ? Theme.raisedHi : Theme.raised))
                .overlay { if active { RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(0.15)) } }
                .overlay(alignment: .leading) { if active { Rectangle().fill(Theme.focus).frame(width: 2).padding(.vertical, 1) } }
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? Theme.focus : (hover ? Color(hex: 0x3A3A3A) : Theme.lineSoft)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            let busy = store.uploading || store.auditions.capture.busy || a.busy
            Button(active ? "Stop preview" : "Preview") { toggle() }.disabled(!ready || busy)
            Button("Load into slot…") { choose() }.disabled(!ready || store.uploading)
            if !item.factory {
                Divider()
                Button("Delete…", role: .destructive) { store.requestIRDelete(item.ref) }.disabled(!ready || busy)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librow-\(item.factory ? "factory" : "user")-\(item.index)")
    }
    private func choose() { store.slotChooser = PedalStore.SlotChoice(kind: .cab, name: item.name, factory: item.factory, index: item.index) }
    private func toggle() { Task { if store.auditions.ir.isActive(item) { await store.stopIRPreview() } else { await store.startIRPreview(item.ref) } } }
}

/// `.library-preview`: 26-point square, ▶ to audition, ■ while it plays, … while it starts.
private struct PreviewButton: View {
    @Environment(PedalStore.self) private var store
    let item: IRKey
    @State private var hover = false
    var body: some View {
        let a = store.auditions.ir, active = a.isActive(item), pending = a.isPending(item)
        let enabled = store.connected && store.library != nil && !a.busy
        Button {
            Task { if active { await store.stopIRPreview() } else { await store.startIRPreview(item.ref) } }
        } label: {
            Group {
                if pending { Text("…").font(.system(size: 15)) }
                else { PlayStopIcon(stop: active).frame(width: 12, height: 12) }
            }
            .foregroundStyle(active ? Color(hex: 0xE1DCFF) : Color(hex: 0xDDDDDD))
            .frame(width: 26, height: 26)
            .background {
                RoundedRectangle(cornerRadius: 4).fill(active ? Theme.raised : (hover && enabled ? Color(hex: 0x2C2C2C) : Color(hex: 0x242424)))
                    .overlay { if active { RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.2)) } }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(active ? Theme.accentHi : (hover && enabled ? Color(hex: 0x777777) : Color(hex: 0x414141))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
        .help(pending ? "Starting preview" : active && a.stopping ? "Stopping preview" : active ? "Stop preview" : "Audition without loading into a slot")
        .accessibilityLabel(active ? "Stop preview of \(item.name)" : "Preview \(item.name)")
        .accessibilityValue(active ? "playing" : "")
        .accessibilityIdentifier("libpreview-\(item.factory ? "factory" : "user")-\(item.index)")
    }
}

/// The SVG paths of `.library-preview-icon` (16-unit box): `M5 3v10l8-5z` (play) and `M4 3h8v10H4z` (stop).
private struct PlayStopIcon: Shape {
    let stop: Bool
    func path(in r: CGRect) -> Path {
        let s = r.width / 16
        var p = Path()
        if stop { p.addRect(CGRect(x: 4 * s, y: 3 * s, width: 8 * s, height: 10 * s)) }
        else { p.move(to: CGPoint(x: 5 * s, y: 3 * s)); p.addLine(to: CGPoint(x: 5 * s, y: 13 * s)); p.addLine(to: CGPoint(x: 13 * s, y: 8 * s)); p.closeSubpath() }
        return p
    }
}

// MARK: confirmations

/// The sheets of this feature set, on the window (ContentView): a Cloud IR send, an IR delete.
struct AuditionSheets: ViewModifier {
    @Environment(PedalStore.self) private var store
    func body(content: Content) -> some View {
        @Bindable var auditions = store.auditions
        content
            .sheet(item: $auditions.irSend, onDismiss: { if store.auditions.irSendAnswer != nil { store.answerIRSend(false) } }) { IRSendSheet(prompt: $0) }
            .sheet(item: $auditions.irDelete) { IRDeleteSheet(prompt: $0) }
    }
}

/// "Send X to the pedal?" for a Cortex Cloud IR (pro/ui.js `receiveCloudIR`).
private struct IRSendSheet: View {
    @Environment(PedalStore.self) private var store
    let prompt: IRSendPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Send \(prompt.name) to the pedal?").padding(.bottom, 8)
            ModalText(String(format: "%.1f KB over Bluetooth. This adds it to “IRs on pedal”; it does not change any preset slot.", Double(prompt.bytes) / 1024)).padding(.bottom, 18)
            HStack(spacing: 8) { Spacer()
                Button("Cancel") { store.answerIRSend(false) }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Send IR") { store.answerIRSend(true) }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.modalPanel(width: 440)
    }
}

/// "Delete IR “X” from the pedal?" (pro/ui.js `deleteLibraryIR`).
private struct IRDeleteSheet: View {
    @Environment(PedalStore.self) private var store
    let prompt: IRDeletePrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Delete IR “\(prompt.item.name)” from the pedal?").padding(.bottom, 8)
            ModalText(prompt.detail).padding(.bottom, 18)
            HStack(spacing: 8) { Spacer()
                Button("Cancel") { store.auditions.irDelete = nil }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Delete") { let item = prompt.item; Task { await store.deleteLibraryIR(item) } }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }.modalPanel(width: 440)
    }
}
