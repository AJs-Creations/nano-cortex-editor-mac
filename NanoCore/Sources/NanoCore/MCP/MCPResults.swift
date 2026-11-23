// Result builders for the read tools, with the field names both editions share (mcp/PROTOCOL.md §4 "Results"). Pure:
// the app hands in what PedalStore holds.

import Foundation

public enum MCPResults {
    // MARK: effects

    public static func paramInfo(_ p: ParamDef) -> JSONValue {
        switch p.meta {
        case .options(let o)?: return ["name": .string(p.name), "options": .array(o.map(JSONValue.string))]
        case .range(let lo, let hi, let step, let unit, _, _, _)?:
            return ["name": .string(p.name), "unit": .string(unit), "min": .number(lo), "max": .number(hi), "step": .number(step)]
        case nil: return ["name": .string(p.name), "unit": "", "min": 0, "max": 10, "step": 0.1]
        }
    }

    /// `list_effects`: the models each slot takes ("None" is not listed; it is always allowed).
    public static func listEffects(slot: Slot?) -> JSONValue {
        let slots = slot.map { [$0] } ?? Slot.allCases
        return ["slots": .array(slots.map { s in
            ["slot": .string(s.rawValue), "title": .string(s.title),
             "models": .array(MCPEffects.models(for: s).map { m in
                 ["name": .string(m.name), "category": .string(m.category), "params": .array(m.params.map(paramInfo))]
             })]
        })]
    }

    /// One effect slot of `get_current_preset`.
    public static func effect(slot: Slot, block: FXSlotState?, preset: Int) -> JSONValue {
        guard let b = block, b.model != nil || b.unknownId != nil else {
            return ["slot": .string(slot.rawValue), "title": .string(slot.title), "on": false, "model": "None", "category": "Bypass", "known": true, "params": [], "valuesKnown": true]
        }
        guard let m = b.model else {
            return ["slot": .string(slot.rawValue), "title": .string(slot.title), "on": .bool(b.on), "model": "Unknown effect", "category": "Unknown", "known": false,
                    "params": [], "valuesKnown": false]
        }
        let params: [JSONValue] = m.params.enumerated().map { i, p in
            let v = i < b.values.count ? b.values[i] : p.defaultValue
            switch p.meta {
            case .options(let o)?:
                let k = max(0, min(o.count - 1, Int(v.rounded())))
                return ["name": .string(p.name), "value": .string(o.isEmpty ? "" : o[k]), "options": .array(o.map(JSONValue.string))]
            case .range(let lo, let hi, let step, let unit, _, _, _)?:
                return ["name": .string(p.name), "value": .number(v), "display": .string(MCPEffects.display(v, meta: p.meta)), "unit": .string(unit),
                        "min": .number(lo), "max": .number(hi), "step": .number(step)]
            case nil:
                return ["name": .string(p.name), "value": .number(v), "display": .string(MCPEffects.display(v, meta: nil)), "unit": "", "min": 0, "max": 10, "step": 0.1]
            }
        }
        return ["slot": .string(slot.rawValue), "title": .string(slot.title), "on": .bool(b.on), "model": .string(m.name), "category": .string(m.category),
                "known": true, "params": .array(params), "valuesKnown": .bool(b.valuesKnown(preset: preset))]
    }

    // MARK: presets, slots

    /// `list_presets`: 64 presets (1-based numbers), the loaded one, the footswitches.
    public static func listPresets(names: [String], current: Int?, footswitch: Footswitches?) -> JSONValue {
        let count = max(64, names.count)
        let presets: [JSONValue] = (0..<count).map { i in
            let n = i < names.count ? names[i] : ""
            return ["number": .number(Double(i + 1)), "name": n.isEmpty ? .null : .string(n), "empty": .bool(n.isEmpty)]
        }
        let fs: JSONValue = footswitch.map { f in
            .object(Dictionary(uniqueKeysWithValues: FootswitchSlot.allCases.map { ($0.label, JSONValue.number(Double(f[$0] + 1))) }))
        } ?? ["IA": nil, "IB": nil, "IIA": nil, "IIB": nil]
        return ["current": current.map { .number(Double($0 + 1)) } ?? .null, "presets": .array(presets), "footswitches": fs]
    }

