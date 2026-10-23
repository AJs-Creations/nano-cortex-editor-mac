// Dev remote endpoints for live pedal sync, monitoring and preset moves (debug builds only; DevRemote.swift routes here).
//   /live                      dump: dirty, dirtyForPrompt, in-flight edits, unknown preset, expression position, reports applied
//   /live?knob=gain|level|bass|mid|treble|capvol|gate&raw=0..255     a knob turned on the (demo) pedal: 26 + 115
//   /live?fx=pre1..post3&i=N&raw=0..255                             an FX parameter on the pedal: 99 + its 26 companion + 115
//   /live?bypass=pre1..post3&on=0|1                                  a footswitch / expression switch / MIDI CC bypass: 31 + 115
//   /live?exp=0..255  or  sweep=0-255&steps=8&ms=60                  the expression pedal: 64 (one position, or a sweep)
//   /live?state=N  (N bare 31 {1:1} in a row)   cab=1  (94)   dirty=0|1 (115)   type=&hex= (any frame from the pedal)
//   /live?drag=gain|capvol|gate&v=   …&release=1                     a knob drag in the app (reports for it wait until release)
//   /move?from=&to=  (0-based; choice=save|discard|cancel answers the prompt; async=1 returns at once; /move?choice= alone answers a prompt that is up)
//   /move?preview=from,to  shows the drag styling (source dimmed, outline on the target); preview=0 clears it
//   /move?hover=N  draws row N (0-based) as if the pointer were over it, with the ⋮⋮ grip; hover=-1 clears it
//   /mute?input=0|1&outputs=0|1  (read=1 re-reads 66)   /fakehooks?quiet=0|1&dropstate=0|1&refuse=0|1&delay=ms&reply=ms (demo pedal hooks)
//   /headless?view=main|settings&section=device&w=&h=&file=  renders the window's content (or Settings) into a window that
//                              is never ordered on screen, then closes it: screenshots of a test instance launched hidden
#if DEBUG
import Foundation
import AppKit
import SwiftUI
import NanoCore

