// The Nano Cortex MCP helper, native edition (mcp/PROTOCOL.md). An assistant app launches it over stdio; it serves
// the shared tool list (tools.json, in the app's Resources/mcp) and forwards every call to the running editor over a
// private local socket. It never launches the editor: when the editor is closed, or AI assistants are off, every
// call answers errors.editorNotRunning. It behaves exactly like mcp/helper.js; mcp/conformance.js checks both.
//
// Threads: the main thread reads stdin; one thread per editor connection reads the socket; everything else (state,
// replies on stdout) runs on one serial queue, `loop`, the counterpart of Node's event loop.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let maxLine = 1024 * 1024   // one message, either direction
let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]   // newest first

// MARK: - Lines in, messages out

enum Line: Sendable {
    case empty
    case bad
    case message(JSON)
}

/// One line as endpoint.js's lineReader sees it: trimmed, skipped when empty, else JSON or not.
func parseLine(_ bytes: ArraySlice<UInt8>) -> Line {
    let text = jsTrim(String(decoding: bytes, as: UTF8.self))
    if text.isEmpty { return .empty }
    guard let msg = JSONParser.parse(text) else { return .bad }
    return .message(msg)
}

/// Reads `fd` until EOF, calling `onLine` per line, as endpoint.js's lineReader: a line longer than maxLine bytes is
/// refused with `onTooLong` whether or not its newline has arrived yet, and the rest of it is skipped (never read as a
/// message). A callback returning false stops reading (a socket; stdin answers a parse error and goes on). Returns
/// when the stream ends or a callback returns false.
func readLines(_ fd: Int32, onLine: (Line) -> Bool, onTooLong: () -> Bool) {
    var buf: [UInt8] = []
    var skipping = false   // inside a line that was already refused as too long
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        if n == 0 { return }
        buf += chunk[0..<n]
        var start = 0
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            let line = buf[start..<nl]
            start = nl + 1
            if skipping { skipping = false; continue }
            if line.count > maxLine {
                if !onTooLong() { return }
                continue
            }
            if !onLine(parseLine(line)) { return }
        }
        if start > 0 { buf.removeFirst(start) }
        if skipping {
            buf = []
        } else if buf.count > maxLine {
            buf = []
            skipping = true
            if !onTooLong() { return }
        }
    }
}

// MARK: - The contract (tools.json) as MCP serves it

struct Contract: Sendable {
    let raw: JSONObject
    let tools: JSON                 // tools/list's `tools`
    let toolNames: Set<String>
    let kinds: [String: String]
    let prompts: [JSON]
    let notRunning: String

    static func load() -> Contract {
        let path: String
        if let p = ProcessInfo.processInfo.environment["NANO_MCP_TOOLS"], !p.isEmpty {
            path = resolvePath(p)
        } else if let exe = executablePath() {
            path = resolvePath((exe as NSString).deletingLastPathComponent + "/../Resources/mcp/tools.json")
        } else {
            fatal("cannot find my own executable, so cannot find the tool list (set NANO_MCP_TOOLS to tools.json).")
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            fatal("cannot read the tool list at \(path) (set NANO_MCP_TOOLS to tools.json).")
        }
        guard let root = JSONParser.parse(Array(data))?.object else { fatal("the tool list at \(path) is not a JSON object.") }
        guard let list = root["tools"]?.array else { fatal("the tool list at \(path) has no \"tools\" array.") }
        guard let notRunning = root["errors"]?["editorNotRunning"]?.string else {
            fatal("the tool list at \(path) has no errors.editorNotRunning text.")
        }
        let defs = root["$defs"]?.object ?? JSONObject()

        func inline(_ node: JSON) throws -> JSON {
            if case .array(let a) = node { return .array(try a.map(inline)) }
            guard case .object(let o) = node else { return node }
            var out = JSONObject()
            if case .string(let ref)? = o["$ref"] {
                let prefix = "#/$defs/"
                let name = ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ""
                guard !name.isEmpty, let def = defs[name], def.truthy else { throw UnknownRef(ref: ref) }
                out = try inline(def).object ?? JSONObject()
            }
            for (k, v) in o.entries where k != "$ref" { out[k] = try inline(v) }
            return .object(out)
        }

        var tools: [JSON] = []
        var names = Set<String>()
        var kinds: [String: String] = [:]
        for t in list {
            let name = t["name"]?.string
            let kind = t["kind"]?.string
            if let name {
                names.insert(name)
                if let kind { kinds[name] = kind }
            }
            let read = kind == "read" || name == "cloud_search" || name == "cloud_open"
            let annotations = JSON.obj([
                ("title", t["title"]),
                ("readOnlyHint", .bool(read)),
                ("destructiveHint", .bool(!read && (kind == "confirm" || (t["destructive"]?.truthy ?? false)))),
                ("idempotentHint", .bool(read)),
                ("openWorldHint", .bool(kind == "cloud" || name == "cloud_send")),
            ])
            let schema: JSON?
            do { schema = try t["inputSchema"].map(inline) } catch let e as UnknownRef {
                fatal("unknown $ref \(e.ref) in the tool list at \(path).")
            } catch {
                fatal("cannot read the tool list at \(path).")
            }
            tools.append(.obj([
                ("name", t["name"]), ("title", t["title"]), ("description", t["description"]),
                ("inputSchema", schema), ("annotations", annotations),
            ]))
        }
        return Contract(raw: root, tools: .array(tools), toolNames: names, kinds: kinds,
                        prompts: root["prompts"]?.array ?? [], notRunning: notRunning)
    }

