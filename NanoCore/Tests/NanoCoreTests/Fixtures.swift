import Foundation
import XCTest
@testable import NanoCore

/// The recording file format (Electron's Record button and this app's), used to check the JSON round trip.
struct RecordedEvent: Decodable { let t: Double; let dir: String; let hex: String; let label: String? }
struct Recording: Decodable { let events: [RecordedEvent] }

/// Helpers for the frames inlined in `RecordedFrames.swift`. No recording files ship with the repository.
enum Fixtures {
    static func bytes(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
    static func base64(_ text: String) -> [UInt8] {
        [UInt8](Data(base64Encoded: text) ?? Data())
    }
    /// The single-packet frame's body.
    static func body(_ hex: String) -> [UInt8] { Frame.body(of: bytes(hex)) ?? [] }
    /// Deterministic stand-in for capture data (.cns) of a given size.
    static func syntheticCapture(_ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) } }
}
