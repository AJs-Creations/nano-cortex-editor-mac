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
}
