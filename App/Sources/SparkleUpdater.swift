// Sparkle 2 behind `Updates` (Updates.swift, DECISIONS #23). The standard updater controller shows Sparkle's own
// windows: the update alert (Install Update / Skip This Version / Remind Me Later, with the release notes), download
// progress, and "Install and Relaunch". Configuration is in Info.plist (project.yml): SUFeedURL, SUPublicEDKey,
// SUEnableAutomaticChecks (on, so Sparkle never asks "check automatically?"), SUScheduledCheckInterval (a day).
// This adds a background check a few seconds after launch and writes every check, its result and the user's choice
// to the Activity log (and so to activity.log for bug reports). Under `-demo` (UI tests, screenshots, agents) the
// updater is created but never started: no schedule, no check, no Sparkle window; "Check for Updates…" is greyed out.
//
// Testing against a local feed: launch with `-SUFeedURL http://127.0.0.1:<port>/appcast.xml` (the argument domain
// overrides Info.plist for that run and writes nothing; Sparkle logs a warning about a feed URL in user defaults).

import AppKit
import Sparkle

extension SPUUpdater: UpdaterBackend {}

@MainActor
final class SparkleUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = SparkleUpdater()

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    /// False under `-demo` (UpdateFeed.updaterRuns): the updater is not started at all.
    let runs = UpdateFeed.updaterRuns(arguments: ProcessInfo.processInfo.arguments)
    /// The Activity log. Lines from before the store hooks in are kept and handed over then.
    var log: ((String) -> Void)? { didSet { if let log { pending.forEach(log); pending.removeAll() } } }
    private var pending: [String] = []

    private override init() { super.init() }

    var updater: SPUUpdater? { controller?.updater }

    /// Starts Sparkle once, at launch: its daily schedule, plus our launch check a few seconds later. Under `-demo`
    /// the controller exists (the menu item and the Settings switch bind to it) but the updater never starts.
    func start() {
        guard controller == nil else { return }
        let c = SPUStandardUpdaterController(startingUpdater: runs, updaterDelegate: self, userDriverDelegate: nil)
        controller = c
        Updates.shared.attach(c.updater)
        // Sparkle sets canCheckForUpdates on the main thread; the hop keeps the closure free of actor assumptions.
        observation = c.updater.observe(\.canCheckForUpdates) { _, _ in Task { @MainActor in Updates.shared.refresh() } }
        guard runs else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: UpdateFeed.launchCheckDelay)
            self?.checkAtLaunch()
        }
    }

    private func checkAtLaunch() {
        guard let u = updater, !u.sessionInProgress,
              UpdateFeed.shouldCheckAtLaunch(automaticChecks: u.automaticallyChecksForUpdates, allowed: runs, lastCheck: u.lastUpdateCheckDate)
        else { return }
        u.checkForUpdatesInBackground()
    }

    private func note(_ line: String) {
        if let log { log("Updates: " + line) } else { pending.append("Updates: " + line) }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let kind = updateCheck == .updates ? "Check for Updates…" : updateCheck == .updatesInBackground ? "automatic" : "information"
        note("checking \(updater.feedURL?.absoluteString ?? "?") (\(kind))")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        note("version \(item.displayVersionString) (\(item.versionString)) is available")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        note("no newer version (\(error.localizedDescription))")
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        let what = switch choice {
        case .install: "Install Update"
        case .skip: "Skip This Version"
        case .dismiss: "Remind Me Later"
        @unknown default: "choice \(choice.rawValue)"
        }
        note("\(what) for \(updateItem.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        note("download of \(item.displayVersionString) failed: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        note("installing \(item.displayVersionString)")
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        note("relaunching into the new version")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        // "No update" is logged by updaterDidNotFindUpdate; a cancelled install needs no line either.
        if e.domain == SUSparkleErrorDomain, [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(e.code) { return }
        note("stopped: \(e.localizedDescription) (\(e.domain) \(e.code))")
    }
}
