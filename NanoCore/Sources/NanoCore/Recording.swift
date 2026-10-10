// Session recording: every packet in both directions with timestamps relative to the start, plus the
// Activity log lines, saved as JSON in the Electron app's format (pro/ui.js "session recording";
// session recordings there). Recordings stay private and are never committed (they carry pedal ids and users' presets).

import Foundation

public enum PacketDirection: String, Sendable, Codable { case tx, rx }

/// Called by `Session` for every raw packet: TX just before the C304 write (with the job's label),
/// RX for every C305 notification as it arrives (before reassembly). Runs on the session's executor.
public typealias PacketTap = @Sendable (PacketDirection, [UInt8], String?) -> Void

/// The saved file: `{app, recorded, demo, device, preset, events: [{t, dir, hex, label?}], log: [{t, text}]}`.
/// `preset` is 1-based, as in the Electron app; `t` is milliseconds since the start.
public struct SessionRecording: Codable, Sendable, Equatable {
    public struct Event: Codable, Sendable, Equatable {
        public var t: Int
        public var dir: PacketDirection
        public var hex: String
        public var label: String?
    }
    public struct Line: Codable, Sendable, Equatable {
        public var t: Int
        public var text: String
    }
    public var app: String
    public var recorded: String
    public var demo: Bool
    public var device: String?
    public var preset: Int?
    public var events: [Event]
    public var log: [Line]

    private enum CodingKeys: String, CodingKey { case app, recorded, demo, device, preset, events, log }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app); try c.encode(recorded, forKey: .recorded); try c.encode(demo, forKey: .demo)
        try c.encode(device, forKey: .device); try c.encode(preset, forKey: .preset)   // null when unknown, like Electron
        try c.encode(events, forKey: .events); try c.encode(log, forKey: .log)
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
    public static func parse(_ data: Data) throws -> SessionRecording { try JSONDecoder().decode(SessionRecording.self, from: data) }

    public var tx: [Event] { events.filter { $0.dir == .tx } }
    public var rx: [Event] { events.filter { $0.dir == .rx } }
}

/// Thread-safe recorder shared between the UI (start/stop, log lines) and the session's packet tap.
/// Not recording → `record` and `note` are no-ops, so the tap can stay installed.
public final class SessionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Date?
    private var events: [SessionRecording.Event] = []
    private var lines: [SessionRecording.Line] = []

    public init() {}

    public var isRecording: Bool { lock.withLock { started != nil } }
    public var count: Int { lock.withLock { events.count } }
    public var startDate: Date? { lock.withLock { started } }

    public func start(at date: Date = Date()) {
        lock.withLock { started = date; events = []; lines = [] }
    }

    public func record(_ dir: PacketDirection, _ bytes: [UInt8], label: String? = nil, at date: Date = Date()) {
        lock.withLock {
            guard let started else { return }
            events.append(.init(t: Self.ms(date, since: started), dir: dir, hex: Self.hex(bytes), label: label))
        }
    }

    public func note(_ text: String, at date: Date = Date()) {
        lock.withLock {
            guard let started else { return }
            lines.append(.init(t: Self.ms(date, since: started), text: text))
        }
    }

    /// Ends the recording and returns it (nil when none was running).
    public func stop(app: String = "nano-cortex-mac", demo: Bool, device: String?, preset: Int?) -> SessionRecording? {
        lock.withLock {
            guard let s = started else { return nil }
            started = nil
            defer { events = []; lines = [] }
            return SessionRecording(app: app, recorded: Self.iso(s), demo: demo, device: device, preset: preset, events: events, log: lines)
        }
    }

    /// The tap to hand to `Session(transport:tap:)`.
    public var tap: PacketTap { { [self] dir, bytes, label in record(dir, bytes, label: label) } }

    // MARK: format helpers (match the Electron app)

    /// "0C C0 18 01": uppercase, space separated.
    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// `new Date().toISOString()`: UTC with milliseconds.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// `nano-session-2026-10-08T14-47-17.json` (the ISO date in UTC, `:` and `.` replaced, seconds precision).
    public static func fileName(for date: Date) -> String {
        "nano-session-" + String(iso(date).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-").prefix(19)) + ".json"
    }

    private static func ms(_ d: Date, since s: Date) -> Int { max(0, Int((d.timeIntervalSince(s) * 1000).rounded())) }
}
