// Device info (types 46/47 and the keep-alive 91/92), global settings (65–68) and capture details (17/18),
// decoded from the phone app's trace of 2026-10-09 (recorded phone-app session, not published;
// PROTOCOL-NOTES §13). Only two settings are confirmed (LED brightness, USB playback volume); the rest of
// the settings reply is kept raw so the UI can show it read-only.

import Foundation

/// Type 47 `{1:1 3:1 4:"" 5: firmware 6: serial 7: 64-hex}` plus the keep-alive reply 92
/// `{1:3 3:1 5: firmware build 6: serial 7: device name}`.
public struct DeviceInfo: Equatable, Sendable {
    public var firmware: String?        // 47.5, "2.2.1"
    public var firmwareBuild: String?   // 92.5, "2.2.1+06d34443"
    public var serial: String?          // 47.6 / 92.6
    /// 47.7: 64 hex characters that change on every request (not a fixed id; maybe a reply to the clock in 46.3).
    public var hash: String?
    public var name: String?            // 92.7, "Neural DSP Nano Cortex"

    public init(firmware: String? = nil, firmwareBuild: String? = nil, serial: String? = nil, hash: String? = nil, name: String? = nil) {
        self.firmware = firmware; self.firmwareBuild = firmwareBuild; self.serial = serial; self.hash = hash; self.name = name
    }

    static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    public static func parse(deviceInfo body: [UInt8]) -> DeviceInfo {
        let f = ProtoFields.parse(body)
        return DeviceInfo(firmware: nonEmpty(f.string(5)), serial: nonEmpty(f.string(6)), hash: nonEmpty(f.string(7)))
    }
    /// Adds what the keep-alive reply (92) carries.
    public mutating func merge(keepAlive body: [UInt8]) {
        let f = ProtoFields.parse(body)
        firmwareBuild = Self.nonEmpty(f.string(5)) ?? firmwareBuild
        serial = serial ?? Self.nonEmpty(f.string(6))
        name = Self.nonEmpty(f.string(7)) ?? name
    }
}

/// Type 66, the global settings. Confirmed: 5 device name, 6 LED brightness (0–255), 17 USB playback volume (f32 dB).
/// Everything else is unverified and only kept in `raw` (PROTOCOL-NOTES §13).
public struct DeviceSettings: Equatable, Sendable {
    public struct RawField: Equatable, Sendable { public var field: Int; public var value: String }
    public var name: String?
    public var ledBrightness: Int?
    public var usbVolumeDb: Float?
    /// Every field after the status pair (1, 3), in order, values rendered as text.
    public var raw: [RawField]

    public init(name: String? = nil, ledBrightness: Int? = nil, usbVolumeDb: Float? = nil, raw: [RawField] = []) {
        self.name = name; self.ledBrightness = ledBrightness; self.usbVolumeDb = usbVolumeDb; self.raw = raw
    }

    public static func parse(_ body: [UInt8]) -> DeviceSettings {
        let f = ProtoFields.parse(body)
        var raw: [RawField] = []
        for n in f.fields.keys.sorted() where n != 1 && n != 3 {
            for v in f[n] { raw.append(RawField(field: n, value: render(v))) }
        }
        return DeviceSettings(name: DeviceInfo.nonEmpty(f.string(5)), ledBrightness: f.int(6).map { Int(min($0, 255)) },
                              usbVolumeDb: f.first(17)?.float32, raw: raw)
    }

    static func render(_ v: ProtoValue) -> String {
        switch v {
        case .varint(let x): return "\(x)"
        case .fixed32: return String(format: "%.2f", v.float32 ?? 0)
        case .bytes(let b): return String(bytes: b, encoding: .utf8).map { "\"\($0)\"" } ?? b.map { String(format: "%02X", $0) }.joined()
        case .fixed64(let b): return b.map { String(format: "%02X", $0) }.joined()
        }
    }

    /// The phone app's slider shows brightness as a percentage of 255 (153 = 60 %, the manual's default).
    public static func brightnessPercent(_ raw: Int) -> Int { Int((Double(max(0, min(255, raw))) / 255 * 100).rounded()) }
    public static func brightnessRaw(percent: Int) -> Int { Int((Double(max(0, min(100, percent))) / 100 * 255).rounded()) }
}

/// Type 18, the reply to a capture details request (17):
/// `{1:6 3: status 7:{1 author id 2 author name} 8: description? 9: hash 10: name 11: CaptureRecord}`.
/// Field 11 is byte-identical to the state dump's field 34 for the active capture.
public struct CaptureDetails: Equatable, Sendable {
    public var ok: Bool
    public var slot: Int                // 1-based capture slot asked for
    public var name: String
    public var hash: String
    public var author: String
    public var description: String      // 18.8, or the record's 5; empty on every capture seen so far
    public var record: CaptureRecord?

    public var deviceType: String { record?.deviceType ?? "default" }
    public var instrument: String { record?.instrumentType ?? "instrument_not_set" }
    public var tags: [String] { record?.tags ?? [] }

    public static func parse(_ body: [UInt8], slot: Int) -> CaptureDetails {
        let f = ProtoFields.parse(body)
        let rec = f.message(11).map(CaptureRecord.decode)
        let author = f.message(7)
        let authorName = DeviceInfo.nonEmpty(author?.string(2)) ?? DeviceInfo.nonEmpty(author?.string(1)) ?? DeviceInfo.nonEmpty(rec?.authorName) ?? ""
        return CaptureDetails(ok: f.int(3) == 1, slot: slot,
                              name: DeviceInfo.nonEmpty(f.string(10)) ?? rec?.name ?? "",
                              hash: DeviceInfo.nonEmpty(f.string(9)) ?? rec?.hash ?? "",
                              author: authorName,
                              description: DeviceInfo.nonEmpty(f.string(8)) ?? rec?.description ?? "",
                              record: rec)
    }
}
