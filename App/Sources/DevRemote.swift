// Debug-only local HTTP endpoint so a terminal can drive the app during hardware
// sessions (the Electron app has the same idea). Compiled out of release builds.
//   curl http://127.0.0.1:4849/state          current state + link
//   curl http://127.0.0.1:4849/log?since=N    activity log lines
//   curl http://127.0.0.1:4849/connect | /disconnect | /demo | /reread
//   curl "http://127.0.0.1:4849/preset?i=13"  (0-based)
//   curl "http://127.0.0.1:4849/amp?knob=gain&v=150"
#if DEBUG
import Foundation
import AppKit
import Network
import NanoCore

@MainActor
final class DevRemote {
    private let store: PedalStore
    private var listener: NWListener?

    private let cloud: CloudController
    private let metro: Metronome
    init(store: PedalStore, cloud: CloudController, metro: Metronome) {
        self.cloud = cloud; self.metro = metro
        self.store = store
        guard let port = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["NANO_DEV_PORT"] ?? "4849") ?? 4849),
              let l = try? NWListener(using: .tcp, on: port) else { return }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Task { @MainActor in
                    let body = await self?.handle(request) ?? "{}"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
                }
            }
        }
        l.start(queue: .main)
        AppSettings.shared.devRemotePort = Int(port.rawValue)
        store.append("Dev remote on http://127.0.0.1:\(port)")
    }

    /// SwiftUI's Settings window (identifier `com_apple_SwiftUI_Settings_window`; the main window's identifier is its view type).
    static func textField(id: String, in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.accessibilityIdentifier() == id { return tf }
        for v in view.subviews { if let tf = textField(id: id, in: v) { return tf } }
        return nil
    }
    private static func isSettings(_ w: NSWindow) -> Bool { w.identifier?.rawValue.hasPrefix("com_apple_SwiftUI_Settings") == true || w.title.hasSuffix("Settings") }

    private func handle(_ request: String) async -> String {
        guard let line = request.split(separator: "\r\n").first, let target = line.split(separator: " ").dropFirst().first,
              let url = URLComponents(string: "http://x" + target) else { return "{}" }
        let q = { (k: String) -> String? in url.queryItems?.first { $0.name == k }?.value }
        func json(_ v: Any) -> String { (try? JSONSerialization.data(withJSONObject: v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}" }
        switch url.path {
        case "/log":
            let since = Int(q("since") ?? "0") ?? 0
            return json(["next": store.log.count, "lines": Array(store.log.dropFirst(since))])
        case "/state":
            var out: [String: Any] = ["link": "\(store.link)", "pedal": store.pedalName, "dirty": store.dirty, "demo": store.demo]
            if let s = store.state {
                out["presetIndex"] = s.presetIndex; out["firmware"] = s.firmware ?? ""; out["gain"] = s.gain; out["level"] = s.level
                out["bass"] = s.bass; out["mid"] = s.mid; out["treble"] = s.treble; out["capture"] = s.captureName; out["captureSlot"] = s.captureSlot ?? 0
                out["ir"] = s.irShortName; out["cabSlot"] = s.cabSlot; out["gateOn"] = s.gateOn; out["gate"] = s.gateReductionPercent ?? -1
                out["fx"] = s.fx.mapValues { ["model": $0.modelIdHex ?? "", "on": $0.on] }
                out["captureVolumeDb"] = s.captureVolumeDb
                out["footswitch"] = Dictionary(uniqueKeysWithValues: FootswitchSlot.allCases.map { ($0.label.lowercased(), s.footswitch[$0]) })
                out["tempo"] = s.tempo; out["presetTempo"] = store.presetTempo ?? 0; out["edited"] = store.edited
                out["captureBank"] = s.captureBank; out["capturePosition"] = s.capturePosition; out["captureId"] = s.captureId; out["irFull"] = s.irFullName
            }
            if let m = store.metadata { out["presets"] = m.presetNames; out["captures"] = m.captureNames; out["irs"] = m.irNames }
            return json(out)
        case "/connect": await store.connect(); return json(["link": "\(store.link)"])
        case "/demo": await store.connect(demo: true, firmware: q("firmware")); return json(["link": "\(store.link)", "firmware": store.state?.firmware ?? "", "firmwareNotice": store.firmwareNotice ?? ""])
        case "/fxunknown":   // demo: the pedal reports model id `id` (hex varint bytes, e.g. 7E) in `slot`, as a newer firmware could
            guard let slot = Slot(rawValue: q("slot") ?? ""), let hex = q("id"), hex.count % 2 == 0, !hex.isEmpty,
                  let pedal = store.demoPedal else { return json(["ok": false, "error": "demo only; slot=pre1..post3&id=7E"]) }
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap { UInt8(hex.dropFirst($0).prefix(2), radix: 16) }
            await pedal.setModelOnPedal(slot, id: bytes)
            store.requestState()
            try? await Task.sleep(for: .milliseconds(300))
            return json(["ok": true, "unknownId": store.blocks[slot]?.unknownId ?? "", "title": store.subtitle(PedalStore.Stage(rawValue: slot.rawValue)!)])
        case "/firmwarenotice":   // the banner's text (empty when hidden); dismiss=1 hides it
            if q("dismiss") == "1" { store.firmwareNotice = nil }
            return json(["notice": store.firmwareNotice ?? "", "warned": UserDefaults.standard.string(forKey: PedalStore.firmwareWarnedKey) ?? ""])
        case "/disconnect": await store.disconnect(); return json(["link": "\(store.link)"])
        case "/reread": store.requestState(); return json(["ok": true])
        case "/tempo":
            // bpm= with live=1 (pedal plays it, preset clean) or live=0 (into the preset: edited, Save keeps it);
            // nudge=1 = a − / + step (live now, commit when settled); tap=1 = the inspector's Tap; pedal=1 (demo) = a tap on
            // the pedal itself (unsolicited echo). Returns the store's tempo and the metronome's.
            if let b = Int(q("bpm") ?? "") {
                if q("pedal") == "1" { await (store.demoPedal)?.tapTempoOnPedal(bpm: Double(b)) }
                else if q("nudge") == "1" { store.nudgeTempo(b) }
                else { store.setTempo(b, live: q("live") != "0") }
            }
            if q("tap") == "1" { store.tapTempo() }
            try? await Task.sleep(for: .milliseconds(Int(q("wait") ?? "150") ?? 150))
            return json(["presetTempo": store.presetTempo ?? 0, "stateTempo": store.state?.tempo ?? 0, "edited": store.edited, "dirty": store.dirty,
                         "metroBpm": metro.bpm, "metroFollows": metro.tempoFollowsPreset, "effectiveTempo": metro.effectiveTempo])
        case "/save": let ok = await store.save(); return json(["ok": ok])
        case "/preset": if let i = Int(q("i") ?? "") { store.selectPreset(i) }; return json(["ok": true])
        case "/amp":
            if let k = AmpKnob(rawValue: q("knob") ?? ""), let v = Int(q("v") ?? "") { store.setAmp(k, v, commit: true); return json(["ok": true]) }
            return json(["ok": false, "error": "knob=gain|level|bass|mid|treble&v=0..255"])
        case "/pick":
            guard let slot = Int(q("slot") ?? ""), let index = Int(q("index") ?? "") else { return json(["ok": false]) }
            _ = await store.ensureLibrary()
            store.pick(.init(kind: q("kind") == "cab" ? .cab : .capture, name: q("name") ?? "?", factory: q("factory") != "0", index: index), slot: slot)
            return json(["ok": true])
        case "/chooser":
            _ = await store.ensureLibrary()
            store.slotChooser = .init(kind: q("kind") == "cab" ? .cab : .capture, name: q("name") ?? "Item", factory: true, index: Int(q("index") ?? "0") ?? 0); return json(["ok": true])
        case "/discard":   // confirm=1 performs it, otherwise just opens the sheet
            if q("confirm") == "1" { await store.discardEdits(); store.discardRequested = false } else { store.discardRequested = true }
            return json(["ok": true, "edited": store.edited])
        case "/switch":
            if store.pendingAssignment != nil { store.resolveAssignment(q("choice") ?? "cancel"); return json(["ok": true]) }
            guard let t = store.pendingPreset else { return json(["ok": false, "error": "nothing pending"]) }
            switch q("choice") { case "save": store.saveAndSwitch(t); case "discard": store.switchPreset(t); default: store.pendingPreset = nil }
            return json(["ok": true])
        case "/scan": await store.scanSlotUsage(); return json(["complete": store.usage?.complete ?? false, "captures": Dictionary(uniqueKeysWithValues: (store.usage?.captures ?? [:]).map { ("\($0.key)", $0.value) }), "cabs": Dictionary(uniqueKeysWithValues: (store.usage?.cabs ?? [:]).map { ("\($0.key)", $0.value) })])
        case "/tab": store.tab = q("t") == "cloud" ? .cloud : .editor; return json(["tab": store.tab == .cloud ? "cloud" : "editor"])
        case "/cloud":
            if let u = q("url").flatMap(URL.init(string:)) { cloud.go(u) }
            return json(["url": cloud.url?.absoluteString ?? "", "title": cloud.title, "captureId": cloud.captureId ?? "", "loading": cloud.loading, "message": cloud.message ?? ""])
        case "/cloudjs":   // runs JS in the Cloud web view, returns its JSON-serialisable result
            guard let js = q("js") else { return json(["ok": false]) }
            do { let r = try await cloud.webView.evaluateJavaScript(js); return json(["ok": true, "result": r is NSNull ? "" : (r ?? "")]) }
            catch { return json(["ok": false, "error": "\(error)"]) }
        case "/send":
            guard let id = q("id") ?? cloud.captureId else { return json(["ok": false, "error": "no capture page"]) }
            do { let b = try await cloud.fetchBundle(id: id); store.offerSend(b); return json(["ok": true, "name": b.record.name, "bytes": b.cns.count, "hash": b.record.hash]) }
            catch { return json(["ok": false, "error": error.localizedDescription]) }
        case "/sendfile":   // a saved download reply {payload, name}, for demo-mode tests
            guard let f = q("file"), let data = FileManager.default.contents(atPath: f), let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = j["payload"] as? String else { return json(["ok": false]) }
            do { let b = try CaptureBundle.parse(payloadBase64: payload, name: j["name"] as? String, cloudId: "file"); store.offerSend(b); return json(["ok": true, "name": b.record.name, "bytes": b.cns.count]) }
            catch { return json(["ok": false, "error": "\(error)"]) }
        case "/sendconfirm": store.sendPending(); return json(["ok": true])
        case "/offer": if q("choice") == "slot", let o = store.offerSlot { store.offerSlot = nil; store.slotChooser = o } else { store.offerSlot = nil }; return json(["ok": true])
        case "/metro":
            // open=0|1 on=0|1 bpm= beats= (Simple) tap=1 wait=ms mode=simple|advanced levels=0|1 (the popover)
            // Advanced setup: abeats= nv= pattern=<preset name, e.g. 5/4> accents=ANSM… (one letter per beat) sub=1..4 swing=0..100
            //   countin=0..2 ramp=0|1 target= step= every= gap=0|1 play= mute=   Levels: lacc= lmain= lsub= (0..100)
            // bar=N dumps the generated events of bar N (count-in included); events=1 the played log summary (+ list=1 the events).
            // Sounds (Settings → Sounds): sample=accent|main|sub with file=<abs path> (as if picked in the open panel: checked,
            // copied into Application Support), reset=1 (back to the built-in sound, copy deleted), builtin=click|woodblock|…
            // (that role's built-in sound; drops its sample), preview=1 (the row's ▶). Every reply has `sounds` (per role).
            // Writes the shared `metro.sounds` default and the copies: delete both afterwards.
            var sampleResult: [String: Any]?
            if let name = q("sample") {
                guard let role = SoundRole(name: name) else { return json(["ok": false, "error": "sample=accent|main|sub"]) }
                if let f = q("file") {
                    let ok = metro.setSample(from: URL(fileURLWithPath: f), for: role)
                    sampleResult = ["ok": ok, "error": metro.sampleError ?? ""]
                }
                if q("reset") == "1" { metro.resetSample(role) }
                if let b = q("builtin").flatMap(ClickSound.init(rawValue:)) { metro.setBuiltIn(b, for: role) }
                if q("preview") == "1" { metro.preview(role) }
            }
            if let v = q("mode").flatMap(MetronomeMode.init(rawValue:)) { metro.mode = v }
            var su = metro.setup
            if let v = Int(q("abeats") ?? "") { su.setBeats(v) }
            if let v = Int(q("nv") ?? ""), [4, 8, 16].contains(v) { su.noteValue = v }
            if let name = q("pattern"), let p = MetronomePattern.presets.first(where: { $0.name.hasPrefix(name) }) { su.apply(p) }
            if let a = q("accents") {
                let map: [Character: MetronomePattern.Level] = ["A": .accent, "N": .normal, "S": .soft, "M": .mute]
                let levels = a.uppercased().compactMap { map[$0] }
                if !levels.isEmpty { su.setBeats(levels.count); su.accents = levels }
            }
            if let v = Int(q("sub") ?? ""), (1...4).contains(v) { su.subdivision = v }
            if let v = Double(q("swing") ?? "") { su.swing = max(0, min(1, v / 100)) }
            if let v = Int(q("countin") ?? ""), (0...2).contains(v) { su.countIn = v }
            if let v = q("ramp") { su.rampOn = v == "1" }
            if let v = Int(q("target") ?? "") { su.rampTarget = max(30, min(300, v)) }
            if let v = Int(q("step") ?? "") { su.rampStep = max(1, min(20, v)) }
            if let v = Int(q("every") ?? "") { su.rampEvery = max(1, min(16, v)) }
            if let v = q("gap") { su.gapOn = v == "1" }
            if let v = Int(q("play") ?? "") { su.gapPlay = max(1, min(16, v)) }
            if let v = Int(q("mute") ?? "") { su.gapMute = max(1, min(16, v)) }
            // type=metro-beats|ramp-target|ramp-step|ramp-every|gap-play|gap-mute&text=… commits a string the way the overlay's field does
            // (clamped; no number = unchanged). metro-simple-beats sets Simple's beats.
            if let f = q("type"), let t = q("text") {
                switch f {
                case "metro-beats": if let v = TypedNumber.commit(t, range: MetronomeSetup.beatsRange) { su.setBeats(v) }
                case "ramp-target": if let v = TypedNumber.commit(t, range: MetronomeSetup.rampTargetRange) { su.rampTarget = v }
                case "ramp-step": if let v = TypedNumber.commit(t, range: MetronomeSetup.rampStepRange) { su.rampStep = v }
                case "ramp-every": if let v = TypedNumber.commit(t, range: MetronomeSetup.barsRange) { su.rampEvery = v }
                case "gap-play": if let v = TypedNumber.commit(t, range: MetronomeSetup.barsRange) { su.gapPlay = v }
                case "gap-mute": if let v = TypedNumber.commit(t, range: MetronomeSetup.barsRange) { su.gapMute = v }
                case "metro-simple-beats": if let v = TypedNumber.commit(t, range: 1...12) { metro.set(beats: v) }
                default: break
                }
            }
            if su != metro.setup { metro.setup = su }
            // focus=<stepper id> puts the cursor in that field (as a click would), for screenshots and /key tests.
            if let f = q("focus") {
                metro.focusRequest = f
                // Without key status (a second instance behind the owner's app) SwiftUI focus does not move; make the field
                // first responder through AppKit, as a click would.
                for win in NSApp.windows where win.isVisible { if let tf = Self.textField(id: f, in: win.contentView) { win.makeFirstResponder(tf); break } }
            }
            var lv = metro.levels
            if let v = Double(q("lacc") ?? "") { lv.accent = max(0, min(1, v / 100)) }
            if let v = Double(q("lmain") ?? "") { lv.main = max(0, min(1, v / 100)) }
            if let v = Double(q("lsub") ?? "") { lv.sub = max(0, min(1, v / 100)) }
            if lv != metro.levels { metro.levels = lv }
            if let b = Int(q("bpm") ?? "") { metro.set(bpm: b) }
            if let b = Int(q("beats") ?? "") { metro.set(beats: b) }
            if let o = q("open") { metro.open = o == "1"; if !metro.open { metro.close() } }
            if let v = q("levels") { metro.levelsOpen = v == "1" }
            if let on = q("on") { on == "1" ? metro.start() : metro.stop() }
            if q("tap") == "1" { metro.tap() }
            try? await Task.sleep(for: .milliseconds(Int(q("wait") ?? "0") ?? 0))
            let s = metro.setup
            var out: [String: Any] = ["open": metro.open, "running": metro.running, "mode": metro.mode.rawValue, "bpm": metro.bpm, "effectiveTempo": metro.effectiveTempo,
                                      "followsPreset": metro.tempoFollowsPreset, "presetTempo": metro.presetTempo ?? 0,
                                      "beats": metro.beats, "beat": metro.beat, "sub": metro.sub, "bar": metro.bar, "barKind": metro.barKind.rawValue, "barLabel": metro.barLabel,
                                      "count": metro.count, "rampStatus": metro.rampStatus ?? "", "levelsOpen": metro.levelsOpen,
                                      "levels": ["accent": metro.levels.accent, "main": metro.levels.main, "sub": metro.levels.sub],
                                      "setup": ["beats": s.beats, "noteValue": s.noteValue, "accents": s.accents.map { $0.rawValue }, "pattern": s.presetName ?? "Custom",
                                                "subdivision": s.subdivision, "swing": s.swing, "countIn": s.countIn,
                                                "ramp": ["on": s.rampOn, "target": s.rampTarget, "step": s.rampStep, "every": s.rampEvery],
                                                "gap": ["on": s.gapOn, "play": s.gapPlay, "mute": s.gapMute]] as [String: Any],
                                      "error": metro.error ?? "", "outputs": metro.outputs.map { $0.name }, "editingField": metro.editingField ?? "",
                                      "sounds": metro.soundReport, "sampleError": metro.sampleError ?? ""]
            if let sampleResult { out["sample"] = sampleResult }
            func ev(_ e: MetronomePattern.Event) -> [String: Any] { ["offset": (e.offset * 10000).rounded() / 10000, "role": e.role.rawValue, "beat": e.beat, "sub": e.sub] }
            if let n = Int(q("bar") ?? "") {
                let (kind, events) = metro.barPlan(max(0, n))
                out["barDump"] = ["index": n, "kind": kind.rawValue, "events": events.map(ev),
                                  "roles": Dictionary(grouping: events, by: { $0.role.rawValue }).mapValues { $0.count }] as [String: Any]
            }
            if q("events") == "1" {
                let p = metro.played
                out["played"] = ["total": p.count, "roles": Dictionary(grouping: p, by: { $0.event.role.rawValue }).mapValues { $0.count },
                                 // role:sound pairs as played ("accent:sample", "normal:click", …) and how many were cut at the next event
                                 "sounds": Dictionary(grouping: p, by: { "\($0.event.role.rawValue):\($0.sound)" }).mapValues { $0.count }, "cut": p.filter(\.cut).count,
                                 "bars": Dictionary(grouping: p, by: { "\($0.bar)" }).mapValues { g in ["kind": g[0].kind.rawValue, "events": g.count, "bpm": g[0].bpm, "t": (g[0].time * 1000).rounded() / 1000] as [String: Any] },
                                 "seconds": ((p.last?.time ?? 0) * 1000).rounded() / 1000] as [String: Any]
                if q("list") == "1" { out["list"] = p.map { var d = ev($0.event); d["bar"] = $0.bar; d["t"] = ($0.time * 10000).rounded() / 10000; d["bpm"] = $0.bpm; d["sound"] = $0.sound; d["cut"] = $0.cut; return d } }
            }
            return json(out)
        case "/settings":
            // accent=teal|… dock=0|1 sound=click|… (every role's built-in sound) volume=0..1 bpm= beats= (defaults) connect=0|1 showlog=0|1 devtools=0|1
            // section=appearance|metronome|connection|device|advanced|about open=1 forget=1 (forgets the remembered pedal) icon=/path.png (the rendered 1024 px icon) sounds=1 (buffer stats)
            let s = AppSettings.shared
            if let a = q("accent").flatMap(Accent.init(rawValue:)) { s.accent = a }
            if let v = q("dock") { s.dockIconFollowsAccent = v == "1" }
            if let v = q("sound").flatMap(ClickSound.init(rawValue:)) { metro.sound = v }
            if let v = Double(q("volume") ?? "") { metro.volume = max(0, min(1, v)) }
            if let v = Int(q("bpm") ?? "") { s.metroDefaultBPM = max(30, min(300, v)) }
            if let v = Int(q("beats") ?? "") { s.metroDefaultBeats = max(1, min(12, v)) }
            if let v = q("connect") { s.connectAtLaunch = v == "1" }
            if let v = q("followpreset") { s.metroFollowsPreset = v == "1"; metro.adopt(presetTempo: metro.presetTempo) }
            if let v = q("showlog") { s.showLogAtLaunch = v == "1" }
            if let v = q("devtools") { s.devTools = v == "1" }   // shared UserDefaults (`ui.devTools`): put it back afterwards
            if let v = q("opensin").flatMap(MetronomeMode.init(rawValue:)) { s.metroOpensIn = v; if !metro.running { metro.mode = v } }
            if let v = q("section").flatMap(AppSettings.Section.init(rawValue:)) { s.section = v }
            if q("open") == "1" { s.openSettings?(); try? await Task.sleep(for: .milliseconds(400)) }
            if q("preview") == "1" { metro.preview() }
            if q("forget") == "1" { await store.forgetPedal() }
            var out: [String: Any] = ["accent": s.accent.rawValue, "accentHex": s.accent.rgb.css, "accentHi": s.accent.hi.css, "activeRow": s.accent.activeRow.css,
                                      "dockIconFollowsAccent": s.dockIconFollowsAccent, "dockIconSet": NSApp.applicationIconImage != nil && s.dockIconFollowsAccent,
                                      "sound": s.metroSounds.main.builtIn.rawValue, "roleSounds": metro.soundReport, "volume": s.metroVolume, "output": Int(s.metroOutput), "defaultBPM": s.metroDefaultBPM, "defaultBeats": s.metroDefaultBeats,
                                      "opensIn": s.metroOpensIn.rawValue, "followPreset": s.metroFollowsPreset, "levels": ["accent": s.metroLevels.accent, "main": s.metroLevels.main, "sub": s.metroLevels.sub],
                                      "advancedPattern": s.metroSetup.presetName ?? "Custom", "advancedSubdivision": s.metroSetup.subdivision, "advancedCountIn": s.metroSetup.countIn,
                                      "connectAtLaunch": s.connectAtLaunch, "showLogAtLaunch": s.showLogAtLaunch, "devTools": s.devTools, "showLog": store.showLog, "recording": store.recording, "rememberedPedal": s.rememberedPedal ?? "", "hasRememberedPedal": s.hasRememberedPedal,
                                      "devRemotePort": s.devRemotePort ?? 0, "section": s.section.rawValue,
                                      "settingsWindowOpen": NSApp.windows.contains { $0.isVisible && Self.isSettings($0) }]
            // The app menu's items with their key equivalents (checks that "Settings…" is there with ⌘,).
            out["appMenu"] = NSApp.mainMenu?.items.first?.submenu?.items.filter { !$0.isSeparatorItem }.map { $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent) + ($0.isHidden ? " (hidden)" : "") } ?? []
            // Ask each View menu to update first, as AppKit does when the user opens it (SwiftUI fills its menus lazily).
            let viewMenus = (NSApp.mainMenu?.items ?? []).filter { $0.title == "View" }.compactMap(\.submenu)
            for m in viewMenus { m.delegate?.menuNeedsUpdate?(m); m.update() }
            out["viewMenu"] = viewMenus.flatMap(\.items).filter { !$0.isSeparatorItem }.map { $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent) }
            out["menus"] = NSApp.mainMenu?.items.map(\.title) ?? []
            out["shortcutRows"] = ShortcutsSheet.rows(devTools: s.devTools).map(\.0)
            out["windows"] = NSApp.windows.map { "\($0.className) '\($0.title)' id=\($0.identifier?.rawValue ?? "") visible=\($0.isVisible)" }
            if let f = q("icon") {
                let png = AppIcon.bitmap(for: s.accent)?.representation(using: .png, properties: [:])
                out["iconWritten"] = (try? png?.write(to: URL(fileURLWithPath: f))) != nil && png != nil
                out["iconSVGStops"] = [s.accent.ledStops.0, s.accent.ledStops.1, s.accent.ledStops.2]
            }
            if q("sounds") == "1" {
                // Per sound: frames, peak, RMS and the zero-crossing frequency estimate of the click and the accent.
                func stats(_ x: [Float]) -> [String: Any] {
                    let peak = x.map(abs).max() ?? 0
                    let rms = (x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))).squareRoot()
                    let zc = zip(x, x.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
                    return ["frames": x.count, "ms": Double(x.count) / 48, "peak": (Double(peak) * 1000).rounded() / 1000, "rms": (rms * 1000).rounded() / 1000, "zcHz": Int(Double(zc) / 2 / (Double(x.count) / 48000))]
                }
                out["sounds"] = Dictionary(uniqueKeysWithValues: ClickSound.allCases.map { c in (c.rawValue, ["click": stats(ClickSound.samples(c, accent: false, rate: 48000)), "accent": stats(ClickSound.samples(c, accent: true, rate: 48000))]) })
            }
            return json(out)
        case "/updates":
            // Sparkle (DECISIONS #23). check=1 runs "Check for Updates…" (contacts the feed); auto=0|1 flips Settings'
            // switch, which Sparkle stores as SUEnableAutomaticChecks in the shared UserDefaults: delete it afterwards.
            if let v = q("auto") { Updates.shared.setAutomaticChecks(v == "1") }
            if q("check") == "1" { Updates.shared.checkForUpdates(); try? await Task.sleep(for: .milliseconds(300)) }
            let u = SparkleUpdater.shared.updater
            return json(["feedURL": u?.feedURL?.absoluteString ?? "", "defaultFeedURL": UpdateFeed.url.absoluteString,
                         "automaticChecks": Updates.shared.automaticChecks, "canCheck": Updates.shared.canCheck,
                         "sessionInProgress": u?.sessionInProgress ?? false, "interval": u?.updateCheckInterval ?? 0,
                         "lastCheck": u?.lastUpdateCheckDate.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                         "updaterRuns": SparkleUpdater.shared.runs,
                         "windows": NSApp.windows.filter(\.isVisible).map { "\($0.className) '\($0.title)'" }])
        case "/key":
            // k=esc|return|space|tab, or chars=<text> (typed one key at a time), into the main window (target=settings: the
            // Settings window) the way NSApplication dispatches a key: key equivalents first, then the first responder.
            let win = q("target") == "settings" ? NSApp.windows.first(where: { $0.isVisible && Self.isSettings($0) }) : NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain })
            guard let win else { return json(["ok": false, "error": "no window"]) }
            let named: [String: (String, UInt16)] = ["esc": ("\u{1b}", 53), "return": ("\r", 36), "space": (" ", 49), "tab": ("\t", 48)]
            let keys: [(String, UInt16)] = q("k").flatMap { named[$0] }.map { [$0] } ?? (q("chars") ?? "").map { (String($0), UInt16(0)) }
            for (c, code) in keys {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                                   context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code) else { continue }
                    if type == .keyDown, win.performKeyEquivalent(with: e) { break }
                    win.sendEvent(e)
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(100))
            return json(["ok": true, "keys": keys.count, "firstResponder": String(describing: type(of: win.firstResponder as Any)), "metroOpen": metro.open, "editingField": metro.editingField ?? ""])
        case "/resize":
            if let w = Double(q("w") ?? ""), let h = Double(q("h") ?? ""), let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                win.setContentSize(NSSize(width: w, height: h)); return json(["w": win.frame.width, "h": win.frame.height])
            }
            return json(["ok": false])
        case "/record":   // on=1 starts; on=0 stops and writes `file` (default: the recording folder) without the save panel
            if q("on") == "1" { if !store.recording { store.startRecording() }; return json(["recording": true]) }
            if q("on") == "0" {
                let started = store.recorder.startDate ?? Date()
                guard let rec = store.stopRecording() else { return json(["ok": false, "error": "not recording"]) }
                let url = q("file").map { URL(fileURLWithPath: $0) } ?? PedalStore.recordingFolder.appending(path: SessionRecorder.fileName(for: started))
                return json(["ok": store.write(rec, to: url), "file": url.path, "events": rec.events.count, "tx": rec.tx.count, "rx": rec.rx.count, "log": rec.log.count])
            }
            return json(["recording": store.recording, "events": store.recorder.count])
        case "/device":
            // Settings → Device. brightness=0..255 (raw) or pct=0..100, usb=dB (−20…0), read=1 re-reads first; writes go
            // through the same coalescing path as the sliders and need a prior read. Without parameters: a dump.
            if q("read") == "1" || store.deviceSettings == nil { await store.readDevice() }
            let b = Int(q("brightness") ?? "") ?? Int(q("pct") ?? "").map { DeviceSettings.brightnessRaw(percent: $0) }
            let u = Double(q("usb") ?? "")
            if b != nil || u != nil { store.setDeviceSettings(brightness: b, usbVolumeDb: u); try? await Task.sleep(for: .milliseconds(400)) }
            let i = store.deviceInfo, st = store.deviceSettings
            return json(["connected": store.connected, "name": st?.name ?? i?.name ?? "", "firmware": i?.firmware ?? "", "firmwareBuild": i?.firmwareBuild ?? "", "serial": i?.serial ?? "", "hash": i?.hash ?? "",
                         "read": st != nil, "ledBrightness": store.ledBrightness, "ledPercent": DeviceSettings.brightnessPercent(store.ledBrightness), "usbVolumeDb": store.usbVolumeDb,
                         "readBrightness": st?.ledBrightness ?? -1, "readUsbVolumeDb": st?.usbVolumeDb.map(Double.init) ?? 0,
                         "raw": st?.raw.map { "\($0.field): \($0.value)" } ?? [], "error": store.deviceError ?? ""])
        case "/captureinfo":
            // slot=1..25; open=1 shows the popover on that slot's cell (switches the inspector to Capture) instead of only fetching.
            guard let slot = Int(q("slot") ?? "") else { return json(["ok": false]) }
            var d: CaptureDetails?
            if q("open") == "1" {
                store.selectedStage = .capture
                try? await Task.sleep(for: .milliseconds(200))
                store.showCaptureInfo(slot: slot, anchor: q("anchor") == "node" ? .node : .slot(slot))
                for _ in 0..<30 where store.captureInfo == nil && store.captureInfoError == nil { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(300))
                d = store.captureInfo
            } else { d = await store.fetchCaptureInfo(slot: slot) }
            guard let d else { return json(["ok": false, "error": store.captureInfoError ?? "no reply"]) }
            return json(["ok": d.ok, "slot": d.slot, "name": d.name, "author": d.author, "hash": d.hash, "description": d.description, "deviceType": d.deviceType, "instrument": d.instrument, "tags": d.tags, "gainType": d.record?.gainType.map(Int.init) ?? -1])
        case "/support":
            // What the status bar's "♥ Support" button (and Help → Support the Project…) would open, without opening a
            // browser; plus the Help menu's items, the About panel's credits and the other outbound links.
            let help = NSApp.mainMenu?.items.first { $0.title == "Help" }?.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
            return json(["url": Links.support.absoluteString, "manual": Links.manual.absoluteString, "troubleshooting": Links.troubleshooting.absoluteString,
                         "repository": Links.repository.absoluteString, "newIssue": Links.newIssue.absoluteString, "crossPlatform": Links.crossPlatform.absoluteString,
                         "helpMenu": help, "aboutCredits": AboutPanel.credits.string, "version": AboutSection.version])
        case "/linkproblem":   // text= shows a connect problem on the connect card (empty clears it); error= sets the failed-connect line
            if let t = q("text") { store.linkProblem = t.isEmpty ? nil : t }
            if let e = q("error") { store.error = e.isEmpty ? nil : e }
            return json(["linkProblem": store.linkProblem ?? "", "error": store.error ?? ""])
        case "/shortcuts": store.shortcutsOpen = q("on") != "0"; return json(["open": store.shortcutsOpen])
        case "/refresh": store.refresh(); return json(["ok": true])
        case "/drawer": store.showLog = q("on") != "0"; return json(["ok": true])
        case "/expression":
            // dump; add=<gain|bass|mid|treble|pre1..post3|level|gate>&min=&max=&inv=0|1 (raw 0–255);
            // bypass=<capture|cab|pre1..post3|gate>&mode=heelToe|switch|stop&delay=ms&latch=0|1&inv=0|1; remove=<key>&kind=range|bypass;
            // clear=1; open=1|0 (the panel); reread=1
            if q("reread") == "1" { await store.readExpression() }
            if let o = q("open") { store.expressionOpen = o != "0" }
            if q("clear") == "1" { store.clearExpression() }
            if var set = store.expression {
                var changed = false
                if let k = q("add"), let t = ExpRange.allCases.first(where: { $0.key == k }) {
                    set.ranges[t] = .init(inverted: q("inv") == "1", min: Int(q("min") ?? "") ?? 0, max: Int(q("max") ?? "") ?? 255); changed = true
                }
                if let k = q("bypass"), let t = ExpBypass.allCases.first(where: { $0.key == k }) {
                    let inv = q("inv") == "1", delay = Int(q("delay") ?? "") ?? 600
                    set.bypasses[t] = q("mode") == "switch" ? .toggle(inverted: inv, latch: q("latch") == "1") : q("mode") == "stop" ? .stop(delayMs: delay) : .heelToe(inverted: inv, delayMs: delay)
                    changed = true
                }
                if let k = q("remove") {
                    if q("kind") != "bypass", let t = ExpRange.allCases.first(where: { $0.key == k }) { set.ranges[t] = nil; changed = true }
                    else if let t = ExpBypass.allCases.first(where: { $0.key == k }) { set.bypasses[t] = nil; changed = true }
                }
                if changed { store.setExpression(set) }
            }
            var out: [String: Any] = ["open": store.expressionOpen, "preset": store.expressionPreset ?? -1, "loaded": store.expression != nil, "edited": store.edited, "error": store.expressionError ?? ""]
            if let set = store.expression {
                out["count"] = set.count
                out["ranges"] = Dictionary(uniqueKeysWithValues: set.ranges.map { ($0.key.key, ["min": $0.value.min, "max": $0.value.max, "inverted": $0.value.inverted] as [String: Any]) })
                out["bypasses"] = Dictionary(uniqueKeysWithValues: set.bypasses.map { k, v -> (String, [String: Any]) in
                    switch v {
                    case .heelToe(let i, let d): (k.key, ["mode": "heelToe", "inverted": i, "delay": d])
                    case .toggle(let i, let l): (k.key, ["mode": "switch", "inverted": i, "latch": l])
                    case .stop(let d): (k.key, ["mode": "stop", "delay": d])
                    }
                })
                out["body"] = set.encode(presetIndex: store.expressionPreset ?? 0).map { String(format: "%02X", $0) }.joined(separator: " ")
            }
            return json(out)
        case "/stage": if let s = PedalStore.Stage(rawValue: q("s") ?? "") { store.selectedStage = s }; return json(["stage": store.selectedStage.rawValue])
        case "/ui":
            var out: [String: Any] = ["stage": store.selectedStage.rawValue, "edited": store.edited, "notice": store.notice ?? "", "pendingPreset": store.pendingPreset ?? -1, "pendingAssignment": store.pendingAssignment.map { "\($0.slot.label) \($0.index)" } ?? "", "chooser": store.slotChooser?.name ?? "", "captureOn": store.captureOn, "captureSlot": store.captureSlot ?? 0, "captureFromLibrary": store.captureFromLibrary, "tab": store.tab == .cloud ? "cloud" : "editor", "pendingSend": store.pendingSend?.record.name ?? "", "uploading": store.uploading, "offerSlot": store.offerSlot?.name ?? "", "lastAction": store.lastAction, "captureName": store.captureName,
                                      "gateOn": store.gateOn, "gate": store.gateReduction, "tuner": store.tunerOn, "amp": Dictionary(uniqueKeysWithValues: store.amp.map { ($0.key.rawValue, $0.value) })]
            out["cab"] = ["on": store.cab.on, "slot": store.cab.slot, "name": store.cab.name, "mic": store.cab.mic, "position": store.cab.position, "libraryIndex": store.cab.libraryIndex ?? -1, "fromLibrary": store.cab.fromLibrary, "positionFromRecord": store.cabPositionFromRecord ?? -1, "fullName": store.cabFullName, "mics": store.cabMics, "level": store.cab.levelDb, "hpf": store.cab.highPassHz, "lpf": store.cab.lowPassHz, "loaded": store.cab.loaded]
            out["blocks"] = Dictionary(uniqueKeysWithValues: store.blocks.map { ($0.key.rawValue, ["model": $0.value.model?.name ?? "", "on": $0.value.on, "values": $0.value.values, "unknownId": $0.value.unknownId ?? ""]) })
            return json(out)
        case "/fxmodel":
            guard let slot = Slot(rawValue: q("slot") ?? "") else { return json(["ok": false]) }
            let name = q("name") ?? "None"
            store.setFXModel(slot, name == "None" ? nil : Models.list(for: slot.rawValue).first { $0.name == name }); return json(["ok": true])
        case "/fxon": if let slot = Slot(rawValue: q("slot") ?? "") { store.setFX(slot, on: q("on") == "1") }; return json(["ok": true])
        case "/fxparam": if let slot = Slot(rawValue: q("slot") ?? ""), let i = Int(q("i") ?? ""), let v = Double(q("v") ?? "") { store.setFXParam(slot, index: i, value: v, commit: true) }; return json(["ok": true])
        case "/capture": if let s = Int(q("slot") ?? "") { s == 0 ? store.toggleCapture() : store.setCapture(slot: s) }; return json(["ok": true])
        case "/cab": if let s = Int(q("slot") ?? "") { store.selectCab(slot: s) }; return json(["ok": true])
        case "/cabrefresh": store.refreshCab(); return json(["ok": true])
        case "/cabmic": store.setCabMic(q("mic") ?? store.cab.mic, position: Int(q("pos") ?? "") ?? store.cab.position); return json(["ok": true])
        case "/gate": if let on = q("on") { store.setGate(on: on == "1") }; if let r = Int(q("r") ?? "") { store.setGateReduction(r, commit: true) }; return json(["ok": true])
        case "/saveas": guard let i = Int(q("i") ?? "") else { return json(["ok": false]) }; return json(["error": await store.saveAs(index: i, name: q("name") ?? "") ?? ""])
        case "/footswitch":   // slot=ia|ib|iia|iib&i=N (0-based) assigns; open=1 opens the Assign… popover instead
            guard let slot = FootswitchSlot(label: q("slot") ?? "") else { return json(["ok": false, "error": "slot must be ia, ib, iia or iib"]) }
            if q("open") == "1" { store.footswitchPicker = slot; return json(["ok": true]) }
            guard let i = Int(q("i") ?? ""), (0..<64).contains(i) else { return json(["ok": false, "error": "i must be 0–63"]) }
            // Like the UI: with unsaved edits the prompt opens; answer it with confirm=save|discard|cancel (same call or a later one).
            store.requestAssignment(slot, index: i)
            if let c = q("confirm"), store.pendingAssignment != nil { store.resolveAssignment(c) }
            if store.pendingAssignment != nil { return json(["ok": false, "pending": true, "edited": store.edited || store.dirty]) }
            for _ in 0..<40 where store.footswitch?[slot] != i && q("confirm") != "cancel" { try? await Task.sleep(for: .milliseconds(50)) }
            return json(["ok": store.footswitch?[slot] == i, "footswitch": store.footswitch.map { f in Dictionary(uniqueKeysWithValues: FootswitchSlot.allCases.map { ($0.label.lowercased(), f[$0]) }) } ?? [:]])
        case "/delete": guard let i = Int(q("i") ?? "") else { return json(["ok": false]) }; return json(["error": await store.deletePreset(index: i) ?? ""])
        case "/saveassheet": store.saveAsOpen = q("on") != "0"; return json(["ok": true])
        case "/rename": return json(["error": await store.rename(q("name") ?? "") ?? ""])
        case "/tuner": store.tuner(on: q("on") == "1"); return json(["ok": true])
        case "/library":   // `open=capture|cab` also opens the picker popover
            let l = await store.ensureLibrary()
            if let o = q("open") { store.openLibrary(o == "cab" ? .cab : .capture, into: nil) }
            let factory: [String] = l?.factoryCaptures.map { "\($0.index) \($0.name) \($0.hash.prefix(8))" } ?? []
            let user: [String] = l?.userCaptures.map { "\($0.index) \($0.name) \($0.hash.prefix(8))" } ?? []
            let irs: [String] = l?.factoryIRs.map { $0.name } ?? []
            let userIRs: [String] = l?.userIRs.map { $0.name } ?? []
            let kinds: [String] = ((l?.factoryCaptures ?? []) + (l?.userCaptures ?? [])).map { "\($0.type)|\($0.instrument)" }
            return json(["factory": factory, "user": user, "irs": irs, "userIRs": userIRs, "kinds": kinds])
        case "/shot" where q("target") == "cloud":
            guard let file = q("file"), let img = await cloud.snapshot(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return json(["ok": false]) }
            try? png.write(to: URL(fileURLWithPath: file)); return json(["ok": true, "file": file, "url": cloud.url?.absoluteString ?? ""])
        case "/shot":
            // `&full=1` renders the theme frame (title bar and traffic lights included) instead of the content view;
            // `&target=settings` the Settings window, `&target=popover` an open popover (the metronome's Levels…).
            let settingsWin = q("target") == "settings" ? NSApp.windows.first(where: { $0.isVisible && Self.isSettings($0) })
                : q("target") == "popover" ? NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Popover") }) : nil
            guard let file = q("file"), let win = settingsWin ?? NSApp.windows.first(where: { $0.isVisible && $0.isSheet }) ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.contentView != nil && !Self.isSettings($0) }) ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = q("full") == "1" ? (win.contentView?.superview ?? win.contentView) : win.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return json(["ok": false]) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return json(["ok": false]) }
            do { try png.write(to: URL(fileURLWithPath: file)); return json(["ok": true, "file": file, "w": rep.pixelsWide, "h": rep.pixelsHigh]) } catch { return json(["ok": false, "error": "\(error)"]) }
        case "/hit":   // which view receives a click at (x, y) points from the window's top-left
            guard let x = Double(q("x") ?? ""), let y = Double(q("y") ?? ""), let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let frame = win.contentView?.superview else { return json(["ok": false]) }
            let v = frame.hitTest(NSPoint(x: x, y: win.frame.height - y))
            return json(["view": v.map { String(describing: type(of: $0)) } ?? "nil", "super": v?.superview.map { String(describing: type(of: $0)) } ?? "nil"])
        default:
            if let r = await AuditionRemote.handle(url.path, q, store: store, cloud: cloud) { return json(r) }   // AuditionRemote.swift
            return json(["error": "unknown path"])
        }
    }
}
#endif
