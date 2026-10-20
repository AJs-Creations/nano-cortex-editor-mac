// The rules of a Bluetooth connect, without CoreBluetooth, so the unit tests drive them with a fake memory
// (PedalLinkTests). BluetoothTransport feeds them what CoreBluetooth reports. DECISIONS #24; the Electron edition
// follows the same rules (its src/bt-picker.js, issue #15 there).
//  • GattSetup: is the connected device a Nano Cortex, and is the link ready? Ready means the A002/A003 services gave
//    the C304 write and C305 notify characteristics and C305 notifications are on. A discovery that finishes without
//    them proves the device isn't a Nano; an error proves nothing.
//  • LinkPolicy: which device a connect goes to first, what is remembered (only a ready pedal), what is forgotten (only
//    a device proven not to be a Nano; a timeout, an error or a dropped link forget nothing), and how often a failing
//    connect is retried before it scans afresh or gives up.

import Foundation

/// One GATT setup on a connected device, from service discovery to C305 notifications. Each event returns the
/// verdict when that event settles the setup (once), nil while it is still open or after it has settled.
struct GattSetup: Equatable {
    static let services: Set<String> = ["A002", "A003"]
    static let write = "C304", notify = "C305"

    enum Verdict: Equatable { case ready, notANano, failed(String) }

    private(set) var verdict: Verdict?
    /// Nano services whose characteristics have not been reported yet.
    private(set) var awaiting: Set<String> = []
    private var servicesKnown = false
    private var hasWrite = false, hasNotify = false, notifying = false
    private var errors: [String] = []

    /// didDiscoverServices: the services found (any UUIDs; only A002/A003 count), or the error.
    mutating func servicesDiscovered(_ uuids: [String], error: String? = nil) -> Verdict? {
        guard verdict == nil else { return nil }
        if let error { return settle(.failed(error)) }
        servicesKnown = true
        awaiting = Set(uuids.map { $0.uppercased() }).intersection(Self.services)
        return awaiting.isEmpty ? settle(.notANano) : nil
    }

    /// didDiscoverCharacteristicsFor one of the Nano services. An error on one service is held: the other one may
    /// still carry C304/C305, and if neither does, the error (not "not a Nano") is the verdict.
    mutating func characteristicsDiscovered(_ uuids: [String], in service: String, error: String? = nil) -> Verdict? {
        guard verdict == nil else { return nil }
        awaiting.remove(service.uppercased())
        if let error { errors.append(error) }
        let found = Set(uuids.map { $0.uppercased() })
        hasWrite = hasWrite || found.contains(Self.write)
        hasNotify = hasNotify || found.contains(Self.notify)
        return evaluate()
    }

    /// didUpdateNotificationStateFor C305.
    mutating func notificationsUpdated(on: Bool, error: String? = nil) -> Verdict? {
        guard verdict == nil else { return nil }
        if let error { return settle(.failed(error)) }
        notifying = on
        return evaluate()
    }

    private mutating func evaluate() -> Verdict? {
        if hasWrite && hasNotify && notifying { return settle(.ready) }
        guard servicesKnown, awaiting.isEmpty, !(hasWrite && hasNotify) else { return nil }   // else: notifications pending
        return settle(errors.first.map { .failed($0) } ?? .notANano)
    }

    private mutating func settle(_ v: Verdict) -> Verdict { verdict = v; return v }
}

/// Where the remembered pedal lives: UserDefaults in the app (`DefaultsPedalMemory`), a fake in the tests.
protocol PedalMemory: AnyObject {
    var identifier: String? { get }
    func remember(identifier: String, name: String?)
    func forget()
}

/// `pedal.identifier` and `pedal.name` (AppSettings.Key; Settings → Connection shows and forgets them).
final class DefaultsPedalMemory: PedalMemory {
    static let identifierKey = "pedal.identifier", nameKey = "pedal.name"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var identifier: String? { defaults.string(forKey: Self.identifierKey) }
    func remember(identifier: String, name: String?) {
        if let name, !name.isEmpty { defaults.set(name, forKey: Self.nameKey) }
        else if self.identifier != identifier { defaults.removeObject(forKey: Self.nameKey) }   // another device's name
        defaults.set(identifier, forKey: Self.identifierKey)
    }
    func forget() {
        defaults.removeObject(forKey: Self.identifierKey)
        defaults.removeObject(forKey: Self.nameKey)
    }
}

