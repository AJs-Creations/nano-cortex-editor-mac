// Update notifications (DECISIONS #23): Sparkle's standard alert (Install Update / Skip This Version / Remind Me
// Later), fed by the appcast that release.yml attaches to every GitHub Release. This file is the pure part (Foundation
// and Observation only) so the unit tests compile it (UpdatesTests); SparkleUpdater.swift connects it to Sparkle.

import Foundation
import Observation

enum UpdateFeed {
    /// The appcast `release.yml` uploads with each Release. GitHub redirects `releases/latest/download/<asset>` to that
    /// asset of the newest Release that isn't a prerelease or a draft, so there is no website to host. Same string as
    /// `SUFeedURL` in project.yml (Sparkle reads that one; UpdatesTests keeps them equal).
    static let url = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor-mac/releases/latest/download/appcast.xml")!
    /// Sparkle's own schedule (`SUScheduledCheckInterval`): once a day.
    static let checkInterval: TimeInterval = 86_400
    /// The extra background check after launch (Anup: "once a day, plus a few seconds after launch").
    static let launchCheckDelay: Duration = .seconds(5)

    /// The updater isn't started with `-demo`: the UI tests, screenshots and agent sessions get no update check, no
    /// schedule and no Sparkle window ("Check for Updates…" is greyed out there). Pedal → Demo mode doesn't pass it.
    static func updaterRuns(arguments: [String]) -> Bool { !arguments.contains("-demo") }

    /// Whether the launch check should run: automatic checks are on, the updater runs, and Sparkle didn't check moments ago
    /// by itself (it does at launch on the first run and whenever the last check is more than a day old).
    static func shouldCheckAtLaunch(automaticChecks: Bool, allowed: Bool, lastCheck: Date?, now: Date = Date()) -> Bool {
        guard automaticChecks, allowed else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > 60
    }
}

/// The updater as the menu and Settings see it (Sparkle's `SPUUpdater` conforms; the tests use a fake).
@MainActor
protocol UpdaterBackend: AnyObject {
    /// Persisted by the updater itself (`SUEnableAutomaticChecks` in UserDefaults; the Info.plist default is on).
    var automaticallyChecksForUpdates: Bool { get set }
    /// False while a check or an update is in progress in a way that a new check can't take over.
    var canCheckForUpdates: Bool { get }
    /// A user-initiated check: shows the update alert, or "You're up to date", or an error.
    func checkForUpdates()
}

/// What the app menu's "Check for Updates…" and Settings → Advanced → "Check for updates automatically" bind to.
/// It mirrors the updater for SwiftUI and writes the setting only when the user flips the switch, as Sparkle asks
/// (its properties are backed by UserDefaults; keeping a second copy would drift).
@MainActor @Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private var backend: (any UpdaterBackend)?
    /// The Settings switch. Off (and the switch inert) until an updater is attached.
    private(set) var automaticChecks = false
    /// Enables "Check for Updates…".
    private(set) var canCheck = false

    init() {}

    func attach(_ backend: any UpdaterBackend) {
        self.backend = backend
        refresh()
    }

    /// Re-reads the updater (called when Sparkle reports a change, e.g. `canCheckForUpdates` during a check).
    func refresh() {
        automaticChecks = backend?.automaticallyChecksForUpdates ?? false
        canCheck = backend?.canCheckForUpdates ?? false
    }

    /// The Settings switch: a user action, so it writes through to the updater, then shows what the updater kept.
    func setAutomaticChecks(_ on: Bool) {
        guard let backend else { return }
        backend.automaticallyChecksForUpdates = on
        refresh()
    }

    /// "Check for Updates…".
    func checkForUpdates() {
        guard let backend, backend.canCheckForUpdates else { return }
        backend.checkForUpdates()
    }
}
