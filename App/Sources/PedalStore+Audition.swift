// Auditions, Cortex Cloud IRs and deleting a library IR, on the store (parity with the Electron edition's pro/ui.js,
// contributed there in PR #14). Two ways to hear something on the pedal without storing it: a Cortex Cloud capture
// (150 → 151, Live Preview in the Cloud toolbar) and a library cab or IR (158 → 159, ▶ in the Cab / IR inspector).
// Both end with 148 → 149 and are kept alive with 91 every 20 s. Anything that saves or changes the preset stops them
// first (`stopAnyAudition`); if the pedal doesn't confirm the stop, the action doesn't happen.

import Foundation
import Observation
import NanoCore

/// The audition and Cloud IR state the views read (one object on the store, so the store file stays small).
@MainActor @Observable
final class AuditionCenter {
    var capture = CapturePreviewState()
    var ir = IRAuditionState()
    /// The Cab / IR inspector's "From the library" search; kept when the inspector shows another block.
    var librarySearch = ""
    /// "Send X to the pedal?" for a Cloud IR, and "Delete IR X from the pedal?".
    var irSend: IRSendPrompt?
    var irDelete: IRDeletePrompt?
    /// The cab slot the Cloud toolbar's IR: Off left, so IR: On returns to it.
    var lastCabSlot: Int?
    /// The last Cloud IR transfer's outcome (dev remote).
    var lastCloudIR: CloudIROutcome?
    var keepAliveRunning: Bool { keepAlive != nil }
    @ObservationIgnored var keepAlive: Task<Void, Never>?
    @ObservationIgnored var keepAliveInterval: Duration = .seconds(Audition.keepAliveSeconds)
    @ObservationIgnored var irSendAnswer: CheckedContinuation<Bool, Never>?
}

struct IRSendPrompt: Identifiable { let id = UUID(); let name: String; let bytes: Int }
struct IRDeletePrompt: Identifiable { let id = UUID(); let item: IRRef; let detail: String }

/// A Cloud IR download, checked (CloudIR.swift): the WAV, its product id and the name and file name the pedal gets.
struct CloudIRBundle: Sendable { var wav: [UInt8]; var productId: String; var name: String; var filename: String }

/// What the Cloud page's Send to Nano button shows afterwards (On Nano, Sent, Cancelled or Retry).
struct CloudIROutcome: Equatable, Sendable {
    var ok = false, cancelled = false, alreadyOnNano = false, refreshed = false
    var index = 0
    var name = ""
    var error = ""
    var dictionary: [String: Any] {
        ["ok": ok, "cancelled": cancelled, "alreadyOnNano": alreadyOnNano, "refreshed": refreshed, "index": index,
         "name": String(name.prefix(256)), "error": String(error.prefix(500))]
    }
}

extension IRRef { var key: IRKey { IRKey(factory: factory, index: index, name: name) } }
extension IRKey { var ref: IRRef { IRRef(factory: factory, index: index, name: name) } }

/// Plain words for transfer errors (the toasts and the log).
func transferMessage(_ error: Error) -> String {
    switch error {
    case let e as StreamError: e.description
    case let e as IRError: e.message
    case TransportError.notConnected: "Not connected"
    case TransportError.timeout(let what): "The pedal did not answer \(what) in time"
    case is CancellationError: "Cancelled"
    default: error.localizedDescription
    }
}

extension PedalStore {
    /// Something plays, starts or stops.
    var auditioning: Bool { auditions.capture.phase != .idle || auditions.ir.auditioning }

    // MARK: the gate

    /// Ends any audition before `action` (Save, the preset switch, …); false, with a toast saying why, when the action
    /// must not happen.
    func stopAnyAudition(_ action: String) async -> Bool {
        if let refusal = await auditionRefusal(action) { toast(refusal); return false }
        return true
    }
    /// The same, for sheets that show the reason themselves: nil = go ahead.
    func auditionRefusal(_ action: String) async -> String? {
        let verdict = await AuditionGate.check(action: action, capture: auditions.capture, ir: auditions.ir,
                                               stopCapture: { await self.stopCapturePreview(quiet: true) },
                                               stopIR: { await self.stopIRPreview(quiet: true) })
        if case .refused(let why) = verdict { append("Refused \(action): \(why)"); return why }
        return nil
    }
    /// The hook a preset reorder (and anything else that moves or changes presets) awaits first.
    func prepareForPresetChange(_ action: String = "the reorder") async -> Bool { await stopAnyAudition(action) }

