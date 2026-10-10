// Capture kind icons: the pedal's library record carries a device type (field 6, e.g. "amp_head") and an
// instrument (field 10, e.g. "guitar"). The picker shows them as small line icons instead of the raw words.
// The SVGs are the same strings as the Electron app's KIND_ICONS (pro/ui.js) so both editors look alike;
// they are our own drawings, not Neural DSP's.

import SwiftUI
import AppKit

enum CaptureKind {
    struct Icon: Hashable { let key: String; let label: String }

    private static let prefix = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none" stroke="#FFFFFF" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">"##
    private static let bodies: [String: String] = [
        "ampHead": #"<rect x="1.5" y="5.5" width="13" height="7" rx="1"/><path d="M6 5.5V3.5h4v2M4.5 8h0M8 8h0M11.5 8h0"/></svg>"#,
        "combo": #"<rect x="1.5" y="1.5" width="13" height="13" rx="1"/><path d="M1.5 5.5h13M4.5 3.5h0M7 3.5h0"/><circle cx="8" cy="10" r="2.5"/></svg>"#,
        "pedal": #"<rect x="4" y="1.5" width="8" height="13" rx="1.5"/><path d="M8 4.5h0"/><circle cx="8" cy="10.5" r="1.75"/></svg>"#,
        "rack": #"<rect x="1.5" y="5.5" width="13" height="5" rx=".5"/><path d="M3.5 5.5v5M12.5 5.5v5M6.5 8h0M9.5 8h0"/></svg>"#,
        "powerAmp": #"<rect x="1.5" y="3.5" width="13" height="9" rx="1"/><circle cx="10.5" cy="8" r="2"/><path d="M5.5 5.5 4 8h2.5L5 10.5"/></svg>"#,
        "fullRig": #"<rect x="3.5" y="1.5" width="9" height="4" rx=".5"/><path d="M6 3.5h0M8 3.5h0M10 3.5h0"/><rect x="2.5" y="7.5" width="11" height="7" rx=".5"/><circle cx="8" cy="11" r="2"/></svg>"#,
        "cab": #"<rect x="2.5" y="2.5" width="11" height="11" rx="1"/><circle cx="8" cy="8" r="3"/></svg>"#,
        "guitar": #"<path d="M9.5 6.5 14 2"/><path d="M8.2 5.3c-.9-.4-2 0-2.4 1-.2.5-.8.6-1.4.6-1.6 0-2.9 1.3-2.9 2.9 0 2.4 1.9 4.1 4.1 4.1 1.6 0 2.9-1.3 2.9-2.9 0-.6.1-1.2.6-1.4 1-.4 1.4-1.5 1-2.4z"/><path d="M5 11h0"/></svg>"#,
        "bass": #"<path d="M9.5 6.5 14.5 1.5"/><path d="M8.2 5.3c-.9-.4-2 0-2.4 1-.2.5-.8.6-1.4.6-1.6 0-2.9 1.3-2.9 2.9 0 2.4 1.9 4.1 4.1 4.1 1.6 0 2.9-1.3 2.9-2.9 0-.6.1-1.2.6-1.4 1-.4 1.4-1.5 1-2.4z"/><path d="M5 11h0M12 2.5l1.5 1.5"/></svg>"#,
    ]
    /// Type words → icon. `default` means "no icon" on purpose.
    private static let types: [String: Icon] = [
        "amp_head": Icon(key: "ampHead", label: "Amp head"), "amp": Icon(key: "ampHead", label: "Amp head"),
        "combo": Icon(key: "combo", label: "Combo"), "pedal": Icon(key: "pedal", label: "Pedal"),
        "preamp": Icon(key: "rack", label: "Preamp"), "rack": Icon(key: "rack", label: "Rack"),
        "power_amp": Icon(key: "powerAmp", label: "Power amp"),
        "full_rig": Icon(key: "fullRig", label: "Full rig"), "rig": Icon(key: "fullRig", label: "Full rig"),
        "cab": Icon(key: "cab", label: "Cab"),
    ]
    private static let instruments: [String: Icon] = [
        "guitar": Icon(key: "guitar", label: "Guitar"), "bass": Icon(key: "bass", label: "Bass"),
    ]
    private static let knownBlank: Set<String> = ["", "default", "instrument_not_set"]
    nonisolated(unsafe) private static var reported: Set<String> = []

    /// The icons for a capture, in order: type, then instrument. Unknown words get none and are logged once.
    static func icons(type: String, instrument: String) -> [Icon] {
        var out: [Icon] = []
        for (word, table) in [(type, types), (instrument, instruments)] {
            if let i = table[word] { out.append(i) }
            else if !knownBlank.contains(word), !reported.contains(word) { reported.insert(word); NSLog("[library] unknown capture kind: %@", word) }
        }
        return out
    }

    nonisolated(unsafe) private static var cache: [String: NSImage] = [:]
    static func image(_ key: String) -> NSImage? {
        if let img = cache[key] { return img }
        guard let body = bodies[key], let img = NSImage(data: Data((prefix + body).utf8)) else { return nil }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}

/// `.pop .sub .kind`: a 14-point icon in the subtitle colour, with the label as its tooltip.
struct KindIcon: View {
    let icon: CaptureKind.Icon
    var body: some View {
        Group {
            if let img = CaptureKind.image(icon.key) { Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high) }
        }
        .frame(width: 14, height: 14)
        .help(icon.label)
        .accessibilityLabel(icon.label)
    }
}
