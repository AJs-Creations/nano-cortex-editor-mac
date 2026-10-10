// Metadata the pedal sends on connect (the "FE stream" reply to the metadata
// request `06 C0 08 03 01 00 00 00`): field 17 capture slots (25), 18 presets
// (64), 19 IR slots (5). And the library reply (type 77): field 3 factory
// captures, 4 factory IRs, 5 user captures, 6 user IRs.

import Foundation

public struct Metadata: Equatable, Sendable {
    public var presetNames: [String]      // 64 entries, "" where unreadable
    public var captureNames: [String]     // ≥ 25 entries
    public var irNames: [String]          // ≥ 5 entries

    public static func parse(_ body: [UInt8]) -> Metadata {
        let top = ProtoFields.parse(body)
        // At least 25 capture / 5 IR / 64 preset entries; the pedal may list more (firmware 2.2.1 reports capture slot 26 and cab slot 6 in use).
        func pad(_ a: [String], _ n: Int) -> [String] { var x = a; while x.count < n { x.append("") }; return x }
        let captures = top[17].compactMap(\.bytes).map { ProtoFields.parse($0).string(2) ?? "" }
        let presets = top[18].compactMap(\.bytes).map { ProtoFields.parse($0).string(1) ?? "" }.filter { $0.count <= 120 }
        let irs = top[19].compactMap(\.bytes).map { ProtoFields.parse($0).string(1) ?? "" }
        return Metadata(presetNames: pad(presets, 64), captureNames: pad(captures, 25), irNames: pad(irs, 5))
    }
}

public struct LibraryCapture: Equatable, Sendable {
    public var index: Int          // position in its list; the pedal addresses items by it
    public var hash: String
    public var name: String
    public var type: String
    public var tags: [String]
    public var instrument: String
    public var author: String
    public var description: String
    public var corrupted: Bool
}

public struct LibraryItem: Equatable, Sendable { public var index: Int; public var name: String }

public struct Library: Equatable, Sendable {
    public var factoryCaptures: [LibraryCapture]
    public var userCaptures: [LibraryCapture]
    public var factoryIRs: [LibraryItem]
    public var userIRs: [LibraryItem]

    /// Record: 1 hash, 2 name, 4 { 2: author }, 5 description, 6 type, 7 tags, 10 instrument, 13 corrupted.
    public static func parse(_ body: [UInt8]) -> Library {
        let f = ProtoFields.parse(body)
        func captures(_ n: Int) -> [LibraryCapture] {
            f[n].compactMap(\.bytes).enumerated().map { i, raw in
                let r = ProtoFields.parse(raw)
                return LibraryCapture(index: i, hash: r.string(1) ?? "", name: r.string(2) ?? "", type: r.string(6) ?? "default",
                                      tags: r[7].compactMap(\.string), instrument: r.string(10) ?? "",
                                      author: r.message(4)?.string(2) ?? "", description: r.string(5) ?? "",
                                      corrupted: (r.int(13) ?? 0) != 0)
            }.filter { !$0.name.isEmpty && !$0.corrupted }
        }
        func items(_ n: Int) -> [LibraryItem] { f[n].compactMap(\.string).enumerated().map { LibraryItem(index: $0, name: $1) }.filter { !$0.name.isEmpty } }
        return Library(factoryCaptures: captures(3), userCaptures: captures(5), factoryIRs: items(4), userIRs: items(6))
    }
}
