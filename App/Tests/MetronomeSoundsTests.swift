// Custom metronome samples (MetronomeSounds.swift, compiled into this bundle): the loader/validator, the settings
// model, the copies in the samples folder, the launch fallback and the cut at the next click. Every audio file is
// generated here at runtime; nothing binary is committed.
import XCTest
import AVFoundation

final class MetronomeSoundsTests: XCTestCase {
    private var dir: URL!
    private let rate = 48000.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "metro-sounds-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: fixtures

    nonisolated(unsafe) private static let pcm16: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
    /// Writes `seconds` of audio; `fill(channel, frame)` gives each sample. The file type comes from the extension.
    @discardableResult
    private func write(_ name: String, seconds: Double, rate: Double = 48000, channels: Int = 1, settings: [String: Any] = pcm16,
                       fill: (Int, Int) -> Float = { _, i in sinf(Float(i) * 0.05) * 0.5 }) throws -> URL {
        let url = dir.appending(path: name)
        var s = settings
        s[AVSampleRateKey] = rate; s[AVNumberOfChannelsKey] = channels
        do {
            let file = try AVAudioFile(forWriting: url, settings: s, commonFormat: .pcmFormatFloat32, interleaved: false)
            let n = Int(seconds * rate)
            guard n > 0 else { return url }   // header only
            let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)))
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<channels { for i in 0..<n { buf.floatChannelData![c][i] = fill(c, i) } }
            try file.write(from: buf)
        }   // the file is finished when it goes out of scope
        return url
    }

    // MARK: loader

    func testAcceptsWavAndAiff() throws {
        let wav = try SampleLoader.load(try write("click.wav", seconds: 0.2), rate: rate)
        XCTAssertEqual(wav.samples.count, 9600)
        XCTAssertFalse(wav.trimmed)
        XCTAssertEqual(wav.channels, 1)
        XCTAssertEqual(wav.samples[100], sinf(100 * 0.05) * 0.5, accuracy: 0.001)   // 16-bit round trip

        var be = Self.pcm16; be[AVLinearPCMIsBigEndianKey] = true
        let aiff = try SampleLoader.load(try write("click.aiff", seconds: 0.25, settings: be), rate: rate)
        XCTAssertEqual(aiff.samples.count, 12000)
        XCTAssertEqual(aiff.samples[100], sinf(100 * 0.05) * 0.5, accuracy: 0.001)
    }

    /// The formats the open panel offers, as far as macOS can encode them (MP3 has no encoder; see the next test).
    func testDecodesCafM4aFlac() throws {
        let caf = try SampleLoader.load(try write("a.caf", seconds: 0.3, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]), rate: rate)
        XCTAssertEqual(caf.samples.count, 14400)
        let m4a = try SampleLoader.load(try write("a.m4a", seconds: 0.5, rate: 44100, channels: 2, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 128000]), rate: rate)
        XCTAssertEqual(Double(m4a.samples.count), 24000, accuracy: 2400)   // AAC frames pad the length a little
        XCTAssertEqual(m4a.sourceRate, 44100); XCTAssertEqual(m4a.channels, 2)
        XCTAssertGreaterThan(m4a.samples.map(abs).max() ?? 0, 0.3)
        let flac = try SampleLoader.load(try write("a.flac", seconds: 0.3, rate: 44100, settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 16]), rate: rate)
        XCTAssertEqual(Double(flac.samples.count), 14400, accuracy: 1200)   // the encoder may leave out part of its last block
        XCTAssertGreaterThan(flac.samples.map(abs).max() ?? 0, 0.3)
    }

    /// MP3 can only be decoded here: use a system sound when this macOS has one (not on every runner).
    func testDecodesMp3WhenOneIsAvailable() throws {
        let mp3 = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PersonalAudio.framework/Versions/A/Resources/Enrollment_1.mp3")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mp3.path), "no MP3 on this system")
        let l = try SampleLoader.load(mp3, rate: rate)
        XCTAssertEqual(l.samples.count, 96000)   // longer than 2 s: trimmed
        XCTAssertTrue(l.trimmed)
    }

    func testConvertsRateAndMixesToMono() throws {
        // 44.1 kHz stereo: left 0.6, right 0.2 → mono 0.4 at 48 kHz; a step at 0.1 s stays at 0.1 s.
        let url = try write("stereo.wav", seconds: 0.5, rate: 44100, channels: 2) { c, i in i < 4410 ? 0 : (c == 0 ? 0.6 : 0.2) }
        let l = try SampleLoader.load(url, rate: rate)
        XCTAssertEqual(l.sourceRate, 44100); XCTAssertEqual(l.channels, 2)
        XCTAssertEqual(Double(l.samples.count), 24000, accuracy: 2)
        XCTAssertEqual(l.samples[12000], 0.4, accuracy: 0.005)
        XCTAssertEqual(l.samples[4700], 0, accuracy: 0.01)
        XCTAssertEqual(l.samples[4900], 0.4, accuracy: 0.01)
    }

    func testTrimsToTwoSecondsWithAFade() throws {
        let l = try SampleLoader.load(try write("long.wav", seconds: 3, fill: { _, _ in 0.5 }), rate: rate)
        XCTAssertTrue(l.trimmed)
        XCTAssertEqual(l.samples.count, 96000)
        XCTAssertEqual(l.seconds, 3, accuracy: 0.001)
        XCTAssertEqual(l.samples[48000], 0.5, accuracy: 0.001)
        XCTAssertEqual(l.samples.last ?? 1, 0, accuracy: 0.001)   // faded, so the cut doesn't click
        XCTAssertFalse(try SampleLoader.load(try write("two.wav", seconds: 2), rate: rate).trimmed)
    }

    func testRejectsUndecodableEmptyMissingAndOversize() throws {
        let junk = dir.appending(path: "junk.wav")
        try Data("not audio at all".utf8).write(to: junk)
        XCTAssertThrowsError(try SampleLoader.load(junk, rate: rate)) { XCTAssertEqual($0 as? SampleLoader.Failure, .unreadable) }
        XCTAssertThrowsError(try SampleLoader.load(try write("empty.wav", seconds: 0), rate: rate)) { XCTAssertEqual($0 as? SampleLoader.Failure, .empty) }
        XCTAssertThrowsError(try SampleLoader.load(dir.appending(path: "nope.wav"), rate: rate)) { XCTAssertEqual($0 as? SampleLoader.Failure, .missing) }
        let big = dir.appending(path: "big.wav")
        try Data(count: SampleLoader.maxBytes + 1).write(to: big)
        XCTAssertThrowsError(try SampleLoader.load(big, rate: rate)) { XCTAssertEqual($0 as? SampleLoader.Failure, .tooLarge(bytes: SampleLoader.maxBytes + 1)) }
        XCTAssertEqual(SampleLoader.Failure.tooLarge(bytes: 6_291_456).errorDescription, "it's 6.0 MB; samples can be up to 5 MB.")
    }

    // MARK: settings

    func testSettingsRoundTripAndLegacySeed() throws {
        let suite = "metro-sounds-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MetronomeSounds.load(from: d), MetronomeSounds(all: .click))   // fresh install
        d.set("cowbell", forKey: MetronomeSounds.legacyKey)
        XCTAssertEqual(MetronomeSounds.load(from: d), MetronomeSounds(all: .cowbell))   // the earlier single sound
        var s = MetronomeSounds(all: .tick)
        s[.main].builtIn = .woodblock
        s[.accent].sample = .init(file: "accent.wav", name: "My Clave.wav")
        s.save(to: d)
        let back = MetronomeSounds.load(from: d)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back[.accent].builtIn, .tick)    // Reset goes back to this
        XCTAssertEqual(back[.main].builtIn, .woodblock)
        XCTAssertNil(back[.sub].sample)
        d.set(Data("{".utf8), forKey: MetronomeSounds.key)   // unreadable: the legacy sound again
        XCTAssertEqual(MetronomeSounds.load(from: d), MetronomeSounds(all: .cowbell))
    }

    func testRolesAndSource() {
        XCTAssertEqual(SoundRole(.soft), .main)
        XCTAssertEqual(SoundRole(.normal), .main)
        XCTAssertNil(SoundRole(.mute))
        XCTAssertEqual(SoundRole(name: "normal"), .main)
        XCTAssertEqual(SoundRole.allCases.map(\.title), ["Accent", "Main beat", "Subdivision"])
        var s = MetronomeSounds(all: .beep)
        s[.main].sample = .init(file: "main.wav", name: "x.wav")
        let custom: [Float] = [0.1, 0.2, 0.3]
        let src = MetronomeClickSource(sounds: s, samples: [.main: custom])
        XCTAssertEqual(src.samples(for: .normal, rate: rate), custom)
        XCTAssertEqual(src.samples(for: .soft, rate: rate), custom)   // soft beats: the main sample (Levels makes it quieter)
        XCTAssertEqual(src.samples(for: .accent, rate: rate), ClickSound.samples(.beep, accent: true, rate: rate))
        XCTAssertEqual(src.tag(for: .normal), "sample"); XCTAssertEqual(src.tag(for: .sub), "beep")
        // A sample in the settings that didn't load plays the built-in sound.
        XCTAssertEqual(MetronomeClickSource(sounds: s, samples: [:]).samples(for: .normal, rate: rate), ClickSound.samples(.beep, accent: false, rate: rate))
    }

    // MARK: the copies

    func testInstallCopiesReplacesAndRemoves() throws {
        let store = SampleStore(folder: dir.appending(path: "Metronome Sounds"))
        let files = { (try? FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()) ?? [] }
        let first = try write("Clave.WAV", seconds: 0.1)
        let (sample, loaded) = try store.install(first, for: .accent, rate: rate)
        XCTAssertEqual(sample, .init(file: "accent.wav", name: "Clave.WAV"))
        XCTAssertEqual(loaded.samples.count, 4800)
        XCTAssertEqual(files(), ["accent.wav"])
        try FileManager.default.removeItem(at: first)   // the copy survives the original going away
        XCTAssertEqual(try SampleLoader.load(store.url("accent.wav"), rate: rate).samples.count, 4800)

        var be = Self.pcm16; be[AVLinearPCMIsBigEndianKey] = true
        _ = try store.install(try write("b.aiff", seconds: 0.1, settings: be), for: .accent, rate: rate)   // re-pick: replaced
        _ = try store.install(try write("m.wav", seconds: 0.1), for: .main, rate: rate)
        XCTAssertEqual(files(), ["accent.aiff", "main.wav"])
        _ = try store.install(store.url("main.wav"), for: .main, rate: rate)   // the stored copy itself, picked again
        XCTAssertEqual(files(), ["accent.aiff", "main.wav"])

        let junk = dir.appending(path: "junk.mp3")
        try Data("nope".utf8).write(to: junk)
        XCTAssertThrowsError(try store.install(junk, for: .accent, rate: rate))
        XCTAssertEqual(files(), ["accent.aiff", "main.wav"])   // a refused file leaves the earlier sample alone

        store.remove(.accent)
        XCTAssertEqual(files(), ["main.wav"])
    }

    func testLaunchFallsBackWhenACopyIsMissingOrUnreadable() throws {
        let store = SampleStore(folder: dir.appending(path: "Metronome Sounds"))
        var s = MetronomeSounds(all: .woodblock)
        s[.accent].sample = .init(file: "accent.wav", name: "Gone.wav")   // never copied
        s[.main].sample = .init(file: "main.wav", name: "Broken.wav")
        let (sub, _) = try store.install(try write("tick.wav", seconds: 0.05), for: .sub, rate: rate)
        s[.sub].sample = sub
        try Data("garbage".utf8).write(to: store.url("main.wav"))

        let r = store.loadAll(s, rate: rate)
        XCTAssertEqual(Array(r.samples.keys), [.sub])
        XCTAssertEqual(r.samples[.sub]?.count, 2400)
        XCTAssertNil(r.sounds[.accent].sample); XCTAssertNil(r.sounds[.main].sample)
        XCTAssertEqual(r.sounds[.sub].sample, sub)
        XCTAssertEqual(r.sounds[.accent].builtIn, .woodblock)
        XCTAssertEqual(r.problems, ["The accent sample Gone.wav is missing; playing Woodblock instead.",
                                    "The main beat sample Broken.wav can't be read; playing Woodblock instead."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url("main.wav").path))   // the unreadable copy is deleted
        // What then plays: the built-in sound for accent and main beat, the sample for subdivisions.
        let src = MetronomeClickSource(sounds: r.sounds, samples: r.samples)
        XCTAssertEqual(src.tag(for: .accent), "woodblock"); XCTAssertEqual(src.tag(for: .sub), "sample")
        XCTAssertEqual(store.loadAll(MetronomeSounds(), rate: rate).problems, [])
    }

    // MARK: playback

    func testCutAtTheNextEvent() {
        let x = [Float](repeating: 1, count: 10)
        XCTAssertEqual(ClickCut.cut(x, room: 10, fade: 3), x)
        XCTAssertEqual(ClickCut.cut(x, room: 20, fade: 3), x)
        let y = ClickCut.cut(x, room: 6, fade: 3)
        XCTAssertEqual(y.count, 6)
        XCTAssertEqual(y[0], 1); XCTAssertEqual(y[2], 1)
        XCTAssertEqual(y[3], 2.0 / 3, accuracy: 1e-6); XCTAssertEqual(y[4], 1.0 / 3, accuracy: 1e-6); XCTAssertEqual(y[5], 0)
        XCTAssertEqual(ClickCut.cut(x, room: 0, fade: 3), [])
        XCTAssertEqual(ClickCut.fadeFrames(rate: 48000), 240)
    }

    // MARK: the folder (1.2.1: out of the Electron edition's data folder)

    /// `dir` stands in for ~/Library/Application Support: the Electron edition's data folder "Nano Cortex Editor" with
    /// its own files and the 1.2.0 Metronome Sounds folder in it.
    private func electronDataFolder(sounds: [String]) throws -> (old: URL, new: URL, others: [URL]) {
        let fm = FileManager.default
        let electron = dir.appending(path: "Nano Cortex Editor", directoryHint: .isDirectory)
        let local = electron.appending(path: "Local Storage", directoryHint: .isDirectory)
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("{\"accent\":\"blue\"}".utf8).write(to: electron.appending(path: "settings.json"))
        try Data("leveldb".utf8).write(to: local.appending(path: "000003.log"))
        let old = SampleStore.legacyFolder(support: dir)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        for f in sounds { try fm.copyItem(at: try write("src-\(f)", seconds: 0.05), to: old.appending(path: f)) }
        return (old, SampleStore.folder(support: dir, bundleId: SampleStore.defaultBundleId),
                [electron.appending(path: "settings.json"), local.appending(path: "000003.log")])
    }
    private func names(_ u: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }

    func testTheFolderIsNamedAfterTheBundleId() {
        XCTAssertEqual(SampleStore.folder(support: dir, bundleId: "com.community.nanocortex").path, dir.appending(path: "com.community.nanocortex/Metronome Sounds").path)
        XCTAssertEqual(SampleStore.legacyFolder(support: dir).path, dir.appending(path: "Nano Cortex Editor/Metronome Sounds").path)
        XCTAssertTrue(SampleStore.standard.folder.path.hasSuffix("Application Support/\(Bundle.main.bundleIdentifier ?? SampleStore.defaultBundleId)/Metronome Sounds"))
        XCTAssertFalse(SampleStore.standard.folder.path.contains("Nano Cortex Editor"))
    }

    func testTheOldFolderMovesOnceAndTheSamplesStillLoad() throws {
        let (old, new, others) = try electronDataFolder(sounds: ["accent.wav", "sub.wav"])
        XCTAssertEqual(SampleFolderMigration.run(from: old, to: new), .moved(files: 2))
        XCTAssertEqual(names(new), ["accent.wav", "sub.wav"], "same names: the settings store only the names")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        for o in others { XCTAssertTrue(FileManager.default.fileExists(atPath: o.path), "\(o.lastPathComponent) untouched") }
        XCTAssertEqual(names(old.deletingLastPathComponent()), ["Local Storage", "settings.json"], "the Electron folder keeps everything else")
        XCTAssertEqual(SampleFolderMigration.run(from: old, to: new), .nothing, "once")

        var s = MetronomeSounds()
        s[.accent].sample = .init(file: "accent.wav", name: "Clave.wav")
        s[.sub].sample = .init(file: "sub.wav", name: "Tick.wav")
        let r = SampleStore(folder: new).loadAll(s, rate: rate)
        XCTAssertEqual(r.problems, [])
        XCTAssertEqual(r.samples[.accent]?.count, 2400)
        XCTAssertEqual(r.sounds, s)
        let line = try XCTUnwrap(SampleFolderMigration.line(.moved(files: 2), old: old, new: new))
        XCTAssertTrue(line.hasPrefix("Metronome: moved your custom sounds (2 files) from "), line)
    }

    func testNoOldFolderDoesNothing() throws {
        let new = SampleStore.folder(support: dir, bundleId: SampleStore.defaultBundleId)
        XCTAssertEqual(SampleFolderMigration.run(from: SampleStore.legacyFolder(support: dir), to: new), .nothing)
        XCTAssertEqual(names(dir), [], "nothing created")
        XCTAssertNil(SampleFolderMigration.line(.nothing, old: dir, new: new))
    }

    func testAnEmptyOldFolderIsRemovedAndNothingElse() throws {
        let (old, new, others) = try electronDataFolder(sounds: [])
        try Data().write(to: old.appending(path: ".DS_Store"))   // Finder's, if the folder was ever opened
        XCTAssertEqual(SampleFolderMigration.run(from: old, to: new), .removedEmptyOld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "no new folder until a sample is picked")
        for o in others { XCTAssertTrue(FileManager.default.fileExists(atPath: o.path)) }
    }

    func testWithBothFoldersTheNewOneWinsAndTheOldOneIsLeftAlone() throws {
        let (old, new, _) = try electronDataFolder(sounds: ["main.wav"])
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try write("other.wav", seconds: 0.05), to: new.appending(path: "accent.wav"))
        XCTAssertEqual(SampleFolderMigration.run(from: old, to: new), .keptBoth)
        XCTAssertEqual(names(old), ["main.wav"])
        XCTAssertEqual(names(new), ["accent.wav"])
        // Emptied later: then it goes.
        try FileManager.default.removeItem(at: old.appending(path: "main.wav"))
        XCTAssertEqual(SampleFolderMigration.run(from: old, to: new), .removedEmptyOld)
        XCTAssertEqual(names(new), ["accent.wav"])
    }

    func testAFailedMoveLeavesTheOldFolderInPlace() throws {
        let (old, new, _) = try electronDataFolder(sounds: ["accent.wav"])
        try Data("a file where the folder should go".utf8).write(to: new.deletingLastPathComponent())
        guard case .failed = SampleFolderMigration.run(from: old, to: new) else { return XCTFail("the move can't happen") }
        XCTAssertEqual(names(old), ["accent.wav"], "this launch reads the old folder (Metronome.init)")
    }
}
