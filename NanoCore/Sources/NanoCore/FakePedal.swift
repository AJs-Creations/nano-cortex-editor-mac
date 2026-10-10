// A pedal that answers like the real one, through the same byte layouts, so the
// session, the UI and the tests run without hardware. Mirrors the Electron app's
// demo mode: replies go through the real parsers.

import Foundation
import CryptoKit

public struct DemoState: Sendable {
    public var presetNames: [String]
    public var captureNames: [String]
    public var irNames: [String]
    public var presetIndex = 1
    public var amp: [AmpKnob: Int] = [.gain: 127, .level: 127, .bass: 127, .mid: 127, .treble: 127]
    public var captureVolumeRaw = 127
    public var captureSlot = 2            // 1–25, 0 = bypassed
    public var cabSlot = 1                // 1–5, 0 = bypassed
    public var cabLevelDb = -10.0, cabHighPassHz = 20.0, cabLowPassHz = 20000.0
    public var cabMic = "Dynamic 57", cabPosition = 3
    public var gateOn = true, gateReduction = 50
    public var fxModel: [Slot: [UInt8]?] = [.pre1: Models.pre1.first { $0.name == "Green 808" }!.id, .pre2: nil, .post1: nil, .post2: Models.post2.first { $0.name == "Analog Delay" }!.id, .post3: Models.post3.first { $0.name == "Mind Hall" }!.id]
    public var fxOn: [Slot: Bool] = [.pre1: true, .pre2: false, .post1: false, .post2: true, .post3: true]
    public var fxParams: [Slot: [Float]] = [:]
    public var dirty = false
    public var tunerOn = false
    public var libraryUser: [(name: String, hash: String)] = []
    public var firmware = "2.2.1"
    // Device page (PROTOCOL-NOTES §13): the values Anup's pedal reported at the start of the 2026-10-09 trace.
    public var deviceName = "Neural DSP Nano Cortex"
    public var serial = "NP00XXXXXX"
    public var ledBrightness = 153
    public var usbVolumeDb: Float = -6
    /// Footswitch slots IA, IB, IIA, IIB (0-based preset indexes).
    public var footswitch = Footswitches(ia: 0, ib: 2, iia: 6, iib: 14)
    /// The current preset's tempo buffer (state field 56): a scope-0 write sets it, Save stores it in `presetTempos`.
    public var tempo = Tempo.defaultBPM
    /// What the pedal plays: scope-1 writes and the pedal's own tap change it without dirtying the preset.
    public var liveTempo = Tempo.defaultBPM
    /// Saved tempo per preset index (absent = 120); a preset change loads it.
    public var presetTempos: [Int: Double] = [:]
    /// Expression assignments per preset index (the demo's preset 2, index 1, has a full gain sweep).
    public var expression: [Int: ExpressionAssignments] = [1: ExpressionAssignments(ranges: [.gain: .init(min: 0, max: 255)])]

    public static func demo() -> DemoState {
        let presets = (1...64).map { i -> String in i <= 24 ? ["Princeton Clean", "JP2C Lead", "Jubilee Crunch", "5150 Rhythm", "VH4 Ambient Lead", "SVT Bass", "Tremolo Surf", "Funk Wah", "Fuzz Wall", "Octave Down Riff"][(i - 1) % 10] + (i > 10 ? " \((i - 1) / 10 + 1)" : "") : "" }
        let captures = ["Silver Jubilee Ch1", "5150 Lead", "JP2C Ch3", "Princeton 65", "VH4 Ch3", "SVT Classic", "Plexi 1959 Bright", "AC30 Top Boost", "Deluxe Reverb Vib", "Dumble ODS", "Recto Modern", "JCM800 2203", "Bassman 59", "Matchless DC30", "Friedman BE100", "Soldano SLO", "Orange OR50", "Two Rock Classic", "Bogner Ecstasy Blue", "Hiwatt DR103", "Trainwreck Express", "Fryette Deliverance", "EVH 5153 Red", "Darkglass B7K", "Tone King Imperial"]
        let irs = ["412 V30", "412 Greenback", "412 Recto", "810 SVT", "212 Blue"]
        var s = DemoState(presetNames: presets, captureNames: captures, irNames: irs)
        for i in 0..<24 { s.presetTempos[i] = [120, 96, 140, 110, 75, 100, 132, 105, 160, 90][i % 10] }
        s.tempo = s.presetTempos[s.presetIndex] ?? Tempo.defaultBPM; s.liveTempo = s.tempo
        return s
    }
}

