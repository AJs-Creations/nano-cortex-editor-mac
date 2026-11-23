// The AI features master switch (mcp/PROTOCOL.md §4 "The master switch"): Settings → Advanced → AI features, off by
// default, UserDefaults `ai.features` (`-ai.features YES` turns it on for one launch without writing it: argument
// domain). While it is off the editor shows nothing about AI (no Settings section, no Assistant pill, no toast) and the
// socket server does not listen, whatever "Allow AI assistants to control the editor" says. Pure rules, unit-tested
// (AIFeaturesTests); AppSettings and AgentServer apply them.
import Foundation

enum AIFeatures {
    static let key = "ai.features"
    /// Off unless the user (or a launch argument) turned it on.
    static func isOn(in d: UserDefaults) -> Bool { d.bool(forKey: key) }
    /// The socket listens only with both switches on.
    static func listens(features: Bool, allowed: Bool) -> Bool { features && allowed }
    /// The Settings sections to show: without AI features, every one but the AI assistants section.
    static func visible<S: Equatable>(_ all: [S], ai: S, features: Bool) -> [S] { features ? all : all.filter { $0 != ai } }
    /// The section to stay on: the current one while it is still shown, else the first one.
    static func section<S: Equatable>(_ current: S, in visible: [S]) -> S { visible.contains(current) || visible.isEmpty ? current : visible[0] }
}
