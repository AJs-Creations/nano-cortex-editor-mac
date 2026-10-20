// Monitoring: the pedal's global Mute Input and Mute Outputs 1L/2R (type 67 field 12 / 13 with an explicit 0 or 1,
// acked by 68, read back as 66 field 15 / 16; PROTOCOL-NOTES §13). Settings → Device → Monitoring has both switches;
// the header's Mute button is Mute Input. Global settings: the pedal reports nothing dirty and there is nothing to save.
// Ported from the Electron edition (pro/ui.js "device page", contributed in its #14).

import SwiftUI
import Observation
import NanoCore

@MainActor @Observable
final class MonitoringState {
    /// What the switches show (nil until the pedal's settings were read). A switch flips at once and goes back if the
    /// pedal refuses it.
    var input: Bool?
    var outputs: Bool?
    /// Written, not confirmed by a read-back yet.
    var pending: Set<Monitor> = []
    var error: String?
    /// One writer at a time for every type-67 write (brightness/USB too): the 68 ack doesn't say which write it answers.
    @ObservationIgnored let gate = SettingsWriteGate()
    @ObservationIgnored var queue: [(Monitor, Bool)] = []
    @ObservationIgnored var confirmed: [Monitor: Bool] = [:]
    @ObservationIgnored var writing = false
    /// Bumped by every Mute Input change, so the tuner's re-arm stands down after a click.
    @ObservationIgnored var inputRevision = 0
    @ObservationIgnored var tunerSnapshot: (muted: Bool, revision: Int)?
    @ObservationIgnored var rearm: Task<Void, Never>?
    /// The last values written, in order (dev remote).
    @ObservationIgnored var written: [String] = []

    func value(_ m: Monitor) -> Bool? { m == .input ? input : outputs }
    func set(_ m: Monitor, _ v: Bool?) { if m == .input { input = v } else { outputs = v } }
    var ready: Bool { input != nil && outputs != nil }
    func reset() {
        input = nil; outputs = nil; pending = []; error = nil
        queue = []; confirmed = [:]; tunerSnapshot = nil; rearm?.cancel(); rearm = nil; written = []
    }
}

/// Serialises async work: a second caller waits until the first is done.
@MainActor final class SettingsWriteGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy { await withCheckedContinuation { waiting.append($0) } }
        busy = true
        defer { busy = false; if !waiting.isEmpty { waiting.removeFirst().resume() } }
        return try await body()
    }
}

extension PedalStore {
    /// Reads the global settings so the header's Mute button is usable at once (Electron reads them at connect too).
    func readMonitoring() async {
        guard let session else { return }
        do {
            let s = try await session.readDeviceSettings()
            // The first read also gives the brightness and USB volume their real values (writes carry both, DECISIONS #16);
            // later reads leave the sliders alone (one may be moving).
            if deviceSettings == nil { if let b = s.ledBrightness { ledBrightness = b }; if let v = s.usbVolumeDb { usbVolumeDb = Double(v) } }
            deviceSettings = s
            applyMonitoringReport(s)
        } catch { append("Settings request failed: \(error)") }
    }

    /// A settings read (asked for, or sent by the pedal itself). A switch written here and not yet seen in a read keeps
    /// its new value until it is; anything else takes what the pedal says.
    func applyMonitoringReport(_ s: DeviceSettings) {
        for m in Monitor.allCases {
            let reported = s.muted(m)
            monitor.confirmed[m] = reported
            if monitor.pending.contains(m), monitor.value(m) != reported { continue }
            monitor.pending.remove(m)
            monitor.set(m, reported)
        }
        append("Device settings: input mute \(s.muteInput ? "on" : "off"), output mute \(s.muteOutputs ? "on" : "off")")
    }

    /// The Settings switches and the header button: flips at once, writes 67, reads 66 back after the 68.
    func setMute(_ which: Monitor, _ on: Bool) {
        guard connected, session != nil, let current = monitor.value(which) else { return }
        if which == .input { monitor.inputRevision += 1 }
        if current == on, !monitor.pending.contains(which) { return }
        monitor.set(which, on)
        monitor.pending.insert(which)
        monitor.error = nil
        if let i = monitor.queue.firstIndex(where: { $0.0 == which }) { monitor.queue[i].1 = on } else { monitor.queue.append((which, on)) }
        pumpMonitoring()
    }

