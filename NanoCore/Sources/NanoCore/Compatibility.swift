// Firmware compatibility: the effect models and their parameters (Models.swift) are hardcoded from firmware 2.2.1.
// A newer firmware can add effects we don't know; the app then shows a one-time notice (per firmware version) and
// treats unknown model ids as read-only blocks. After a firmware update, see CLAUDE.md for the Models.swift checklist.

import Foundation

public enum Compatibility {
    /// The firmware the effect list and the protocol were verified against. Bump it after updating Models.swift.
    public static let testedFirmware = "2.2.1"

    /// The numeric part of a version string: "2.2.1+06d34443" → "2.2.1", "v2.3" → "2.3". nil when it is not a dotted
    /// list of numbers ("", "abc", "2..1").
    public static func core(_ version: String) -> String? {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let cut = s.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == " " }) { s = String(s[..<cut]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && Int($0) != nil }) else { return nil }
        return s
    }

    /// Numeric comparison per component (2.10.0 > 2.9.9; "3.0" == "3.0.0"); build suffixes are ignored.
    /// nil when either side is not a version.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult? {
        guard let ca = core(a), let cb = core(b) else { return nil }
        let x = ca.split(separator: ".").map { Int($0)! }, y = cb.split(separator: ".").map { Int($0)! }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// True only for a readable version newer than `testedFirmware`; older, equal, missing or garbage → false.
    public static func isNewerThanTested(_ firmware: String?) -> Bool {
        guard let firmware else { return false }
        return compare(firmware, testedFirmware) == .orderedDescending
    }

    /// Whether the "newer firmware" notice should show: newer than tested and not already shown for this version
    /// (`lastWarned` holds the core version last warned about, e.g. "2.3.0").
    public static func shouldWarn(firmware: String?, lastWarned: String?) -> Bool {
        guard isNewerThanTested(firmware), let c = firmware.flatMap(core) else { return false }
        guard let lastWarned else { return true }
        return compare(c, lastWarned) != .orderedSame
    }

    public static let newerFirmwareNotice = "This firmware is newer than the editor has been tested with. Some new effects may not be editable until this app is updated."
    public static let unknownEffectTitle = "Unknown effect"
    public static let unknownEffectSubtitle = "Newer firmware?"
    public static let unknownEffectNote = "This effect isn't in the editor's list yet, so its settings can't be edited here. It still plays as saved on the pedal. Update the editor to edit it."
}
