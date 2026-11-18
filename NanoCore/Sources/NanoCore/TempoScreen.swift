// NanOS 2.3+ tempo: the pedal's TempoScreenMessage (type 145) and its metronome. Measured on Anup's pedal on 2026-11-17
// (DECISIONS #41, #42; PROTOCOL-NOTES §11): the pedal clamps the tempo to 40–240 BPM and keeps decimals; the first
// `3:1` frame after a close only "opens the screen" (its tempo is ignored, the pedal answers `{1:1 3:1 5:bpm}` with
// the tempo it had); later `3:1` frames set the tempo; a `3:0` frame only closes. It never reports its metronome
// settings (not in the 145 answer, not in the state dump), so the editor keeps its own copy (`PedalMetronome`), and
// every `3:1` frame is whole (fields 3–11) carrying it: a frame without fields 7–11 makes the pedal reset them to their
// defaults (heard 2026-11-18: after a tempo change the subdivision fell back to 1/4, the volume to 0 dB). State field
// 60 is tempoScreenActive (1 while the screen is open).
// Firmware older than 2.3 keeps the 1.2.3 frames (`Writes.tempo`), timing and 30–300 range byte for byte.
//
// `TempoScreen` is the sequence as a pure state machine (the Electron edition's `scr` in pro/ui.js, "preset tempo"):
// open with a whole frame carrying the pedal's current tempo and mode → the pedal's answer or 300 ms → the writes (the
// last value wins, at least 120 ms apart) → `{3:0}` once the change has settled (or when the metronome's Pedal tab
// closes) → a state read (the edited flag, the pedal's clamped tempo). The caller runs its `Action`s: writes in order,
// timers it reports back with `fired(_:now:)`, state reads.

import Foundation

public enum Tempo23 {
    /// The pedal's tempo range on NanOS 2.3.0 (it clamps 241 → 240, 30 and 39 → 40).
    public static let range: ClosedRange<Double> = 40...240
    /// Firmware 2.3 or newer (a readable version only; "2.3.0+abc" counts).
    public static func applies(firmware: String?) -> Bool {
        guard let firmware, let c = Compatibility.compare(firmware, "2.3") else { return false }
        return c != .orderedAscending
    }
    /// Into the pedal's range, one decimal kept (Electron's clampTempo on 2.3).
    public static func clamp(_ bpm: Double) -> Double { (min(range.upperBound, max(range.lowerBound, bpm)) * 10).rounded() / 10 }
    /// "120", or "120.5" when the tempo is not a whole number (Electron's fmtTempo).
    public static func format(_ bpm: Double) -> String { bpm == bpm.rounded() ? String(Int(bpm)) : String(format: "%.1f", bpm) }
    /// Delays, in seconds (Electron: TEMPO_GAP, TEMPO_OPEN_WAIT, TEMPO_REREAD; COMMIT_STEP, COMMIT_TAP, COMMIT_METRO).
    public static let gap = 0.12, openWait = 0.3, reread = 0.3, busyAfterWrite = 0.5
    public static let settleStep = 0.8, settleTap = 2.6, settleMetronome = 1.5
}

/// The pedal metronome's settings as the editor last sent them (fields 7–11 of a whole TempoScreenMessage). The pedal
/// never reports them; defaults as the official app showed them: muted, 0 dB, 4/4, 1/4, Blip.
public struct PedalMetronome: Equatable, Sendable, Codable {
    public var muted = true
    /// dB, −60…+9 in 0.5 dB steps.
    public var volume = 0.0
    /// Index into `timeSignatures`.
    public var timeSig = 2
    /// Index into `notes` (the subdivision).
    public var note = 0
    /// Index into `sounds`.
    public var sound = 0
    public init(muted: Bool = true, volume: Double = 0, timeSig: Int = 2, note: Int = 0, sound: Int = 0) {
        self.muted = muted; self.volume = volume; self.timeSig = timeSig; self.note = note; self.sound = sound
    }