    private func pumpMonitoring() {
        guard !monitor.writing else { return }
        monitor.writing = true
        Task {
            defer { monitor.writing = false }
            while !monitor.queue.isEmpty, let session, connected {
                let (which, on) = monitor.queue.removeFirst()
                monitor.written.append("\(which.rawValue)=\(on ? 1 : 0)")
                var ok = false
                do {
                    ok = try await monitor.gate.run { try await session.writeMonitoring(which, on: on) }
                    append(ok ? "Device settings confirmed" : "Device settings REFUSED: \(which.label) \(on ? "on" : "off")")
                } catch { append("Device monitoring write failed: \(error)") }
                if !ok {
                    // Back to what the pedal last said, unless a newer change of this switch is already waiting.
                    if !monitor.queue.contains(where: { $0.0 == which }) {
                        monitor.pending.remove(which)
                        monitor.set(which, monitor.confirmed[which] ?? !on)
                    }
                    monitor.error = "The pedal didn’t take \(which.label). Try again."
                    continue
                }
                if monitor.queue.isEmpty { await readMonitoring() }
            }
        }
    }

    /// Opening the tuner notes the input mute; closing it re-arms the mute exactly like the Electron edition: the pedal
    /// still reports the input muted after the tuner closes, but its audio path needs a fresh off → on edge to mute
    /// again (seen on a pedal, #14). Wait for the tuner-off write, let the pedal settle 200 ms, send off and, 100 ms
    /// after that write, on again, unless the mute was changed meanwhile.
    func tunerMonitoring(opening: Bool, closing: Bool) {
        if opening { monitor.tunerSnapshot = connected && monitor.input != nil ? (monitor.input == true, monitor.inputRevision) : nil }
        guard closing, let snapshot = monitor.tunerSnapshot else { return }
        monitor.tunerSnapshot = nil
        guard snapshot.muted, connected, let session else { return }
        monitor.rearm?.cancel()
        monitor.rearm = Task { [weak self] in
            let deadline = Date().addingTimeInterval(3)
            while await session.isBusy, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.connected, !self.tunerOn, self.monitor.input != nil, self.monitor.inputRevision == snapshot.revision else { return }
            self.append("Tuner closed with the input muted: re-applying Mute Input")
            self.setMute(.input, false)
            let revision = self.monitor.inputRevision
            while self.monitor.writing || !self.monitor.queue.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, self.connected, !self.tunerOn, self.monitor.inputRevision == revision else { return }
            self.setMute(.input, true)
        }
    }

    func resetMonitoring() { monitor.reset() }
}

// MARK: - views

/// The header's Mute (`#muteBtn`): ghost like Tuner, red with white text while the guitar input is muted
/// (`.head .btn.mute-active`); off until the pedal's settings were read.
struct MuteButton: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        let muted = store.monitor.input == true
        Button("Mute") { if let v = store.monitor.input { store.setMute(.input, !v) } }
            .buttonStyle(MuteButtonStyle(active: muted))
            .disabled(!store.connected || store.monitor.input == nil)
            .help("Mute Guitar Input")
            .accessibilityLabel("Mute Guitar Input")
            .accessibilityValue(muted ? "on" : "off")
            .accessibilityAddTraits(muted ? .isSelected : [])
            .accessibilityIdentifier("muteButton")
    }
}

private struct MuteButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View { Styled(active: active, configuration: configuration) }
    private struct Styled: View {
        let active: Bool
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let h = hover && enabled
            configuration.label
                .lineLimit(1).fixedSize()
                .font(Theme.font(13))
                .padding(.horizontal, 13).frame(height: 30)
                .background(active ? (h ? Color(hex: 0xC93B4E) : Theme.danger) : (h ? Theme.raised : .clear), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(active ? .white : h ? Theme.text : Theme.dim)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

/// Settings → Device → Monitoring: the Electron page's two settings, each a title, a note and a labelled switch.
struct MonitoringSection: View {
    @Environment(PedalStore.self) private var store
    var body: some View {
        let ready = store.connected && store.monitor.ready
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Monitoring")
            row(.input, title: "Mute Guitar Input", note: "Mutes the Guitar Input. USB input remains available.", ready: ready)
            row(.outputs, title: "Mute Guitar Output", note: "Mutes processed audio to Outputs 1L/2R. USB playback remains available.", ready: ready)
            if let e = store.monitor.error {
                Text(e).font(Theme.font(12)).foregroundStyle(Theme.warn).accessibilityIdentifier("monitor-error")
            } else if !store.monitor.pending.isEmpty {
                Text("Waiting for the pedal…").font(Theme.font(12)).foregroundStyle(Theme.faint).accessibilityIdentifier("monitor-pending")
            }
        }
    }
    private func row(_ which: Monitor, title: String, note: String, ready: Bool) -> some View {
        let on = store.monitor.value(which) == true
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.font(13))
                Text(note).font(Theme.font(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300, alignment: .leading)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Switch(on: on, color: Theme.accent, enabled: ready) { store.setMute(which, !on) }
                Text(which.label).font(Theme.font(13)).foregroundStyle(ready ? Theme.text : Theme.faint).fixedSize()
                    .onTapGesture { if ready { store.setMute(which, !on) } }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(which.label)
            .accessibilityValue(on ? "on" : "off")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(which == .input ? "device-mute-input" : "device-mute-output")
            .opacity(ready ? 1 : 0.5)
        }
    }
}
