// The shared MCP contract (mcp/tools.json, a verbatim copy of the Electron edition's; mcp/PROTOCOL.md): the tools with
// their kinds and input schemas, the error texts, the loudness limits, the client display names and the shared texts
// (Settings, the dialogs' "Asked by", the refusals). No copy of any of them lives in code. Loaded at run time from the copy the app
// bundles (Contents/Resources/mcp/tools.json, the file the helper serves), so the editor and its helper can never
// disagree; NanoCore's tests load the repo's copy.

import Foundation

public struct MCPContract: Sendable {
    public enum Kind: String, Sendable { case read, live, confirm, cloud }

    public struct Tool: Sendable {
        public let name: String
        public let kind: Kind
        public let title: String
        public let destructive: Bool
        /// The input schema with every `$ref` inlined (as the helper serves it).
        public let schema: JSONValue
    }

    public struct Errors: Sendable {
        public let editorNotRunning, notConnected, busy, cancelled, unsavedEdits: String
    }

    public struct Safety: Sendable {
        public let ampLevelStep, captureVolumeDbStep, captureVolumeDbMax, cabLevelDbStep, cabLevelDbMax, effectLevelStepShare: Double
        public let effectLevelParams: String
        public let stepRefusal, maxRefusal: String
        public init(ampLevelStep: Double, captureVolumeDbStep: Double, captureVolumeDbMax: Double, cabLevelDbStep: Double, cabLevelDbMax: Double,
                    effectLevelStepShare: Double, effectLevelParams: String, stepRefusal: String, maxRefusal: String) {
            self.ampLevelStep = ampLevelStep; self.captureVolumeDbStep = captureVolumeDbStep; self.captureVolumeDbMax = captureVolumeDbMax
            self.cabLevelDbStep = cabLevelDbStep; self.cabLevelDbMax = cabLevelDbMax; self.effectLevelStepShare = effectLevelStepShare
            self.effectLevelParams = effectLevelParams; self.stepRefusal = stepRefusal; self.maxRefusal = maxRefusal
        }
        /// Whether an effect parameter counts as a loudness control (`effectLevelParams`, case-insensitive).
        public func isLevelParam(_ name: String) -> Bool {
            name.range(of: effectLevelParams, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// `clients`: what people call the assistant apps (MCP `clientInfo.name` → the name Settings and the dialogs show).
    public struct Clients: Sendable {
        public let fallback: String
        /// Lower-cased `clientInfo.name` → display name.
        public let names: [String: String]
        public init(fallback: String, names: [String: String]) {
            self.fallback = fallback
            self.names = Dictionary(names.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// `messages`: the texts both editors use word for word (`{x}` filled in by the helpers below).
    public struct Messages: Sendable {
        public let askedBy, anotherEditor, contractMismatch, nothingToSave, captureSlotRange, cabSlotRange, slotOrOff, tempoRange,
                   connected, settingsSwitch, settingsExplain, statusOff, statusWaiting, statusConnected, pill,
                   aiFeaturesSwitch, aiFeaturesExplain: String
        /// The keys of tools.json → messages this struct carries (a test keeps them equal to the file's).
        public static let keys = ["askedBy", "anotherEditor", "contractMismatch", "nothingToSave", "captureSlotRange", "cabSlotRange", "slotOrOff",
                                  "tempoRange", "connected", "settingsSwitch", "settingsExplain", "statusOff", "statusWaiting", "statusConnected", "pill",
                                  "aiFeaturesSwitch", "aiFeaturesExplain"]
        init(_ m: [String: String]) {
            askedBy = m["askedBy"]!; anotherEditor = m["anotherEditor"]!; contractMismatch = m["contractMismatch"]!; nothingToSave = m["nothingToSave"]!
            captureSlotRange = m["captureSlotRange"]!; cabSlotRange = m["cabSlotRange"]!; slotOrOff = m["slotOrOff"]!; tempoRange = m["tempoRange"]!
            connected = m["connected"]!; settingsSwitch = m["settingsSwitch"]!; settingsExplain = m["settingsExplain"]!; statusOff = m["statusOff"]!
            statusWaiting = m["statusWaiting"]!; statusConnected = m["statusConnected"]!; pill = m["pill"]!
            aiFeaturesSwitch = m["aiFeaturesSwitch"]!; aiFeaturesExplain = m["aiFeaturesExplain"]!
        }
        /// "Asked by Claude Code." (the first line of every dialog an assistant opened).
        public func askedBy(client: String) -> String { MCPContract.fill(askedBy, ["client": client]) }
        /// "Claude Code connected" (the toast when a connection opens).
        public func connected(client: String) -> String { MCPContract.fill(connected, ["client": client]) }
        /// "Connected: Claude Code, Codex" (Settings' status line).
        public func statusConnected(clients: [String]) -> String { MCPContract.fill(statusConnected, ["clients": clients.joined(separator: ", ")]) }
        public func nothingToSave(number: Int) -> String { MCPContract.fill(nothingToSave, ["number": String(number)]) }
        /// `field` ("slot", "capture_slot") must be between 1 and `count`.
        public func slotRange(field: String, count: Int, cab: Bool) -> String {
            MCPContract.fill(cab ? cabSlotRange : captureSlotRange, ["field": field, "count": String(count)])
        }
        public func tempoRange(_ range: ClosedRange<Double>) -> String {
            MCPContract.fill(tempoRange, ["min": MCPValidator.format(range.lowerBound), "max": MCPValidator.format(range.upperBound)])
        }
    }

    public enum LoadError: Error, Equatable { case notJSON, missing(String) }

    public let contractVersion: Int
    public let serverName: String
    public let errors: Errors
    public let safety: Safety
    public let clients: Clients
    public let messages: Messages
    public let tools: [Tool]

    public init(data: Data) throws {
        guard let root = try? JSONValue.parse(data), root.objectValue != nil else { throw LoadError.notJSON }
        func str(_ v: JSONValue?, _ what: String) throws -> String { guard let s = v?.stringValue else { throw LoadError.missing(what) }; return s }
        func num(_ v: JSONValue?, _ what: String) throws -> Double { guard let n = v?.numberValue else { throw LoadError.missing(what) }; return n }
        guard let version = root["contractVersion"]?.intValue else { throw LoadError.missing("contractVersion") }
        contractVersion = version
        serverName = try str(root["server"]?["name"], "server.name")
        let e = root["errors"]
        errors = Errors(editorNotRunning: try str(e?["editorNotRunning"], "errors.editorNotRunning"), notConnected: try str(e?["notConnected"], "errors.notConnected"),
                        busy: try str(e?["busy"], "errors.busy"), cancelled: try str(e?["cancelled"], "errors.cancelled"),
                        unsavedEdits: try str(e?["unsavedEdits"], "errors.unsavedEdits"))
        let s = root["safety"]
        safety = Safety(ampLevelStep: try num(s?["ampLevelStep"], "safety.ampLevelStep"), captureVolumeDbStep: try num(s?["captureVolumeDbStep"], "safety.captureVolumeDbStep"),
                        captureVolumeDbMax: try num(s?["captureVolumeDbMax"], "safety.captureVolumeDbMax"), cabLevelDbStep: try num(s?["cabLevelDbStep"], "safety.cabLevelDbStep"),
                        cabLevelDbMax: try num(s?["cabLevelDbMax"], "safety.cabLevelDbMax"), effectLevelStepShare: try num(s?["effectLevelStepShare"], "safety.effectLevelStepShare"),
                        effectLevelParams: try str(s?["effectLevelParams"], "safety.effectLevelParams"),
                        stepRefusal: try str(s?["stepRefusal"], "safety.stepRefusal"), maxRefusal: try str(s?["maxRefusal"], "safety.maxRefusal"))
        let c = root["clients"]
        guard let names = c?["names"]?.objectValue else { throw LoadError.missing("clients.names") }
        clients = Clients(fallback: try str(c?["fallback"], "clients.fallback"),
                          names: try names.mapValues { v in guard let s = v.stringValue else { throw LoadError.missing("clients.names") }; return s })
        var texts: [String: String] = [:]
        for key in Messages.keys { texts[key] = try str(root["messages"]?[key], "messages.\(key)") }
        messages = Messages(texts)
        let defs = root["$defs"]?.objectValue ?? [:]
        func inline(_ node: JSONValue) throws -> JSONValue {
            switch node {
            case .array(let a): return .array(try a.map(inline))
            case .object(let o):
                var out: [String: JSONValue] = [:]
                if let ref = o["$ref"]?.stringValue {
                    let name = ref.hasPrefix("#/$defs/") ? String(ref.dropFirst(8)) : ""
                    guard let def = defs[name] else { throw LoadError.missing(ref) }
                    out = try inline(def).objectValue ?? [:]
                }
                for (k, v) in o where k != "$ref" { out[k] = try inline(v) }
                return .object(out)
            default: return node
            }
        }
        guard let list = root["tools"]?.arrayValue else { throw LoadError.missing("tools") }
        tools = try list.map { t in
            let name = try str(t["name"], "tool name")
            guard let kind = t["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { throw LoadError.missing("\(name).kind") }
            return Tool(name: name, kind: kind, title: try str(t["title"], "\(name).title"), destructive: t["destructive"]?.boolValue ?? false,
                        schema: try inline(t["inputSchema"] ?? .object([:])))
        }
    }

    public func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    /// Fills `{what}`, `{step}`, `{max}` into a refusal template.
    public static func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
