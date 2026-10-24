// The metronome's sounds per role (Settings → Metronome → Sounds): a built-in synthesized sound, or the user's own
// sample. Foundation + AVFoundation only, so the unit tests compile this file: the settings model, the sample
// loader/validator, the copies in Application Support (and moving them out of the 1.2.0 folder), and how a sound is cut
// at the next click (DECISIONS #25, #36).

import Foundation
import AVFoundation

/// The click sounds a user can set, one row each in Settings. Soft beats play the main beat's sound (quieter, Levels);
/// count-in bars play the accent and the main beat. The raw value names the stored copy and the dev remote's `sample=`.
enum SoundRole: String, CaseIterable, Codable, Sendable, Identifiable {
    case accent, main, sub
    var id: String { rawValue }
    var title: String {
        switch self {
        case .accent: "Accent"
        case .main: "Main beat"
        case .sub: "Subdivision"
        }
    }
    /// The engine role whose sound this is (soft beats share the main beat's).
    var engineRole: MetronomePattern.Role {
        switch self {
        case .accent: .accent
        case .main: .normal
        case .sub: .sub
        }
    }
    init?(_ role: MetronomePattern.Role) {
        switch role {
        case .accent: self = .accent
        case .normal, .soft: self = .main
        case .sub: self = .sub
        case .mute: return nil
        }
    }
    /// `normal` also names the main beat (the engine's word for it).
    init?(name: String) { self.init(rawValue: name == "normal" ? "main" : name) }
}

/// Which sound each role plays. Stored as JSON under `metro.sounds`; a sample is a copy kept by `SampleStore`.
struct MetronomeSounds: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var file: String     // the copy's name in the Metronome Sounds folder, e.g. "accent.wav"
        var name: String     // the picked file's name, shown in Settings
    }
    struct Choice: Codable, Equatable, Sendable {
        var builtIn: ClickSound = .click
        var sample: Sample?  // when set, the sample plays instead of `builtIn`; Reset goes back to `builtIn`
    }
    var accent = Choice(), main = Choice(), sub = Choice()

    init(all sound: ClickSound = .click) {
        accent.builtIn = sound; main.builtIn = sound; sub.builtIn = sound
    }
    subscript(role: SoundRole) -> Choice {
        get {
            switch role {
            case .accent: accent
            case .main: main
            case .sub: sub
            }
        }
        set {
            switch role {
            case .accent: accent = newValue
            case .main: main = newValue
            case .sub: sub = newValue
            }
        }
    }

    static let key = "metro.sounds"
    /// Before per-role sounds: one click sound for every role.
    static let legacyKey = "metro.sound"
    /// The stored choice; without one, every role plays the earlier single sound (Click on a fresh install).
    static func load(from d: UserDefaults) -> MetronomeSounds {
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode(MetronomeSounds.self, from: data) { return s }
        return MetronomeSounds(all: d.string(forKey: legacyKey).flatMap(ClickSound.init(rawValue:)) ?? .click)
    }
    func save(to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}

/// Reads a user's sample: anything `AVAudioFile` decodes (WAV, AIFF, CAF, MP3, M4A/AAC, FLAC), at most 5 MB, the
/// first 2 s kept, mixed down to mono and converted to the engine's rate once, here.
enum SampleLoader {
    static let maxBytes = 5 * 1024 * 1024
    static let maxSeconds = 2.0
    /// What the open panel offers. Decoding decides; these are the formats checked with `AVAudioFile` (PLAN row 36).
    static let extensions = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac", "flac"]

    struct Loaded: Sendable {
        var samples: [Float]   // mono, at the engine's rate
        var trimmed: Bool      // the file was longer than 2 s; only its start is kept
        var seconds: Double    // the file's own length
        var sourceRate: Double
        var channels: Int
    }
    enum Failure: Error, Equatable, LocalizedError {
        case missing, tooLarge(bytes: Int), unreadable, empty, notSaved
        var errorDescription: String? {
            switch self {
            case .missing: "the file isn't there."
            case .tooLarge(let b): "it's \(String(format: "%.1f", Double(b) / 1_048_576)) MB; samples can be up to 5 MB."
            case .unreadable: "it isn't an audio file the app can read."
            case .empty: "it has no audio."
            case .notSaved: "the app couldn't keep a copy of it."
            }
        }
    }

