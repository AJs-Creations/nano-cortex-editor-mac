// The link to the pedal, abstracted so the session logic runs headless.
// `BluetoothTransport` (app target, CoreBluetooth) and `FakePedal` (here) both implement it.

import Foundation

public protocol NanoTransport: Sendable {
    /// A fresh stream of C305 notifications for one session. Cancelling its consumer ends only that stream;
    /// the transport keeps the link and can hand out another one (reconnects).
    func subscribe() -> AsyncStream<[UInt8]>
    /// One C304 write with response. Throws when the link is gone.
    func write(_ bytes: [UInt8]) async throws
    func disconnect() async
}

public enum TransportError: Error, Sendable { case notConnected, timeout(String), refused(String) }

/// Fan-out of notification packets to any number of per-session streams.
public final class NotificationHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<[UInt8]>.Continuation] = [:]
    public init() {}
    public func subscribe() -> AsyncStream<[UInt8]> {
        let id = UUID()
        return AsyncStream { c in
            lock.lock(); subscribers[id] = c; lock.unlock()
            c.onTermination = { [weak self] _ in guard let self else { return }; self.lock.lock(); self.subscribers[id] = nil; self.lock.unlock() }
        }
    }
    public func yield(_ packet: [UInt8]) {
        lock.lock(); let subs = Array(subscribers.values); lock.unlock()
        subs.forEach { $0.yield(packet) }
    }
    public func finishAll() {
        lock.lock(); let subs = Array(subscribers.values); subscribers.removeAll(); lock.unlock()
        subs.forEach { $0.finish() }
    }
}
