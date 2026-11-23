// The app's outbound links: the repository, the manual, the cross-platform edition, the support page and the AI
// assistants' official MCP setup pages.
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
    // Settings → AI assistants → Learn more: each assistant's official MCP page (mcp/PROTOCOL.md).
    static let claudeCodeMCP = URL(string: "https://code.claude.com/docs/en/mcp")!
    static let codexMCP = URL(string: "https://developers.openai.com/codex/mcp")!
    static let claudeDesktopMCP = URL(string: "https://modelcontextprotocol.io/docs/develop/connect-local-servers")!
    static let cursorMCP = URL(string: "https://cursor.com/docs/context/mcp")!
    static let vscodeMCP = URL(string: "https://code.visualstudio.com/docs/copilot/customization/mcp-servers")!
}