    static func load(_ url: URL, rate: Double) throws(Failure) -> Loaded {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else { throw .missing }
        guard size <= maxBytes else { throw .tooLarge(bytes: size) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw .unreadable }
        let fmt = file.processingFormat   // deinterleaved Float32 at the file's rate and channel count
        guard file.length > 0, fmt.sampleRate > 0, fmt.channelCount > 0 else { throw .empty }
        let limit = AVAudioFramePosition((maxSeconds * fmt.sampleRate).rounded())
        let want = Int(min(file.length, limit)), channels = Int(fmt.channelCount)
        // A read can return fewer frames than asked (a CAF gave 14336 of 14400), so read until there are enough.
        guard let chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(min(want, 1 << 16))) else { throw .unreadable }
        var mono: [Float] = []
        mono.reserveCapacity(want)
        while mono.count < want {
            do { try file.read(into: chunk, frameCount: AVAudioFrameCount(min(want - mono.count, Int(chunk.frameCapacity)))) } catch { throw .unreadable }
            guard chunk.frameLength > 0, let ch = chunk.floatChannelData else { break }
            let n = Int(chunk.frameLength), start = mono.count
            mono += UnsafeBufferPointer(start: ch[0], count: n)
            for c in 1..<max(1, channels) { let p = ch[c]; for i in 0..<n { mono[start + i] += p[i] } }
        }
        guard !mono.isEmpty else { throw .empty }
        if channels > 1 { let g = 1 / Float(channels); for i in mono.indices { mono[i] *= g } }
        guard var out = resample(mono, from: fmt.sampleRate, to: rate) else { throw .unreadable }
        let trimmed = file.length > limit
        if trimmed {
            out = Array(out.prefix(Int((maxSeconds * rate).rounded())))
            ClickCut.fadeOut(&out, frames: ClickCut.fadeFrames(rate: rate))
        }
        guard !out.isEmpty else { throw .empty }
        return Loaded(samples: out, trimmed: trimmed, seconds: Double(file.length) / fmt.sampleRate, sourceRate: fmt.sampleRate, channels: channels)
    }

    /// Mono sample-rate conversion with `AVAudioConverter` (highest quality; a 2 s sample converts in milliseconds).
    static func resample(_ x: [Float], from src: Double, to dst: Double) -> [Float]? {
        guard src != dst, !x.isEmpty else { return x }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: src, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: dst, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(x.count)) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        let feed = OneShotInput(input)
        let capacity = AVAudioFrameCount((Double(x.count) * dst / src).rounded(.up)) + 1024
        var out: [Float] = []
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in feed.next(inputStatus) }
            if status == .error { return nil }
            out += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
            if status != .haveData || chunk.frameLength == 0 { break }
        }
        return out
    }
    /// Hands the converter the whole input once, then end of stream.
    private final class OneShotInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ b: AVAudioPCMBuffer) { buffer = b }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else { status.pointee = .endOfStream; return nil }
            buffer = nil; status.pointee = .haveData
            return b
        }
    }
}

/// The copies of the user's samples, so a sample survives the original moving:
/// `~/Library/Application Support/com.community.nanocortex/Metronome Sounds/<role>.<ext>` (the folder is named after the
/// bundle id). Up to 1.2.0 they were in `Application Support/Nano Cortex Editor/`, which is also the Electron edition's
/// whole data folder (its productName), so removing that app's data deleted them; `SampleFolderMigration` moves them
/// once at launch (DECISIONS #36). The settings store only the copies' names, so nothing else changes.
struct SampleStore: Sendable {
    let folder: URL
    static let folderName = "Metronome Sounds"
    static let defaultBundleId = "com.community.nanocortex"
    /// `<support>/<bundle id>/Metronome Sounds`.
    static func folder(support: URL, bundleId: String) -> URL {
        support.appending(path: bundleId, directoryHint: .isDirectory).appending(path: folderName, directoryHint: .isDirectory)
    }
    /// Where 1.2.0 and earlier kept the copies.
    static func legacyFolder(support: URL) -> URL {
        support.appending(path: "Nano Cortex Editor", directoryHint: .isDirectory).appending(path: folderName, directoryHint: .isDirectory)
    }
    static let standard = SampleStore(folder: folder(support: .applicationSupportDirectory, bundleId: Bundle.main.bundleIdentifier ?? defaultBundleId))
    static let legacy = SampleStore(folder: legacyFolder(support: .applicationSupportDirectory))

    func url(_ file: String) -> URL { folder.appending(path: file) }

    /// Checks `source`, then copies it in as `<role>.<ext>`, replacing the role's earlier sample.
    func install(_ source: URL, for role: SoundRole, rate: Double) throws(SampleLoader.Failure) -> (sample: MetronomeSounds.Sample, loaded: SampleLoader.Loaded) {
        let loaded = try SampleLoader.load(source, rate: rate)
        let ext = source.pathExtension.lowercased()
        let file = ext.isEmpty ? role.rawValue : "\(role.rawValue).\(ext)"
        // Read first: the source may be the stored copy itself (picked again from this folder).
        guard let data = try? Data(contentsOf: source) else { throw .missing }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            remove(role)
            try data.write(to: url(file), options: .atomic)
        } catch { throw .notSaved }
        return (MetronomeSounds.Sample(file: file, name: source.lastPathComponent), loaded)
    }

    /// Deletes the role's copy, whatever its extension.
    func remove(_ role: SoundRole) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for f in files where f == role.rawValue || f.hasPrefix(role.rawValue + ".") { try? FileManager.default.removeItem(at: url(f)) }
    }

    /// Loads every role's stored sample (at launch). A missing or unreadable copy is dropped from the choice, so that
    /// role plays its built-in sound again, with one line saying so; an unreadable copy is deleted.
    func loadAll(_ sounds: MetronomeSounds, rate: Double) -> (samples: [SoundRole: [Float]], sounds: MetronomeSounds, problems: [String]) {
        var samples: [SoundRole: [Float]] = [:], kept = sounds, problems: [String] = []
        for role in SoundRole.allCases {
            guard let s = sounds[role].sample else { continue }
            do { samples[role] = try SampleLoader.load(url(s.file), rate: rate).samples }
            catch {
                let why = error == .missing ? "is missing" : "can't be read"
                if error != .missing { try? FileManager.default.removeItem(at: url(s.file)) }
                problems.append("The \(role.title.lowercased()) sample \(s.name) \(why); playing \(sounds[role].builtIn.title) instead.")
                kept[role].sample = nil
            }
        }
        return (samples, kept, problems)
    }
}

