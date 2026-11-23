// The texts AI assistants' users see come from the contract (mcp/tools.json → messages, errors, clients), never from
// a copy in the app's code (PROTOCOL.md §4 "Shared texts"). This scans App/Sources for any of them written as a string
// literal, so a copy that could drift from the contract fails here. NanoCore's MCPContractTests checks that every text
// loads; scripts/mcp-demo-check.js checks what a running editor shows.
import XCTest

final class AgentTextsTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Each contract text, cut at its {placeholders}; the parts long enough to be unmistakable.
    func contractFragments() throws -> [String] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.repo.appending(path: "mcp/tools.json"))) as? [String: Any])
        var texts: [String] = []
        for key in ["messages", "errors"] {
            let section = try XCTUnwrap(root[key] as? [String: Any])
            texts += section.filter { $0.key != "$comment" }.compactMap { $0.value as? String }
        }
        let clients = try XCTUnwrap(root["clients"] as? [String: Any])
        texts.append(try XCTUnwrap(clients["fallback"] as? String))
        return texts.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "{}")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 12 }
    }

    func testNoContractTextIsCopiedIntoTheApp() throws {
        let fragments = try contractFragments()
        XCTAssertGreaterThan(fragments.count, 10)
        let dir = Self.repo.appending(path: "App/Sources")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for f in files {
            // Comments may quote the texts; only code counts.
            let code = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }.joined(separator: "\n")
            for fragment in fragments {
                XCTAssertFalse(code.contains(fragment), "\(f.lastPathComponent) has a copy of the contract text “\(fragment)”: read it from tools.json (AgentBridge.messages / contract.errors)")
            }
        }
    }
}
