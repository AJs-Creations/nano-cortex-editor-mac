// The editor's private local socket for its MCP helper (mcp/PROTOCOL.md §1–§2, DECISIONS #43): listens only while
// Settings → AI assistants is on (`ai.enabled`, off by default; `-ai.enabled YES` turns it on for one launch), at
// /tmp/nano-cortex-<uid>/editor.sock (NANO_MCP_DIR overrides the folder, tests only) in a 0700 folder with a fresh 0600
// token. One editor at a time: if another editor (either edition) answers on the socket, this one waits and retries
// every 5 s. The first line of a connection must be a hello with the token and the contract version; then calls run one
// at a time across all connections, in arrival order (AgentBridge). Turning it off, or quitting, closes every
// connection and removes editor.sock and token.

import Foundation
import Observation
import NanoCore

@MainActor @Observable
final class AgentServer {
    static let enabledKey = "ai.enabled"
    enum Status: Equatable { case off, waiting, anotherEditor, cannotListen(String) }

    private(set) var status: Status = .off
    private(set) var enabled: Bool
    /// Connection → the assistant's name, once its hello went through.
    private(set) var clients: [Int: String] = [:]
    var clientNames: [String] { clients.keys.sorted().compactMap { clients[$0] } }
    private(set) var callsWaiting = 0
    let bridge: AgentBridge
    let endpoint = MCPEndpoint.current()

    @ObservationIgnored private var socket: AgentSocket?
    @ObservationIgnored private var token = ""
    @ObservationIgnored private var rawNames: [Int: String] = [:]
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(bridge: AgentBridge) {
        self.bridge = bridge
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        bridge.server = self
        if enabled { start() }
    }

    /// Settings → AI assistants → the switch. `persist: false` (the dev remote's /agent?enabled=) leaves the shared
    /// setting as it is.
    func setEnabled(_ on: Bool, persist: Bool = true) {
        guard on != enabled else { return }
        if persist { UserDefaults.standard.set(on, forKey: Self.enabledKey) }
        enabled = on
        bridge.store.append(on ? "Assistant: AI assistants turned on" : "Assistant: AI assistants turned off")
        if on { start() } else { stop() }
    }

    /// The status line under the switch (tools.json → messages, word for word).
    var statusText: String {
        guard let m = AgentBridge.messages else { return "Can't listen for assistants: the tool list is missing from the app." }
        switch status {
        case .off: return ""   // not shown: the status line exists only while the switch is on
        case .waiting: return clients.isEmpty ? m.statusWaiting : m.statusConnected(clients: clientNames)
        case .anotherEditor: return m.anotherEditor
        case .cannotListen(let why): return "Can't listen for assistants: \(why)."
        }
    }

    // MARK: listening

