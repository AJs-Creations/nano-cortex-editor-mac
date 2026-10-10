// The app's outbound links: the repository, the manual, the cross-platform edition and the support page.
// Pure Foundation so the unit tests compile it too (LinksTests). Every link opens in the default browser
// (`Links.open`), never in the Cortex Cloud web view. The support link stays quiet: a status bar text button,
// Settings → About, the Help menu and the About panel; no prompts, counters or tracking.

import Foundation

enum Links {
    static let repository = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor-mac")!
    static let manual = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor-mac/blob/main/docs/MANUAL.md")!
    /// The manual's Troubleshooting section (GitHub's anchor for "## 16. Troubleshooting").
    static let troubleshooting = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor-mac/blob/main/docs/MANUAL.md#16-troubleshooting")!
    static let newIssue = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor-mac/issues/new/choose")!
    static let crossPlatform = URL(string: "https://github.com/AJs-Creations/nano-cortex-editor")!
    static let support = URL(string: "https://buymeacoffee.com/ajscreations")!
}
