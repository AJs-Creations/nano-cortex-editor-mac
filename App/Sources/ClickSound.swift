// The built-in click sounds, synthesized (pure Foundation, so the unit tests compile this file too).

import Foundation

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
enum ClickSound: String, CaseIterable, Identifiable, Codable, Sendable {
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
