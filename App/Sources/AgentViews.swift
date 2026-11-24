// AI assistants in the window and in Settings (mcp/PROTOCOL.md "What the user sees"): the confirmation an assistant's
// call waits on, the "Asked by …" line the editor's own sheets get when an assistant opened them, the status bar's
// "Assistant connected" indicator, and what Settings → Advanced shows under the AI assistants switch while it is on
// (the status line, Add to Claude Desktop…, Add to ChatGPT…, the line pointing at the manual). No other AI UI.

import SwiftUI
import AppKit
import NanoCore

/// "Asked by Claude Code." — the first line of every dialog an assistant opened.
struct AskedByLine: View {
    let name: String
    var body: some View {
        Text(AgentBridge.messages?.askedBy(client: name) ?? name).font(Theme.font(12, .semibold)).foregroundStyle(Theme.accentHi).accessibilityIdentifier("askedBy")
    }
}

/// A confirmation in the editor's style (`.modal`): Cancel / the action. Escape or closing it cancels.
struct AgentPromptSheet: View {
    @Environment(PedalStore.self) private var store
    let prompt: AgentPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AskedByLine(name: prompt.askedBy).padding(.bottom, 8)
            ModalTitle(prompt.title).padding(.bottom, 8)
            ForEach(Array(prompt.lines.enumerated()), id: \.offset) { _, line in ModalText(line).padding(.bottom, 6) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { store.answerAgentPrompt(false) }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction).accessibilityIdentifier("agentCancel")
                Button(prompt.confirm) { store.answerAgentPrompt(true) }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction).accessibilityIdentifier("agentConfirm")
            }.padding(.top, 12)
        }
        .modalPanel(width: 460)
        .accessibilityIdentifier("agentPrompt")
    }
}

/// The status bar's indicator while an assistant is connected: a label, not a button (no action, not focusable),
/// accent fill, the client names as its tooltip.
struct AssistantIndicator: View {
    let names: [String]
    var body: some View {
        Text(AgentBridge.messages?.pill ?? "").font(Theme.font(11, .semibold)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8).frame(height: 17)
            .background(Theme.accent, in: Capsule())
            .fixedSize()
            .focusable(false)
            .help(names.joined(separator: ", "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AgentBridge.messages?.pill ?? "")
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("assistantPill")
    }
}

// MARK: - Settings → Advanced, under the AI assistants switch (only while it is on)

struct AIAssistantsRows: View {
    let agent: AgentServer
    @State private var claudeOpen = false
    @State private var chatGPTOpen = false
    @State private var claudeMessage: String?
    @State private var chatGPTMessage: String?
    private let setup = MCPSetup(appBundle: Bundle.main.bundlePath)
    private var m: MCPContract.Messages? { AgentBridge.messages }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(agent.statusText).font(Theme.font(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ai-status")
            }
            HStack(spacing: 8) {
                Button(m?.addClaude ?? "") { claudeMessage = nil; claudeOpen = true }.buttonStyle(ThemedButton(small: true)).accessibilityIdentifier("ai-claude-desktop")
                Button(m?.addChatGPT ?? "") { chatGPTMessage = nil; chatGPTOpen = true }.buttonStyle(ThemedButton(small: true)).accessibilityIdentifier("ai-chatgpt")
            }
            if let msg = claudeMessage ?? chatGPTMessage {
                Text(msg).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ai-add-message")
            }
            Button { Links.open(Links.aiAssistantsManual) } label: { Text(m?.otherAssistants ?? "") }
                .buttonStyle(LinkStyle(size: 12)).help(Links.aiAssistantsManual.absoluteString).accessibilityIdentifier("ai-other")
        }
        .sheet(isPresented: $claudeOpen) { ClaudeDesktopSheet(setup: setup) { claudeMessage = $0; claudeOpen = false } }
        .sheet(isPresented: $chatGPTOpen) { ChatGPTSheet(setup: setup) { chatGPTMessage = $0; chatGPTOpen = false } }
    }

    private var statusColor: Color {
        switch agent.status {
        case .off: Theme.groove
        case .waiting: agent.clients.isEmpty ? Theme.warn : Theme.ok
        case .anotherEditor, .cannotListen: Theme.danger
        }
    }
}

/// "Add to Claude Desktop…": shows the entry and where it goes, then adds it (every other entry kept, the old file
/// backed up next to it). Never written without this click.
private struct ClaudeDesktopSheet: View {
    let setup: MCPSetup
    let done: (String?) -> Void
    @State private var error: String?
    var body: some View {
        let path = ClaudeDesktopConfig.path
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Add Nano Cortex Editor to Claude Desktop?").padding(.bottom, 8)
            ModalText("This entry goes into the \"mcpServers\" section of \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")):").padding(.bottom, 10)
            Text(verbatim: setup.claudeDesktopEntry).font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                .padding(.bottom, 10)
            ModalText("Every other entry in the file stays as it is, and the current file is kept next to it as a backup. Restart Claude Desktop afterwards.").padding(.bottom, 14)
            if let error { ModalText(error, color: Theme.danger).padding(.bottom, 12) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Add") {
                    switch ClaudeDesktopConfig.add(setup) { case .success(let m): done(m); case .failure(let e): error = e.message }
                }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction).accessibilityIdentifier("ai-claude-add")
            }
        }
        .modalPanel(width: 520)
    }
}

