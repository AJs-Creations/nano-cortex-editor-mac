// The metronome's pattern engine, pure (Foundation only) so the unit tests compile this file on its own.
// `events(...)` turns one bar's inputs into the events the audio scheduler plays; the trainers
// (count-in, gap, tempo ramp) are pure functions of the bar index, so the scheduler only asks them
// at bar boundaries and nothing drifts. Offsets are in beats of the note value (7/8 at 120 = 120 eighths a minute).
//
// Room for later rounds (polyrhythms, custom samples): every event carries a `voice` (0 today; a second
// concurrent pattern would generate its own bar with voice 1 and the scheduler merges by offset), and sounds
// are looked up per `Role` through a `ClickSource`, so a sample-file source can replace the synth one.

import Foundation

enum MetronomePattern {
    /// What one beat cell plays. A click on the cell cycles accent → normal → soft → mute.
    enum Level: String, Codable, CaseIterable, Sendable {
        case accent, normal, soft, mute
        var next: Level { switch self { case .accent: .normal; case .normal: .soft; case .soft: .mute; case .mute: .accent } }
        var role: Role { switch self { case .accent: .accent; case .normal: .normal; case .soft: .soft; case .mute: .mute } }
    }
    /// What an event sounds like. `mute` events are silent but still drive the beat indicator.
    enum Role: String, Codable, CaseIterable, Sendable { case accent, normal, soft, sub, mute }

    struct Event: Equatable, Sendable {
        var offset: Double   // beats from the start of the bar
        var role: Role
        var beat: Int        // 0-based beat in the bar
        var sub: Int         // 0 on the beat, 1… for subdivisions
        var voice = 0        // which pattern (a second, polyrhythmic one would be 1)
    }

    /// Where a bar sits in the sequence: count-in, playing, or muted by the gap trainer.
    enum BarKind: String, Equatable, Sendable { case countIn, play, muted }

    /// One bar of events.
    /// - beats: beats per bar (1–16); noteValue: 4 / 8 / 16 (labels the beat; offsets are in these beats).
    /// - accents: one level per beat (missing entries are `.normal`, beat 1 `.accent`).
    /// - subdivision: 1 (none), 2, 3 or 4 ticks per beat; swing 0…1 delays the off-beat ticks of 2 and 4
    ///   from straight (0) to a triplet feel (1).
    /// - kind: a count-in bar plays every beat (accent on 1, no subdivisions); a muted bar keeps every event as `.mute`.
    /// Subdivision ticks still sound under a muted beat cell (off-beat practice); only a muted bar silences them.
    static func events(beats: Int, noteValue: Int = 4, accents: [Level], subdivision: Int = 1, swing: Double = 0, kind: BarKind = .play) -> [Event] {
        let beats = max(1, min(16, beats))
        let subs = kind == .countIn ? 1 : max(1, min(4, subdivision))
        let swing = max(0, min(1, swing))
        var out: [Event] = []
        for b in 0..<beats {
            let level: Level = kind == .countIn ? (b == 0 ? .accent : .normal) : (b < accents.count ? accents[b] : (b == 0 ? .accent : .normal))
            for s in 0..<subs {
                let role: Role = kind == .muted ? .mute : (s == 0 ? level.role : .sub)
                out.append(Event(offset: Double(b) + subOffset(s, of: subs, swing: swing), role: role, beat: b, sub: s))
            }
        }
        return out
    }

    /// Offset of tick `s` inside a beat. Swing moves the second tick of each pair from 1/2 to 2/3 of the pair.
    static func subOffset(_ s: Int, of subs: Int, swing: Double) -> Double {
        switch subs {
        case 2: return s == 0 ? 0 : 0.5 + swing / 6
        case 4: let pair = Double(s / 2) * 0.5; return s % 2 == 0 ? pair : pair + 0.5 * (0.5 + swing / 6)
        default: return Double(s) / Double(subs)
        }
    }

    /// Bar `index` counts from 0 including the count-in bars. Gap: play `play` bars, mute `mute` bars, repeat.
    static func barKind(index: Int, countIn: Int, gap: (play: Int, mute: Int)? = nil) -> BarKind {
        if index < countIn { return .countIn }
        guard let gap, gap.play > 0, gap.mute > 0 else { return .play }
        return (index - countIn) % (gap.play + gap.mute) < gap.play ? .play : .muted
    }

    /// The tempo trainer: from `start` towards `target` by `step` BPM after every `every` completed main bars, stopping at the target.
    static func rampTempo(start: Int, target: Int, step: Int, every: Int, barsCompleted: Int) -> Int {
        guard step > 0, every > 0, start != target else { return start }
        let moved = step * (max(0, barsCompleted) / every)
        return start < target ? min(target, start + moved) : max(target, start - moved)
    }

    // MARK: presets