    /// The official app's 21, in its order (upstream's METRO_TIME_SIGS).
    public static let timeSignatures = ["2/4", "3/4", "4/4", "5/4", "6/4", "7/4", "8/4", "9/4", "10/4", "11/4", "12/4", "13/4", "3/8", "6/8", "9/8", "12/8",
                                        "5/8 (3+2)", "5/8 (2+3)", "7/8 (3+2+2)", "7/8 (2+3+2)", "7/8 (2+2+3)"]
    public static let notes = ["1/4", "1/8", "1/8T", "1/16"]
    public static let sounds = ["Blip", "Digital"]
    public static let volumeRange: ClosedRange<Double> = -60...9

    /// Every value put into range (volume on its 0.5 dB step); an index out of range falls back to the default.
    public var normalized: PedalMetronome {
        var m = self
        m.volume = min(Self.volumeRange.upperBound, max(Self.volumeRange.lowerBound, (volume * 2).rounded() / 2))
        if !Self.timeSignatures.indices.contains(timeSig) { m.timeSig = 2 }
        if !Self.notes.indices.contains(note) { m.note = 0 }
        if !Self.sounds.indices.contains(sound) { m.sound = 0 }
        return m
    }
    /// "−6 dB", "0 dB", "+4.5 dB" (Electron's fmtDb).
    public static func formatDb(_ v: Double) -> String { (v > 0 ? "+" : v < 0 ? "−" : "") + Tempo23.format(abs(v)) + " dB" }
    /// The Activity log's words for a whole frame ("metronome on -6.0 dB, 3/4, 1/8, Digital").
    public var summary: String {
        let n = normalized
        return "metronome " + (n.muted ? "off" : "on " + String(format: "%.1f", n.volume) + " dB") + ", " + Self.timeSignatures[n.timeSig] + ", " + Self.notes[n.note] + ", " + Self.sounds[n.sound]
    }

    // Keys as Electron's localStorage "pedalMetronome"; a missing or unreadable key keeps its default.
    private enum CodingKeys: String, CodingKey { case muted, volume, timeSig, note, sound }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PedalMetronome()
        muted = (try? c.decodeIfPresent(Bool.self, forKey: .muted)) ?? d.muted
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? d.volume
        timeSig = (try? c.decodeIfPresent(Int.self, forKey: .timeSig)) ?? d.timeSig
        note = (try? c.decodeIfPresent(Int.self, forKey: .note)) ?? d.note
        sound = (try? c.decodeIfPresent(Int.self, forKey: .sound)) ?? d.sound
        self = normalized
    }
    public static func decode(_ data: Data?) -> PedalMetronome {
        data.flatMap { try? JSONDecoder().decode(PedalMetronome.self, from: $0) } ?? PedalMetronome()
    }
    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

extension Writes {
    /// NanOS 2.3+ TempoScreenMessage with field 3 = 1, always whole (fields 3–11; DECISIONS #41): 4 the Global | Preset
    /// mode, 5 the tempo, 6 an external MIDI clock (sent as 0), 7 volume dB f32, 8 muted, 9 time signature, 10 note,
    /// 11 sound, the last five from the editor's copy. It opens the screen (the first after a close) or sets the tempo,
    /// the mode or the metronome. There is no short frame on 2.3+: the pedal resets fields 7–11 left out. Open at 120
    /// with the default copy: `1C C0 18 01 20 00 2D 00 00 F0 42 30 00 3D 00 00 00 00 40 01 48 02 50 00 58 00 91 00 00 00`.
    public static func tempoScreen(bpm: Double, global: Bool, metronome m: PedalMetronome) -> [UInt8] {
        let n = m.normalized
        return single(ProtoWriter().int(3, 1).int(4, global ? 1 : 0).float32(5, Float(bpm)).int(6, 0)
            .float32(7, Float(n.volume)).int(8, n.muted ? 1 : 0).int(9, UInt64(n.timeSig)).int(10, UInt64(n.note)).int(11, UInt64(n.sound)),
                      MessageType.tempo.rawValue)
    }
    /// `{3:0}` alone: closes the screen (`06 C0 18 00 91 00 00 00`). A tempo in a 3:0 frame is ignored.
    public static let tempoScreenClose: [UInt8] = single(ProtoWriter().int(3, 0), MessageType.tempo.rawValue)
}