    // MARK: keep-alive (91 → 92 every 20 s while anything plays)

    func startKeepAlive() {
        guard auditions.keepAlive == nil else { return }
        let interval = auditions.keepAliveInterval
        append("Live preview keep-alive started (every \(Int(interval.components.seconds)) s).")
        auditions.keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.sendKeepAlive()
            }
        }
    }
    /// One keep-alive now (the timer's tick; the dev remote's `/audition?keepalive=1`).
    func sendKeepAlive() async {
        guard auditions.capture.playing || auditions.ir.active != nil, let session else { return }
        do {
            let accepted = try await session.previewKeepAlive()
            append("Live preview keep-alive " + (accepted ? "acknowledged." : "was not accepted."))
        } catch { append("ERROR: Preview keep-alive: \(transferMessage(error))") }
    }
    func stopKeepAlive() {
        guard let task = auditions.keepAlive else { return }
        task.cancel()
        auditions.keepAlive = nil
        append("Live preview keep-alive stopped.")
    }
    private func stopKeepAliveIfIdle() { if !auditions.capture.playing && auditions.ir.active == nil { stopKeepAlive() } }

    // MARK: library IR audition (158 → 159)

    /// Plays a library cab or IR on the pedal without loading it into a slot. A new one replaces the one playing.
    @discardableResult
    func startIRPreview(_ item: IRRef) async -> Bool {
        guard connected, let session, library != nil, !item.name.isEmpty else { return false }
        if auditions.ir.busy || auditions.capture.busy || uploading { return false }
        if await session.streamBusy != nil { return false }
        if auditions.capture.phase == .active, !(await stopCapturePreview(quiet: true)) {
            toast("The live preview could not be stopped, so \(item.name) was not previewed.")
            return false
        }
        auditions.ir.busy = true; auditions.ir.pending = item.key; auditions.ir.stopping = false
        defer { auditions.ir.busy = false; auditions.ir.pending = nil }
        do {
            let reply = try await session.previewIR(item)
            guard reply.ok else {
                append("IR preview rejected: type 159 index=\(item.index) status=\(reply.status)")
                toast("The pedal did not accept the IR preview.")
                return false
            }
            auditions.ir.active = item.key
            startKeepAlive()
            append("IR preview accepted: type 159 index=\(item.index) status=\(reply.status)")
            return true
        } catch {
            append("ERROR: IR preview: \(transferMessage(error))")
            toast("IR preview failed: \(transferMessage(error))")
            return false
        }
    }

    /// True once the pedal confirmed the stop (149 with this transaction and status 1). Otherwise nothing changes: the
    /// IR may still be playing, so it stays marked active and the keep-alive keeps running.
    @discardableResult
    func stopIRPreview(quiet: Bool = false) async -> Bool {
        guard auditions.ir.active != nil else { return !auditions.ir.busy }
        guard !auditions.ir.busy, connected, let session else { return false }
        auditions.ir.busy = true; auditions.ir.stopping = true
        let (confirmed, error) = await stop(.ir, on: session)
        auditions.ir.busy = false; auditions.ir.stopping = false
        guard confirmed else {
            if !quiet { toast("The pedal did not confirm stopping the IR preview" + (error.isEmpty ? "." : ": \(error)") + " It may still be playing.") }
            return false
        }
        auditions.ir.active = nil
        stopKeepAliveIfIdle()
        await refreshState()   // as the official app does after a stop; the pedal may then report the preset dirty
        return true
    }

    /// 148 → 149: confirmed only by this stop's transaction with status 1.
    private func stop(_ kind: AuditionKind, on session: Session) async -> (confirmed: Bool, error: String) {
        let tx = Audition.nextTransaction()
        let what = kind == .ir ? "IR" : "Capture"
        do {
            let r = try await session.stopAudition(kind, transaction: tx)
            let ok = Audition.stopConfirmed(r, transaction: tx)
            append("\(what) preview stop " + (ok ? "confirmed" : "NOT confirmed (status \(r.status), transaction \(r.transaction.map(String.init) ?? "none"))") + " (\(tx))")
            return (ok, "")
        } catch {
            append("ERROR: stopping \(what.lowercased()) preview: \(transferMessage(error))")
            return (false, transferMessage(error))
        }
    }

    // MARK: Cloud capture preview (150 → 151)

    /// Live Preview: `fetch` downloads the capture with the Cloud session (or reads a file, dev remote), then it streams
    /// as a preview. Nothing is stored on the pedal. Returns why it didn't start, or nil. The toolbar follows
    /// `auditions.capture`, whose every exit lands in idle or active.
    func startCapturePreview(fetch: @MainActor () async throws -> CaptureBundle) async -> String? {
        guard connected, let session else { return "Connect your Nano Cortex first, then preview this capture." }
        let streaming = await session.streamBusy != nil
        if uploading || streaming { return "Another transfer to the pedal is still running. Try again when it has finished." }
        if auditions.capture.busy || auditions.ir.busy { return "Wait for the current preview to start or stop, then try again." }
        guard auditions.capture.beginStart() else { return "Stop the live preview first." }
        func refuse(_ why: String) -> String { auditions.capture.finishStart(accepted: false, error: why); lastAction = ""; return why }

        let bundle: CaptureBundle
        do { bundle = try await fetch() } catch { return refuse("Could not fetch the capture for preview: \(transferMessage(error))") }
        let name = bundle.record.name
        auditions.capture.named(name)
        if auditions.ir.active != nil, !(await stopIRPreview(quiet: true)) { return refuse("The IR preview could not be stopped, so \(name) was not previewed.") }
        guard connected else { return refuse("Connect your Nano Cortex first, then preview \(name).") }

        lastAction = "Preparing live preview: \(name)"
        let reply: Audition.Reply
        do {
            reply = try await session.previewCapture(cns: bundle.cns, record: bundle.record) { [weak self] i, n in
                Task { @MainActor in if self?.auditions.capture.phase == .preparing { self?.lastAction = "Previewing \(name): sending \(i) / \(n)" } }
            }
        } catch { return refuse("Live preview failed: \(transferMessage(error))") }
        lastAction = ""
        guard reply.ok, connected else {
            append("Capture preview REFUSED: \"\(name)\"")
            return refuse(connected ? "The pedal refused the live preview" + (reply.message.isEmpty ? "." : ": \(reply.message)") : "The Nano Cortex disconnected; live preview stopped.")
        }
        append("Capture preview accepted: \"\(reply.name.isEmpty ? name : reply.name)\"")
        auditions.capture.finishStart(accepted: true)
        guard auditions.capture.phase == .active else { return nil }   // a disconnect ended it meanwhile
        startKeepAlive()
        toast("Previewing \(name). Click Stop Preview to end it.")
        return nil
    }

    /// True once the pedal confirmed the stop. Otherwise the preview stays marked active (it may still be playing), the
    /// keep-alive keeps running and the toolbar shows Stop Preview again, with the reason.
    @discardableResult
    func stopCapturePreview(quiet: Bool = false) async -> Bool {
        guard auditions.capture.phase == .active else { return !auditions.capture.busy }
        guard connected, let session else { return false }
        _ = auditions.capture.beginStop()
        lastAction = "Stopping live preview"
        let (confirmed, error) = await stop(.capture, on: session)
        lastAction = ""
        guard confirmed else {
            let why = "The pedal did not confirm stopping the live preview" + (error.isEmpty ? "." : ": \(error)") + " It may still be playing."
            auditions.capture.finishStop(confirmed: false, error: quiet ? "" : why)
            if !quiet { toast(why) }
            return false
        }
        auditions.capture.finishStop(confirmed: true)
        stopKeepAliveIfIdle()
        if !quiet { toast("Live preview stopped.") }
        return true
    }

    // MARK: endings the user didn't ask for

    /// The pedal switched presets itself (footswitch) during an audition: the stops go out (best effort) and the
    /// auditions are forgotten, so the keep-alive stops and nothing shows an audition of the old preset.
    func endAuditionsAfterPedalPresetChange() {
        guard auditions.capture.playing || auditions.ir.active != nil else { return }
        append("The pedal changed presets during a preview; ending the preview.")
        if let session {
            for kind in [auditions.capture.playing ? AuditionKind.capture : nil, auditions.ir.active != nil ? .ir : nil].compactMap({ $0 }) {
                Task { [weak self] in
                    do { _ = try await session.stopAudition(kind, transaction: Audition.nextTransaction()) }
                    catch { self?.append("Preview stop after a preset change: \(transferMessage(error))") }
                }
            }
        }
        auditions.capture.endPlaying()
        auditions.ir.active = nil
        stopKeepAlive()
        toast("The pedal switched presets, so the preview ended.")
    }

    /// The link is gone: nothing plays any more.
    func endAuditionsOnDisconnect() {
        let capture = auditions.capture.phase != .idle, ir = auditions.ir.auditioning
        stopKeepAlive()
        auditions.capture.end(error: capture ? "The Nano Cortex disconnected; live preview stopped." : "")
        auditions.ir = IRAuditionState()
        if ir { append("IR preview ended because the Nano Cortex disconnected.") }
        if auditions.irSend != nil { answerIRSend(false) }
        auditions.irDelete = nil
    }

    // MARK: the Cloud toolbar's IR: On / Off

    /// Turns the current preset's cab on or off (to hear a previewed capture with or without it); back on, it returns to
    /// the slot it had.
    func toggleCabIR() -> String? {
        guard connected else { return "Connect your Nano Cortex before toggling Cab / IR." }
        if cab.on {
            if cab.slot > 0 { auditions.lastCabSlot = cab.slot }
            selectCab(slot: 0)
        } else {
            selectCab(slot: auditions.lastCabSlot ?? max(1, cab.slot))
        }
        return nil
    }

    // MARK: Cortex Cloud IR → the pedal's IR library (15 → 16)

    /// The rest of a Send to Nano click once the WAV is downloaded and checked: refusals, the duplicate check, the
    /// confirmation, the transfer, the library re-read. Never retried by itself; the page's button offers Retry.
    func receiveCloudIR(_ bundle: CloudIRBundle) async -> CloudIROutcome {
        let name = bundle.name.isEmpty ? "Cloud impulse response" : bundle.name
        var outcome = CloudIROutcome(name: name)
        func fail(_ why: String) -> CloudIROutcome {
            toast(why); append("Cloud IR: \(why)")
            outcome.error = why; auditions.lastCloudIR = outcome
            return outcome
        }
        tab = .editor
        guard connected, let session else { return fail("Connect your Nano Cortex first, then send \(name) again.") }
        let streaming = await session.streamBusy != nil
        if uploading || streaming { return fail("Another transfer to the pedal is still running. Try again when it has finished.") }
        if auditioning { return fail("Stop the active preview before sending a Cloud IR.") }
        guard let lib = await ensureLibrary() else { return fail("Could not read the Nano Cortex IR library. Refresh it and try again.") }
        if let existing = (lib.userIRs + lib.factoryIRs).first(where: { IRTransfer.sameName($0.name, name) }) {
            toast("\(existing.name) is already in IRs on pedal.")
            outcome = CloudIROutcome(ok: true, alreadyOnNano: true, refreshed: true, index: existing.index, name: existing.name)
            auditions.lastCloudIR = outcome
            return outcome
        }
        // The download was checked (CloudIR.swift / the dev remote); these guard the hand-over.
        guard bundle.wav.count <= IRTransfer.maxBytes else { return fail("Cloud IR transfer failed: The IR is larger than 1 MB.") }
        do { _ = try WAVCheck.check(bundle.wav) } catch { return fail("Cloud IR transfer failed: \(transferMessage(error))") }
        guard IRTransfer.isProductId(bundle.productId), bundle.filename.lowercased().hasSuffix(".wav") else {
            return fail("Cloud IR transfer failed: The Cloud IR download is missing its product ID or WAV filename.")
        }

        guard await askIRSend(IRSendPrompt(name: name, bytes: bundle.wav.count)) else {
            outcome.cancelled = true; auditions.lastCloudIR = outcome
            append("Cloud IR \"\(name)\": cancelled")
            return outcome
        }
        guard connected else { return fail("Connect your Nano Cortex first, then send \(name) again.") }
        uploading = true
        lastAction = "Sending IR \(name)"
        let reply: IRTransfer.Reply
        do {
            reply = try await session.uploadIR(wav: bundle.wav, productId: bundle.productId, filename: bundle.filename, name: name) { [weak self] i, n in
                Task { @MainActor in if self?.uploading == true { self?.lastAction = "Sending IR \(name): \(i) / \(n)" } }
            }
        } catch {
            uploading = false; lastAction = ""
            return fail("Cloud IR transfer failed: \(transferMessage(error))")
        }
        uploading = false; lastAction = ""
        let pedalName0 = reply.name.isEmpty ? name : reply.name
        append("Cloud IR download " + (reply.ok ? "accepted" : "REFUSED") + ": \"\(pedalName0)\" user IR index \(reply.index)" + (reply.message.isEmpty ? "" : " (\(reply.message))"))
        guard reply.ok else { return fail("The pedal refused \(name)" + (reply.message.isEmpty ? "." : ": \(reply.message)")) }

        // 16 gives the new user-IR index; read the library again so the inspector lists it right away.
        library = nil
        let refreshed = await ensureLibrary()
        let item = refreshed?.userIRs.first { $0.index == reply.index } ?? refreshed?.userIRs.first { IRTransfer.sameName($0.name, pedalName0) }
        let pedalName = item?.name ?? pedalName0
        toast(item != nil ? "\(pedalName) is now in IRs on pedal." : "\(pedalName) was sent to the pedal, but its IR list did not refresh. Use Refresh to reload it.")
        outcome = CloudIROutcome(ok: true, refreshed: item != nil, index: reply.index, name: pedalName)
        auditions.lastCloudIR = outcome
        return outcome
    }

    /// Shows "Send X to the pedal?" and waits for the answer (one prompt at a time; a newer one cancels the older).
    private func askIRSend(_ prompt: IRSendPrompt) async -> Bool {
        if auditions.irSendAnswer != nil { answerIRSend(false) }
        return await withCheckedContinuation { c in
            auditions.irSendAnswer = c
            auditions.irSend = prompt
        }
    }
    func answerIRSend(_ send: Bool) {
        auditions.irSend = nil
        let answer = auditions.irSendAnswer
        auditions.irSendAnswer = nil
        answer?.resume(returning: send)
    }

    // MARK: deleting a user IR (82 → 83)

    /// "Delete…" on one of your IRs: the confirmation, saying if a cab slot holds it.
    func requestIRDelete(_ item: IRRef) {
        guard connected, !item.factory else { return }
        Task {
            let streaming = await session?.streamBusy != nil
            if uploading || streaming || auditions.capture.busy || auditions.ir.busy { toast("Finish the current pedal action before deleting an IR."); return }
            let names = metadata?.irNames ?? []
            let slots = (1...cabSlotCount).filter { IRTransfer.sameName(names[safe: $0 - 1] ?? "", item.name) }
            let playing = cab.on ? cab.slot : 0
            let where_ = cab.on && cab.fromLibrary && IRTransfer.sameName(cab.name, item.name)
                ? " The current preset plays it straight from the library."
                : slots.isEmpty ? ""
                : " It is loaded in IR slot \(slots.map(String.init).joined(separator: " and "))" + (slots.contains(playing) ? ", which the current preset uses" : "")
                    + ". Check \(slots.count > 1 ? "those slots" : "that slot") afterwards."
            auditions.irDelete = IRDeletePrompt(item: item, detail: "This permanently removes the IR from the Nano Cortex library. There is no undo." + where_)
        }
    }

    /// The confirmed delete: the library is read again right before, and the index must still hold this IR (indices
    /// shift when an IR is added or removed); then 82 → 83 and the library again.
    func deleteLibraryIR(_ item: IRRef) async {
        auditions.irDelete = nil
        guard connected, let session, !item.factory else { return }
        guard await stopAnyAudition("deleting the IR") else { return }
        uploading = true
        lastAction = "Checking the pedal library…"
        library = nil
        let before = await ensureLibrary()
        let current = before?.userIRs.first { $0.index == item.index }
        let same = current.map { IRTransfer.sameName($0.name, item.name) } ?? false
        var deleted = false
        if let current, same {
            lastAction = "Deleting IR \(current.name)"
            do { deleted = try await session.deleteIR(index: current.index, name: current.name) }
            catch { append("ERROR: deleting IR \(current.name): \(transferMessage(error))") }
        }
        uploading = false
        lastAction = ""
        guard let current, same else {
            toast(before != nil ? "The pedal’s IR library changed: “\(item.name)” is no longer where it was. Nothing was deleted."
                                : "Could not read the pedal’s IR library, so nothing was deleted. Try again.")
            return
        }
        guard deleted else { toast("The pedal did not confirm deleting \(current.name)."); return }
        append("Deleted IR \"\(current.name)\" (user IR \(current.index)) from the pedal")
        library = nil
        let refreshed = await ensureLibrary()
        if refreshed == nil, var lib = before { lib.userIRs.removeAll { $0.index == current.index }; library = lib }
        toast(refreshed != nil ? "\(current.name) deleted from the pedal IR library." : "\(current.name) deleted, but the pedal IR list could not be refreshed.")
    }
}