/// Moves the 1.2.0 Metronome Sounds folder to its own place, once, at launch (before the samples load). Only that
/// folder is ever moved or removed; nothing else in `Nano Cortex Editor/` (the Electron edition's data) is touched.
enum SampleFolderMigration {
    enum Outcome: Equatable {
        case nothing                 // no old folder
        case moved(files: Int)       // the old folder became the new one, its files under the same names
        case removedEmptyOld         // the old folder was empty (or held only Finder's .DS_Store): removed
        case keptBoth                // both exist and the old one isn't empty: the new one is used, the old one left alone
        case failed(String)          // the move failed: this launch reads the old folder
    }

    static func run(from old: URL, to new: URL, fileManager fm: FileManager = .default) -> Outcome {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return .nothing }
        let files = ((try? fm.contentsOfDirectory(atPath: old.path)) ?? []).filter { $0 != ".DS_Store" }
        if files.isEmpty {
            do { try fm.removeItem(at: old); return .removedEmptyOld } catch { return .failed(error.localizedDescription) }
        }
        guard !fm.fileExists(atPath: new.path) else { return .keptBoth }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            return .moved(files: files.count)
        } catch { return .failed(error.localizedDescription) }
    }

    /// The Activity log line for an outcome (nil when there was nothing to do).
    static func line(_ outcome: Outcome, old: URL, new: URL) -> String? {
        func tilde(_ u: URL) -> String { (u.path as NSString).abbreviatingWithTildeInPath }
        switch outcome {
        case .nothing: return nil
        case .moved(let n): return "Metronome: moved your custom sounds (\(n) file\(n == 1 ? "" : "s")) from \(tilde(old)) to \(tilde(new))."
        case .removedEmptyOld: return "Metronome: removed the empty folder \(tilde(old))."
        case .keptBoth: return "Metronome: \(tilde(new)) is in use; \(tilde(old)) was left as it is."
        case .failed(let why): return "Metronome: couldn't move \(tilde(old)) to \(tilde(new)) (\(why)); using the old folder for now."
        }
    }
}

/// Each role's sound: the user's sample when one is loaded, otherwise the role's built-in sound.
struct MetronomeClickSource: ClickSource {
    let sounds: MetronomeSounds
    let samples: [SoundRole: [Float]]
    func samples(for role: MetronomePattern.Role, rate: Double) -> [Float] {
        guard let r = SoundRole(role) else { return [] }
        if sounds[r].sample != nil, let s = samples[r] { return s }
        return SynthClickSource(sound: sounds[r].builtIn).samples(for: role, rate: rate)
    }
    /// "sample" or the built-in sound's name: what the dev remote reports per played event.
    func tag(for role: MetronomePattern.Role) -> String {
        guard let r = SoundRole(role) else { return role.rawValue }
        return sounds[r].sample != nil && samples[r] != nil ? "sample" : sounds[r].builtIn.rawValue
    }
}

/// A player node plays one buffer at a time: a buffer scheduled while an earlier one still sounds interrupts it, and
/// the earlier one resumes afterwards (checked by offline render, 2026-10-20). So each sound is cut where the next
/// event starts, with a short fade (DECISIONS #25). The built-in sounds (≤ 110 ms) only meet this at very fast tempos.
enum ClickCut {
    static func fadeFrames(rate: Double) -> Int { Int(rate * 0.005) }   // 5 ms
    /// `x`, or its first `room` frames fading to silence over the last `fade` of them.
    static func cut(_ x: [Float], room: Int, fade: Int) -> [Float] {
        guard x.count > room else { return x }
        guard room > 0 else { return [] }
        var y = Array(x.prefix(room))
        fadeOut(&y, frames: fade)
        return y
    }
    /// A linear fade to silence over the last `frames` (the last sample is 0).
    static func fadeOut(_ x: inout [Float], frames: Int) {
        guard !x.isEmpty else { return }
        let f = max(1, min(frames, x.count)), n = x.count
        for k in 0..<f { x[n - f + k] *= Float(f - 1 - k) / Float(f) }
    }
}