    private func start() {
        guard enabled, socket == nil else { return }
        retry?.cancel(); retry = nil
        guard let contract = bridge.contract else { status = .cannotListen("the tool list is missing from the app"); return }
        if let why = MCPEndpoint.checkPrivateDir(endpoint.dir, create: true) { status = .cannotListen(why); scheduleRetry(); return }
        if AgentSocket.someoneListening(at: endpoint.socket) { status = .anotherEditor; scheduleRetry(); return }
        unlink(endpoint.socket)   // nothing answers: a stale file from an editor that didn't get to clean up
        // Bound first, then the token: an editor that loses a race to bind never writes or removes a token, so it can't
        // clobber the winner's (review #9).
        let s = AgentSocket(
            onItems: { id, items, overflow in Task { @MainActor [weak self] in self?.received(id, items, overflow: overflow, contract: contract) } },
            onClose: { id in Task { @MainActor [weak self] in self?.closed(id) } })
        do { try s.start(path: endpoint.socket) } catch {
            status = AgentSocket.someoneListening(at: endpoint.socket) ? .anotherEditor : .cannotListen("\(error)")
            scheduleRetry()
            return
        }
        do { token = try MCPEndpoint.writeToken(endpoint.token) } catch {
            s.stop()
            unlink(endpoint.socket)
            status = .cannotListen("\(error)")
            scheduleRetry()
            return
        }
        socket = s
        status = .waiting
        bridge.store.append("Assistant: listening for AI assistants on \(endpoint.socket)")
    }

    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.socket == nil else { return }
            self.start()
        }
    }

    /// Closes every connection and removes the socket file and the token (only ours: never another editor's).
    func stop() {
        retry?.cancel(); retry = nil
        // A dialog an assistant's call waits on closes with it: no click on it can still write once assistants are off (review #5).
        bridge.store.endAgentDialogs(.cancelled)
        if let s = socket {
            s.stop()
            unlink(endpoint.socket)
            unlink(endpoint.token)
        }
        socket = nil
        if !clients.isEmpty { bridge.store.append("Assistant: closed \(clients.count) connection\(clients.count == 1 ? "" : "s")") }
        clients = [:]; rawNames = [:]
        status = .off
    }

    // MARK: messages

    private func received(_ id: Int, _ items: [MCPLineBuffer.Item], overflow: Bool, contract c: MCPContract) {
        let contract = c.contractVersion
        guard let socket else { return }
        for item in items {
            guard case .message(let msg) = item else { socket.closeConnection(id); return }   // a line that isn't JSON closes the connection
            if rawNames[id] == nil {
                switch MCPHello.check(msg, token: token, contract: contract, mismatch: c.messages.contractMismatch) {
                case .success(let client):
                    rawNames[id] = client.name
                    let name = MCPClientNames.display(client.name, clients: c.clients)
                    clients[id] = name
                    socket.send(id, MCPHello.accepted(version: AgentBridge.version, contract: contract).compact)
                    bridge.store.append("Assistant: \(name) connected")
                    bridge.store.toast(c.messages.connected(client: name))
                case .failure(let r):
                    socket.send(id, MCPHello.refused(r.message).compact)
                    socket.closeConnection(id)
                    bridge.store.append("Assistant: refused a connection: \(r.message)")
                    return
                }
                continue
            }
            guard msg["type"]?.stringValue == "call", let callID = msg["id"], let tool = msg["tool"]?.stringValue else { continue }
            let args = msg["args"] ?? .object([:])
            let client = rawNames[id] ?? ""
            Task { [weak self] in
                guard let self else { return }
                let r = await self.run(tool, args: args, client: client, connection: id)
                let reply: JSONValue
                switch r {
                case .success(let result): reply = ["type": "result", "id": callID, "ok": true, "result": result]
                case .failure(let e): reply = ["type": "result", "id": callID, "ok": false, "error": .string(e.message)]
                }
                self.socket?.send(id, reply.compact)
            }
        }
        if overflow { socket.closeConnection(id) }
    }

    private func closed(_ id: Int) {
        rawNames[id] = nil
        if let name = clients.removeValue(forKey: id) { bridge.store.append("Assistant: \(name) disconnected") }
        // Its call's dialog can't be answered any more: it closes as cancelled (PROTOCOL.md §4, dialog deadline).
        if runningFor == id { bridge.store.endAgentDialogs(.cancelled) }
    }
    /// The connection whose call runs now (nil: none, or the dev remote).
    @ObservationIgnored private var runningFor: Int?

    /// One call at a time across every connection (and the dev remote's /agent), in arrival order; a confirmation
    /// dialog holds the queue.
    func run(_ tool: String, args: JSONValue, client: String, connection: Int? = nil) async -> AgentBridge.Outcome {
        let previous = tail
        callsWaiting += 1
        let job = Task { @MainActor [weak self, bridge] () -> AgentBridge.Outcome in
            await previous?.value
            if let connection, self?.rawNames[connection] == nil { return .failure(MCPRefusal("The connection closed.")) }   // gone while queued
            self?.runningFor = connection
            defer { self?.runningFor = nil }
            return await bridge.call(tool, args: args, client: client)
        }
        tail = Task { _ = await job.value }
        let r = await job.value
        callsWaiting -= 1
        return r
    }
}