/// Claude Desktop's settings file. `-ai.claudeDesktopConfig <path>` (argument domain) points it elsewhere, for tests.
enum ClaudeDesktopConfig {
    static var overridden: Bool { UserDefaults.standard.string(forKey: "ai.claudeDesktopConfig")?.isEmpty == false }
    static var path: String { UserDefaults.standard.string(forKey: "ai.claudeDesktopConfig").flatMap { $0.isEmpty ? nil : $0 } ?? MCPSetup.claudeDesktopConfig() }

    /// Merges the entry in; a message for Settings, or why nothing was written.
    static func add(_ setup: MCPSetup) -> Result<String, MCPRefusal> {
        let fm = FileManager.default, file = path, dir = (file as NSString).deletingLastPathComponent
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return .failure(MCPRefusal("Claude Desktop doesn't seem to be installed (there is no \(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")) folder). Install and open it once, then try again."))
        }
        let existing = fm.contents(atPath: file)
        if setup.claudeDesktopHasEntry(existing) { return .success("Already added. Restart Claude Desktop if it doesn't list nano-cortex.") }
        let merged: Data
        do { merged = try setup.mergedClaudeDesktopConfig(existing) }
        catch { return .failure(MCPRefusal("The settings file isn't valid JSON, so nothing was changed. Fix or remove \(file), or add the entry by hand.")) }
        do {
            if existing != nil {
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
                let backup = (dir as NSString).appendingPathComponent("claude_desktop_config.backup-\(f.string(from: Date())).json")
                try fm.copyItem(atPath: file, toPath: backup)
            }
            try merged.write(to: URL(fileURLWithPath: file), options: .atomic)
        } catch { return .failure(MCPRefusal("Could not write \(file): \(error.localizedDescription)")) }
        return .success("Added. Restart Claude Desktop to use it.")
    }
}

/// "Add to ChatGPT…": the ChatGPT desktop app shares its MCP servers with Codex (~/.codex/config.toml). Shows the
/// table and where it goes, then appends it (the file otherwise kept as it is, the old one backed up next to it);
/// a nano-cortex server already there is left alone. Never written without this click.
private struct ChatGPTSheet: View {
    let setup: MCPSetup
    let done: (String?) -> Void
    @State private var error: String?
    var body: some View {
        let path = ChatGPTConfig.path
        VStack(alignment: .leading, spacing: 0) {
            ModalTitle("Add Nano Cortex Editor to ChatGPT?").padding(.bottom, 8)
            ModalText("This table goes at the end of \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")), the file the ChatGPT desktop app and Codex read their MCP servers from:").padding(.bottom, 10)
            Text(verbatim: setup.chatGPTTable).font(Theme.mono(11)).foregroundStyle(Theme.text).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                .padding(.bottom, 10)
            ModalText("The rest of the file stays as it is, and the current file is kept next to it as a backup.").padding(.bottom, 14)
            if let error { ModalText(error, color: Theme.danger).padding(.bottom, 12) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(ThemedButton()).keyboardShortcut(.cancelAction)
                Button("Add") {
                    switch ChatGPTConfig.add(setup) { case .success(let m): done(m); case .failure(let e): error = e.message }
                }.buttonStyle(ThemedButton(kind: .primary)).keyboardShortcut(.defaultAction).accessibilityIdentifier("ai-chatgpt-add")
            }
        }
        .modalPanel(width: 520)
    }
}

/// ~/.codex/config.toml. `-ai.codexConfig <path>` (argument domain) points it elsewhere, for tests.
enum ChatGPTConfig {
    static var overridden: Bool { UserDefaults.standard.string(forKey: "ai.codexConfig")?.isEmpty == false }
    static var path: String { UserDefaults.standard.string(forKey: "ai.codexConfig").flatMap { $0.isEmpty ? nil : $0 } ?? MCPSetup.codexConfig() }

    /// Appends the table (MCPSetup.addToCodexConfig); a message for Settings, or why nothing was written.
    static func add(_ setup: MCPSetup) -> Result<String, MCPRefusal> {
        do {
            switch try setup.addToCodexConfig(path: path) {
            case .alreadyThere: return .success("Already added (the file has a nano-cortex server). Restart the ChatGPT app if it doesn't list it.")
            case .added: return .success("Added. Restart the ChatGPT app, then use a Work chat or Codex: its plain Chat tab doesn't offer local tools yet.")
            }
        } catch { return .failure(MCPRefusal("Could not write \(path): \(error.localizedDescription)")) }
    }
}