/// Encodes the pedal's replies from a `DemoState` (also handy for tests).
public enum StateEncoder {
    public static func dump(_ s: DemoState, withLists: Bool) -> [UInt8] {
        var w = ProtoWriter().int(1, 1)
            .int(3, UInt64(s.amp[.gain]!)).int(4, UInt64(s.amp[.level]!)).int(5, UInt64(s.amp[.bass]!)).int(6, UInt64(s.amp[.mid]!)).int(7, UInt64(s.amp[.treble]!))
        if s.captureSlot > 0 { w = w.int(9, UInt64((s.captureSlot - 1) / 5 + 1)).int(11, UInt64((s.captureSlot - 1) % 5 + 1)) }
        if s.cabSlot > 0 { w = w.int(12, UInt64(s.cabSlot)) }
        w = w.int(13, UInt64(s.presetIndex))
        // Fields 14/15/38/39; zeros are elided like on the pedal.
        for slot in FootswitchSlot.allCases where s.footswitch[slot] != 0 { w = w.int(slot.stateField, UInt64(s.footswitch[slot])) }
        if withLists {
            for c in s.captureNames { w = w.message(17, ProtoWriter().string(2, c)) }
            for p in s.presetNames { w = w.message(18, ProtoWriter().string(1, p)) }
            for i in s.irNames { w = w.message(19, ProtoWriter().string(1, i).string(3, i + "/" + s.cabMic + "/\(s.cabPosition - 1)")) }
        }
        w = w.string(24, s.firmware)
        w = w.bytes(31, Slot.allCases.map { s.fxOn[$0] == true ? 0 : 1 })
        let capName = s.captureSlot > 0 ? s.captureNames[s.captureSlot - 1] : ""
        w = w.message(32, ProtoWriter().int(1, 1).string(2, capName).string(3, "demo-id"))
        let irName = s.cabSlot > 0 ? s.irNames[s.cabSlot - 1] : ""
        w = w.message(33, ProtoWriter().int(1, 1).string(2, irName).string(3, irName + "/" + s.cabMic + "/\(s.cabPosition - 1)"))
        if s.dirty { w = w.int(41, 1) }
        w = w.int(44, UInt64(s.captureVolumeRaw)).float32(46, 440)
        for slot in Slot.allCases { if let id = s.fxModel[slot] ?? nil, let v = Varint.read(id, at: 0)?.0 { w = w.int(slot.stateField, v) } }
        w = w.float32(53, Float(s.gateReduction + 108) / 255)
        if !s.gateOn { w = w.int(54, 1) }
        w = w.float32(56, Float(s.tempo))
        return w.build()
    }
    public static func settings(_ s: DemoState) -> [UInt8] {
        ProtoWriter().int(1, 1).int(3, 1).string(5, s.deviceName).int(6, UInt64(s.ledBrightness)).int(7, 1).int(8, 1).int(11, 0).int(12, 1).int(13, 129).int(14, 1).float32(17, s.usbVolumeDb).build()
    }
    /// The demo capture kinds, shared by the library reply and the details reply.
    static func kind(_ s: DemoState, _ i: Int) -> (type: String, instrument: String) {
        let type = [7, 8].contains(i) ? "combo" : i >= s.captureNames.count - 2 ? "pedal" : i == 9 ? "default" : "amp_head"
        let instrument = [5, 23].contains(i) ? "bass" : i == 9 ? "instrument_not_set" : "guitar"
        return (type, instrument)
    }
    static func demoHash(_ i: Int) -> String { String(repeating: "0", count: 62) + String(format: "%02x", i) }
    /// Type 18 for a capture slot (1-based): `{1:6 3:1 7:{author} 8:"" 9:hash 10:name 11:record}`, like the trace.
    public static func captureDetails(_ s: DemoState, slot: Int) -> [UInt8] {
        guard slot >= 1, slot <= s.captureNames.count, !s.captureNames[slot - 1].isEmpty else { return ProtoWriter().int(1, 6).int(3, 0).build() }
        let i = slot - 1, name = s.captureNames[i], k = kind(s, i)
        let words = name.split(separator: " ").map(String.init).filter { $0.count > 2 && Int($0) == nil }
        let rec = CaptureRecord(hash: demoHash(i), name: name, cloudUUID: "", authorId: "NeuralDSP", authorName: "NeuralDSP", deviceType: k.type,
                                tags: Array(words.prefix(3)) + ["Demo"], gainType: UInt64(4 + i % 5), instrumentType: k.instrument)
        return ProtoWriter().int(1, 6).int(3, 1).message(7, ProtoWriter().string(1, "NeuralDSP").string(2, "NeuralDSP")).string(8, "")
            .string(9, rec.hash).string(10, name).bytes(11, rec.encode()).build()
    }
    public static func library(_ s: DemoState) -> [UInt8] {
        var w = ProtoWriter()
        for (i, c) in s.captureNames.enumerated() {
            // Kinds vary like the Electron demo data: combos, pedals, a bass, one with nothing set.
            let (type, instrument) = kind(s, i)
            w = w.message(3, ProtoWriter().string(1, demoHash(i)).string(2, c).message(4, ProtoWriter().string(2, "Neural DSP")).string(6, type).string(10, instrument))
        }
        for i in s.irNames { w = w.string(4, i) }
        for u in s.libraryUser { w = w.message(5, ProtoWriter().string(1, u.hash).string(2, u.name).string(6, "pedal").string(10, "guitar")) }
        return w.build()
    }
}

