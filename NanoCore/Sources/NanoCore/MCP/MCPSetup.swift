// Settings → AI assistants → Set up (mcp/PROTOCOL.md "Setup lines"): the exact text per assistant for this
// installation's helper (`<app>/Contents/Helpers/nano-cortex-mcp`, no environment), the Cursor and VS Code install
// links, and the Claude Desktop config merge (one entry added, every other entry kept). No secrets: the token lives
// only in the private folder.

import Foundation

public struct MCPSetup: Equatable, Sendable {
    public static let serverName = "nano-cortex"
    public let helper: String
    public init(helper: String) { self.helper = helper }
    /// The helper inside an app bundle.
    public init(appBundle: String) { helper = (appBundle as NSString).appendingPathComponent("Contents/Helpers/nano-cortex-mcp") }

    private var helperJSON: String { JSONValue.string(helper).compact }

    public var claudeCode: String { "claude mcp add -s user \(Self.serverName) -- \"\(helper)\"" }
    public var codex: String { "codex mcp add \(Self.serverName) -- \"\(helper)\"" }
    /// "Other assistants": `{"mcpServers":{"nano-cortex":{"command":"<helper>"}}}`.
    public var json: String { "{\"mcpServers\":{\"\(Self.serverName)\":{\"command\":\(helperJSON)}}}" }
    /// `cursor://anysphere.cursor-deeplink/mcp/install?name=nano-cortex&config=<base64 of {"command":…}>`.
    public var cursorLink: URL {
        let config = Data("{\"command\":\(helperJSON)}".utf8).base64EncodedString()
        var c = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")!
        c.percentEncodedQueryItems = [URLQueryItem(name: "name", value: Self.serverName), URLQueryItem(name: "config", value: Self.queryEncode(config))]
        return c.url!
    }
    /// `vscode:mcp/install?<URL-encoded {"name":"nano-cortex","command":…}>`.
    public var vscodeLink: URL {
        URL(string: "vscode:mcp/install?" + Self.queryEncode("{\"name\":\"\(Self.serverName)\",\"command\":\(helperJSON)}"))!
    }
    /// encodeURIComponent: everything but A–Z a–z 0–9 - _ . ! ~ * ' ( ).
    static func queryEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-_.!~*'()")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Claude Desktop

    /// `~/Library/Application Support/Claude/claude_desktop_config.json`.
    public static func claudeDesktopConfig(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/Claude/claude_desktop_config.json"
    }
    /// The entry "Add to Claude Desktop…" shows before it writes: `"nano-cortex": { "command": "<helper>" }`.
    public var claudeDesktopEntry: String {
        "\"\(Self.serverName)\": {\n  \"command\": \(helperJSON)\n}"
    }
    public enum MergeError: Error, Equatable { case notAnObject, serversNotAnObject }
    /// The config with `mcpServers.nano-cortex` set to this helper; every other key and server kept. A missing or
    /// empty file counts as `{}`; anything that isn't a JSON object is refused (nothing is written then).
    public func mergedClaudeDesktopConfig(_ existing: Data?) throws -> Data {
        var root: [String: JSONValue] = [:]
        if let existing, !String(decoding: existing, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let v = try? JSONValue.parse(existing), let o = v.objectValue else { throw MergeError.notAnObject }
            root = o
        }
        var servers: [String: JSONValue] = [:]
        if let s = root["mcpServers"] {
            guard let o = s.objectValue else { throw MergeError.serversNotAnObject }
            servers = o
        }
        servers[Self.serverName] = ["command": .string(helper)]
        root["mcpServers"] = .object(servers)
        return Data((JSONValue.object(root).pretty + "\n").utf8)
    }
    /// Whether the config already has this exact entry.
    public func claudeDesktopHasEntry(_ existing: Data?) -> Bool {
        guard let existing, let v = try? JSONValue.parse(existing) else { return false }
        return v["mcpServers"]?[Self.serverName]?["command"]?.stringValue == helper
    }
}
