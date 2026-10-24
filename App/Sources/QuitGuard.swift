// Quitting while an audition plays (a Cortex Cloud Live Preview, type 150, or a library IR, 158). Without a stop the
// link just drops and the pedal keeps playing the audition until it times out. The app delegate answers AppKit's
// "should terminate?" with `.terminateLater` only while something plays, runs the same stops as the audition gate
// (148 → 149) and replies once the pedal confirmed, refused or didn't answer: after the stop's answer or 1.5 s,
// whichever comes first. Quitting is never refused, and never waits when nothing plays. Foundation only, so the unit
// tests compile this file (QuitGuardTests drives it against the fake pedal).

import Foundation

@MainActor
enum QuitGuard {
    /// How long a quit waits for the pedal at most.
    static let cap: Duration = .milliseconds(1500)

    enum Outcome: Equatable, Sendable {
        case stopped        // every stop confirmed (149 with its transaction and status 1)
        case notConfirmed   // the pedal refused, the reply didn't match, or the link was gone
        case timedOut       // no answer within the cap
    }

    /// Runs `stop` and calls `reply` exactly once: when `stop` returns, or when `cap` has passed, whichever comes first.
    /// The cap is a run-loop timer in the common modes, so it fires during AppKit's wait for the reply even if the
    /// stop's own work can't run then.
    static func run(cap: Duration = Self.cap, stop: @escaping @MainActor () async -> Bool,
                    reply: @escaping @MainActor (Outcome, Duration) -> Void) {
        let once = Once(reply)
        let start = ContinuousClock.now
        let timer = Timer(timeInterval: seconds(cap), repeats: false) { _ in
            MainActor.assumeIsolated { once.fire(.timedOut, ContinuousClock.now - start) }
        }
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in
            let confirmed = await stop()
            timer.invalidate()
            once.fire(confirmed ? .stopped : .notConfirmed, ContinuousClock.now - start)
        }
    }

    /// The one Activity line a quit with an audition writes.
    static func line(_ outcome: Outcome, after took: Duration) -> String {
        switch outcome {
        case .stopped: "Quit: stopped the preview first (the pedal confirmed in \(Int((seconds(took) * 1000).rounded())) ms)."
        case .notConfirmed: "Quit: the pedal did not confirm stopping the preview; quitting anyway."
        case .timedOut: "Quit: the pedal did not answer the preview stop within \(String(format: "%.1f", seconds(cap))) s; quitting anyway."
        }
    }

    nonisolated static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }

    /// Calls the reply once; later calls do nothing.
    @MainActor private final class Once {
        private var reply: (@MainActor (Outcome, Duration) -> Void)?
        init(_ reply: @escaping @MainActor (Outcome, Duration) -> Void) { self.reply = reply }
        func fire(_ outcome: Outcome, _ took: Duration) {
            guard let r = reply else { return }
            reply = nil
            r(outcome, took)
        }
    }
}
