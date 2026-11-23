// AI assistants in the window and in Settings (mcp/PROTOCOL.md "What the user sees"): the confirmation an assistant's
// call waits on, the "Asked by …" line the editor's own sheets get when an assistant opened them, the status bar's
// Assistant pill, and Settings → AI assistants (the switch, its status line, the Set up rows).

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

/// The status bar's pill while an assistant is connected: accent fill, the client names as its tooltip.
struct AssistantPill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.font(11, .semibold)).foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8).frame(height: 17)
            .background(Theme.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

// MARK: - Settings → AI assistants

struct AssistantsSection: View {
    @Environment(AgentServer.self) private var server: AgentServer?
    var body: some View {
        if let server { AssistantsSettings(agent: server) } else { Text("AI assistants are not available here.").foregroundStyle(Theme.dim) }
    }
}

private struct AssistantsSettings: View {
    let agent: AgentServer
    @State private var copied: String?
    @State private var claudeOpen = false
    @State private var claudeMessage: String?
    private let setup = MCPSetup(appBundle: Bundle.main.bundlePath)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    // tools.json → messages, word for word (both editions show the same texts).
                    Text(AgentBridge.messages?.settingsSwitch ?? "").font(Theme.font(13)).accessibilityIdentifier("ai-switch-label")
                    Text(AgentBridge.messages?.settingsExplain ?? "").accessibilityIdentifier("ai-explain")
                        .font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Switch(on: agent.enabled, color: Theme.accent) { agent.setEnabled(!agent.enabled) }.accessibilityIdentifier("settings-ai-enabled")
            }
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(agent.statusText).font(Theme.font(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("ai-status")
            }
            Divider().overlay(Theme.line)
            SectionLabel(text: "Set up")
            copyRow("Claude Code", setup.claudeCode, learn: Links.claudeCodeMCP, id: "claude-code")
            copyRow("Codex and the ChatGPT desktop app", setup.codex, learn: Links.codexMCP, id: "codex")
            actionRow("Claude Desktop", detail: claudeMessage ?? "Adds the entry to Claude Desktop's settings file, after showing it.", button: "Add to Claude Desktop…", learn: Links.claudeDesktopMCP, id: "claude-desktop") { claudeMessage = nil; claudeOpen = true }
            actionRow("Cursor", detail: nil, button: "Install in Cursor", learn: Links.cursorMCP, id: "cursor") { Links.open(setup.cursorLink) }
            actionRow("VS Code", detail: nil, button: "Install in VS Code", learn: Links.vscodeMCP, id: "vscode") { Links.open(setup.vscodeLink) }
            copyRow("Other assistants", setup.json, learn: nil, id: "json")
        }
        .sheet(isPresented: $claudeOpen) { ClaudeDesktopSheet(setup: setup) { claudeMessage = $0; claudeOpen = false } }
    }

    private var statusColor: Color {
        switch agent.status {
        case .off: Theme.groove
        case .waiting: agent.clients.isEmpty ? Theme.warn : Theme.ok
        case .anotherEditor, .cannotListen: Theme.danger
        }
    }

    private func learnMore(_ url: URL, id: String) -> some View {
        Button { Links.open(url) } label: {
            HStack(spacing: 4) { Text("Learn more"); Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold)) }
        }
        .buttonStyle(LinkStyle(size: 12)).help(url.absoluteString).accessibilityIdentifier("ai-learn-\(id)")
    }

    private func copyRow(_ title: String, _ text: String, learn: URL?, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.font(13))
                Spacer()
                if let learn { learnMore(learn, id: id) }
            }
            HStack(spacing: 8) {
                Text(verbatim: text).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                    .background(Theme.ws, in: RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
                    .help(text).accessibilityIdentifier("ai-setup-\(id)")
                Button(copied == id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                    copied = id
                    Task { try? await Task.sleep(for: .seconds(1.5)); if copied == id { copied = nil } }
                }.buttonStyle(ThemedButton(small: true)).frame(width: 64, alignment: .trailing).accessibilityIdentifier("ai-copy-\(id)")
            }
        }
    }

    private func actionRow(_ title: String, detail: String?, button: String, learn: URL, id: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13))
                if let detail { Text(detail).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            learnMore(learn, id: id)
            Button(button, action: action).buttonStyle(ThemedButton(small: true)).accessibilityIdentifier("ai-\(id)")
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
