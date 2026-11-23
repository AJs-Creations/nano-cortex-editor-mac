// The setup for this installation's helper (`<app>/Contents/Helpers/nano-cortex-mcp`, no arguments, no environment;
// mcp/PROTOCOL.md "Setup lines"): the lines the manual documents for Claude Code, Codex and other assistants, and what
// Settings → Advanced's two buttons write: the Claude Desktop config merge (one entry added, every other entry kept)
// and the ChatGPT desktop app's `[mcp_servers.nano-cortex]` table in ~/.codex/config.toml (appended, the file kept as
// it is otherwise). No secrets: the token lives only in the private folder.

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

    // MARK: ChatGPT (the desktop app shares its MCP servers with Codex)

    /// `~/.codex/config.toml`.
    public static func codexConfig(home: String = NSHomeDirectory()) -> String { home + "/.codex/config.toml" }

    /// A TOML basic string: quotes, backslashes and control characters escaped.
    public static func tomlString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// What "Add to ChatGPT…" shows and appends (the native helper takes no arguments and no environment).
    public var chatGPTTable: String { "[mcp_servers.\(Self.serverName)]\ncommand = \(Self.tomlString(helper))\n" }

    /// Whether the file already has a nano-cortex server: its table (`[mcp_servers.nano-cortex]`, quoted or not, or a
    /// sub-table of it) or a dotted key under it at the top level.
    public static func codexHasServer(_ existing: Data?) -> Bool {
        guard let existing else { return false }
        let name = #"(nano-cortex|"nano-cortex"|'nano-cortex')"#
        let header = try! NSRegularExpression(pattern: #"^\s*\[\s*mcp_servers\s*\.\s*"# + name + #"\s*(\]|\.)"#)
        let dotted = try! NSRegularExpression(pattern: #"^\s*mcp_servers\s*\.\s*"# + name + #"\s*\."#)
        for line in String(decoding: existing, as: UTF8.self).components(separatedBy: .newlines) {
            let r = NSRange(line.startIndex..., in: line)
            if header.firstMatch(in: line, range: r) != nil || dotted.firstMatch(in: line, range: r) != nil { return true }
        }
        return false
    }

    /// The file with the table appended after a blank line; everything before it unchanged.
    public func appendedCodexConfig(_ existing: Data?) -> Data {
        var text = existing.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.isEmpty { text += "\n" }
        return Data((text + chatGPTTable).utf8)
    }

    public enum CodexAdd: Equatable, Sendable { case added(backup: String?), alreadyThere }
    /// "Add to ChatGPT…" after the user confirmed: nothing changes when a nano-cortex server is already there;
    /// otherwise the old file is copied next to it (`config.backup-<stamp>.toml`), the folder created when missing,
    /// and the table appended (atomic write).
    public func addToCodexConfig(path: String, now: Date = Date()) throws -> CodexAdd {
        let fm = FileManager.default
        let existing = fm.contents(atPath: path)
        if Self.codexHasServer(existing) { return .alreadyThere }
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var backup: String?
        if existing != nil {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let b = (dir as NSString).appendingPathComponent("config.backup-\(f.string(from: now)).toml")
            if fm.fileExists(atPath: b) { try fm.removeItem(atPath: b) }
            try fm.copyItem(atPath: path, toPath: b)
            backup = b
        }
        try appendedCodexConfig(existing).write(to: URL(fileURLWithPath: path), options: .atomic)
        return .added(backup: backup)
    }
}
