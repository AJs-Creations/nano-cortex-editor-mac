// Metronome: sample-accurate clicks from AVAudioEngine, with the output device selectable
// (CoreAudio device list → the output unit's CurrentDevice), tap tempo, and a choice of synthesized
// click sounds. Volume, output, sound, levels, the opening mode and the Advanced setup live in AppSettings
// (Settings → Metronome).
//
// Simple mode is the original metronome (beats 1–12, accent on beat 1). Advanced mode plays a
// `MetronomeSetup`: time signature, accent pattern, subdivisions with swing, count-in, tempo and gap trainers.
// Both go through the same scheduler: `MetronomePattern.events` makes one bar at a time, events are scheduled
// two beats ahead on the player's sample clock, and the trainers only change inputs between bars.

import SwiftUI
import AVFoundation
import CoreAudio

enum MetronomeMode: String, CaseIterable, Identifiable {
    case simple, advanced
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor @Observable
final class Metronome {
    struct Output: Identifiable, Hashable { let id: AudioDeviceID; let name: String }
    /// A played (or silently passed, for `mute`) event, for the indicator and the dev remote.
    struct Played: Sendable {
        let bar: Int            // absolute bar index, count-in included
        let kind: MetronomePattern.BarKind
        let event: MetronomePattern.Event
        let time: Double        // seconds from the first event, on the sample clock
        let bpm: Int
    }

    var open = false
    var running = false
    var mode: MetronomeMode
    // The tempo starts at Settings' default each launch; the overlay changes it for the session.
    // No clamping inside didSet: with @Observable that re-enters the setter forever. Clamp through set(bpm:)/set(beats:).
    var bpm: Int
    var beats: Int              // Simple mode's beats per bar
    // Volume, output, sound, levels and the Advanced setup are shared with Settings (AppSettings persists them).
    var volume: Double {
        get { settings.metroVolume }
        set { settings.metroVolume = newValue; player.volume = Float(newValue) }
    }
    var outputID: AudioDeviceID {
        get { settings.metroOutput }
        set { let old = settings.metroOutput; settings.metroOutput = newValue; if old != newValue, running { restart() } }
    }
    var sound: ClickSound {
        get { settings.metroSound }
        set { settings.metroSound = newValue; makeBuffers() }
    }
    var levels: MetronomeLevels {
        get { settings.metroLevels }
        set { settings.metroLevels = newValue; makeBuffers() }
    }
    var setup: MetronomeSetup {
        get { settings.metroSetup }
        set { settings.metroSetup = newValue }
    }
    var levelsOpen = false      // the Levels… popover
    /// The typeable field being edited (a stepper's id, or "bpm"): while set, Space and Esc belong to the field,
    /// not to Start and Close.
    var editingField: String?
    /// Asks the field with this id to take focus (the dev remote's `focus=`); the field clears it.
    var focusRequest: String?

    // Tempo source (PLAN row 25, DECISION #17). With Settings → Metronome "Follow the preset tempo" on and a pedal
    // connected, the metronome's BPM mirrors the preset tempo (`adopt`), and changes made here go to the pedal through
    // `onTempoChanged` (the store writes them live and commits them into the preset once they settle).
    var presetTempo: Int?
    /// Whether the store has a preset tempo to follow (connected, state read). Set by `PedalStore.attach`.
    var presetLinked: () -> Bool = { false }
    var tempoFollowsPreset: Bool { settings.metroFollowsPreset && presetLinked() }
    var effectiveTempo: Int { tempoFollowsPreset ? (presetTempo ?? bpm) : bpm }
    /// (bpm, commit): commit is false for the tempo trainer's steps, which the pedal only plays.
    var onTempoChanged: ((Int, Bool) -> Void)?

    func set(bpm v: Int, commit: Bool = true) {
        let v = max(30, min(300, v))
        guard v != bpm else { return }
        bpm = v
        if tempoFollowsPreset { presetTempo = v }
        onTempoChanged?(v, commit)
    }
    /// The preset's tempo, from the store (preset load, edits, the pedal's own tap). Never writes back.
    func adopt(presetTempo v: Int?) {
        presetTempo = v
        if tempoFollowsPreset, let v, v != bpm { bpm = v }
    }
    func set(beats v: Int) { beats = max(1, min(12, v)) }

    var outputs: [Output] = []
    // Indicator state, set when each event plays.
    var beat = -1               // currently sounding beat
    var sub = -1                // currently sounding subdivision tick (0 on the beat)
    var bar = 0                 // absolute bar index of the sounding event
    var barKind: MetronomePattern.BarKind = .play
    var count = 0               // beats (sub 0) played since Start, muted ones included
    var played: [Played] = []   // the last 4000 events since Start
    /// The tempo trainer's start tempo while it runs (nil when off).
    var rampFrom: Int?
    var error: String?
    private var taps = TapTempo()