    struct Preset: Identifiable, Sendable {
        let name: String
        let beats: Int
        let noteValue: Int
        let accents: [Level]
        var id: String { name }
    }
    /// Group starts are `.normal`, the rest `.soft`, beat 1 `.accent`: the grouping is audible.
    static let presets: [Preset] = [
        Preset(name: "4/4", beats: 4, noteValue: 4, accents: [.accent, .normal, .normal, .normal]),
        Preset(name: "3/4", beats: 3, noteValue: 4, accents: [.accent, .normal, .normal]),
        Preset(name: "6/8 (3+3)", beats: 6, noteValue: 8, accents: grouped([3, 3])),
        Preset(name: "5/4 (3+2)", beats: 5, noteValue: 4, accents: grouped([3, 2])),
        Preset(name: "7/8 (2+2+3)", beats: 7, noteValue: 8, accents: grouped([2, 2, 3])),
        Preset(name: "12/8 (4×3)", beats: 12, noteValue: 8, accents: grouped([3, 3, 3, 3])),
    ]
    static func grouped(_ groups: [Int]) -> [Level] {
        var out: [Level] = []
        for (i, g) in groups.enumerated() { out.append(i == 0 ? .accent : .normal); out += Array(repeating: .soft, count: max(0, g - 1)) }
        return out
    }
    static func defaultAccents(_ beats: Int) -> [Level] { (0..<max(1, beats)).map { $0 == 0 ? .accent : .normal } }
}

/// The remembered Advanced-mode setup (persisted as JSON by AppSettings).
struct MetronomeSetup: Codable, Equatable, Sendable {
    var beats = 4
    var noteValue = 4
    var accents: [MetronomePattern.Level] = MetronomePattern.defaultAccents(4)
    var subdivision = 1
    var swing = 0.0           // 0…1
    var countIn = 0           // bars
    var rampOn = false
    var rampTarget = 140
    var rampStep = 4          // BPM
    var rampEvery = 4         // bars
    var gapOn = false
    var gapPlay = 2
    var gapMute = 2
    static let beatsRange = 1...16, rampTargetRange = 30...300, rampStepRange = 1...20, barsRange = 1...16

    /// Beats changed: keep the existing cells, new ones normal (beat 1 accented).
    mutating func setBeats(_ n: Int) {
        let n = max(1, min(16, n))
        beats = n
        if accents.count > n { accents = Array(accents.prefix(n)) }
        while accents.count < n { accents.append(accents.isEmpty ? .accent : .normal) }
    }
    mutating func apply(_ p: MetronomePattern.Preset) { beats = p.beats; noteValue = p.noteValue; accents = p.accents }
    /// The preset whose meter and accents this setup matches, if any.
    var presetName: String? { MetronomePattern.presets.first { $0.beats == beats && $0.noteValue == noteValue && $0.accents == accents }?.name }

    func events(kind: MetronomePattern.BarKind) -> [MetronomePattern.Event] {
        MetronomePattern.events(beats: beats, noteValue: noteValue, accents: accents, subdivision: subdivision, swing: swing, kind: kind)
    }
    func barKind(_ index: Int) -> MetronomePattern.BarKind {
        MetronomePattern.barKind(index: index, countIn: countIn, gap: gapOn ? (gapPlay, gapMute) : nil)
    }
}

/// Where each role's sound comes from. Today: the synthesized `ClickSound`s; a sample-file source can conform later.
protocol ClickSource: Sendable {
    func samples(for role: MetronomePattern.Role, rate: Double) -> [Float]
}

/// Per-role gains (Levels…), multiplied into the buffers. Defaults reproduce the original mix (accent 1, click 0.7).
struct MetronomeLevels: Codable, Equatable, Sendable {
    var accent = 1.0
    var main = 0.7
    var sub = 0.5
    static let softFactor = 0.45   // soft beats: the main level × this
    func gain(_ role: MetronomePattern.Role) -> Double {
        switch role {
        case .accent: accent
        case .normal: main
        case .soft: main * Self.softFactor
        case .sub: sub
        case .mute: 0
        }
    }
}

/// A number typed into a stepper's field: digits parsed and clamped to the range; nil when there is no number
/// (the field then reverts). Shared by the overlay, Settings and the dev remote's `/metro?type=`.
enum TypedNumber {
    static func commit(_ text: String, range: ClosedRange<Int>) -> Int? {
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(range.lowerBound, min(range.upperBound, v))
    }
}

/// Tap tempo: the average of the last few gaps; a pause longer than `reset` starts over. Shared by the metronome and
/// the inspector's preset Tempo control.
struct TapTempo {
    var reset: TimeInterval = 2.5
    var keep = 5
    private(set) var taps: [Date] = []
    /// Records a tap; returns the tempo (30–300) once there are two taps in a row.
    mutating func tap(at now: Date = Date()) -> Int? {
        if let last = taps.last, now.timeIntervalSince(last) > reset { taps = [] }
        taps.append(now)
        if taps.count > keep { taps.removeFirst(taps.count - keep) }
        guard taps.count >= 2 else { return nil }
        let avg = now.timeIntervalSince(taps[0]) / Double(taps.count - 1)
        return max(30, min(300, Int((60 / avg).rounded())))
    }
}
