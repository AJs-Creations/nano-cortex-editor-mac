// CoreBluetooth implementation of NanoTransport. Finds the pedal by its editor
// service (A002), remembers it, and reconnects by itself whenever it advertises
// (after a power-up the pedal only advertises once EXIT + CAPTURE is held).

import Foundation
import CoreBluetooth
import NanoCore

final class BluetoothTransport: NSObject, NanoTransport, @unchecked Sendable {
    nonisolated(unsafe) static let serviceUUIDs = [CBUUID(string: "A002"), CBUUID(string: "A003")]
    nonisolated(unsafe) static let writeUUID = CBUUID(string: "C304")
    nonisolated(unsafe) static let notifyUUID = CBUUID(string: "C305")
    nonisolated(unsafe) static let namePattern = try! NSRegularExpression(pattern: "nano|cortex|ndsp|neural", options: .caseInsensitive)
    private static let rememberedKey = "pedal.identifier"   // AppSettings.Key.pedalIdentifier; Settings → Connection can forget it
    private static let rememberedNameKey = "pedal.name"

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
    private var reconnecting = false

    var phase: Phase { lock.lock(); defer { lock.unlock() }; return _phase }
    private func setPhase(_ p: Phase) { lock.lock(); _phase = p; lock.unlock(); onPhase?(p) }
    private func log(_ s: String) { onLog?(s) }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    func subscribe() -> AsyncStream<[UInt8]> { hub.subscribe() }

    // MARK: NanoTransport

    /// Starts looking for the pedal and resolves once C304/C305 are ready.
    func connect() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if case .connected = self.phase { c.resume(); return }
                self.readyWaiters.append(c)
                if self.wantConnection { return }      // a connect is already in flight; just wait for it
                self.wantConnection = true
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
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.setPhase(.off)
            self.hub.finishAll()
        }
    }

    // MARK: scanning / reconnect

    private func startScanning() {
        guard central.state == .poweredOn else { log("Bluetooth is \(central.state == .poweredOff ? "off" : "not ready")"); return }
        if let id = UserDefaults.standard.string(forKey: Self.rememberedKey).flatMap(UUID.init(uuidString:)),
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
        p.delegate = self
        setPhase(.connecting(p.name ?? "Nano Cortex"))
        central.connect(p, options: nil)
    }

    private func failReady(_ error: Error) {
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume(throwing: error) }
    }
}

extension BluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.rawValue)")
        if central.state == .poweredOn, wantConnection { startScanning() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        log("Found \(name.isEmpty ? p.identifier.uuidString : name) (\(RSSI) dBm)")
        // Service filter already narrows to A002/A003 advertisers; the name is a second check when present.
        if name.isEmpty || Self.namePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil { attach(p) }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log("Connected to \(p.name ?? "pedal"); discovering services…")
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.rememberedKey)
        if let n = p.name { UserDefaults.standard.set(n, forKey: Self.rememberedNameKey) }
        p.discoverServices(Self.serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
        if wantConnection { startScanning() } else { failReady(TransportError.notConnected) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        writeChar = nil; notifyChar = nil
        let w = writeWaiters; writeWaiters = []
        w.forEach { $0.resume(throwing: TransportError.notConnected) }
        onLinkLost?()
        if wantConnection {
            reconnecting = true
            setPhase(.reconnecting(p.name ?? "pedal"))
            central.connect(p, options: nil)   // CoreBluetooth keeps this pending until the pedal advertises again
        } else {
            setPhase(.off)
        }
    }
}

extension BluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { log("Service discovery failed: \(error!.localizedDescription)"); return }
        for s in p.services ?? [] { p.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.writeUUID { writeChar = ch }
            if ch.uuid == Self.notifyUUID { notifyChar = ch; p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Self.notifyUUID else { return }
        if let error { log("Notifications failed: \(error.localizedDescription)"); failReady(error); return }
        guard writeChar != nil else { return }
        log("C305 notifications on, MTU \(p.maximumWriteValueLength(for: .withResponse))")
        setPhase(.connected(p.name ?? "Nano Cortex"))
        let w = readyWaiters; readyWaiters = []
        w.forEach { $0.resume() }
        if reconnecting { reconnecting = false; onReconnected?() }
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