/// The tempo-screen sequence on NanOS 2.3+ (see the top of this file). Pure: every change returns the actions to run.
public struct TempoScreen: Sendable {
    public enum Phase: String, Sendable { case closed, opening, open }
    public enum Timer: String, Sendable, CaseIterable { case open, send, close, reread }
    public enum Action: Equatable, Sendable {
        /// Send this frame now, after every write before it.
        case write([UInt8], label: String)
        /// (Re)start this timer; call `fired(_:now:)` when it runs out.
        case start(Timer, after: Double)
        case cancel(Timer)
        /// Read the current state again (the edited flag, the pedal's tempo).
        case reread
        case log(String)
        /// The open has finished (answered, or no answer in time): a Save waiting for it may go on.
        case opened
    }

    public private(set) var phase: Phase = .closed
    /// A write waiting to go out (the latest tempo, mode and metronome copy, whole).
    public private(set) var pending = false
    public private(set) var lastSentAt: Date?
    /// The metronome window's Pedal tab shows: the screen stays open between changes.
    public private(set) var held = false
    public private(set) var closeWhenOpen = false
    /// What the pedal has (from its dump, its answer, our last write).
    public private(set) var pedalBpm: Double?
    public private(set) var pedalGlobal = false
    /// The mode to write: field 4 of every frame, the pedal's own unless the user switches it.
    public private(set) var global = false
    /// State field 61: an external MIDI clock sets the tempo; the tempo and the mode are read-only.
    public private(set) var externalClock = false
    /// The tempo the editor shows and writes.
    public var tempo: Double?
    /// The editor's copy of the pedal metronome (sent whole).
    public var metronome = PedalMetronome()
    /// A drag on the tempo label is under way (reports wait).
    public var dragging = false
    public private(set) var timers: Set<Timer> = []

    public init() {}

    /// A new connection: closed, nothing pending, nothing known from the pedal yet.
    public mutating func reset() {
        let m = metronome
        self = TempoScreen()
        metronome = m
    }

    /// True while a change of ours is under way, so a dump or a report must not overwrite the tempo shown.
    public func busy(now: Date) -> Bool {
        if pending || timers.contains(.send) || timers.contains(.close) || phase == .opening || dragging { return true }
        if phase != .closed, let t = lastSentAt, now.timeIntervalSince(t) < Tempo23.busyAfterWrite { return true }
        return false
    }

    // MARK: user changes

