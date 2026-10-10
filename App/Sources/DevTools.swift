// Settings → Advanced → Developer tools: shows the Activity log, session recording and protocol details (Record and
// Activity in the status bar, ⌘L, raw device settings, hashes, the "Sent: …" status text). Off by default, for fresh
// installs and for settings saved before the switch existed (DECISION #21). Pure Foundation: unit-tested.

import Foundation

enum DevTools {
    static let key = "ui.devTools"
    /// `bool(forKey:)` also reads a launch argument such as `-ui.devTools YES` (the UI tests use it).
    static func isOn(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
}