    private let settings = AppSettings.shared
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var buffers: [MetronomePattern.Role: AVAudioPCMBuffer] = [:]
    private var silent: AVAudioPCMBuffer?
    private var scheduler: Task<Void, Never>?
    private var previewStop: Task<Void, Never>?
    private var generation = 0
    private var rampStartBar = 0
    private var rampLast: Int?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

    init() {
        bpm = AppSettings.shared.metroDefaultBPM
        beats = AppSettings.shared.metroDefaultBeats
        mode = AppSettings.shared.metroOpensIn
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        makeBuffers()
        refreshOutputs()
    }

    /// The sound source for every role (synthesized today; a sample-file source can replace it).
    private var source: ClickSource { SynthClickSource(sound: sound) }

    private func makeBuffers() {
        let rate = format.sampleRate, src = source, lv = levels
        var out: [MetronomePattern.Role: AVAudioPCMBuffer] = [:]
        for role in MetronomePattern.Role.allCases where role != .mute {
            let g = Float(lv.gain(role))
            out[role] = Self.buffer(src.samples(for: role, rate: rate).map { $0 * g }, format: format)
        }
        buffers = out
        silent = Self.buffer([0], format: format)
    }
    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let p = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: samples.count) }
        return b
    }

    /// One bar's worth of the current sound (accent, click, click), when the metronome is stopped.
    func preview() {
        guard !running else { return }
        let rate = format.sampleRate, src = source, lv = levels
        let gap = [Float](repeating: 0, count: Int(rate * 0.28))
        let a = src.samples(for: .accent, rate: rate).map { $0 * Float(lv.gain(.accent)) }
        let c = src.samples(for: .normal, rate: rate).map { $0 * Float(lv.gain(.normal)) }
        let pad = { (x: [Float]) in x + gap.dropFirst(min(gap.count, x.count)) }
        guard let buf = Self.buffer(pad(a) + pad(c) + c, format: format) else { return }
        error = nil
        previewStop?.cancel()
        player.stop(); engine.stop()
        applyOutput()
        do { try engine.start() } catch { self.error = "Audio engine: \(error.localizedDescription)"; return }
        player.volume = Float(volume)
        player.scheduleBuffer(buf, at: nil, options: [])
        player.play()
        previewStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled, !self.running else { return }
            self.player.stop(); self.engine.stop()
        }
    }

    // MARK: outputs (CoreAudio)
    func refreshOutputs() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return }
        outputs = ids.compactMap { id in
            var out = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &out, 0, nil, &s) == noErr, s > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>? = nil
            var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, &name) == noErr, let n = name?.takeRetainedValue() else { return nil }
            if (n as String).hasPrefix("CADefaultDeviceAggregate") { return nil }   // CoreAudio's own aggregate, not a user device
            return Output(id: id, name: n as String)
        }
        if outputID != 0, !outputs.contains(where: { $0.id == outputID }) { outputID = 0 }
    }
    private func applyOutput() {
        guard let unit = engine.outputNode.audioUnit else { return }
        var id = outputID == 0 ? defaultOutput() : outputID
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr { error = "Could not switch the metronome output (\(status)); using the system default."; outputID = 0 }
    }
    private func defaultOutput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0; var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    // MARK: pattern

    /// Beats in the bar the current mode plays.
    var barBeats: Int { mode == .advanced ? setup.beats : beats }
    /// What bar `index` (count-in included) is and its events, for the current mode. Simple: no count-in, no trainers.
    func barPlan(_ index: Int) -> (kind: MetronomePattern.BarKind, events: [MetronomePattern.Event]) {
        switch mode {
        case .simple:
            return (.play, MetronomePattern.events(beats: beats, accents: MetronomePattern.defaultAccents(beats)))
        case .advanced:
            let s = setup, k = s.barKind(index)
            return (k, s.events(kind: k))
        }
    }
    /// The tempo trainer, asked at each bar boundary: bar `index` is about to be scheduled.
    private func applyTrainers(at index: Int) {
        guard mode == .advanced, setup.rampOn else { rampFrom = nil; rampLast = nil; return }
        let s = setup
        if rampFrom == nil { rampFrom = bpm; rampStartBar = max(index, s.countIn); rampLast = bpm }
        let completed = index - rampStartBar
        guard completed >= 0, let from = rampFrom else { return }
        let t = MetronomePattern.rampTempo(start: from, target: s.rampTarget, step: s.rampStep, every: s.rampEvery, barsCompleted: completed)
        if t != rampLast { rampLast = t; set(bpm: t, commit: false) }
    }
    /// "ramping 96 → 120", or "reached 120".
    var rampStatus: String? {
        guard mode == .advanced, setup.rampOn else { return nil }
        guard running, let from = rampFrom else { return "ramp to \(setup.rampTarget)" }
        return bpm == setup.rampTarget && from != setup.rampTarget ? "reached \(setup.rampTarget)" : "ramping \(from) → \(setup.rampTarget)"
    }

    // MARK: transport
    func toggle() { running ? stop() : start() }
    func start() {
        guard !running else { return }
        error = nil
        previewStop?.cancel(); player.stop()
        engine.stop()
        applyOutput()
        do { try engine.start() } catch { self.error = "Audio engine: \(error.localizedDescription)"; return }
        running = true; beat = -1; sub = -1; bar = 0; barKind = .play; count = 0; played = []
        rampFrom = nil; rampLast = nil
        generation += 1
        let gen = generation
        player.volume = Float(volume)
        player.play()
        let rate = format.sampleRate
        applyTrainers(at: 0)
        var barIndex = 0
        var (kind, events) = barPlan(0)
        var barLen = Double(barBeats)
        var idx = 0
        var cursorFrame = -1.0     // sample time of the last scheduled event (or bar start)
        var cursorBeat = 0.0       // its offset in the bar
        var firstFrame = 0.0
        scheduler = Task { [weak self] in
            // Schedule two beats ahead, sample-accurately. Each event is placed relative to the previous one at the
            // current tempo, so tempo changes (slider, ramp) take effect without drift; bars change only at their end.
            while let self, !Task.isCancelled, self.running, self.generation == gen {
                guard let t = self.player.lastRenderTime, let pt = self.player.playerTime(forNodeTime: t) else { try? await Task.sleep(for: .milliseconds(20)); continue }
                var fpb = rate * 60 / Double(self.effectiveTempo)
                if cursorFrame < 0 { cursorFrame = Double(pt.sampleTime) + rate * 0.05; firstFrame = cursorFrame }
                let horizon = Double(pt.sampleTime) + 2 * fpb
                while true {
                    if idx == events.count {   // bar boundary: the trainers may change the tempo, then the next bar
                        cursorFrame += (barLen - cursorBeat) * fpb; cursorBeat = 0
                        barIndex += 1
                        self.applyTrainers(at: barIndex)
                        (kind, events) = self.barPlan(barIndex)
                        barLen = Double(self.barBeats); idx = 0
                        fpb = rate * 60 / Double(self.effectiveTempo)
                    }
                    let ev = events[idx]
                    let frame = cursorFrame + (ev.offset - cursorBeat) * fpb
                    if frame >= horizon { break }
                    self.schedule(Played(bar: barIndex, kind: kind, event: ev, time: (frame - firstFrame) / rate, bpm: self.effectiveTempo), at: frame, rate: rate, gen: gen)
                    cursorFrame = frame; cursorBeat = ev.offset; idx += 1
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
    private func schedule(_ p: Played, at frame: Double, rate: Double, gen: Int) {
        guard let buf = (p.event.role == .mute ? silent : buffers[p.event.role]) else { return }
        player.scheduleBuffer(buf, at: AVAudioTime(sampleTime: AVAudioFramePosition(frame.rounded()), atRate: rate), options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == gen else { return }
                self.beat = p.event.beat; self.sub = p.event.sub; self.bar = p.bar; self.barKind = p.kind
                if p.event.sub == 0 { self.count += 1 }
                self.played.append(p)
                if self.played.count > 4000 { self.played.removeFirst(self.played.count - 4000) }
            }
        }
    }
    func stop() {
        guard running else { return }
        running = false; beat = -1; sub = -1
        generation += 1
        scheduler?.cancel(); scheduler = nil
        player.stop(); engine.stop()
        // The tempo trainer goes back to where it started, ready for the next run.
        if let from = rampFrom { set(bpm: from, commit: false) }
        rampFrom = nil; rampLast = nil
    }
    private func restart() { stop(); start() }
    func tap() { if let v = taps.tap() { set(bpm: v) } }
    func close() { stop(); levelsOpen = false; editingField = nil; open = false }

    /// Main-bar number for the display (1-based, count-in excluded).
    var barLabel: String {
        guard running, beat >= 0 else { return mode == .advanced && setup.countIn > 0 ? "Count-in \(setup.countIn) bar\(setup.countIn == 1 ? "" : "s")" : "Bar –" }
        switch barKind {
        case .countIn: return "Count-in \(bar + 1)/\(setup.countIn)"
        case .play: return "Bar \(bar - (mode == .advanced ? setup.countIn : 0) + 1)"
        case .muted: return "Bar \(bar - setup.countIn + 1) · muted"
        }
    }
}

/// The synthesized sounds as a `ClickSource`: accent and normal/soft from `ClickSound`, subdivisions a quieter,
/// higher variant of the normal click (pitched up a fifth by resampling).
struct SynthClickSource: ClickSource {
    let sound: ClickSound
    func samples(for role: MetronomePattern.Role, rate: Double) -> [Float] {
        switch role {
        case .accent: ClickSound.samples(sound, accent: true, rate: rate)
        case .normal, .soft: ClickSound.samples(sound, accent: false, rate: rate)
        case .sub: Self.pitched(ClickSound.samples(sound, accent: false, rate: rate), by: 1.5).map { $0 * 0.8 }
        case .mute: []
        }
    }
    /// Linear-interpolation resample: `ratio` > 1 raises the pitch and shortens the sound.
    static func pitched(_ x: [Float], by ratio: Double) -> [Float] {
        guard x.count > 1 else { return x }
        let n = Int(Double(x.count) / ratio)
        return (0..<n).map { i in
            let p = Double(i) * ratio, j = Int(p), f = Float(p - Double(j))
            return j + 1 < x.count ? x[j] * (1 - f) + x[j + 1] * f : x[j]
        }
    }
}

/// The click sounds, synthesized (no sample files). `samples` is pure so the dev remote can report on it.
enum ClickSound: String, CaseIterable, Identifiable {
    case click, woodblock, tick, beep, cowbell
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    static func samples(_ sound: ClickSound, accent: Bool, rate: Double) -> [Float] {
        switch sound {
        case .click:      // the original: short decaying sines, 1 kHz / 1.6 kHz
            return synth(rate: rate, ms: accent ? 36 : 28, normalize: false) { t, i in sin(2 * .pi * (accent ? 1600 : 1000) * t) * exp(-t * 90) * min(1, Double(i) / 48) }
        case .woodblock:  // resonant 800 Hz (accent 1.2 kHz), sharp attack, ~40 ms decay, a quick inharmonic overtone
            let f: Double = accent ? 1200 : 800
            return synth(rate: rate, ms: 60) { t, i in
                let atk = min(1, Double(i) / (rate * 0.0005))
                return atk * (sin(2 * .pi * f * t) * exp(-t * 110) + 0.35 * sin(2 * .pi * f * 2.76 * t) * exp(-t * 260))
            }
        case .tick:       // a noise burst band-passed around 4 kHz (accent 5 kHz, a little longer)
            var noise = Noise(seed: accent ? 7 : 3)
            var bp = Biquad.bandPass(hz: accent ? 5000 : 4000, q: 2.2, rate: rate)
            let decay: Double = accent ? 230 : 320
            return synth(rate: rate, ms: accent ? 22 : 16) { t, i in bp.process(noise.next()) * exp(-t * decay) * min(1, Double(i) / 12) }
        case .beep:       // a longer 880 Hz sine (accent an octave up), soft edges
            let f: Double = accent ? 1760 : 880
            let len = 0.09
            return synth(rate: rate, ms: len * 1000, peak: 0.55) { t, _ in /* sustained, so a lower peak for similar loudness */ sin(2 * .pi * f * t) * min(1, t / 0.003) * min(1, (len - t) / 0.008) }
        case .cowbell:    // two detuned square-ish partials ~560/845 Hz (accent a fourth up), short
            let k: Double = accent ? 4.0 / 3 : 1
            func sq(_ f: Double, _ t: Double) -> Double { tanh(3 * sin(2 * .pi * f * t)) }
            return synth(rate: rate, ms: 110) { t, i in
                let env = exp(-t * 32) * min(1, Double(i) / (rate * 0.0008))
                return (0.55 * sq(562 * k, t) + 0.45 * sq(845 * k, t)) * env
            }
        }
    }

    private static func synth(rate: Double, ms: Double, normalize: Bool = true, peak target: Float = 0.9, _ f: (Double, Int) -> Double) -> [Float] {
        let n = Int(rate * ms / 1000)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(f(Double(i) / rate, i)) }
        if normalize, let peak = out.map(abs).max(), peak > 0 { let g = target / peak; for i in 0..<n { out[i] *= g } }
        return out
    }

    private struct Noise {   // deterministic white noise (LCG), so the buffers are reproducible
        var state: UInt32
        init(seed: UInt32) { state = seed }
        mutating func next() -> Double { state = state &* 1664525 &+ 1013904223; return Double(state) / Double(UInt32.max) * 2 - 1 }
    }
    private struct Biquad {  // RBJ cookbook band-pass (constant 0 dB peak gain)
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        static func bandPass(hz: Double, q: Double, rate: Double) -> Biquad {
            let w = 2 * Double.pi * hz / rate, alpha = sin(w) / (2 * q), a0 = 1 + alpha
            return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
        }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
}
