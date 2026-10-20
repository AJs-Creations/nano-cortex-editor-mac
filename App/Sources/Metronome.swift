// Metronome: sample-accurate clicks from AVAudioEngine, with the output device selectable
// (CoreAudio device list → the output unit's CurrentDevice), tap tempo, and per role (accent, main beat,
// subdivision) a synthesized click sound or the user's own sample (MetronomeSounds.swift). Volume, output, sounds,
// levels, the opening mode and the Advanced setup live in AppSettings (Settings → Metronome).
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
        var sound = ""          // "sample", a built-in sound's name, or "mute"
        var cut = false         // the sound was longer than the gap to the next event and ended there
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
    /// Per role: a built-in sound or a sample (Settings → Metronome → Sounds).
    var sounds: MetronomeSounds { settings.metroSounds }
    /// One built-in sound for every role (the dev remote's `sound=`), as if picked in each row.
    var sound: ClickSound {
        get { settings.metroSounds.main.builtIn }
        set { for r in SoundRole.allCases { setBuiltIn(newValue, for: r) } }
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
    /// Why the last picked sample wasn't used (shown under Settings → Sounds); cleared by the next pick.
    var sampleError: String?
    private var taps = TapTempo()

    private let settings = AppSettings.shared
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var voices: [MetronomePattern.Role: Voice] = [:]
    /// The users' samples, decoded once (mono, engine rate), by role.
    private var samples: [SoundRole: [Float]] = [:]
    private let sampleStore = SampleStore.standard
    /// The Activity log and toasts go through the store (`setReporter`); lines from before it attaches wait here.
    private var reporter: ((_ line: String, _ toast: String?) -> Void)?
    private var waitingReports: [(String, String?)] = []
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
        loadSamples()
        makeBuffers()
        refreshOutputs()
    }

    /// Each role's sound: its sample when one is loaded, otherwise its built-in sound.
    private var source: MetronomeClickSource { MetronomeClickSource(sounds: sounds, samples: samples) }

    /// One role's sound as the scheduler plays it, with its level applied. The first 10 ms is its own buffer, which
    /// carries the completion callback (indicator, played log); the rest follows in a second, contiguous buffer, so the
    /// indicator doesn't wait for a long sample to end.
    private struct Voice {
        static let headFrames = 480   // 10 ms at 48 kHz
        let samples: [Float]
        let head: AVAudioPCMBuffer
        let tail: AVAudioPCMBuffer?
        let tag: String
        init?(_ x: [Float], tag: String, format: AVAudioFormat) {
            guard let parts = Self.split(x, format: format) else { return nil }
            samples = x; head = parts.head; tail = parts.tail; self.tag = tag
        }
        static func split(_ x: [Float], format: AVAudioFormat) -> (head: AVAudioPCMBuffer, tail: AVAudioPCMBuffer?)? {
            guard let h = Metronome.buffer(Array(x.prefix(headFrames)), format: format) else { return nil }
            return (h, x.count > headFrames ? Metronome.buffer(Array(x.dropFirst(headFrames)), format: format) : nil)
        }
        /// The buffers for an event with `room` frames before the next one: as made, or cut there with a fade.
        func segments(room: Int, format: AVAudioFormat) -> (head: AVAudioPCMBuffer, tail: AVAudioPCMBuffer?, cut: Bool) {
            guard samples.count > room, let parts = Self.split(ClickCut.cut(samples, room: max(1, room), fade: ClickCut.fadeFrames(rate: format.sampleRate)), format: format) else { return (head, tail, false) }
            return (parts.head, parts.tail, true)
        }
    }

    private func makeBuffers() {
        let rate = format.sampleRate, src = source, lv = levels
        var out: [MetronomePattern.Role: Voice] = [:]
        for role in MetronomePattern.Role.allCases {
            if role == .mute { out[role] = Voice([0], tag: "mute", format: format); continue }
            let g = Float(lv.gain(role))
            out[role] = Voice(src.samples(for: role, rate: rate).map { $0 * g }, tag: src.tag(for: role), format: format)
        }
        voices = out
    }
    nonisolated fileprivate static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)), let p = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: samples.count) }
        return b
    }

    /// One bar's worth of the current sounds (accent, main beat, main beat), when the metronome is stopped. Each sound
    /// ends where the next starts, as in the scheduler.
    func preview() {
        let gap = Int(format.sampleRate * 0.28), fade = ClickCut.fadeFrames(rate: format.sampleRate)
        let a = voices[.accent]?.samples ?? [], c = voices[.normal]?.samples ?? []
        let pad = { (x: [Float]) in let y = ClickCut.cut(x, room: gap, fade: fade); return y + [Float](repeating: 0, count: gap - y.count) }
        play(pad(a) + pad(c) + c)
    }
    /// One role's sound, whole (a sample up to its 2 s), at its level: the ▶ in Settings → Sounds.
    func preview(_ role: SoundRole) { play(voices[role.engineRole]?.samples ?? []) }
    private func play(_ x: [Float]) {
        guard !running, let buf = Self.buffer(x, format: format) else { return }
        error = nil
        previewStop?.cancel()
        player.stop(); engine.stop()
        applyOutput()
        do { try engine.start() } catch { self.error = "Audio engine: \(error.localizedDescription)"; return }
        player.volume = Float(volume)
        player.scheduleBuffer(buf, at: nil, options: [])
        player.play()
        let seconds = Double(x.count) / format.sampleRate + 0.25
        previewStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.running else { return }
            self.player.stop(); self.engine.stop()
        }
    }

    // MARK: sounds and samples

    /// Picks a built-in sound for a role; a sample set for it is deleted (picking a built-in is a Reset to that sound).
    func setBuiltIn(_ sound: ClickSound, for role: SoundRole) {
        sampleError = nil
        if sounds[role].sample != nil { sampleStore.remove(role); samples[role] = nil }
        var s = sounds; s[role] = .init(builtIn: sound, sample: nil); settings.metroSounds = s
        makeBuffers()
    }
    /// Checks `url`, copies it into the Metronome Sounds folder and plays it for `role` from the next click. Returns
    /// whether it's used; the reason otherwise is in `sampleError` and the log. A sample longer than 2 s is trimmed (toast).
    @discardableResult
    func setSample(from url: URL, for role: SoundRole) -> Bool {
        sampleError = nil
        do {
            let (sample, loaded) = try sampleStore.install(url, for: role, rate: format.sampleRate)
            samples[role] = loaded.samples
            var s = sounds; s[role].sample = sample; settings.metroSounds = s
            makeBuffers()
            let ms = Int((Double(loaded.samples.count) / format.sampleRate * 1000).rounded())
            report("Metronome: \(role.title) plays \(sample.name) (\(ms) ms, \(Int(loaded.sourceRate)) Hz, \(loaded.channels) ch\(loaded.trimmed ? String(format: ", first 2 s of %.1f s", loaded.seconds) : ""))",
                   toast: loaded.trimmed ? "Only the first 2 seconds of \(sample.name) play." : nil)
            return true
        } catch {
            sampleError = "Couldn't use \(url.lastPathComponent): \(error.localizedDescription)"
            report("Metronome: \(sampleError ?? "")")
            return false
        }
    }
    /// Back to the role's built-in sound; the copy is deleted.
    func resetSample(_ role: SoundRole) {
        sampleStore.remove(role); samples[role] = nil
        var s = sounds; s[role].sample = nil; settings.metroSounds = s
        sampleError = nil
        makeBuffers()
    }
    /// The stored samples, decoded once at launch. A missing or unreadable one falls back to the role's built-in sound
    /// (the choice is cleared) with a log line and one toast.
    private func loadSamples() {
        let r = sampleStore.loadAll(sounds, rate: format.sampleRate)
        samples = r.samples
        if r.sounds != sounds { settings.metroSounds = r.sounds }
        for (i, p) in r.problems.enumerated() {
            report("Metronome: " + p, toast: i > 0 ? nil : r.problems.count == 1 ? p : "Some metronome samples are missing; their built-in sounds play instead.")
        }
    }
    /// Activity log lines and toasts, through the store (`PedalStore.attach`). Lines from before that are delivered then.
    func setReporter(_ f: @escaping (_ line: String, _ toast: String?) -> Void) {
        reporter = f
        for (line, toast) in waitingReports { f(line, toast) }
        waitingReports = []
    }
    private func report(_ line: String, toast: String? = nil) {
        if let reporter { reporter(line, toast) } else { waitingReports.append((line, toast)) }
    }
    /// The dev remote's view of each role: what plays and the buffer it plays from.
    var soundReport: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: SoundRole.allCases.map { r in
            let c = sounds[r], v = voices[r.engineRole]
            let peak = v?.samples.map(abs).max() ?? 0
            return (r.rawValue, ["builtIn": c.builtIn.rawValue, "sample": c.sample?.name ?? "", "file": c.sample?.file ?? "",
                                 "fileExists": c.sample.map { FileManager.default.fileExists(atPath: sampleStore.url($0.file).path) } ?? false,
                                 "playing": v?.tag ?? "", "frames": v?.samples.count ?? 0, "peak": (Double(peak) * 1000).rounded() / 1000] as [String: Any])
        })
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
        var pending: (played: Played, frame: Double)?   // placed, not yet scheduled: waits for the next event's time
        scheduler = Task { [weak self] in
            // Schedule two beats ahead, sample-accurately. Each event is placed relative to the previous one at the
            // current tempo, so tempo changes (slider, ramp) take effect without drift; bars change only at their end.
            // An event goes to the player once the next one is placed, so its sound can end where the next starts
            // (`schedule`); that is still at least a beat ahead.
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
                    if let p = pending { self.schedule(p.played, at: p.frame, next: frame, rate: rate, gen: gen) }
                    pending = (Played(bar: barIndex, kind: kind, event: ev, time: (frame - firstFrame) / rate, bpm: self.effectiveTempo), frame)
                    cursorFrame = frame; cursorBeat = ev.offset; idx += 1
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }
    /// Schedules an event's sound, ending where the next event (at `next`) starts: a player node plays one buffer at a
    /// time, and a later buffer interrupts a sounding one, which then resumes (`ClickCut`, DECISIONS #25).
    private func schedule(_ played: Played, at frame: Double, next: Double, rate: Double, gen: Int) {
        guard let voice = voices[played.event.role] else { return }
        let start = AVAudioFramePosition(frame.rounded())
        let (head, tail, cut) = voice.segments(room: Int(AVAudioFramePosition(next.rounded()) - start), format: format)
        var p = played
        p.sound = voice.tag; p.cut = cut
        player.scheduleBuffer(head, at: AVAudioTime(sampleTime: start, atRate: rate), options: [], completionCallbackType: .dataPlayedBack) { [weak self, p] _ in
            Task { @MainActor in
                guard let self, self.running, self.generation == gen else { return }
                self.beat = p.event.beat; self.sub = p.event.sub; self.bar = p.bar; self.barKind = p.kind
                if p.event.sub == 0 { self.count += 1 }
                self.played.append(p)
                if self.played.count > 4000 { self.played.removeFirst(self.played.count - 4000) }
            }
        }
        if let tail { player.scheduleBuffer(tail, at: AVAudioTime(sampleTime: start + AVAudioFramePosition(head.frameLength), atRate: rate), options: []) }
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