    private struct UnknownRef: Error { let ref: String }

    /// How long a call may take before the helper gives up on the editor's answer, in seconds.
    func timeout(for name: String, _ args: JSON) -> Int {
        if kinds[name] == "confirm" { return 10 * 60 }
        if name == "get_slot_usage", args["scan"]?.truthy ?? false { return 5 * 60 }
        if name == "cloud_preview" { return 3 * 60 }
        return 2 * 60
    }
}

func fatal(_ text: String) -> Never {
    logError(text)
    exit(1)
}

/// The app's version: an Info.plist embedded in this binary, else the enclosing app's, else 0.0.0.
func appVersion() -> String {
    if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty { return v }
    if let exe = executablePath() {
        let plist = resolvePath((exe as NSString).deletingLastPathComponent + "/../Info.plist")
        if let data = FileManager.default.contents(atPath: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let v = dict["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
    }
    return "0.0.0"
}

// MARK: - The editor link

/// One socket connection to the editor. `fd` is closed only on `writeQueue`, after the reader thread is done with it,
/// so a write or shutdown can never hit a reused descriptor.
final class Link: @unchecked Sendable {
    let fd: Int32
    let token: String
    private let writeQueue = DispatchQueue(label: "nano-cortex-mcp.link")
    private var fdClosed = false   // writeQueue only

    // loop only:
    var pending: [Int: (JSON) -> Void] = [:]
    var waiters: [(String?) -> Void] = []
    var settled = false
    var closed = false

    init(fd: Int32, token: String) {
        self.fd = fd
        self.token = token
    }

    func send(_ msg: JSON) {
        let bytes = JSONWriter.bytes(msg) + [0x0A]
        writeQueue.async {
            if !self.fdClosed { writeAll(self.fd, bytes) }
        }
    }

    /// Ends the connection; the reader thread then sees the end and reports the close.
    func destroy() {
        writeQueue.async {
            if !self.fdClosed { _ = shutdown(self.fd, Int32(SHUT_RDWR)) }
        }
    }

    func closeDescriptor() {
        writeQueue.async {
            if !self.fdClosed {
                self.fdClosed = true
                close(self.fd)
            }
        }
    }
}

// MARK: - The helper

final class Helper: @unchecked Sendable {
    let loop = DispatchQueue(label: "nano-cortex-mcp.loop")
    let contract: Contract
    let version: String

    // loop only:
    private var link: Link?          // the connection after a successful hello
    private var connecting: Link?    // a connection attempt that every call waits on
    private var nextCall = 1
    private var clientInfo = JSON.obj([("name", .string("unknown")), ("version", .string(""))])

    init(contract: Contract, version: String) {
        self.contract = contract
        self.version = version
    }

    // ---------------------------------------------------------------- stdio

    /// Blocks reading stdin; exits 0 at its end.
    func runStdin() -> Never {
        readLines(0, onLine: { line in
            switch line {
            case .empty: break
            case .bad: loop.async { self.fail(.null, -32700, "Parse error") }
            case .message(let msg): loop.async { self.handle(msg) }
            }
            return true
        }, onTooLong: {
            loop.async { self.fail(.null, -32700, "Parse error") }
            return true
        })
        loop.async { exit(0) }
        dispatchMain()
    }

    private func send(_ msg: JSON) { writeAll(1, JSONWriter.bytes(msg) + [0x0A]) }
    private func reply(_ id: JSON, _ result: JSON) { send(.obj([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])) }
    private func fail(_ id: JSON, _ code: Int, _ message: String) {
        send(.obj([("jsonrpc", .string("2.0")), ("id", id),
                   ("error", .obj([("code", .number(Double(code))), ("message", .string(message))]))]))
    }

    private func fillTemplate(_ text: String, _ args: JSON) -> String {
        // text.replace(/\{(\w+)\}/g, (_, k) => args[k] !== undefined ? String(args[k]) : '')
        func isWord(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_"
        }
        let s = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            if s[i] == "{" {
                var j = i + 1
                while j < s.count, isWord(s[j]) { j += 1 }
                if j > i + 1, j < s.count, s[j] == "}" {
                    let key = String(String.UnicodeScalarView(s[(i + 1)..<j]))
                    if let v = args[key] { out.append(contentsOf: v.jsString.unicodeScalars) }
                    i = j + 1
                    continue
                }
            }
            out.append(s[i])
            i += 1
        }
        return String(out)
    }

    private func handle(_ msg: JSON) {
        let obj = msg.object
        guard let o = obj, o["jsonrpc"] == .string("2.0"), case .string(let method)? = o["method"] else {
            if let o = obj, o["id"] != nil, o["method"] == nil { return }   // a response to nothing we asked: ignore
            return fail(obj?["id"] ?? .null, -32600, "Invalid request")
        }
        guard let id = o["id"], id != .null else { return }   // notifications need no answer
        let params = o["params"]
        switch method {
        case "initialize":
            let asked = andProp(params, "protocolVersion")?.string
            if let p = params, p.truthy, let info = p["clientInfo"], info.truthy {
                let name = info["name"].flatMap { $0.truthy ? $0 : nil }?.jsString ?? "unknown"
                let version = info["version"].flatMap { $0.truthy ? $0 : nil }?.jsString ?? ""
                clientInfo = .obj([("name", .string(jsSlice(name, 80))), ("version", .string(jsSlice(version, 40)))])
            }
            let server = contract.raw["server"]
            reply(id, .obj([
                ("protocolVersion", .string(asked.map { protocolVersions.contains($0) } == true ? asked! : protocolVersions[0])),
                ("capabilities", .obj([("tools", .obj([("listChanged", .bool(false))])),
                                       ("prompts", .obj([("listChanged", .bool(false))]))])),
                ("serverInfo", .obj([("name", server?["name"]), ("title", server?["title"]), ("version", .string(version))])),
                ("instructions", server?["instructions"]),
            ]))
        case "ping":
            reply(id, .emptyObject)
        case "tools/list":
            reply(id, .obj([("tools", contract.tools)]))
        case "prompts/list":
            reply(id, .obj([("prompts", .array(contract.prompts.map {
                .obj([("name", $0["name"]), ("title", $0["title"]), ("description", $0["description"]), ("arguments", $0["arguments"])])
            }))]))
        case "prompts/get":
            let wanted = andProp(params, "name")
            let p = contract.prompts.first { x in
                guard let w = wanted, let n = x["name"] else { return false }
                switch w { case .array, .object: return false; default: return n == w }
            }
            guard let p else { return fail(id, -32602, "Unknown prompt: " + jsConcat(wanted)) }
            let given = andProp(params, "arguments")
            let args = given?.truthy == true ? given! : .emptyObject
            for a in p["arguments"]?.array ?? [] where a["required"]?.truthy ?? false {
                let v = a["name"].flatMap { $0.string }.flatMap { args[$0] }
                let text = v?.truthy == true ? v!.jsString : ""
                if jsTrim(text).isEmpty { return fail(id, -32602, "Missing argument: " + jsConcat(a["name"])) }
            }
            reply(id, .obj([
                ("description", p["description"]),
                ("messages", .array([.obj([("role", .string("user")),
                                           ("content", .obj([("type", .string("text")),
                                                             ("text", .string(fillTemplate(p["template"]?.jsString ?? "", args)))]))])])),
            ]))
        case "tools/call":
            let name = andProp(params, "name")
            guard case .string(let tool)? = name, contract.toolNames.contains(tool) else {
                return fail(id, -32602, "Unknown tool: " + jsConcat(name))
            }
            let given = params?["arguments"]
            let args: JSON = given?.object != nil ? given! : .emptyObject
            callEditor(tool, args) { r in
                if !(r["ok"]?.truthy ?? false) {
                    let e = r["error"]
                    let text = e?.truthy == true ? e!.jsString : "The editor reported an error."
                    return self.reply(id, .obj([("content", .array([.obj([("type", .string("text")), ("text", .string(text))])])),
                                                ("isError", .bool(true))]))
                }
                let result = r["result"] ?? .emptyObject
                let text: String
                if case .string(let s) = result { text = s } else { text = JSONWriter.string(result, indent: 2) }
                var out = JSONObject([("content", .array([.obj([("type", .string("text")), ("text", .string(text))])]))])
                if case .object = result { out["structuredContent"] = result }
                self.reply(id, .object(out))
            }
        default:
            fail(id, -32601, "Method not found: " + method)
        }
    }

    // ---------------------------------------------------------------- the editor link (all on loop)

    private func errorResult(_ text: String) -> JSON { .obj([("ok", .bool(false)), ("error", .string(text))]) }

    private func callEditor(_ name: String, _ args: JSON, _ done: @escaping (JSON) -> Void) {
        if let l = link, !l.closed { return issue(l, name, args, done) }
        let afterConnect: (String?) -> Void = { err in
            if let err { return done(self.errorResult(err)) }
            guard let l = self.link, !l.closed else {
                return done(self.errorResult("The editor closed the connection before answering. " + self.contract.notRunning))
            }
            self.issue(l, name, args, done)
        }
        if let c = connecting { c.waiters.append(afterConnect); return }

        let ep = Endpoint.current()
        if let bad = checkPrivateDir(ep.dir) {
            // A missing folder just means the editor never listened: the usual "open the editor".
            return afterConnect(bad.hasSuffix("does not exist") ? contract.notRunning : "Refusing to talk to the editor: " + bad + ".")
        }
        guard let token = readToken(ep.token), let fd = makeUnixSocket() else { return afterConnect(contract.notRunning) }
        let l = Link(fd: fd, token: token)
        l.waiters = [afterConnect]
        connecting = l
        let socketPath = ep.socket
        let thread = Thread { [self] in
            guard connectUnix(l.fd, socketPath) else {
                l.closeDescriptor()
                loop.async { self.linkClosed(l) }
                return
            }
            loop.async { self.linkConnected(l) }
            readLines(l.fd, onLine: { line in
                switch line {
                case .empty: return true
                case .bad: return false
                case .message(let msg):
                    loop.async { self.linkMessage(l, msg) }
                    return true
                }
            }, onTooLong: { false })
            l.closeDescriptor()
            loop.async { self.linkClosed(l) }
        }
        thread.stackSize = 4 << 20
        thread.start()
    }

    private func issue(_ l: Link, _ name: String, _ args: JSON, _ done: @escaping (JSON) -> Void) {
        let id = nextCall
        nextCall += 1
        let seconds = contract.timeout(for: name, args)
        l.pending[id] = done
        loop.asyncAfter(deadline: .now() + .seconds(seconds)) {
            if let p = l.pending.removeValue(forKey: id) {
                p(self.errorResult("The editor did not answer within \(seconds) s."))
            }
        }
        l.send(.obj([("type", .string("call")), ("id", .number(Double(id))), ("tool", .string(name)), ("args", args)]))
    }

    private func settle(_ l: Link, _ err: String?) {
        guard !l.settled else { return }
        l.settled = true
        if connecting === l { connecting = nil }
        let waiters = l.waiters
        l.waiters = []
        for w in waiters { w(err) }
    }

    private func linkConnected(_ l: Link) {
        guard !l.closed else { return }
        l.send(.obj([("type", .string("hello")), ("token", .string(l.token)), ("contract", contract.raw["contractVersion"]),
                     ("client", clientInfo)]))
    }

    private func linkMessage(_ l: Link, _ msg: JSON) {
        guard !l.closed, let o = msg.object else { return }
        if o["type"] == .string("hello") {
            if o["ok"]?.truthy ?? false {
                link = l
                settle(l, nil)
            } else {
                let e = o["error"]
                settle(l, e?.truthy == true ? e!.jsString : "the editor refused the connection")
                l.destroy()
            }
            return
        }
        if o["type"] == .string("result"), case .number(let d)? = o["id"], let id = Int(exactly: d),
           let p = l.pending.removeValue(forKey: id) {
            p(msg)
        }
    }

    private func linkClosed(_ l: Link) {
        guard !l.closed else { return }
        l.closed = true
        settle(l, contract.notRunning)
        if link === l { link = nil }
        let pending = l.pending
        l.pending = [:]
        for (_, p) in pending.sorted(by: { $0.key < $1.key }) {
            p(errorResult("The editor closed the connection before answering. " + contract.notRunning))
        }
    }
}

// MARK: - Start

signal(SIGPIPE, SIG_IGN)
Helper(contract: Contract.load(), version: appVersion()).runStdin()
