// Reordering presets by drag and drop, ported from the Electron edition (pro/ui.js "preset reordering", contributed
// in its #14; PROTOCOL-NOTES §14). Drag a preset row onto another: 143 {1:4 3:from 4:to} (0-based, absolute, an
// insertion), acked by 144 {1:6 3:from 4:to 5:1}; then the preset list and the current state are read back like at
// connect, so the order, the current preset and the footswitch slots shown are the pedal's, never assumed. If that
// state read fails the current preset is unknown, and Save, Save as, Discard and Rename stay off until a read works.

import SwiftUI
import Observation
import UniformTypeIdentifiers
import NanoCore

@MainActor @Observable
final class ReorderState {
    /// A move is running (from the click on the drop to the read-back): rows dim, drags are off.
    var moving = false
    /// Between the 143 and the read-back: the pedal's 115s are not edits then.
    @ObservationIgnored var awaitingMove = false
    /// The row a drag started on (only drags that start on the list count) and the row under it.
    var dragSource: Int?
    var dropTarget: Int?
    /// The "Save changes to …?" prompt for a move with unsaved edits.
    var prompt: PendingMove?
    @ObservationIgnored var answer: CheckedContinuation<String, Never>?
    var knowledge = PresetKnowledge()
    @ObservationIgnored var dragWatch: Task<Void, Never>?
    /// The last move's outcome (dev remote).
    @ObservationIgnored var last: [String: Any] = [:]

    struct PendingMove: Identifiable, Equatable { let id = UUID(); var from: Int; var to: Int }

    func beginDrag(_ index: Int) {
        dragSource = index; dropTarget = nil
        // SwiftUI says nothing when a drag ends without a drop: watch the mouse button instead.
        dragWatch?.cancel()
        dragWatch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(80)) }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.endDrag()
        }
    }
    func endDrag() { dragWatch?.cancel(); dragWatch = nil; dragSource = nil; dropTarget = nil }
    func resolve(_ choice: String) { prompt = nil; answer?.resume(returning: choice); answer = nil }
    func reset() { endDrag(); resolve("cancel"); moving = false; awaitingMove = false; knowledge.reset(); last = [:] }
}

extension PedalStore {
    /// Rows can be dragged: connected, no move running, no slot usage scan.
    var canReorder: Bool { connected && session != nil && !reorder.moving && scanning == nil }


    /// Moves preset `from` to position `to` (0-based, absolute). Only from an explicit user drag (or the dev remote).
    @discardableResult
    func movePreset(from: Int, to: Int) async -> Bool {
        guard from != to, !reorder.moving else { return false }
        guard let session, connected else { toast(ReorderRefusal.notConnected.message); return false }
        let inFlight = await session.isBusy || uploading || pendingPreset != nil || pendingAssignment != nil || saveAsOpen || deleteTarget != nil
        if let refusal = ReorderRefusal.check(connected: true, scanning: scanning != nil, operationInFlight: inFlight) {
            toast(refusal.message); append("Preset reorder refused: \(refusal.message)")
            return false
        }
        reorder.moving = true
        reorder.last = ["from": from, "to": to]
        defer { reorder.moving = false; reorder.awaitingMove = false }
        guard await prepareForPresetChange("the reorder"), await askBeforeReorder(from: from, to: to), connected, let session = self.session else {
            reorder.last["result"] = "cancelled"
            return false
        }
        let before = presetNames
        reorder.awaitingMove = true
        var reply: PresetMove.Reply?
        do { reply = try await session.movePreset(from: from, to: to) } catch { append("Preset reorder: \(error)") }
        let ackOk = reply?.confirms(from: from, to: to) == true
        append("Preset reorder \(ackOk ? "acknowledged" : "NOT confirmed"): type 144 " + (reply.map { "source=\($0.from) destination=\($0.to) status=\($0.status)" } ?? "no reply"))
        // Read back whatever happened, confirmed or not: the pedal's order and its current preset are the truth.
        let (listed, read) = await rereadAfterMove()
        reorder.awaitingMove = false
        append("Preset reorder read-back: list=\(listed), state=\(read)")
        if listed, ackOk {
            let expected = PresetOrder.apply(before, from: from, to: to)
            append(presetNames == expected ? "Preset order read back as an insertion of \(from + 1) at \(to + 1)" : "Preset order read back differs from an insertion of \(from + 1) at \(to + 1)")
        }
        if !read { reorder.knowledge.moveReadFailed() }
        usage = nil   // the scan's preset numbers are stale now
        reorder.last.merge(["ack": ackOk, "listed": listed, "read": read]) { $1 }
        if !ackOk {
            finish("The pedal did not confirm the move. " + (listed ? "The list shows its order as it is now." : "Its order could not be read either: Refresh to see it.") + (read ? "" : " " + PresetKnowledge.message))
            return false
        }
        if !listed || !read {
            finish("Preset moved, but " + (!listed ? "the preset list could not be read again (Refresh to see the order)" : "the current preset could not be read again") + "." + (read ? "" : " " + PresetKnowledge.message))
            return false
        }
        finish("Moved preset \(from + 1) to position \(to + 1).")
        return true
    }
    private func finish(_ message: String) { toast(message); reorder.last["toast"] = message }

