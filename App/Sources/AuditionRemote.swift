// Dev remote endpoints for auditions, Cloud IRs and the IR delete (debug builds only; DevRemote.swift hands them the
// paths it doesn't know). Demo-mode simulations stand in for the website: `/cloudir?file=` takes a local WAV as if
// Send to Nano had downloaded it, `/preview?file=` a saved capture download (the `/sendfile` format).
//   /audition                        state: capture preview, IR audition, keep-alive, the demo pedal's audition
//   /audition?ir=<name>&kind=factory|user[&index=]   ▶ on a library item (index defaults to the library's)
//   /audition?stop=1                 ■ (the IR)       keepalive=1 one keep-alive now   interval=<s> keep-alive period
//   /audition?refuse=1|0             demo: the pedal refuses (status 0) or confirms every stop
//   /audition?gate=<action>          runs the gate (stopAnyAudition) like Save would, without the action
//   /preview?file=<download json>    Live Preview from a file; id=<uuid> from Cortex Cloud; stop=1 Stop Preview
//   /cloudir?file=<wav>&name=&id=    a downloaded Cloud IR; confirm=send|cancel answers the prompt; choice= answers a
//                                    pending one; status=1 the last outcome
//   /irdelete?index=&name=           Delete… on a user IR (the confirmation); confirm=1 deletes without it
//   /irtoggle                        the Cloud toolbar's IR: On / Off
//   /toolbarshot?file=[&full=1]      the window's top 44 points only (the tab bar), so a Cloud page never ends up in it;
//                                    full=1 with the traffic lights (the title bar darkens it when the window isn't key)
//   /audition?delay=<ms>             demo: the pedal answers that late;  pedalpreset=<0-based> a footswitch preset change
#if DEBUG
import AppKit
import NanoCore