extension DevRemote {
    func handlePort(_ path: String, _ q: (String) -> String?) async -> String {
        func json(_ v: Any) -> String { (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }

        let pedal = store.demoPedal
        switch path {
        case "/live":
            if let k = q("knob"), let raw = Int(q("raw") ?? "") {
                guard let pedal else { return json(["ok": false, "error": "demo only"]) }
                let c: LiveControl? = k == "capvol" ? .captureVolume : k == "gate" ? .gateReduction : AmpKnob(rawValue: k).map { .amp($0) }
                guard let c else { return json(["ok": false, "error": "knob=gain|level|bass|mid|treble|capvol|gate"]) }
                await pedal.turnOnPedal(c, raw: raw)
            }
            if let s = q("fx").flatMap(Slot.init(rawValue:)), let i = Int(q("i") ?? ""), let raw = Float(q("raw") ?? "") { await pedal?.turnFXOnPedal(s, index: i, raw: raw) }
            if let s = q("bypass").flatMap(Slot.init(rawValue:)) { await pedal?.bypassOnPedal(s, on: q("on") == "1") }
            if let p = Int(q("exp") ?? "") { await pedal?.expressionOnPedal(position: p) }
            if let sweep = q("sweep") {
                let ends = sweep.split(separator: "-").compactMap { Int($0) }
                let steps = max(1, Int(q("steps") ?? "") ?? 8), ms = Int(q("ms") ?? "") ?? 60
                if ends.count == 2 {
                    for n in 0...steps {
                        await pedal?.expressionOnPedal(position: ends[0] + (ends[1] - ends[0]) * n / steps)
                        try? await Task.sleep(for: .milliseconds(ms))
                    }
                }
            }
            if let n = Int(q("state") ?? "") { for _ in 0..<max(1, n) { await pedal?.notify(type: 31, body: [0x08, 0x01]) } }
            if q("cab") == "1" { await pedal?.notify(type: 94, body: [0x08, 0x01]) }
            if let d = q("dirty") { await pedal?.notify(type: 115, body: d == "1" ? [0x08, 0x01, 0x18, 0x01] : [0x08, 0x01]) }
            if let t = UInt32(q("type") ?? ""), let hex = q("hex") {
                await pedal?.notify(type: t, body: hex.split(separator: " ").compactMap { UInt8($0, radix: 16) })
            }
            if let k = q("drag") {
                let v = Double(q("v") ?? "")
                let commit = q("release") == "1"
                switch k {
                case "capvol": store.setCaptureVolume(v ?? store.captureVolumeDb, commit: commit)
                case "gate": store.setGateReduction(Int(v ?? Double(store.gateReduction)), commit: commit)
                default: if let a = AmpKnob(rawValue: k) { store.setAmp(a, Int(v ?? Double(store.amp[a] ?? 0)), commit: commit) }
                }
            }
            try? await Task.sleep(for: .milliseconds(Int(q("wait") ?? "250") ?? 250))
            return json(liveDump())
        case "/move":
            if let h = q("hover") {
                store.reorder.hoverPreview = Int(h).flatMap { $0 >= 0 ? $0 : nil }
                return json(["hover": store.reorder.hoverPreview ?? -1, "canReorder": store.canReorder, "gripShown": store.reorder.hoverPreview != nil && store.canReorder && store.reorder.dragSource == nil])
            }
            if let p = q("preview") {
                let ends = p.split(separator: ",").compactMap { Int($0) }
                if ends.count == 2 { store.reorder.dragSource = ends[0]; store.reorder.dropTarget = ends[1] } else { store.reorder.endDrag() }
                return json(["dragSource": store.reorder.dragSource ?? -1, "dropTarget": store.reorder.dropTarget ?? -1, "canReorder": store.canReorder])
            }
            if q("from") == nil, let choice = q("choice") {   // answers a prompt already up
                let up = store.reorder.prompt != nil
                store.reorder.resolve(choice)
                for _ in 0..<100 where store.reorder.moving { try? await Task.sleep(for: .milliseconds(50)) }
                var out: [String: Any] = ["answered": up, "presetIndex": store.presetIndex, "notice": store.notice ?? ""]
                for (k, v) in store.reorder.last { out["last." + k] = v }
                return json(out)
            }
            guard let from = Int(q("from") ?? ""), let to = Int(q("to") ?? "") else { return json(["ok": false, "error": "from=&to= (0-based)"]) }
            let task = Task { await store.movePreset(from: from, to: to) }
            if let choice = q("choice") {
                // Wait for the prompt (it only comes with unsaved edits), then answer it like its buttons do.
                var seen = false
                for _ in 0..<60 {
                    if store.reorder.prompt != nil { store.reorder.resolve(choice); break }
                    if store.reorder.moving { seen = true } else if seen { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            if q("async") == "1" {
                try? await Task.sleep(for: .milliseconds(Int(q("wait") ?? "150") ?? 150))
                return json(["moving": store.reorder.moving, "prompt": store.reorder.prompt != nil])
            }
            let ok = await task.value
            var out: [String: Any] = ["ok": ok, "presetIndex": store.presetIndex, "presetUnknown": store.reorder.knowledge.unknown,
                                      "notice": store.notice ?? "", "names": store.presetNames, "footswitch": footswitchDump()]
            for (k, v) in store.reorder.last { out["last." + k] = v }
            return json(out)
        case "/mute":
            if q("read") == "1" { await store.readMonitoring() }
            if let v = q("input") { store.setMute(.input, v == "1") }
            if let v = q("outputs") { store.setMute(.outputs, v == "1") }
            try? await Task.sleep(for: .milliseconds(Int(q("wait") ?? "300") ?? 300))
            var out: [String: Any] = ["input": store.monitor.input.map { $0 as Any } ?? NSNull(), "outputs": store.monitor.outputs.map { $0 as Any } ?? NSNull(),
                                      "pending": store.monitor.pending.map(\.rawValue), "error": store.monitor.error ?? "", "written": store.monitor.written,
                                      "dirty": store.dirty, "tuner": store.tunerOn]
            if let pedal { let s = await pedal.state; out["pedal"] = ["input": s.muteInput, "outputs": s.muteOutputs] }
            return json(out)
        case "/headless":
            guard let file = q("file") else { return json(["ok": false, "error": "file="]) }
            if let sec = q("section").flatMap(AppSettings.Section.init(rawValue:)) { AppSettings.shared.section = sec }
            let w = Double(q("w") ?? "") ?? 1400, h = Double(q("h") ?? "") ?? 900
            let settings = q("view") == "settings"
            let root = settings ? AnyView(SettingsView().environment(store).environment(metro))
                : AnyView(ContentView().environment(store).environment(cloud).environment(metro).frame(width: w, height: h).preferredColorScheme(.dark))
            let host = NSHostingView(rootView: root)
            let size = settings ? host.fittingSize : NSSize(width: w, height: h)
            let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(Int(q("settle") ?? "500") ?? 500))
            host.layoutSubtreeIfNeeded()
            defer { win.contentView = nil; win.close() }   // never ordered front, gone after the shot
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return json(["ok": false]) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return json(["ok": false]) }
            do { try png.write(to: URL(fileURLWithPath: file)); return json(["ok": true, "file": file, "w": rep.pixelsWide, "h": rep.pixelsHigh]) }
            catch { return json(["ok": false, "error": "\(error)"]) }
        case "/fakehooks":
            guard let pedal else { return json(["ok": false, "error": "demo only"]) }
            var h = await pedal.hooks
            if let v = q("quiet") { h.quietDirty = v == "1" }
            if let v = q("dropstate") { h.dropStateReads = v == "1" }
            if let v = q("refuse") { h.refuseSettings = v == "1" }
            if let v = UInt64(q("delay") ?? "") { h.writeDelayMs = v }
            await pedal.setHooks(h)
            if let r = UInt64(q("reply") ?? "") { await pedal.setReplyDelay(r) }
            return json(["quietDirty": h.quietDirty, "dropStateReads": h.dropStateReads, "refuseSettings": h.refuseSettings, "writeDelayMs": h.writeDelayMs])
        default:
            return json(["error": "unknown path"])
        }
    }

    private func footswitchDump() -> [String: Int] {
        guard let f = store.footswitch else { return [:] }
        return Dictionary(uniqueKeysWithValues: FootswitchSlot.allCases.map { ($0.label.lowercased(), f[$0]) })
    }

    private func liveDump() -> [String: Any] {

        var blocks: [String: Any] = [:]
        for (slot, b) in store.blocks { blocks[slot.rawValue] = ["model": b.model?.name ?? "", "on": b.on, "values": b.values] }
        return ["dirty": store.dirty, "dirtyForPrompt": store.dirtyForPrompt, "movePrompt": store.reorder.prompt != nil, "moving": store.reorder.moving, "editsInFlight": store.live.edits.inFlight,
                "presetUnknown": store.reorder.knowledge.unknown, "presetIndex": store.presetIndex,
                "expressionPosition": store.live.expressionPosition ?? -1, "applied": store.live.applied, "refreshes": store.live.refreshes,
                "amp": Dictionary(uniqueKeysWithValues: store.amp.map { ($0.key.rawValue, $0.value) }), "captureVolumeDb": store.captureVolumeDb,
                "gateReduction": store.gateReduction, "gateOn": store.gateOn, "captureOn": store.captureOn, "cabOn": store.cab.on, "blocks": blocks,
                "expression": store.expression.map { set in set.ranges.keys.map(\.key) + set.bypasses.keys.map { "on:" + $0.key } } ?? [],
                "readbackSlots": store.expressionReadbackSlots().map(\.rawValue)]
    }
}
#endif