    /// A tempo while it moves (a step, a drag, a tap): written through the screen; the caller closes it later
    /// (`closeSoon`). Nothing while an external MIDI clock runs.
    public mutating func live(_ bpm: Double, now: Date) -> [Action] {
        guard !externalClock, bpm.isFinite else { return [] }
        tempo = Tempo23.clamp(bpm)
        var a: [Action] = []
        send(now: now, &a)
        return a
    }
    /// A typed tempo (Enter): written, then the screen closes at once (unless the Pedal tab holds it).
    public mutating func commit(_ bpm: Double, now: Date) -> [Action] {
        guard !externalClock, bpm.isFinite else { return [] }
        let v = Tempo23.clamp(bpm)
        let pending = phase != .closed || pending
        if v == tempo && !pending { return [] }   // nothing changed
        tempo = v
        var a: [Action] = []
        if v != pedalBpm || pending || phase == .closed { send(now: now, &a) }
        if !held { close(now: now, reread: true, &a) }
        return a
    }
    /// The pedal's Global | Preset switch: a (whole) frame with the new mode, then close and re-read.
    public mutating func setMode(global g: Bool, now: Date) -> [Action] {
        guard !externalClock, g != global else { return [] }
        global = g
        var a: [Action] = []
        send(now: now, &a)
        if !held { close(now: now, reread: true, &a) }
        return a
    }
    /// A Pedal-tab metronome control: the copy changes and goes out whole; it closes after the step delay unless the
    /// Pedal tab holds the screen.
    public mutating func setMetronome(_ m: PedalMetronome, now: Date) -> [Action] {
        metronome = m.normalized
        var a: [Action] = []
        send(now: now, &a)
        if !held { closeSoon(after: Tempo23.settleStep, &a) }
        return a
    }
    /// Closes once the change has settled; never while the Pedal tab holds the screen.
    public mutating func closeSoon(after seconds: Double) -> [Action] {
        var a: [Action] = []
        closeSoon(after: seconds, &a)
        return a
    }
    /// The Pedal tab shows (held) or not: leaving it closes the screen.
    public mutating func setHeld(_ h: Bool, now: Date) -> [Action] {
        guard h != held else { return [] }
        held = h
        var a: [Action] = []
        if !h { close(now: now, reread: true, &a) }
        return a
    }
    /// Closes now: the pending write first, then `{3:0}`, then (after 300 ms) a state read.
    public mutating func close(now: Date, reread: Bool = true) -> [Action] {
        var a: [Action] = []
        close(now: now, reread: reread, &a)
        return a
    }
    /// Save: the pending write goes out and the screen closes before the save frame. While the open waits for the
    /// pedal's answer, the close happens when it comes: wait for `.opened` (then for the writes) before saving.
    public mutating func flush(now: Date) -> [Action] {
        var a: [Action] = []
        if phase == .opening { closeWhenOpen = true } else { close(now: now, reread: true, &a) }
        return a
    }
    /// A preset change: pending writes belong to the old preset. Drop them and close (no state read: the preset
    /// change reads the state anyway).
    public mutating func abandon(now: Date) -> [Action] {
        var a: [Action] = []
        pending = false
        cancel(.send, &a); cancel(.reread, &a)
        if phase == .open { close(now: now, reread: false, &a) } else if phase == .opening { closeWhenOpen = true }
        return a
    }

    // MARK: the pedal

    /// A 145 from the pedal `{1:1 3:1 [4:1] 5:bpm}`: the answer to our open (its tempo is the one it had before), or the
    /// tempo changed on the pedal. `changed`: the tempo shown changed (log it, show it).
    public mutating func report(bpm: Double, now: Date) -> (changed: Bool, actions: [Action]) {
        guard bpm.isFinite, bpm >= 20, bpm <= 400 else { return (false, []) }
        if phase == .opening {
            var a: [Action] = []
            opened(why: nil, now: now, &a)
            return (false, a)
        }
        if busy(now: now) { return (false, []) }   // an echo of our own writes
        let v = Tempo23.clamp(bpm)
        pedalBpm = v
        guard v != tempo else { return (false, []) }
        tempo = v
        return (true, [.log("Pedal tempo: " + Tempo23.format(v) + " BPM")])
    }
    /// State dump fields 55 (tempoIsGlobal), 56 (tempo), 60 (tempoScreenActive) and 61 (externalMidiClockRunning).
    /// While a change of ours is under way the tempo and mode shown stay ours; the clock flag always follows. With no
    /// write in flight and no re-read pending, the pedal's word on the screen wins over ours (closed: the next write
    /// opens it again first; open: the next write needs no open), logged either way.
    @discardableResult
    public mutating func dump(tempo t: Double, global g: Bool, externalClock clock: Bool, screenActive: Bool = false, now: Date) -> [Action] {
        let wasBusy = busy(now: now)
        var a: [Action] = []
        externalClock = clock
        if !wasBusy { global = g; pedalGlobal = g }
        if !wasBusy, !timers.contains(.reread) {
            if !screenActive, phase == .open { cancel(.close, &a); phase = .closed; a.append(.log("Tempo screen: the pedal reports it closed")) }
            else if screenActive, phase == .closed { phase = .open; a.append(.log("Tempo screen: the pedal reports it open")) }
        }
        if !wasBusy, t >= 20, t <= 400 { tempo = Tempo23.clamp(t); pedalBpm = tempo }
        return a
    }

