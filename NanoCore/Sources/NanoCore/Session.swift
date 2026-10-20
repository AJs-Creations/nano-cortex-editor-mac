// The editing session: one transport, a serialized write queue with per-key
// coalescing (fast knob turns never back up; the pedal always gets the latest
// value next), typed-reply waiters, and a stream of parsed events for the UI.

import Foundation

public struct TunerReading: Equatable, Sendable { public var note: String; public var cents: Float; public var centered: Bool }

public enum SessionEvent: Sendable {
    case metadata(Metadata)
    case state(StateDump)
    case library(Library)
    case dirty(Bool)
    case presetChangedOnDevice(index: Int, footswitch: Footswitches)
    case fxParams(Slot, [Float])
    case cab(CabSettings)
    case tuner(TunerReading?)
    case tunerMode(on: Bool)
    /// The pedal's tempo changed (type 145 echo): after a live write, or on the pedal itself (tap on footswitch I).
    case tempo(Double)
    /// Something changed on the pedal itself: a knob, a bypass, the expression pedal (LiveReports.swift).
    case live(LiveReport)
    case log(String)
    case disconnected
}

public actor Session {
    public nonisolated let events: AsyncStream<SessionEvent>
    private let emit: AsyncStream<SessionEvent>.Continuation
    private let transport: any NanoTransport
    private let tap: PacketTap?
    private var reader: Task<Void, Never>?
    private var reassembler = Frame.Reassembler()
    public private(set) var connected = false

    // Write queue
    private struct Job { var key: String?; var label: String; var bytes: [UInt8]; var waiters: [CheckedContinuation<Bool, Never>] }
    private var queue: [Job] = []
    private var pumping = false

    // Typed-reply waiters
    private struct Waiter { let id: UInt64; let c: CheckedContinuation<[UInt8], Error> }
    private var waiters: [UInt32: [Waiter]] = [:]
    private var nextWaiterId: UInt64 = 0
    private var pendingFXRefresh: [Slot] = []
    /// Last known footswitch assignments (state dumps, device-side changes): field 9 of a preset change needs them.
    public private(set) var footswitch: Footswitches?

    /// `tap` sees every raw packet in both directions (session recording); it must not block.
    public init(transport: any NanoTransport, tap: PacketTap? = nil) {
        self.transport = transport
        self.tap = tap
        var c: AsyncStream<SessionEvent>.Continuation!
        events = AsyncStream { c = $0 }
        emit = c
    }

    // MARK: connection

    /// Starts reading and performs the initial sync. Returns the metadata and the current state.
    public func connect() async throws -> (Metadata, StateDump) {
        connected = true
        let stream = transport.subscribe()
        reader = Task {
            for await packet in stream { await self.received(packet) }
            await self.lost()
        }
        return try await readAll()
    }

    /// Re-reads everything the initial sync reads: preset, capture and IR names plus the current state.
    public func readAll() async throws -> (Metadata, StateDump) {
        let reply = try await request(Writes.metadataRequest, label: "FE metadata request", expecting: 2, timeout: 10)
        return (Metadata.parse(reply), StateDump.parse(reply))
    }

    public func disconnect() async {
        await transport.disconnect()
        await lost()
    }

    /// The transport reports the link dropped: stop reading its stream (so a new session can take it over)
    /// and fail everything pending. The transport itself may reconnect later.
    public func linkLost() { lost() }

    private func lost() {
        guard connected else { return }
        connected = false
        reader?.cancel()
        for job in queue { job.waiters.forEach { $0.resume(returning: false) } }
        queue.removeAll()
        for (_, list) in waiters { list.forEach { $0.c.resume(throwing: TransportError.notConnected) } }
        waiters.removeAll()
        emit.yield(.disconnected)
    }

    // MARK: incoming

    private func received(_ packet: [UInt8]) {
        tap?(.rx, packet, nil)
        guard let (body, type) = reassembler.feed(packet) else { return }
        if type == 2 { footswitch = StateDump.parse(body).footswitch }
        if let list = waiters.removeValue(forKey: type), !list.isEmpty {
            list.forEach { $0.c.resume(returning: body) }
            if type == 2 || type == 77 || type == 145 { return }   // the requester applies these; events are for unsolicited traffic
            if LiveReport.types.contains(type) { return }          // a reply (a settings read), not a report
        }
        if let report = LiveReport.parse(type: type, body: body) {
            // The pedal answers an expression read (60) with a `{1:1 3:2}` 64 before its 61: that is not a position.
            if case .expression = report, waiters[61] != nil { return }
            emit.yield(.live(report))
            return
        }
        switch type {
        case 2:
            emit.yield(.state(StateDump.parse(body)))
        case 115:
            emit.yield(.dirty((ProtoFields.parse(body).int(3) ?? 0) != 0))
        case 29:
            // Changed on the device (footswitch): ack like the official app, then re-read.
            let f = ProtoFields.parse(body)
            let index = Int(f.int(4) ?? 0)
            let slots = Footswitches.fromPresetSlots(f)
            footswitch = slots
            emit.yield(.presetChangedOnDevice(index: index, footswitch: slots))
            enqueue(Messages.presetChangeAck, key: nil, label: "Preset change ack")
            enqueue(Writes.stateRequest, key: "state", label: "Current preset state request")
        case 138:
            if !pendingFXRefresh.isEmpty { emit.yield(.fxParams(pendingFXRefresh.removeFirst(), FXParams.parse(body: body))) }
        case 96:
            emit.yield(.log("RX cab settings (\(body.count) B): " + body.map { String(format: "%02X", $0) }.joined()))
            emit.yield(.cab(CabSettings.parse(body: body)))
        case 128:
            let f = ProtoFields.parse(body)
            let note = f.string(4) ?? ""
            let cents = f.first(5)?.float32 ?? 0
            emit.yield(.tuner(note.isEmpty ? nil : TunerReading(note: note, cents: cents, centered: (f.int(7) ?? 0) != 0)))
        case 127:
            emit.yield(.tunerMode(on: (ProtoFields.parse(body).int(4) ?? 0) == 1))
        case 77:
            emit.yield(.library(Library.parse(body)))
        case 145:
            if let bpm = Tempo.parseEcho(body: body) { emit.yield(.tempo(bpm)) }
        default: break
        }
    }

    // MARK: write queue

    /// Queues a write. Jobs with the same key replace a not-yet-sent one (coalescing).
    @discardableResult
    public func send(_ bytes: [UInt8], key: String? = nil, label: String) async -> Bool {
        await withCheckedContinuation { c in enqueue(bytes, key: key, label: label, waiter: c) }
    }

    private func enqueue(_ bytes: [UInt8], key: String?, label: String, waiter: CheckedContinuation<Bool, Never>? = nil) {
        if let key, let i = queue.firstIndex(where: { $0.key == key }) {
            queue[i].bytes = bytes; queue[i].label = label
            if let waiter { queue[i].waiters.append(waiter) }
        } else {
            queue.append(Job(key: key, label: label, bytes: bytes, waiters: waiter.map { [$0] } ?? []))
        }
        if !pumping { pumping = true; Task { await self.pump() } }
    }

    /// A queued job with `key` stops coalescing: later writes with that key queue behind whatever came after it.
    private func seal(key: String) {
        if let i = queue.firstIndex(where: { $0.key == key }) { queue[i].key = nil }
    }

    private func pump() async {
        while !queue.isEmpty {
            let job = queue.removeFirst()
            var ok = false
            if connected {
                emit.yield(.log("TX " + job.label))
                tap?(.tx, job.bytes, job.label)
                do { try await transport.write(job.bytes); ok = true }
                catch { emit.yield(.log("ERROR: write failed for \(job.label): \(error)")) }
            }
            job.waiters.forEach { $0.resume(returning: ok) }
        }
        pumping = false
    }

    /// Writes queued or going out, or a reply still awaited. A refresh asked for by a live report waits until this clears.
    public var isBusy: Bool { pumping || !queue.isEmpty || waiters.values.contains { !$0.isEmpty } }

    /// Sends and waits for a reply of `type`.
    public func request(_ bytes: [UInt8], label: String, expecting type: UInt32, timeout: TimeInterval = 5) async throws -> [UInt8] {
        guard connected else { throw TransportError.notConnected }
        nextWaiterId += 1
        let id = nextWaiterId
        return try await withCheckedThrowingContinuation { c in
            waiters[type, default: []].append(Waiter(id: id, c: c))
            Task {
                let sent = await self.send(bytes, label: label)
                if !sent { await self.fail(waiter: id, type: type, with: TransportError.notConnected) }
                try? await Task.sleep(for: .seconds(timeout))
                await self.fail(waiter: id, type: type, with: TransportError.timeout(label))   // a no-op once this waiter was answered
            }
        }
    }
    /// Fails one waiter only: a timer that fires after its request was answered must not touch later requests of the same type.
    private func fail(waiter id: UInt64, type: UInt32, with error: Error) {
        guard var list = waiters[type], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let w = list.remove(at: i)
        waiters[type] = list.isEmpty ? nil : list
        w.c.resume(throwing: error)
    }

    // MARK: editing API (all live on the pedal; `save` commits)

    public func requestState() async throws -> StateDump { StateDump.parse(try await request(Writes.stateRequest, label: "Current preset state request", expecting: 2)) }

    public func selectPreset(index: Int) async throws -> StateDump {
        _ = try await request(Messages.presetChange(index: index, footswitch: footswitch), label: "Preset change \(index + 1)", expecting: 30)
        return try await requestState()
    }
    /// Puts preset `presetIndex` on a footswitch slot (type 29, field 4 = −1), then re-reads the state.
    public func assignFootswitch(slot: FootswitchSlot, presetIndex: Int) async throws -> StateDump {
        _ = try await request(Writes.assignFootswitch(slot: slot, presetIndex: presetIndex), label: "Assign preset \(presetIndex + 1) to footswitch \(slot.label)", expecting: 30)
        return try await requestState()
    }
    public func save(index: Int, name: String) async throws -> Bool {
        let reply = try await request(Writes.save(index: index, name: name), label: "save preset \(index + 1)", expecting: 4)
        return ProtoFields.parse(reply).int(4) == 1
    }
    /// Empties a preset slot on the pedal. Only ever from an explicit, confirmed user action.
    public func deletePreset(index: Int) async throws -> Bool {
        let reply = try await request(Writes.deletePreset(index: index), label: "Delete preset \(index + 1)", expecting: 51, timeout: 10)
        let f = ProtoFields.parse(reply)
        return f.int(4) == 1
    }
    /// Re-reads the names (presets, captures, IRs) without touching the current preset.
    public func requestMetadata() async throws -> Metadata {
        Metadata.parse(try await request(Writes.metadataRequest, label: "FE metadata request", expecting: 2, timeout: 10))
    }

    public func rename(index: Int, name: String) async throws -> Bool {
        let reply = try await request(Messages.renamePreset(index: index, name: name), label: "Rename preset \(index + 1) to \"\(name)\"", expecting: 112)
        return ProtoFields.parse(reply).int(4) == 1
    }

    public func setAmp(_ knob: AmpKnob, _ value: Int) async { await send(Writes.amp(knob, value), key: "amp:\(knob.rawValue)", label: "Amp \(knob.rawValue) = \(value)") }
    public func setCaptureVolume(db: Double) async { await send(Writes.captureVolume(db: db), key: "capture-volume", label: "Capture volume \(db) dB") }
    public func setGate(on: Bool) async { await send(Writes.gateEnabled(on), label: on ? "Gate ON" : "Gate OFF") }
    public func setGateReduction(percent: Int) async { await send(Writes.gateReduction(percent: percent), key: "gate-reduction", label: "Gate reduction \(percent)%") }
    public func setFX(_ slot: Slot, on: Bool) async { await send(Writes.fxEnabled(slot, on), label: "\(slot.title) \(on ? "ON" : "OFF")") }
    public func setFXParam(_ slot: Slot, index: Int, normalized: Float) async { await send(Writes.fxParam(slot, index: index, normalized: normalized), key: "fx:\(slot.rawValue):\(index)", label: "\(slot.title) param \(index)") }
    public func setFXModel(_ slot: Slot, _ model: ModelDef) async { if let id = model.id { await send(Writes.fxModel(slot, id: id), label: "\(slot.title) model select \(model.name)") } }
    /// Asks for the current parameter values of a slot; they arrive as `.fxParams`.
    public func refreshFXParams(_ slot: Slot) async { pendingFXRefresh.append(slot); await send(Writes.fxParamRefresh(slot), label: "\(slot.title) param refresh") }

    public func selectCapture(slot: Int) async { await send(Writes.captureSelect(slot: slot), label: "capture change \(slot)") }
    public func bypassCapture() async { await send(Writes.captureBypass, label: "Capture bypass") }
    public func selectCab(slot: Int) async { await send(Writes.cabSelect(slot: slot), label: "Cab/IR slot select \(slot)") }
    public func refreshCab(slot: Int) async { await send(Writes.cabRefresh(slot: slot), label: "Cab/IR param refresh slot \(slot)") }
    public func setCabLevel(db: Double) async { await send(Writes.cabLevel(db: db), key: "cab-level", label: "Cab/IR level \(db) dB") }
    public func setCabHighPass(hz: Double) async { await send(Writes.cabHighPass(hz: hz), key: "cab-hpf", label: "Cab/IR high pass \(hz) Hz") }
    public func setCabLowPass(hz: Double) async { await send(Writes.cabLowPass(hz: hz), key: "cab-lpf", label: "Cab/IR low pass \(hz) Hz") }
    public func setCabMic(libraryIndex: Int, cabName: String, mic: String, position: Int) async { await send(Writes.cabMicPosition(libraryIndex: libraryIndex, cabName: cabName, mic: mic, position: position), label: "Cab mic/position \(mic) pos \(position)") }

    public func requestLibrary() async throws -> Library { Library.parse(try await request(Writes.libraryRequest, label: "Library content request", expecting: 77, timeout: 10)) }
    public func loadLibraryCapture(slot: Int, factory: Bool, index: Int, name: String) async throws -> Bool {
        let r = try await request(Writes.loadLibraryCapture(slot: slot, factory: factory, index: index, name: name), label: "Load library capture \"\(name)\" into slot \(slot)", expecting: 81, timeout: 10)
        return ProtoFields.parse(r).int(3) == 1
    }
    public func loadLibraryCab(slot: Int, factory: Bool, index: Int, name: String) async throws -> Bool {
        let r = try await request(Writes.loadLibraryCab(slot: slot, factory: factory, index: index, name: name), label: "Load library cab \"\(name)\" into cab slot \(slot)", expecting: 79, timeout: 10)
        return ProtoFields.parse(r).int(3) == 1
    }

    /// Streams a capture into the pedal's library. Progress is (sent, total) writes.
    public func uploadCapture(cns: [UInt8], record: CaptureRecord, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Messages.UploadReply {
        guard connected else { throw TransportError.notConnected }
        let parts = Messages.uploadCapture(cns: cns, record: record)
        nextWaiterId += 1
        let id = nextWaiterId
        let body: [UInt8] = try await withCheckedThrowingContinuation { c in
            waiters[14, default: []].append(Waiter(id: id, c: c))
            Task {
                for (i, part) in parts.enumerated() {
                    let ok = await self.send(part, label: "Capture upload \"\(record.name)\" \(i + 1)/\(parts.count)")
                    if !ok { await self.fail(waiter: id, type: 14, with: TransportError.notConnected); return }
                    progress?(i + 1, parts.count)
                }
                try? await Task.sleep(for: .seconds(20))
                await self.fail(waiter: id, type: 14, with: TransportError.timeout("capture upload"))
            }
        }
        return Messages.parseUploadReply(body: body)
    }

    // MARK: device (PROTOCOL-NOTES §13)

    /// Device info (46 → 47: firmware, serial), then the keep-alive (91 → 92: firmware build, device name).
    /// The second one is optional: a pedal that does not answer it still gives the first.
    public func readDeviceInfo(now: Date = Date()) async throws -> DeviceInfo {
        let reply = try await request(Writes.deviceInfoRequest(unixTime: UInt64(max(0, now.timeIntervalSince1970))), label: "Device info request", expecting: 47)
        var info = DeviceInfo.parse(deviceInfo: reply)
        if let k = try? await request(Writes.keepAlive, label: "Keep-alive", expecting: 92, timeout: 3) { info.merge(keepAlive: k) }
        return info
    }
    public func readDeviceSettings() async throws -> DeviceSettings {
        DeviceSettings.parse(try await request(Writes.settingsRequest, label: "Settings request", expecting: 66))
    }
    /// Writes LED brightness and USB playback volume together (one type-67 message, like the phone app) and waits for 68.
    public func writeDeviceSettings(brightness: Int, usbVolumeDb: Float) async throws -> Bool {
        let label = "Settings: LED brightness \(brightness) (\(DeviceSettings.brightnessPercent(brightness))%), USB volume \(String(format: "%.1f", usbVolumeDb)) dB"
        let reply = try await request(Writes.deviceSettings(brightness: brightness, usbVolumeDb: usbVolumeDb), label: label, expecting: 68)
        return ProtoFields.parse(reply).int(3) == 1
    }
    /// Details of the capture in slot 1–25 (17 → 18).
    public func captureDetails(slot: Int) async throws -> CaptureDetails {
        CaptureDetails.parse(try await request(Writes.captureDetails(slot: slot), label: "Capture details slot \(slot)", expecting: 18), slot: slot)
    }

    /// The preset tempo (type 145, PROTOCOL-NOTES §11). `live`: the pedal plays it, the preset stays clean; same-key
    /// writes coalesce like knobs. Not live: the final value goes out as a live write and then a scope-0 write into the
    /// preset (the pedal reports dirty; Save commits it), the order the official app uses. Later live writes queue
    /// behind the commit instead of overtaking it.
    public func setTempo(bpm: Double, live: Bool) async {
        let v = Tempo.clamp(bpm), shown = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        if live {
            await send(Writes.tempo(bpm: v, live: true), key: "tempo", label: "Tempo \(shown) BPM (live)")
        } else {
            enqueue(Writes.tempo(bpm: v, live: true), key: "tempo", label: "Tempo \(shown) BPM (live)")
            seal(key: "tempo")
            await send(Writes.tempo(bpm: v, live: false), label: "Preset tempo \(shown) BPM")
        }
    }
    /// Asks for the current tempo (the pedal answers with a 145 echo).
    public func requestTempo() async throws -> Double? {
        Tempo.parseEcho(body: try await request(Writes.tempoQuery, label: "Tempo request", expecting: MessageType.tempo.rawValue))
    }
    /// Type 60 → 61: the preset's expression pedal assignments (PROTOCOL-NOTES §12).
    public func readExpression(index: Int) async throws -> ExpressionAssignments {
        ExpressionAssignments.parse(reply: try await request(Writes.expressionRead(index: index), label: "Expression assignments request (preset \(index + 1))", expecting: 61))
    }
    /// Type 62 → 63: replaces the whole set (empty clears it). Live in the edit buffer; Save commits (unverified).
    public func saveExpression(index: Int, _ set: ExpressionAssignments) async throws -> Bool {
        let label = set.isEmpty ? "Expression assignments cleared (preset \(index + 1))" : "Expression assignments (preset \(index + 1)): \(set.count)"
        let reply = try await request(Writes.expressionSave(index: index, set), label: label, expecting: 63)
        return ProtoFields.parse(reply).int(3) == 1
    }

    public func tuner(on: Bool, baseFrequency: Float = 440, muted: Bool = false) async { await send(Messages.tunerMode(on: on, baseFrequency: baseFrequency, live: true, muted: muted), label: on ? "Tuner on" : "Tuner off") }
}

