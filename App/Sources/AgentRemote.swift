// Dev remote endpoints for AI assistants (debug builds only; DevRemote.swift hands them `/agent`):
//   /agent?tool=<name>&args=<url-encoded JSON>   calls the bridge exactly as the socket would (client "dev-remote",
//                                                 the same one-at-a-time queue); async=1 returns at once
//   /agent?status=1                               the server: on/off, status line, socket, clients, the open dialog
//   /agent?dialog=confirm|cancel                  answers the dialog an assistant's call is waiting on, as its
//                                                 buttons would (Save as / Rename with the names the assistant gave)
//   /agent?claudeadd=1                            "Add to Claude Desktop" without the dialog, only when
//                                                 `-ai.claudeDesktopConfig <path>` points it at a test file
#if DEBUG
import Foundation
import NanoCore

@MainActor
enum AgentRemote {
    static func handle(_ q: (String) -> String?, agent: AgentServer?, store: PedalStore) async -> String {
        guard let agent else { return (["ok": false, "error": "no agent server"] as JSONValue).compact }
        if let tool = q("tool") {
            let args: JSONValue
            if let text = q("args"), !text.isEmpty {
                guard let v = try? JSONValue.parse(text) else { return (["ok": false, "error": "args is not JSON"] as JSONValue).compact }
                args = v
            } else { args = .object([:]) }
            if q("async") == "1" {
                Task { _ = await agent.run(tool, args: args, client: "dev-remote") }
                try? await Task.sleep(for: .milliseconds(150))
                return (["started": true, "dialog": dialog(store)] as JSONValue).compact
            }
            switch await agent.run(tool, args: args, client: "dev-remote") {
            case .success(let r): return (["ok": true, "result": r] as JSONValue).compact
            case .failure(let e): return (["ok": false, "error": .string(e.message)] as JSONValue).compact
            }
        }
        if let d = q("dialog") { return JSONValue.object(await answer(d == "confirm", store: store)).compact }
        if q("claudeadd") == "1" {
            guard ClaudeDesktopConfig.overridden else { return (["ok": false, "error": "launch with -ai.claudeDesktopConfig <test path> first"] as JSONValue).compact }
            switch ClaudeDesktopConfig.add(MCPSetup(appBundle: Bundle.main.bundlePath)) {
            case .success(let m): return (["ok": true, "message": .string(m), "path": .string(ClaudeDesktopConfig.path)] as JSONValue).compact
            case .failure(let e): return (["ok": false, "error": .string(e.message)] as JSONValue).compact
            }
        }
        let setup = MCPSetup(appBundle: Bundle.main.bundlePath)
        let status: String
        switch agent.status { case .off: status = "off"; case .waiting: status = "waiting"; case .anotherEditor: status = "anotherEditor"; case .cannotListen: status = "cannotListen" }
        return ([
            "enabled": .bool(agent.enabled), "status": .string(status), "statusText": .string(agent.statusText), "socket": .string(agent.endpoint.socket),
            "socketExists": .bool(FileManager.default.fileExists(atPath: agent.endpoint.socket)), "tokenExists": .bool(FileManager.default.fileExists(atPath: agent.endpoint.token)),
            "clients": .array(agent.clientNames.map(JSONValue.string)), "callsWaiting": .number(Double(agent.callsWaiting)), "contract": .bool(agent.bridge.contract != nil),
            "helper": .string(setup.helper), "helperExists": .bool(FileManager.default.isExecutableFile(atPath: setup.helper)),
            "setup": ["claudeCode": .string(setup.claudeCode), "codex": .string(setup.codex), "json": .string(setup.json), "cursor": .string(setup.cursorLink.absoluteString), "vscode": .string(setup.vscodeLink.absoluteString)],
            "dialog": dialog(store), "notice": store.notice.map(JSONValue.string) ?? .null,
        ] as JSONValue).compact
    }

    /// The dialog an assistant's call waits on (null when none).
    static func dialog(_ store: PedalStore) -> JSONValue {
        guard let w = store.agentWait else { return .null }
        switch w.kind {
        case .prompt:
            guard let p = store.agentPrompt else { return ["kind": "prompt"] }
            return ["kind": "prompt", "tool": .string(p.tool), "askedBy": .string(p.askedBy), "title": .string(p.title), "lines": .array(p.lines.map(JSONValue.string)), "confirm": .string(p.confirm)]
        case .saveAs: return ["kind": "saveAs", "askedBy": store.agentAskedBy.map(JSONValue.string) ?? .null, "number": store.agentSaveAs.map { .number(Double($0.index + 1)) } ?? .null, "name": store.agentSaveAs.map { .string($0.name) } ?? .null]
        case .rename: return ["kind": "rename", "askedBy": store.agentAskedBy.map(JSONValue.string) ?? .null, "name": store.renamePrefill.map(JSONValue.string) ?? .null]
        case .send: return ["kind": "send", "askedBy": store.agentAskedBy.map(JSONValue.string) ?? .null, "name": store.pendingSend.map { .string($0.record.name) } ?? .null]
        }
    }

    /// As the dialog's buttons would.
    static func answer(_ confirm: Bool, store: PedalStore) async -> [String: JSONValue] {
        guard let w = store.agentWait else { return ["answered": false, "error": "no assistant dialog is open"] }
        let before = dialog(store)
        switch w.kind {
        case .prompt: store.answerAgentPrompt(confirm)
        case .saveAs:
            if confirm, let s = store.agentSaveAs {
                if let e = await store.saveAs(index: s.index, name: s.name) { return ["answered": false, "error": .string(e), "dialog": before] }
                store.saveAsOpen = false
            } else { store.saveAsOpen = false; store.agentSheetClosed(.saveAs) }
        case .rename:
            if confirm {
                if let e = await store.rename(store.renamePrefill ?? "") { return ["answered": false, "error": .string(e), "dialog": before] }
                store.renameOpen = false
            } else { store.renameOpen = false; store.agentSheetClosed(.rename) }
        case .send:
            if confirm { store.sendPending() } else { store.pendingSend = nil; store.agentSheetClosed(.send) }
        }
        return ["answered": true, "confirmed": .bool(confirm), "dialog": before]
    }
}
#endif
