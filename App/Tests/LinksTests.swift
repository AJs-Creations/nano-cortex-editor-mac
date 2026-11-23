// The outbound links (Links.swift, compiled into this bundle) are exactly the published URLs.
import XCTest

final class LinksTests: XCTestCase {
    func testSupportLink() {
        XCTAssertEqual(Links.support.absoluteString, "https://buymeacoffee.com/ajscreations")
    }

    func testManualLinks() {
        XCTAssertEqual(Links.manual.absoluteString, "https://github.com/AJs-Creations/nano-cortex-editor-mac/blob/main/docs/MANUAL.md")
        XCTAssertEqual(Links.troubleshooting.absoluteString, Links.manual.absoluteString + "#16-troubleshooting")
    }

    func testRepositoryLinks() {
        XCTAssertEqual(Links.repository.absoluteString, "https://github.com/AJs-Creations/nano-cortex-editor-mac")
        XCTAssertEqual(Links.newIssue.absoluteString, "https://github.com/AJs-Creations/nano-cortex-editor-mac/issues/new/choose")
        XCTAssertEqual(Links.crossPlatform.absoluteString, "https://github.com/AJs-Creations/nano-cortex-editor")
    }

    /// Settings → AI assistants → Learn more (mcp/PROTOCOL.md, the same in both editions).
    func testAssistantLinks() {
        XCTAssertEqual(Links.claudeCodeMCP.absoluteString, "https://code.claude.com/docs/en/mcp")
        XCTAssertEqual(Links.codexMCP.absoluteString, "https://developers.openai.com/codex/mcp")
        XCTAssertEqual(Links.claudeDesktopMCP.absoluteString, "https://modelcontextprotocol.io/docs/develop/connect-local-servers")
        XCTAssertEqual(Links.cursorMCP.absoluteString, "https://cursor.com/docs/context/mcp")
        XCTAssertEqual(Links.vscodeMCP.absoluteString, "https://code.visualstudio.com/docs/copilot/customization/mcp-servers")
    }
}