    /// The preset list and the state again, the way a connect reads them (the metadata read, then the state).
    private func rereadAfterMove() async -> (listed: Bool, read: Bool) {
        guard let session else { return (false, false) }
        var listed = false, read = false
        do { metadata = try await session.requestMetadata(); listed = true } catch { append("Preset list read after the move failed: \(error)") }
        do { let st = try await session.requestState(); await applyState(st, presetLoad: true); read = true } catch { append("State read after the move failed: \(error)") }
        return (listed, read)
    }

    /// Edits are dropped when the pedal moves presets around (the phone app asks first, too).
    private func askBeforeReorder(from: Int, to: Int) async -> Bool {
        guard dirtyForPrompt else { return true }
        let current = presetIndex
        let choice = await withCheckedContinuation { c in
            reorder.answer = c
            reorder.prompt = .init(from: from, to: to)
        }
        append("Reorder prompt (unsaved edits): \(choice == "save" ? "Save and reorder" : choice == "discard" ? "Don’t save" : "Cancel")")
        switch choice {
        case "save":
            guard await save(), !dirty else { toast("Save the current preset before reordering."); return false }
            return true
        case "discard":
            guard let session else { return false }
            do {
                let st = try await session.selectPreset(index: current)
                await applyState(st, presetLoad: true)
                return true
            } catch { toast("The pedal did not confirm reloading the saved preset."); return false }
        default:
            return false
        }
    }

    func resetReorder() { reorder.reset() }

    /// Save, Save as, Discard and Rename act on "the current preset": not while it is unknown.
    func refuseIfPresetUnknown() -> Bool {
        guard !reorder.knowledge.allowsCurrentPresetActions else { return false }
        toast(PresetKnowledge.message)
        return true
    }
}

// MARK: - drag and drop

enum PresetDrag {
    /// Declared in project.yml (UTExportedTypeDeclarations); only rows of this list put it on the drag pasteboard.
    static let identifier = "com.community.nanocortex.preset-row"
    static let type = UTType(exportedAs: identifier, conformingTo: .data)
}

/// A preset row as a drag source and drop target: dims while dragged (`.preset-row.dragging`, .45), a focus outline on
/// the row under the pointer (`.drop-target`), .7 while a move runs (`.reorder-pending`).
struct PresetRowReorder: ViewModifier {
    @Environment(PedalStore.self) private var store
    let index: Int
    func body(content: Content) -> some View {
        let r = store.reorder
        let styled = content
            .opacity(r.dragSource == index ? 0.45 : r.moving ? 0.7 : 1)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(r.dropTarget == index && r.dragSource != index ? Theme.focus : .clear))
            .onDrop(of: [PresetDrag.type], delegate: PresetDropDelegate(store: store, target: index))
        if store.canReorder {
            styled.onDrag {
                store.reorder.beginDrag(index)
                let p = NSItemProvider()
                p.registerDataRepresentation(forTypeIdentifier: PresetDrag.identifier, visibility: .ownProcess) { done in
                    done(Data("\(index)".utf8), nil); return nil
                }
                p.suggestedName = store.presetName(index)
                return p
            }
        } else {
            styled
        }
    }
}

private struct PresetDropDelegate: DropDelegate {
    let store: PedalStore
    let target: Int
    @MainActor private var accepts: Bool { store.reorder.dragSource != nil && store.canReorder }
    func validateDrop(info: DropInfo) -> Bool { MainActor.assumeIsolated { accepts } && info.hasItemsConforming(to: [PresetDrag.type]) }
    func dropEntered(info: DropInfo) { MainActor.assumeIsolated { if accepts { store.reorder.dropTarget = target } } }
    func dropExited(info: DropInfo) { MainActor.assumeIsolated { if store.reorder.dropTarget == target { store.reorder.dropTarget = nil } } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: validateDrop(info: info) ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let source = store.reorder.dragSource, accepts, let provider = info.itemProviders(for: [PresetDrag.type]).first else { store.reorder.endDrag(); return false }
            store.reorder.endDrag()
            guard let move = PresetOrder.move(source: source, target: target, count: max(64, store.presetNames.count)) else { return false }
            // The payload must name the row this drag started on (text dropped from elsewhere never gets here: wrong type).
            _ = provider.loadDataRepresentation(forTypeIdentifier: PresetDrag.identifier) { data, _ in
                let named = data.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                Task { @MainActor in
                    guard named == source else { store.append("Preset drop ignored: the drag didn't start on preset \(source + 1)"); return }
                    await store.movePreset(from: move.from, to: move.to)
                }
            }
            return true
        }
    }
}

/// "Save changes to X?" before a move with unsaved edits (Electron's askBeforePresetReorder).
struct ReorderPrompt: View {
    @Environment(PedalStore.self) private var store
    let pending: ReorderState.PendingMove
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Save changes to \(store.presetName(store.presetIndex))?").padding(.bottom, 8)
            ModalText("Reordering presets can discard edits that haven’t been saved to the pedal.").padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.reorder.resolve("cancel") }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Don’t save") { store.reorder.resolve("discard") }.buttonStyle(ThemedButton())
                Button("Save and reorder") { store.reorder.resolve("save") }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .modalPanel(width: 420)
        .accessibilityIdentifier("reorderPrompt")
    }
}

extension View {
    /// The move prompt, on the sidebar.
    func reorderPrompt(_ store: PedalStore) -> some View {
        sheet(item: Binding(get: { store.reorder.prompt }, set: { if $0 == nil, store.reorder.prompt != nil { store.reorder.resolve("cancel") } })) { ReorderPrompt(pending: $0) }
    }
}