/// Answers writes like the pedal does. Also records every write for assertions.
public actor FakePedal: NanoTransport {
    public private(set) var state: DemoState
    public private(set) var writes: [[UInt8]] = []
    private let hub = NotificationHub()
    private var reassembler = Frame.Reassembler()
    public var replyDelayMs: UInt64 = 5

    /// The sound as last saved: a preset change reloads it, so unsaved edits are dropped like on the real pedal.
    private var saved: DemoState
    public init(state: DemoState = .demo()) { self.state = state; self.saved = state }

    public nonisolated func subscribe() -> AsyncStream<[UInt8]> { hub.subscribe() }
    public func disconnect() { hub.finishAll() }
    public func setReplyDelay(_ ms: UInt64) { replyDelayMs = ms }
    /// The tempo changes on the pedal itself (hold footswitch I and tap): it plays it and says so with an unsolicited echo.
    public func tapTempoOnPedal(bpm: Double) {
        state.liveTempo = Tempo.clamp(bpm)
        reply(body: Self.tempoEcho(state.liveTempo), type: MessageType.tempo.rawValue)
        flush()
    }
    /// `{1: 1, 3: 1, 5: bpm}`, as recorded (`08 01 18 01 2D …`).
    static func tempoEcho(_ bpm: Double) -> [UInt8] { ProtoWriter().int(1, 1).int(3, 1).float32(5, Float(bpm)).build() }

    // Replies are queued during write() and emitted later, in order, like the real pedal's notifications.
    private var pending: [(body: [UInt8], type: UInt32)] = []
    private func reply(body: [UInt8], type: UInt32) { pending.append((body, type)) }
    private func dirty(_ on: Bool) { state.dirty = on; reply(body: on ? ProtoWriter().int(3, 1).build() : [], type: 115) }
    /// Puts the saved sound back (names, index and the library are kept).
    private func restoreSavedSound() {
        state.amp = saved.amp; state.captureVolumeRaw = saved.captureVolumeRaw; state.captureSlot = saved.captureSlot
        state.cabSlot = saved.cabSlot; state.cabLevelDb = saved.cabLevelDb; state.cabHighPassHz = saved.cabHighPassHz; state.cabLowPassHz = saved.cabLowPassHz
        state.cabMic = saved.cabMic; state.cabPosition = saved.cabPosition; state.gateOn = saved.gateOn; state.gateReduction = saved.gateReduction
        state.fxModel = saved.fxModel; state.fxOn = saved.fxOn; state.fxParams = saved.fxParams
        state.expression = saved.expression
    }
    private func flush() {
        let out = pending; pending = []
        guard !out.isEmpty else { return }
        let delay = replyDelayMs
        Task { [hub] in
            try? await Task.sleep(for: .milliseconds(delay))
            for r in out { for chunk in Frame.chunks(body: r.body, type: r.type, pad: false) { hub.yield(chunk) } }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        defer { flush() }
        writes.append(bytes)
        // Streamed messages (only capture uploads so far).
        if bytes.count >= 2, bytes[1] & 0xC0 != 0xC0 {
            guard let whole = reassembler.feed(bytes), whole.type == MessageType.uploadCapture.rawValue else { return }
            let rec = CaptureRecord.decode(ProtoFields.parse(whole.body).message(4) ?? ProtoFields.parse([]))
            state.libraryUser.append((rec.name, rec.hash))
            let record = ProtoWriter().int(1, UInt64(state.libraryUser.count - 1)).string(2, rec.name).string(3, rec.hash)
            reply(body: ProtoWriter().int(1, 6).int(3, 1).message(4, record).build(), type: 14)
            return
        }
        guard let type = Frame.type(of: bytes), let body = Frame.body(of: bytes) else { return }
        let f = ProtoFields.parse(body)
        switch type {
        case 1:   // metadata (1:3 only) or state request
            reply(body: StateEncoder.dump(state, withLists: f.int(3) == nil), type: 2)
        case 3:   // save
            state.presetTempos[Int(f.int(3) ?? 0)] = state.tempo
            state.dirty = false; saved = state
            reply(body: ProtoWriter().int(3, f.int(3) ?? 0).int(4, 1).build(), type: 4)
            dirty(false)
        case 26:  // knobs
            let id = f.int(3) ?? 0, v = Int(f.int(4) ?? 0)
            if let knob = AmpKnob.allCases.first(where: { $0.writeId == id }) { state.amp[knob] = v }
            else if id == 10 { state.captureVolumeRaw = v } else if id == 11 { state.gateReduction = v - 108 }
            dirty(true)
        case 28:  // slot select
            let what = f.int(3) ?? 0, v = Int(f.int(4) ?? 0)
            if what == 4 { state.captureSlot = v + 1 } else if what == 1 { state.captureSlot = 0 } else if what == 3 { state.cabSlot = v }
            dirty(true)
        case 31:  // enable
            let slot = f.int(3) ?? 0, on = (f.int(4) ?? 0) == 0
            if slot == 9 { state.gateOn = on } else if let s = Slot.allCases.first(where: { $0.enableSlot == slot }) { state.fxOn[s] = on }
            dirty(true)
        case 99:  // fx param
            if let s = Slot.allCases.first(where: { $0.modelSlot == (f.int(3) ?? 99) }), let idx = f.int(4), let v = f.first(5)?.float32 {
                var p = state.fxParams[s] ?? []; while p.count <= Int(idx) { p.append(0) }; p[Int(idx)] = v; state.fxParams[s] = p
            }
            dirty(true)
        case 136: // fx model: raw varint id after `18 slot 20`
            if let s = Slot.allCases.first(where: { $0.modelSlot == (f.int(3) ?? 99) }) { state.fxModel[s] = Varint.encode(f.int(4) ?? 0); state.fxParams[s] = nil }
            dirty(true)
        case 137: // fx refresh → type 138 { 1: 6, 4: floats }
            let s = Slot.allCases.first { $0.modelSlot == (f.int(3) ?? 99) }
            let model = s.flatMap { slot in (state.fxModel[slot] ?? nil).flatMap { id in Models.byId(id.map { String(format: "%02X", $0) }.joined(), in: slot.rawValue) } }
            let floats = s.flatMap { state.fxParams[$0] } ?? model?.params.map { FXParams.normalized($0.defaultValue, meta: $0.meta) } ?? []
            var bytes: [UInt8] = []; for x in floats { bytes += LE.bytes(x.bitPattern) }
            reply(body: ProtoWriter().int(1, 6).bytes(4, bytes).build(), type: 138)
        case 94:  // cab params / mic
            if let v = f.first(5)?.float32 { state.cabLevelDb = Cab.levelNormalizedToDb(Double(v)) }
            if let v = f.first(6)?.float32 { state.cabHighPassHz = Cab.normalizedToRange(Double(v), 20, 800) }
            if let v = f.first(7)?.float32 { state.cabLowPassHz = Cab.normalizedToRange(Double(v), 1000, 20000) }
            if let m = f.message(3) { if let mic = m.string(4) { state.cabMic = mic }; if let p = m.int(3) { state.cabPosition = Int(p) + 1 } }
            dirty(true)
        case 95:  // cab refresh → type 96
            let name = state.cabSlot > 0 ? state.irNames[state.cabSlot - 1] : ""
            let rec = ProtoWriter().int(1, UInt64(max(0, state.cabSlot - 1))).string(2, name).int(3, UInt64(state.cabPosition - 1)).string(4, state.cabMic).string(5, name + "/" + state.cabMic + "/\(state.cabPosition - 1)")   // 0-based in the name, as on the pedal
            let p = ProtoWriter().float32(1, Float(Cab.levelDbToNormalized(state.cabLevelDb))).float32(2, Float(Cab.rangeToNormalized(state.cabHighPassHz, 20, 800))).float32(3, Float(Cab.rangeToNormalized(state.cabLowPassHz, 1000, 20000)))
            reply(body: ProtoWriter().int(1, 6).int(3, 1).message(5, rec).message(8, p).build(), type: 96)
        case 50:  // delete preset → empty slot, notice 31, ack 51
            let i = Int(f.int(3) ?? 0)
            if i < state.presetNames.count { state.presetNames[i] = "" }
            reply(body: ProtoWriter().int(1, 1).build(), type: 31)
            reply(body: ProtoWriter().int(1, 6).int(3, UInt64(i)).int(4, 1).build(), type: 51)
        case 29 where f.int(4).map({ Int32(truncatingIfNeeded: $0) < 0 }) == true:   // footswitch assignment (field 4 = −1)
            for slot in FootswitchSlot.allCases {
                if let v = f.int(slot.presetSlotsField), Int32(truncatingIfNeeded: v) >= 0 { state.footswitch[slot] = Int(v) }
            }
            // The pedal reloads the current preset as stored: unsaved edits are gone (phone trace, PROTOCOL-NOTES §10).
            restoreSavedSound(); state.dirty = false
            reply(body: ProtoWriter().int(1, 1).build(), type: 115)
            reply(body: ProtoWriter().int(1, 1).build(), type: 31)
            reply(body: ProtoWriter().int(1, 1).int(4, 1).build(), type: 30)
        case 29:  // preset change (the footswitch slots stay as they are)
            state.presetIndex = Int(f.int(4) ?? 0); state.dirty = false
            restoreSavedSound()
            state.tempo = state.presetTempos[state.presetIndex] ?? Tempo.defaultBPM; state.liveTempo = state.tempo
            reply(body: ProtoWriter().int(4, 1).build(), type: 30)
            dirty(false)
        case 111: // rename
            let idx = Int(f.int(3) ?? 0); if idx < state.presetNames.count, let n = f.string(4) { state.presetNames[idx] = n }
            reply(body: ProtoWriter().int(3, UInt64(idx)).int(4, 1).build(), type: 112)
        case 76:  reply(body: StateEncoder.library(state), type: 77)
        case 80, 78:
            let slot = Int(f.int(3) ?? 0) + 1
            let item = f.message(4) ?? f.message(5)
            if let name = item?.string(2) {
                if type == 80, slot <= state.captureNames.count { state.captureNames[slot - 1] = name }
                if type == 78, slot <= state.irNames.count { state.irNames[slot - 1] = name }
            }
            reply(body: ProtoWriter().int(1, 6).int(3, 1).build(), type: type == 80 ? 81 : 79)
        case 46:  // device info → 47 {1:1 3:1 4:"" 5:firmware 6:serial 7:64 hex}
            let hash = SHA256.hash(data: Data(String(f.int(3) ?? 0).utf8)).map { String(format: "%02x", $0) }.joined()   // 64 hex, new per request like the pedal's
            reply(body: ProtoWriter().int(1, 1).int(3, 1).string(4, "").string(5, state.firmware).string(6, state.serial).string(7, hash).build(), type: 47)
        case 91:  // keep-alive → 92 {1:3 3:1 5:build 6:serial 7:name}
            reply(body: ProtoWriter().int(1, 3).int(3, 1).string(5, state.firmware + "+demo").string(6, state.serial).string(7, state.deviceName).build(), type: 92)
        case 65:  // settings → 66, the shape of the trace's first reply (unverified fields as read there)
            reply(body: StateEncoder.settings(state), type: 66)
        case 67:  // settings write → 68
            if let b = f.int(4) { state.ledBrightness = Int(min(b, 255)) }
            if let v = f.first(14)?.float32 { state.usbVolumeDb = v }
            reply(body: ProtoWriter().int(1, 1).int(3, 1).build(), type: 68)
        case 17:  // capture details → 18
            let slot = Int(f.int(3) ?? 0) + 1
            reply(body: StateEncoder.captureDetails(state, slot: slot), type: 18)
        case 145: // tempo (PROTOCOL-NOTES §11)
            if let bpm = f.first(5)?.float32.map({ Tempo.clamp(Double($0)) }) {
                if f.int(3) == 0 {
                    state.tempo = bpm; dirty(true)                 // into the preset: dirty, no echo (as recorded)
                } else {
                    state.liveTempo = bpm                          // live: echo, preset stays clean. The real pedal echoes
                    reply(body: Self.tempoEcho(bpm), type: 145)    // only the first write of a drag; echoing every one is harmless.
                }
            } else {
                reply(body: Self.tempoEcho(state.liveTempo), type: 145)   // query
            }
        case 60:  // expression read → notice 64, reply 61 (as in the phone-app trace)
            let i = Int(f.int(3) ?? 0)
            reply(body: ProtoWriter().int(1, 1).int(3, 2).build(), type: 64)
            reply(body: (state.expression[i] ?? ExpressionAssignments()).replyBody(), type: 61)
        case 62:  // expression save: replaces the set → ack 63, dirty 115
            let (i, set) = ExpressionAssignments.parse(save: body)
            state.expression[i] = set.isEmpty ? nil : set
            reply(body: ProtoWriter().int(1, 1).int(3, 1).build(), type: 63)
            dirty(true)
        case 127: // tuner: echo
            state.tunerOn = (f.int(4) ?? 0) == 1
            reply(body: body, type: 127)
        default: break
        }
    }
}