@MainActor
enum AuditionRemote {
    static func handle(_ path: String, _ q: (String) -> String?, store: PedalStore, cloud: CloudController) async -> [String: Any]? {
        let a = store.auditions
        switch path {
        case "/audition":
            if let v = q("refuse"), let pedal = store.demoPedal { let on = v == "1"; await pedal.mutate { $0.refuseAuditionStop = on } }
            if let s = Double(q("interval") ?? ""), s > 0 { a.keepAliveInterval = .milliseconds(Int(s * 1000)) }
            if let ms = UInt64(q("delay") ?? ""), let pedal = store.demoPedal { await pedal.setReplyDelay(ms) }
            if let n = Int(q("pedalpreset") ?? ""), let pedal = store.demoPedal {   // demo: a footswitch changes the preset on the pedal
                await pedal.mutate { $0.presetIndex = n }
                await pedal.notifyAsPedal(type: MessageType.setPresetSlots.rawValue, body: ProtoWriter().int(3, 0).int(4, UInt64(n)).build())
                try? await Task.sleep(for: .milliseconds(300))
            }
            var result: [String: Any] = [:]
            if let name = q("ir") {
                let factory = q("kind") != "user"
                let lib = await store.ensureLibrary()
                let index = Int(q("index") ?? "") ?? (factory ? lib?.factoryIRs : lib?.userIRs)?.first { IRTransfer.sameName($0.name, name) }?.index ?? -1
                result["started"] = index >= 0 ? await store.startIRPreview(IRRef(factory: factory, index: index, name: name)) : false
            }
            if q("stop") == "1" { result["stopped"] = await store.stopIRPreview() }
            if q("keepalive") == "1" { await store.sendKeepAlive() }
            if let action = q("gate") { result["gate"] = await store.stopAnyAudition(action) }
            return result.merging(await state(store), uniquingKeysWith: { a, _ in a })
        case "/preview":
            var result: [String: Any] = [:]
            if q("stop") == "1" { result["stopped"] = await store.stopCapturePreview() }
            else if let f = q("file") {
                let error = await store.startCapturePreview {
                    guard let data = FileManager.default.contents(atPath: f), let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let payload = j["payload"] as? String else { throw IRError("Not a capture download: \(f)") }
                    return try CaptureBundle.parse(payloadBase64: payload, name: j["name"] as? String, cloudId: "file")
                }
                result["error"] = error ?? ""
            } else if let id = q("id") {
                result["error"] = await store.startCapturePreview { try await cloud.fetchBundle(id: id) } ?? ""
            }
            return result.merging(await state(store), uniquingKeysWith: { a, _ in a })
        case "/cloudir":
            if q("status") == "1" { return ["outcome": a.lastCloudIR?.dictionary ?? [:], "prompt": a.irSend?.name ?? ""] }
            if let c = q("choice") { let had = a.irSend != nil; store.answerIRSend(c == "send"); return ["answered": had] }
            guard let f = q("file"), let data = FileManager.default.contents(atPath: f) else { return ["ok": false, "error": "file=<a local .wav>"] }
            // The checks the Cloud download gets (CloudIRBridge.fetch): the payload, at most 1 MB decoded, then the WAV.
            let wav: [UInt8]
            do { wav = try IRTransfer.decodePayload(data.base64EncodedString()); _ = try WAVCheck.check(wav) }
            catch { return ["ok": false, "error": transferMessage(error)] }
            let name = q("name") ?? URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent
            let bundle = CloudIRBridge.bundle(wav: wav, productId: q("id") ?? "00000000-0000-4000-8000-0000000000f1", name: name, listedName: name)
            a.lastCloudIR = nil
            let run = Task { await store.receiveCloudIR(bundle) }
            if let c = q("confirm") {
                for _ in 0..<100 where a.irSend == nil && a.lastCloudIR == nil { try? await Task.sleep(for: .milliseconds(20)) }
                if a.irSend != nil { store.answerIRSend(c == "send") }
                let outcome = await run.value
                return ["outcome": outcome.dictionary, "userIRs": store.library?.userIRs.map { "\($0.index) \($0.name)" } ?? []]
            }
            for _ in 0..<100 where a.irSend == nil && a.lastCloudIR == nil { try? await Task.sleep(for: .milliseconds(20)) }
            return ["prompt": a.irSend?.name ?? "", "outcome": a.lastCloudIR?.dictionary ?? [:]]
        case "/irdelete":
            guard let index = Int(q("index") ?? ""), let name = q("name") else { return ["ok": false, "error": "index=&name="] }
            let item = IRRef(factory: false, index: index, name: name)
            if q("confirm") == "1" { await store.deleteLibraryIR(item) }
            else {
                store.requestIRDelete(item)
                for _ in 0..<50 where a.irDelete == nil { try? await Task.sleep(for: .milliseconds(20)) }
            }
            return ["prompt": a.irDelete.map { ["title": "Delete IR “\($0.item.name)” from the pedal?", "detail": $0.detail] } ?? [:], "notice": store.notice ?? "",
                    "userIRs": store.library?.userIRs.map { "\($0.index) \($0.name)" } ?? []]
        case "/toolbarshot":
            guard let file = q("file"), let win = NSApp.windows.first(where: { $0.canBecomeMain && $0.contentView != nil }),
                  let view = q("full") == "1" ? (win.contentView?.superview ?? win.contentView) : win.contentView else { return ["ok": false] }
            let rect = NSRect(x: 0, y: view.bounds.height - TrafficLightCentering.barHeight, width: view.bounds.width, height: TrafficLightCentering.barHeight)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return ["ok": false] }
            view.cacheDisplay(in: rect, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return ["ok": false] }
            do { try png.write(to: URL(fileURLWithPath: file)); return ["ok": true, "file": file, "w": rep.pixelsWide, "h": rep.pixelsHigh] } catch { return ["ok": false, "error": "\(error)"] }
        case "/irtoggle":
            let error = store.toggleCabIR()
            try? await Task.sleep(for: .milliseconds(400))
            return ["error": error ?? "", "cabOn": store.cab.on, "cabSlot": store.cab.slot]
        default:
            return nil
        }
    }

    static func state(_ store: PedalStore) async -> [String: Any] {
        let a = store.auditions
        var out: [String: Any] = [
            "capture": ["phase": a.capture.phase.rawValue, "name": a.capture.name, "error": a.capture.error, "button": a.capture.buttonTitle],
            "ir": ["active": a.ir.active.map { "\($0.factory ? "factory" : "user") \($0.index) \($0.name)" } ?? "", "pending": a.ir.pending?.name ?? "", "busy": a.ir.busy],
            "keepAlive": a.keepAliveRunning, "notice": store.notice ?? "", "lastAction": store.lastAction, "presetIndex": store.presetIndex,
            "dirty": store.dirty, "edited": store.dirtyForPrompt, "cabOn": store.cab.on, "cabSlot": store.cab.slot,
        ]
        if let session = store.session { out["streamBusy"] = await session.streamBusy ?? "" }
        if let pedal = store.demoPedal { let s = await pedal.state; out["pedalAuditioning"] = s.auditioning ?? ""; out["refuseStop"] = s.refuseAuditionStop }
        return out
    }
}
#endif
