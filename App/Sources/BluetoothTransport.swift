// CoreBluetooth implementation of NanoTransport. Finds the pedal by its editor
// service (A002), remembers it once its link is ready, and reconnects by itself whenever it advertises
// (after a power-up the pedal only advertises once EXIT + CAPTURE is held).
// What counts as a ready Nano, what is remembered or forgotten, and how often a failing connect is retried:
// GattSetup and LinkPolicy (PedalLink.swift, unit-tested; DECISIONS #24).

import Foundation
import CoreBluetooth
import NanoCore

final class BluetoothTransport: NSObject, NanoTransport, @unchecked Sendable {
    nonisolated(unsafe) static let serviceUUIDs = GattSetup.services.sorted().map { CBUUID(string: $0) }
    nonisolated(unsafe) static let writeUUID = CBUUID(string: GattSetup.write)
    nonisolated(unsafe) static let notifyUUID = CBUUID(string: GattSetup.notify)

    enum Phase: Equatable { case off, scanning, connecting(String), connected(String), reconnecting(String) }

    private let hub = NotificationHub()
    private let queue = DispatchQueue(label: "nano.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeWaiters: [CheckedContinuation<Void, Error>] = []
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var wantConnection = false
    private let lock = NSLock()
    private var _phase: Phase = .off
    var onPhase: (@Sendable (Phase) -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    /// The GATT link dropped; the owner starts a fresh session when `phase` is `.connected` again.
    var onLinkLost: (@Sendable () -> Void)?
    /// Called once C304/C305 are ready after an automatic reconnect (not after `connect()`).
    var onReconnected: (@Sendable () -> Void)?
    /// An automatic reconnect gave up (no `connect()` call is waiting to hear why); the phase is `.off`.
    var onFailed: (@Sendable (LinkError) -> Void)?
    /// Why a connect is not getting anywhere (Bluetooth off or not allowed, no pedal found yet), or nil once it is.
    var onProblem: (@Sendable (String?) -> Void)?
    private var attempt = 0   // bumps on every scan start, so a stale "not found yet" timer stays quiet
    static let notFoundAfter: TimeInterval = 20
    // The rest is touched on `queue` only.
    private var policy = LinkPolicy(memory: DefaultsPedalMemory())
    private var setup = GattSetup()
    private var setupToken = 0     // bumps when a setup starts or ends, so a stale setup timeout stays quiet
    private var generation = 0     // bumps when a connect ends, so a scheduled retry stays quiet
    private var life = LinkLife()  // C304/C305 ready on the current link, and whether the next ready one is a reconnect

    var phase: Phase { lock.lock(); defer { lock.unlock() }; return _phase }
    private func setPhase(_ p: Phase) { lock.lock(); _phase = p; lock.unlock(); onPhase?(p) }
    private func log(_ s: String) { onLog?(s) }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func subscribe() -> AsyncStream<[UInt8]> { hub.subscribe() }

    // MARK: NanoTransport

    /// Starts looking for the pedal and resolves once C304/C305 are ready. Throws a `LinkError` when the device
    /// turns out not to be a Nano, its setup fails or times out, connecting keeps failing, or `disconnect()` cancels.
    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if case .connected = self.phase { c.resume(); return }
                self.readyWaiters.append(c)
                if self.wantConnection { return }      // a connect is already in flight; just wait for it
                self.wantConnection = true
                self.policy.begin()
                self.startScanning()
            }
        }
    }

    func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let p = self.peripheral, let ch = self.writeChar, p.state == .connected else { c.resume(throwing: TransportError.notConnected); return }
                self.writeWaiters.append(c)
                p.writeValue(Data(bytes), for: ch, type: .withResponse)
            }
        }
    }

    func disconnect() async {
        queue.async {
            self.wantConnection = false
            self.life.reset()   // the store has ended its session; the didDisconnect that follows loses nothing
            self.generation += 1; self.setupToken += 1
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.setPhase(.off)
            self.failReady(LinkError.cancelled)   // a connect() still waiting (Cancel, Stop waiting) ends here
            self.hub.finishAll()
        }
    }

    // MARK: scanning / reconnect

    private func startScanning() {
        guard central.state == .poweredOn else {
            log("Bluetooth is \(central.state == .poweredOff ? "off" : "not ready")")
            onProblem?(Self.problem(for: central.state))
            return
        }
        onProblem?(nil)
        attempt += 1
        let this = attempt
        queue.asyncAfter(deadline: .now() + Self.notFoundAfter) { [weak self] in
            guard let self, self.attempt == this, self.wantConnection else { return }
            switch self.phase {
            case .scanning, .connecting: self.onProblem?("No Nano Cortex found yet. Hold EXIT + CAPTURE until the Gain ring lights up, and close the Cortex Cloud phone app. Still trying…")
            default: break
            }
        }
        if let id = policy.target.flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            log("Connecting to the remembered pedal \(known.name ?? id.uuidString)…")
            attach(known)
            return
        }
        setPhase(.scanning)
        log("Scanning for the Nano Cortex (hold EXIT + CAPTURE after a power-up)…")
        central.scanForPeripherals(withServices: Self.serviceUUIDs, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func attach(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        setupToken += 1
        p.delegate = self
        setPhase(.connecting(p.name ?? "Nano Cortex"))
        central.connect(p, options: nil)
    }

    /// What the connect card says while Bluetooth itself is the problem (nil for transient states).
    static func problem(for state: CBManagerState) -> String? {
        switch state {
        case .poweredOff: "Bluetooth is off. Turn it on in Control Center or System Settings → Bluetooth."
        case .unauthorized: "Nano Cortex Editor isn't allowed to use Bluetooth. Allow it in System Settings → Privacy & Security → Bluetooth."
        case .unsupported: "This Mac doesn't support Bluetooth Low Energy."
        default: nil
        }
    }

    private func failReady(_ error: Error) {
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume(throwing: error) }
    }

    // MARK: setup verdicts

    private func settled(_ p: CBPeripheral, _ verdict: GattSetup.Verdict) {
        guard wantConnection else { return }   // cancelled while discovery was still answering
        switch verdict {
        case .ready: becameReady(p)
        case .failed(let why): setupFailed(p, .setupFailed(why))
        case .notANano:
            switch policy.notANano(identifier: p.identifier.uuidString) {
            case .proven(let forgot):
                log("\(p.name ?? "This device") has no Nano Cortex service (A002/A003 with C304/C305)\(forgot ? "; forgot it" : "")")
                giveUp(.notANano(name: p.name, forgot: forgot), cancel: p)
            case .doubted:   // it was a ready Nano earlier in this session
                setupFailed(p, .setupFailed("no Nano Cortex service answered"))
            }
        }
    }

    private func becameReady(_ p: CBPeripheral) {
        setupToken += 1
        let startSession = life.becameReady(callerWaiting: !readyWaiters.isEmpty)   // a connect() caller starts its own session
        policy.ready(identifier: p.identifier.uuidString, name: p.name)   // only now is the pedal remembered
        log("C305 notifications on, MTU \(p.maximumWriteValueLength(for: .withResponse))")
        setPhase(.connected(p.name ?? "Nano Cortex"))
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume() }
        if startSession { onReconnected?() }
    }

    /// The setup failed or timed out, which proves nothing about the device (nothing is forgotten). A connect someone
    /// asked for ends with the error; an automatic reconnect drops the link and waits for the pedal again, a few times.
    private func setupFailed(_ p: CBPeripheral, _ error: LinkError) {
        setupToken += 1
        log("Setup failed: \(error.message)")
        switch policy.setupFailed(identifier: p.identifier.uuidString, unattended: life.reconnecting && readyWaiters.isEmpty) {
        case .retry: central.cancelPeripheralConnection(p)   // didDisconnect arms the pending connect again
        case .scan, .giveUp: giveUp(error, cancel: p)
        }
    }

    /// Ends the connect: no more retries or waiting, the link (if any) cancelled, and whoever waits is told why
    /// (the `connect()` caller, or `onFailed` after an automatic reconnect).
    private func giveUp(_ error: LinkError, cancel p: CBPeripheral?) {
        wantConnection = false
        life.reset()
        generation += 1; setupToken += 1
        central.stopScan()
        if let p { central.cancelPeripheralConnection(p) }
        peripheral = nil   // its late callbacks (didDisconnect included) are ignored
        writeChar = nil; notifyChar = nil
        log("Not connected: \(error.message)")
        setPhase(.off)
        if readyWaiters.isEmpty { onFailed?(error) } else { failReady(error) }
    }
}

