// The editor-side rules of mcp/PROTOCOL.md §4 that are not about loudness or the tone plan: which tools need a pedal,
// slot numbers against what the pedal has, `use_*_slot` with slot plus on:false, save without unsaved edits, the
// tempo range per firmware, and the preset name a Save as / Rename dialog will accept. Pure; AgentBridge runs them and
// the refusals use the contract's `messages` word for word.

import Foundation

public enum MCPRules {
    /// Every tool except get_status, cloud_search and cloud_open needs a connected pedal (errors.notConnected).
    public static func needsPedal(_ tool: String) -> Bool { !["get_status", "cloud_search", "cloud_open"].contains(tool) }

    /// A slot number above what the pedal has (`count`, as list_library reports the slots): `messages.captureSlotRange`
    /// / `cabSlotRange` with `field` filled in. nil when it is in range.
    public static func slotRange(_ n: Int, field: String, count: Int, cab: Bool, messages: MCPContract.Messages) -> MCPRefusal? {
        n >= 1 && n <= count ? nil : MCPRefusal(messages.slotRange(field: field, count: count, cab: cab))
    }

    /// `use_capture_slot` / `use_cab_slot`: slot and on:false together are `messages.slotOrOff`; neither is refused too.
    public static func useSlot(slot: Int?, on: Bool?, messages: MCPContract.Messages) -> MCPRefusal? {
        if slot != nil, on == false { return MCPRefusal(messages.slotOrOff) }
        if slot == nil, on == nil { return MCPRefusal("Give slot, on, or both.") }
        return nil
    }

    /// `save` with no unsaved edits: `messages.nothingToSave` (`number` is 1-based).
    public static func save(unsaved: Bool, number: Int, messages: MCPContract.Messages) -> MCPRefusal? {
        unsaved ? nil : MCPRefusal(messages.nothingToSave(number: number))
    }

    /// set_tempo: the pedal's range, `messages.tempoRange` outside it. NanOS 2.3+ takes 40–240 BPM and keeps one decimal;
    /// older firmware 30–300 whole BPM. The value to write on success.
    public static func tempo(_ bpm: Double, nanos23: Bool, messages: MCPContract.Messages) -> Result<Double, MCPRefusal> {
        let range = nanos23 ? Tempo23.range : Tempo.range
        guard bpm.isFinite, range.contains(bpm) else { return .failure(MCPRefusal(messages.tempoRange(range))) }
        return .success(nanos23 ? (bpm * 10).rounded() / 10 : bpm.rounded())
    }

    /// The name a Save as or Rename dialog accepts (PedalStore.saveAs / rename): at least 4 characters and at most 64
    /// UTF-8 bytes once the spaces at the ends are gone. Checked before the dialog opens, so it never opens with a name
    /// its own button would refuse.
    public static func presetName(_ name: String) -> MCPRefusal? {
        let t = name.trimmingCharacters(in: .whitespaces)
        if t.count < 4 { return MCPRefusal("name must have at least 4 characters (not counting spaces at the ends).") }
        if t.utf8.count > 64 { return MCPRefusal("name is too long for the pedal: at most 64 bytes (accented letters and symbols count as two or more).") }
        return nil
    }
}