/// The remember / forget / retry rules. Identifiers are CoreBluetooth peripheral UUID strings.
struct LinkPolicy {
    /// From the link coming up (didConnect) to ready. Discovery takes well under a second on the pedal. Waiting for the
    /// pedal to advertise has no limit: CoreBluetooth keeps that connect pending, and the card says what to do.
    static let setupTimeout: TimeInterval = 10
    /// Attempts on one device (didFailToConnect, or a failed setup during an automatic reconnect) before moving on.
    static let maxAttempts = 3
    static let retryDelay: TimeInterval = 1
    /// Advertised names that look like the pedal; an unnamed device that advertises A002/A003 is taken too.
    static let namePattern = "nano|cortex|ndsp|neural"

    enum Next: Equatable { case retry, scan, giveUp }
    /// A discovery without the Nano's service: proof (marked, forgotten if remembered), or doubted because this device
    /// was a ready Nano earlier in this session (a pedal mid-boot, say), which makes it a plain failure.
    enum NotANano: Equatable { case proven(forgot: Bool), doubted }

    let memory: any PedalMemory
    /// This app session: never connected to again (Connect skips them; the remembered one was forgotten).
    private(set) var notNano: Set<String> = []
    /// This app session: reached ready, so a Nano whatever a later discovery says.
    private(set) var verified: Set<String> = []
    private var attempts: [String: Int] = [:]
    /// This connect goes past the remembered device: it failed `maxAttempts` times.
    private(set) var skipRemembered = false

    init(memory: any PedalMemory) { self.memory = memory }

    /// Someone asked to connect (Connect, ⌘K, connect at launch): a fresh count.
    mutating func begin() { attempts = [:]; skipRemembered = false }

    /// The device a connect goes to first, or nil to scan.
    var target: String? {
        guard !skipRemembered, let id = memory.identifier, !notNano.contains(id) else { return nil }
        return id
    }

    /// A scan result (the scan only reports devices that advertise A002/A003): connect to it?
    func accepts(identifier: String, name: String) -> Bool {
        guard !notNano.contains(identifier) else { return false }
        return name.isEmpty || name.range(of: Self.namePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// C304/C305 found and notifications on: this is the pedal to remember.
    mutating func ready(identifier: String, name: String?) {
        verified.insert(identifier)
        notNano.remove(identifier)
        attempts[identifier] = nil
        skipRemembered = false
        memory.remember(identifier: identifier, name: name)
    }

    /// The setup finished without the Nano's service or characteristics.
    mutating func notANano(identifier: String) -> NotANano {
        if verified.contains(identifier) { return .doubted }
        notNano.insert(identifier)
        guard memory.identifier == identifier else { return .proven(forgot: false) }
        memory.forget()
        return .proven(forgot: true)
    }

    /// didFailToConnect: the same device a few times, then (if it was the remembered one) a fresh scan, then stop.
    mutating func connectFailed(identifier: String) -> Next {
        if bump(identifier) < Self.maxAttempts { return .retry }
        if !skipRemembered, memory.identifier == identifier { skipRemembered = true; return .scan }
        return .giveUp
    }

    /// The setup failed with an error or timed out. `unattended` (an automatic reconnect) tries a few more times; a
    /// connect someone asked for stops at once so they see why.
    mutating func setupFailed(identifier: String, unattended: Bool) -> Next {
        guard unattended else { return .giveUp }
        return bump(identifier) < Self.maxAttempts ? .retry : .giveUp
    }

    private mutating func bump(_ id: String) -> Int {
        let n = (attempts[id] ?? 0) + 1
        attempts[id] = n
        return n
    }
}

/// Why a connect ended. `message` is what the connect card (and the status bar) shows.
enum LinkError: Error, Equatable, LocalizedError {
    case notANano(name: String?, forgot: Bool)
    case setupTimedOut
    case setupFailed(String)
    case connectFailed(String)
    /// Cancel, Stop waiting or Disconnect while a connect was in flight: nothing to show.
    case cancelled

    var message: String {
        switch self {
        case .notANano(let name, let forgot):
            (name.map { "“\($0)”" } ?? "That device") + " isn’t a Nano Cortex: it has no Nano Cortex Bluetooth service."
                + (forgot ? " The app forgot it." : "") + " Hold EXIT + CAPTURE on the pedal, then click Connect to look for it."
        case .setupTimedOut:
            "The pedal connected but didn’t finish setting up within \(Int(LinkPolicy.setupTimeout)) seconds. Move closer, close the Cortex Cloud phone app, then click Connect again."
        case .setupFailed(let why):
            "The pedal’s editor service didn’t respond (\(why)). Close the Cortex Cloud phone app, then click Connect again."
        case .connectFailed(let why):
            "Couldn’t connect to the pedal (\(why)). Turn it off and on, hold EXIT + CAPTURE, then click Connect again."
        case .cancelled:
            "Connect cancelled."
        }
    }
    var errorDescription: String? { message }
}