extension BluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.rawValue)")
        // Bluetooth off (a Mac going to sleep does this) ends the link without a didDisconnect: end the session here,
        // so the reconnect when it is back on (startScanning below) syncs a new one (LinkLife, DECISIONS #37).
        if central.state != .poweredOn, let p = peripheral, life.ready {
            log("Bluetooth went off with the pedal connected; the link is gone")
            linkEnded(p, byBluetoothOff: true)
        }
        if central.state == .poweredOn, wantConnection { startScanning() }
        else if wantConnection { onProblem?(Self.problem(for: central.state)) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let label = name.isEmpty ? p.identifier.uuidString : name
        log("Found \(label) (\(RSSI) dBm)")
        // The service filter already narrows to A002/A003 advertisers; the name is a second check when present.
        guard policy.accepts(identifier: p.identifier.uuidString, name: name) else {
            if policy.notNano.contains(p.identifier.uuidString) { log("Skipping \(label): not a Nano Cortex") }
            return
        }
        attach(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral, wantConnection else { central.cancelPeripheralConnection(p); return }   // cancelled meanwhile
        log("Connected to \(p.name ?? "pedal"); discovering services…")
        writeChar = nil; notifyChar = nil
        setup = GattSetup()
        setupToken += 1
        let token = setupToken
        queue.asyncAfter(deadline: .now() + LinkPolicy.setupTimeout) { [weak self] in
            guard let self, self.setupToken == token, self.wantConnection, let p = self.peripheral else { return }
            self.setupFailed(p, .setupTimedOut)
        }
        p.discoverServices(Self.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let why = error?.localizedDescription ?? "unknown error"
        log("Connect failed: \(why)")
        guard p === peripheral, wantConnection else { return }   // disconnect() has already answered connect()
        switch policy.connectFailed(identifier: p.identifier.uuidString) {
        case .retry:
            log("Trying \(p.name ?? "the pedal") again…")
            let gen = generation, id = p.identifier
            queue.asyncAfter(deadline: .now() + LinkPolicy.retryDelay) { [weak self] in
                guard let self, self.generation == gen, self.wantConnection, let p = self.peripheral, p.identifier == id else { return }
                self.central.connect(p, options: nil)
            }
        case .scan:
            log("The remembered pedal keeps failing; scanning for a Nano Cortex instead…")
            startScanning()
        case .giveUp:
            giveUp(.connectFailed(why), cancel: p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        guard p === peripheral else { return }   // a device given up on earlier
        linkEnded(p, byBluetoothOff: false)
        // CoreBluetooth keeps this pending until the pedal advertises again; with Bluetooth off, the scan when it is
        // back on reconnects instead.
        if wantConnection, central.state == .poweredOn { central.connect(p, options: nil) }
    }

    /// The link to `p` is gone: writes fail, the session on it (if any) ends, and the phase says what comes next.
    private func linkEnded(_ p: CBPeripheral, byBluetoothOff: Bool) {
        writeChar = nil; notifyChar = nil
        setupToken += 1
        let w = writeWaiters; writeWaiters = []
        w.forEach { $0.resume(throwing: TransportError.notConnected) }
        let lost = byBluetoothOff ? life.bluetoothOff(wantConnection: wantConnection) : life.ended(wantConnection: wantConnection)
        if lost { onLinkLost?() }   // a dropped setup had no session to end
        setPhase(wantConnection ? .reconnecting(p.name ?? "pedal") : .off)
    }
}

extension BluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        if let error { log("Service discovery failed: \(error.localizedDescription)") }
        let services = p.services ?? []
        if let v = setup.servicesDiscovered(services.map(\.uuid.uuidString), error: error?.localizedDescription) { settled(p, v); return }
        for s in services where setup.awaiting.contains(s.uuid.uuidString.uppercased()) {
            p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        if let error { log("Characteristic discovery failed on \(service.uuid.uuidString): \(error.localizedDescription)") }
        let chars = service.characteristics ?? []
        for ch in chars {
            if ch.uuid == Self.writeUUID { writeChar = ch }
            if ch.uuid == Self.notifyUUID, notifyChar == nil { notifyChar = ch; p.setNotifyValue(true, for: ch) }
        }
        if let v = setup.characteristicsDiscovered(chars.map(\.uuid.uuidString), in: service.uuid.uuidString, error: error?.localizedDescription) { settled(p, v) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard p === peripheral, ch.uuid == Self.notifyUUID else { return }
        if let error { log("Notifications failed: \(error.localizedDescription)") }
        if let v = setup.notificationsUpdated(on: ch.isNotifying, error: error?.localizedDescription) { settled(p, v) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.notifyUUID, let data = ch.value else { return }
        hub.yield([UInt8](data))
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        guard !writeWaiters.isEmpty else { return }
        let c = writeWaiters.removeFirst()
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
