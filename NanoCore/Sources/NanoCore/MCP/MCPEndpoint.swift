// The editor's side of the private local socket (mcp/PROTOCOL.md §1–§2), as in the Electron edition's mcp/endpoint.js:
// the path, the private-folder check both sides make, the token, the hello, one JSON message per line. No sockets in
// here (the app's AgentServer owns those), so all of it is tested headless.

import Foundation

public struct MCPEndpoint: Equatable, Sendable {
    public let dir: String
    public var socket: String { dir + "/editor.sock" }
    public var token: String { dir + "/token" }

    /// `/tmp/nano-cortex-<uid>`, or `NANO_MCP_DIR` (tests only; the helper honours it too).
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPEndpoint {
        if let custom = environment["NANO_MCP_DIR"], !custom.isEmpty {
            let abs = custom.hasPrefix("/") ? custom : FileManager.default.currentDirectoryPath + "/" + custom
            return MCPEndpoint(dir: (abs as NSString).standardizingPath)
        }
        return MCPEndpoint(dir: "/tmp/nano-cortex-\(getuid())")
    }
    public init(dir: String) { self.dir = dir }

    /// nil when `dir` is a private folder of this user (created 0700 when `create`), else why not (endpoint.js's
    /// `checkPrivateDir`, same texts): a symlink, a file, another user's folder or one others can read is refused.
    public static func checkPrivateDir(_ dir: String, create: Bool = false) -> String? {
        var st = stat()
        if lstat(dir, &st) != 0 {
            let err = errno
            guard err == ENOENT else { return "cannot read \(dir): \(String(cString: strerror(err)))" }
            guard create else { return "the folder \(dir) does not exist" }
            if mkdir(dir, 0o700) != 0, errno != EEXIST { return "cannot create \(dir): \(String(cString: strerror(errno)))" }
            guard lstat(dir, &st) == 0 else { return "cannot read \(dir): \(String(cString: strerror(errno)))" }
        }
        let type = st.st_mode & S_IFMT
        if type == S_IFLNK { return "\(dir) is a symbolic link" }
        if type != S_IFDIR { return "\(dir) is not a folder" }
        if st.st_uid != getuid() { return "\(dir) belongs to another user" }
        let mode = st.st_mode & 0o777
        if mode & 0o077 != 0 { return "\(dir) is not private (mode \(String(mode, radix: 8)), expected 700)" }
        return nil
    }

    /// A new token (64 hex characters), written 0600 to a temporary file and renamed over `file`.
    public static func writeToken(_ file: String) throws -> String {
        var rng = SystemRandomNumberGenerator()   // arc4random: cryptographically secure on Apple platforms
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        let tmp = "\(file).\(getpid()).tmp"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let bytes = Array((token + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        fchmod(fd, 0o600)
        close(fd)
        guard written == bytes.count, rename(tmp, file) == 0 else { unlink(tmp); throw CocoaError(.fileWriteUnknown) }
        return token
    }

    /// The token, when `file` is a regular file of this user that others can't read and holds 64 hex characters.
    public static func readToken(_ file: String) -> String? {
        var st = stat()
        guard lstat(file, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(), st.st_mode & 0o077 == 0,
              let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 64 && t.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) ? t : nil
    }

    /// Constant-time comparison (the time doesn't depend on where the tokens differ).
    public static func sameToken(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// Splits a socket's byte stream into lines of JSON (one message per line, at most 1 MiB each), as endpoint.js's
/// lineReader does for a socket: a line over `maxLine` bytes is refused whether or not its newline has arrived, and
/// after a refused line (too long, or not JSON) nothing more is read, since the connection closes.
public struct MCPLineBuffer: Sendable {
    public static let maxLine = 1024 * 1024
    private var buffer = Data()
    /// A line was refused: everything after it is ignored.
    public private(set) var ended = false
    public init() {}
    public enum Item: Equatable, Sendable { case message(JSONValue), bad }
    /// The complete lines in `chunk` (blank lines skipped), up to and including the first `.bad` one; `overflow` when
    /// a line is longer than `maxLine` (close). Either ends the buffer.
    public mutating func feed(_ chunk: Data) -> (items: [Item], overflow: Bool) {
        guard !ended else { return ([], false) }
        buffer.append(chunk)
        var items: [Item] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if line.count > Self.maxLine { end(); return (items, true) }   // measured before it is decoded
            buffer = Data(buffer[buffer.index(after: nl)...])
            let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let v = try? JSONValue.parse(trimmed) else { items.append(.bad); end(); return (items, false) }
            items.append(.message(v))
        }
        if buffer.count > Self.maxLine { end(); return (items, true) }
        return (items, false)
    }
    private mutating func end() { ended = true; buffer = Data() }
}

/// The first message on a connection (PROTOCOL.md §2).
public enum MCPHello {
    public struct Client: Equatable, Sendable { public let name: String; public let version: String }
    public static let wrongToken = "The editor refused the connection: the token does not match (it changes each time AI assistants are turned on). Try again."
    public static let notHello = "The editor expected a hello first."

    /// The client on success, else the `error` of the refusing hello. `mismatch`: the contract's
    /// `messages.contractMismatch` (another contract version).
    public static func check(_ msg: JSONValue, token: String, contract: Int, mismatch: String) -> Result<Client, MCPRefusal> {
        guard msg["type"]?.stringValue == "hello" else { return .failure(MCPRefusal(notHello)) }
        guard let t = msg["token"]?.stringValue, MCPEndpoint.sameToken(t, token) else { return .failure(MCPRefusal(wrongToken)) }
        guard msg["contract"]?.intValue == contract else { return .failure(MCPRefusal(mismatch)) }
        let name = String((msg["client"]?["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let version = String((msg["client"]?["version"]?.stringValue ?? "").prefix(40))
        return .success(Client(name: name, version: version))
    }

    /// `{"type":"hello","ok":true,"editor":{…}}`.
    public static func accepted(version: String, contract: Int) -> JSONValue {
        ["type": "hello", "ok": true, "editor": ["name": "Nano Cortex Editor", "edition": "native", "version": .string(version), "contract": .number(Double(contract))]]
    }
    public static func refused(_ why: String) -> JSONValue { ["type": "hello", "ok": false, "error": .string(why)] }
}

/// What people call the assistant apps: MCP `clientInfo.name` → the name Settings and the dialogs show, through the
/// contract's `clients` (tools.json; no table in code). As its `$comment` says: control characters stripped, trimmed,
/// cut to 60 characters; empty or "unknown" → the fallback; a name not listed is shown as sent.
public enum MCPClientNames {
    public static let maxLength = 60
    public static func display(_ raw: String, clients: MCPContract.Clients) -> String {
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let n = String(visible.trimmingCharacters(in: .whitespaces).prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        if n.isEmpty || n.lowercased() == "unknown" { return clients.fallback }
        return clients.names[n.lowercased()] ?? n
    }
}