    /// `get_slot_usage`: slot → preset numbers (1-based), from the last scan; null parts when there was none.
    /// Slot 0 means "straight from the library" (no slot).
    public static func slotUsage(captures: [Int: [Int]]?, cabs: [Int: [Int]]?) -> JSONValue {
        func map(_ m: [Int: [Int]]?) -> JSONValue {
            guard let m else { return .null }
            return .object(Dictionary(uniqueKeysWithValues: m.filter { $0.key > 0 }.map { ("\($0.key)", JSONValue.array($0.value.sorted().map { .number(Double($0 + 1)) })) }))
        }
        return ["scanned": .bool(captures != nil || cabs != nil), "capture": map(captures), "cab": map(cabs)]
    }

    /// `list_library`: every slot (name null when empty) plus the library, narrowed by the optional filters.
    public static func library(kind: String, slotNames: [String], library: Library, instrument: String? = nil, type: String? = nil, query: String? = nil) -> JSONValue {
        let slots: [JSONValue] = slotNames.enumerated().map { i, n in ["slot": .number(Double(i + 1)), "name": n.isEmpty ? .null : .string(n)] }
        let q = query?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        func hit(_ name: String, _ description: String) -> Bool { q.isEmpty || name.lowercased().contains(q) || description.lowercased().contains(q) }
        var items: [JSONValue] = []
        if kind == "cab" {
            for (source, list) in [("factory", library.factoryIRs), ("user", library.userIRs)] {
                items += list.filter { hit($0.name, "") }.map { ["source": .string(source), "name": .string($0.name)] }
            }
        } else {
            for (source, list) in [("factory", library.factoryCaptures), ("user", library.userCaptures)] {
                for c in list where hit(c.name, c.description) {
                    if let instrument, !c.instrument.lowercased().contains(instrument.lowercased()) { continue }
                    if let type, c.type.caseInsensitiveCompare(type) != .orderedSame { continue }
                    var o: [String: JSONValue] = ["source": .string(source), "name": .string(c.name), "type": .string(c.type), "instrument": .string(Self.instrument(c.instrument))]
                    if !c.description.isEmpty { o["description"] = .string(c.description) }
                    items.append(.object(o))
                }
            }
        }
        return ["kind": .string(kind), "slots": .array(slots), "library": .array(items)]
    }
    /// "instrument_guitar" / "guitar" → "guitar"; nothing set → "".
    static func instrument(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("bass") { return "bass" }
        if l.contains("guitar") { return "guitar" }
        return l.contains("not_set") ? "" : raw
    }

    // MARK: Cortex Cloud

    /// The search API's reply (`numberOfResults`, `numberOfPages`, `data[]`) as `cloud_search`'s result; nil when it
    /// isn't that shape. `onPedal` is null when the pedal's library hashes are not known.
    public static func cloudSearch(_ reply: JSONValue, query: String, page: Int, libraryHashes: Set<String>?) -> JSONValue? {
        guard let data = reply["data"]?.arrayValue else { return nil }
        func text(_ v: JSONValue?) -> JSONValue { v?.stringValue.map(JSONValue.string) ?? (v?.numberValue).map { .string(MCPValidator.format($0)) } ?? .null }
        let results: [JSONValue] = data.compactMap { item in
            guard let id = item["productId"]?.stringValue ?? item["product_id"]?.stringValue ?? item["id"]?.stringValue else { return nil }
            let meta = item["metadata"]
            let tags: [JSONValue] = (item["tags"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["name"]?.stringValue }.map(JSONValue.string)
            var description = item["description"]?.stringValue ?? ""
            if description.count > 300 { description = String(description.prefix(299)) + "…" }
            let hash = item["hash"]?.stringValue?.lowercased()
            let onPedal: JSONValue = libraryHashes.map { set in .bool(hash.map { set.contains($0) } ?? false) } ?? .null
            return ["product_id": .string(id), "name": text(item["name"]), "author": text(item["authorUsername"] ?? item["author"]), "tags": .array(tags),
                    "instrument": text(meta?["instrument"] ?? meta?["instrumentType"] ?? item["instrument"]),
                    "device": text(meta?["device"] ?? meta?["deviceType"] ?? item["device"]),
                    "gain": text(meta?["gain"] ?? meta?["gainType"] ?? item["gain"]),
                    "downloads": item["downloads"]?.numberValue.map(JSONValue.number) ?? .null, "likes": item["likes"]?.numberValue.map(JSONValue.number) ?? .null,
                    "description": .string(description), "onPedal": onPedal]
        }
        return ["query": .string(query), "page": .number(Double(page)),
                "pages": reply["numberOfPages"]?.numberValue.map(JSONValue.number) ?? .null,
                "total": reply["numberOfResults"]?.numberValue.map(JSONValue.number) ?? .null, "results": .array(results)]
    }
}