    /// A timer the caller started has run out.
    public mutating func fired(_ t: Timer, now: Date) -> [Action] {
        guard timers.remove(t) != nil else { return [] }
        var a: [Action] = []
        switch t {
        case .open: opened(why: "no answer in \(Int(Tempo23.openWait * 1000)) ms", now: now, &a)
        case .send: pump(now: now, &a)
        case .close: close(now: now, reread: true, &a)
        case .reread: if phase == .closed { a.append(.reread) }
        }
        return a
    }

    // MARK: the sequence

    private var modeName: String { global ? "global" : "preset" }

    private mutating func start(_ t: Timer, _ s: Double, _ a: inout [Action]) { timers.insert(t); a.append(.start(t, after: s)) }
    private mutating func cancel(_ t: Timer, _ a: inout [Action]) { if timers.remove(t) != nil { a.append(.cancel(t)) } }

    private mutating func send(now: Date, _ a: inout [Action]) {
        pending = true
        cancel(.close, &a); cancel(.reread, &a)
        if phase == .closed { open(&a) } else if phase == .open { pump(now: now, &a) }
    }
    private mutating func open(_ a: inout [Action]) {
        let bpm = (pedalBpm ?? 0) > 0 ? pedalBpm! : ((tempo ?? 0) > 0 ? tempo! : Tempo.defaultBPM)
        phase = .opening; closeWhenOpen = false
        a.append(.write(Writes.tempoScreen(bpm: bpm, global: pedalGlobal, metronome: metronome),
                        label: "Tempo screen open (\(Tempo23.format(bpm)) BPM, \(pedalGlobal ? "global" : "preset"), \(metronome.summary))"))
        start(.open, Tempo23.openWait, &a)
    }
    private mutating func opened(why: String?, now: Date, _ a: inout [Action]) {
        guard phase == .opening else { return }
        cancel(.open, &a)
        phase = .open
        if let why { a.append(.log("Tempo screen: \(why), writing anyway")) }
        if closeWhenOpen { closeWhenOpen = false; close(now: now, reread: true, &a) } else { pump(now: now, &a) }
        a.append(.opened)
    }
    private mutating func writeNow(now: Date, _ a: inout [Action]) {
        guard pending else { return }
        pending = false
        guard let bpm = (tempo ?? 0) > 0 ? tempo : pedalBpm, bpm > 0 else { return }
        lastSentAt = now
        pedalBpm = bpm; pedalGlobal = global
        a.append(.write(Writes.tempoScreen(bpm: bpm, global: global, metronome: metronome), label: "Tempo \(Tempo23.format(bpm)) BPM (\(modeName)), " + metronome.summary))
    }
    private mutating func pump(now: Date, _ a: inout [Action]) {
        guard phase == .open, pending, !timers.contains(.send) else { return }
        let wait = (lastSentAt.map { $0.timeIntervalSince(now) } ?? -1) + Tempo23.gap
        if wait > 0 { start(.send, wait, &a) } else { writeNow(now: now, &a) }
    }
    private mutating func closeSoon(after s: Double, _ a: inout [Action]) {
        guard !held, phase != .closed else { return }
        cancel(.close, &a)
        start(.close, s, &a)
    }
    private mutating func close(now: Date, reread: Bool, _ a: inout [Action]) {
        cancel(.close, &a)
        if phase == .closed { return }
        if phase == .opening { closeWhenOpen = true; return }
        cancel(.send, &a)
        writeNow(now: now, &a)
        phase = .closed
        a.append(.write(Writes.tempoScreenClose, label: "Tempo screen close"))
        if reread { start(.reread, Tempo23.reread, &a) }
    }
}