/// The socket itself, off the main thread: a listening AF_UNIX socket, a read source per connection, line splitting
/// (MCPLineBuffer) and ordered writes. All state lives on `queue`.
final class AgentSocket: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.community.nanocortex.agent-socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// A connection: its descriptor is non-blocking, so a peer that stops reading can never stall this queue (and so
    /// `stop()`, which runs on the main actor): what doesn't fit in the socket waits in `out` for a write source, and
    /// a peer that lets more than `maxQueued` pile up is dropped (review #8).
    private struct Conn {
        let fd: Int32
        let source: DispatchSourceRead
        let closer: FDCloser
        var buffer = MCPLineBuffer()
        var out: [UInt8] = []
        var writer: DispatchSourceWrite?
    }
    /// Closes the descriptor once every dispatch source on it has been cancelled.
    private final class FDCloser: @unchecked Sendable {
        let fd: Int32; var sources: Int
        init(fd: Int32, sources: Int) { self.fd = fd; self.sources = sources }
        func cancelled() { sources -= 1; if sources == 0 { Darwin.close(fd) } }   // AgentSocket.queue only
    }
    static let maxQueued = 8 * 1024 * 1024
    private var conns: [Int: Conn] = [:]
    private var nextID = 1
    private let onItems: @Sendable (Int, [MCPLineBuffer.Item], Bool) -> Void
    private let onClose: @Sendable (Int) -> Void

    init(onItems: @escaping @Sendable (Int, [MCPLineBuffer.Item], Bool) -> Void, onClose: @escaping @Sendable (Int) -> Void) {
        self.onItems = onItems; self.onClose = onClose
    }

    enum SocketError: Error, CustomStringConvertible {
        case path, system(String)
        var description: String { switch self { case .path: "the socket path is too long"; case .system(let s): s } }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Whether something accepts connections at `path` (another editor serving).
    static func someoneListening(at path: String) -> Bool {
        guard var addr = address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        return r == 0
    }

    func start(path: String) throws {
        try queue.sync {
            guard var addr = Self.address(path) else { throw SocketError.path }
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SocketError.system("socket(): \(String(cString: strerror(errno)))") }
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard bound == 0 else { let e = errno; Darwin.close(fd); throw SocketError.system("cannot listen on \(path): \(String(cString: strerror(e)))") }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else { let e = errno; Darwin.close(fd); unlink(path); throw SocketError.system("listen(): \(String(cString: strerror(e)))") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            listenFD = fd
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.acceptAll() }
            src.setCancelHandler { Darwin.close(fd) }
            acceptSource = src
            src.activate()
        }
    }

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let id = nextID; nextID += 1
            let closer = FDCloser(fd: fd, sources: 1)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self] in self?.readable(id) }
            src.setCancelHandler { closer.cancelled() }
            conns[id] = Conn(fd: fd, source: src, closer: closer)
            src.activate()
        }
    }

    private func readable(_ id: Int) {
        guard let c = conns[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = chunk.withUnsafeMutableBytes { read(c.fd, $0.baseAddress, $0.count) }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        guard n > 0 else { drop(id); return }
        let (items, overflow) = conns[id]!.buffer.feed(Data(chunk[0..<n]))
        if !items.isEmpty || overflow { onItems(id, items, overflow) }
    }

    private func drop(_ id: Int) {
        guard let c = conns.removeValue(forKey: id) else { return }
        if let w = c.writer { w.cancel() }
        c.source.cancel()
        onClose(id)
    }

    /// One message (a line) to a connection, written whole and in order.
    func send(_ id: Int, _ line: String) {
        queue.async { [weak self] in
            guard let self, self.conns[id] != nil else { return }
            self.conns[id]!.out += Array((line + "\n").utf8)
            if self.conns[id]!.out.count > Self.maxQueued { self.drop(id); return }   // the peer stopped reading
            self.flush(id)
        }
    }

    /// Writes what the socket takes now; the rest waits for a write source (non-blocking, never stalls the queue).
    private func flush(_ id: Int) {
        guard var c = conns[id] else { return }
        while !c.out.isEmpty {
            let n = c.out.withUnsafeBytes { write(c.fd, $0.baseAddress, $0.count) }
            if n > 0 { c.out.removeFirst(n); continue }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if c.writer == nil {
                    let w = DispatchSource.makeWriteSource(fileDescriptor: c.fd, queue: queue)
                    w.setEventHandler { [weak self] in self?.flush(id) }
                    c.closer.sources += 1
                    let closer = c.closer
                    w.setCancelHandler { closer.cancelled() }
                    c.writer = w
                    conns[id] = c
                    w.activate()
                } else {
                    conns[id] = c
                }
                return
            }
            conns[id] = c
            drop(id)
            return
        }
        if let w = c.writer { c.writer = nil; w.cancel() }
        conns[id] = c
    }

    func closeConnection(_ id: Int) { queue.async { [weak self] in self?.drop(id) } }

    func stop() {
        queue.sync {
            for id in Array(conns.keys) { drop(id) }
            acceptSource?.cancel(); acceptSource = nil
            listenFD = -1
        }
    }
}
