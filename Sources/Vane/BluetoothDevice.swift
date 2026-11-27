@preconcurrency import CoreBluetooth
import Foundation

/// The native half of Web Bluetooth: UUIDs, the GATT blocklist, and the radio. Nothing here
/// knows about pages, origins or grants; see WebBluetooth.swift for those.

/// What a page is told when something fails: a DOMException name (or `TypeError`) and text.
struct BluetoothError: Error, Equatable, Sendable {
    let name: String
    let message: String

    static func type(_ message: String) -> BluetoothError { BluetoothError(name: "TypeError", message: message) }
    static func state(_ message: String) -> BluetoothError { BluetoothError(name: "InvalidStateError", message: message) }
    static func security(_ message: String) -> BluetoothError { BluetoothError(name: "SecurityError", message: message) }
    static func notFound(_ message: String) -> BluetoothError { BluetoothError(name: "NotFoundError", message: message) }
    static func network(_ message: String) -> BluetoothError { BluetoothError(name: "NetworkError", message: message) }
    static func notSupported(_ message: String) -> BluetoothError { BluetoothError(name: "NotSupportedError", message: message) }
    static func notAllowed(_ message: String) -> BluetoothError { BluetoothError(name: "NotAllowedError", message: message) }
}

enum BluetoothUUID {
    /// The lowercase 128-bit form, or nil. Pages send this form (BluetoothUUID resolves
    /// names and aliases before anything crosses); this is the check that they did.
    static func canonical(_ value: Any?) -> String? {
        guard let text = value as? String, text.count == 36,
              text.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil else { return nil }
        return text
    }

    static func alias(_ short: UInt32) -> String { String(format: "%08x-0000-1000-8000-00805f9b34fb", short) }

    /// CoreBluetooth's short forms (`180D`, `FFE0FFE1`) widened to the 128-bit one.
    static func from(_ uuid: CBUUID) -> String {
        let text = uuid.uuidString.lowercased()
        if text.count == 4 || text.count == 8, let short = UInt32(text, radix: 16) { return alias(short) }
        return text
    }
}

/// Chromium's GATT blocklist (the Web Bluetooth CG's `gatt_blocklist.txt`): services that
/// would let a page act as a keyboard or a security key or reflash a device, and the few
/// characteristics and descriptors that identify a person or would break pairing.
enum BluetoothBlocklist {
    enum Rule: Sendable { case all, reads, writes }

    static let services: [String: Rule] = [
        BluetoothUUID.alias(0x1812): .all,                          // Human Interface Device
        "00001530-1212-efde-1523-785feabcd123": .all,               // Nordic legacy DFU
        "f000ffc0-0451-4000-b000-000000000000": .all,               // TI OAD
        BluetoothUUID.alias(0x00060000): .all,                      // Nordic secure DFU
        BluetoothUUID.alias(0xFFFD): .all,                          // FIDO
    ]
    static let characteristics: [String: Rule] = [
        BluetoothUUID.alias(0x2A02): .writes,                       // peripheral privacy flag
        BluetoothUUID.alias(0x2A03): .all,                          // reconnection address
        BluetoothUUID.alias(0x2A25): .all,                          // serial number string
    ]
    static let descriptors: [String: Rule] = [
        BluetoothUUID.alias(0x2902): .writes,                       // client characteristic configuration
        BluetoothUUID.alias(0x2903): .writes,                       // server characteristic configuration
    ]

    static func blocks(_ rule: Rule?, write: Bool) -> Bool {
        switch rule {
        case .all: true
        case .reads: !write
        case .writes: write
        case nil: false
        }
    }

    /// iBeacon frames (Apple's company id, then 02 15) name a place, not a device: Chromium
    /// refuses any filter that could match one. A filter can unless a byte of its first two,
    /// under its mask, rules 02 15 out; an empty prefix matches everything Apple sends.
    static func blocksManufacturer(company: Int, prefix: Data, mask: Data? = nil) -> Bool {
        guard company == 0x004C else { return false }
        let mask = mask.map(Array.init) ?? Array(repeating: 0xff, count: prefix.count)
        return zip(zip(prefix, mask), [0x02, 0x15] as [UInt8]).allSatisfy { pair, beacon in pair.0 & pair.1 == beacon & pair.1 }
    }
}

/// One peripheral the radio heard, as the chooser and filters see it.
struct BluetoothAdvertisement: Equatable, Sendable {
    /// CoreBluetooth's id for it: stable for this app, never shown to a page.
    let id: UUID
    var name: String?
    var services: [String] = []
    var manufacturer: [Int: Data] = [:]

    var label: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown or Unsupported Device" }
}

/// A service, characteristic or descriptor of one connected peripheral. `instance` is the
/// radio layer's handle for it; it means nothing outside the connection that found it.
struct BluetoothAttribute: Equatable, Sendable {
    let instance: UInt64
    let uuid: String
    /// A characteristic's properties, in the Bluetooth Core order: broadcast, read, write
    /// without response, write, notify, indicate, signed writes, extended (reliable write and
    /// writable auxiliaries are bits 8 and 9).
    var properties: UInt16 = 0
}

enum BluetoothEvent: Sendable {
    case found(BluetoothAdvertisement)
    case disconnected(UUID)
    case value(UUID, UInt64, Data)
    case availability(Bool)
}

/// The radio, as WebBluetooth.swift uses it. The fixtures have one of their own. Nothing
/// here is reached until a page has been granted a device or the user asked to pick one,
/// because the first use of CoreBluetooth is what makes macOS ask about Bluetooth.
@MainActor protocol BluetoothBackend: AnyObject {
    var onEvent: ((BluetoothEvent) -> Void)? { get set }
    /// Whether Bluetooth may be usable, without asking macOS anything.
    var available: Bool { get }
    func startScan()
    /// The chooser closed. What the radio heard of peripherals not in `keeping` may go.
    func stopScan(keeping: Set<UUID>)
    func connect(_ id: UUID) async -> Bool
    func disconnect(_ id: UUID)
    func services(_ id: UUID) async -> [BluetoothAttribute]?
    func characteristics(_ id: UUID, service: UInt64) async -> [BluetoothAttribute]?
    func descriptors(_ id: UUID, characteristic: UInt64) async -> [BluetoothAttribute]?
    func read(_ id: UUID, _ attribute: UInt64) async -> Data?
    func write(_ id: UUID, _ attribute: UInt64, _ data: Data, withResponse: Bool) async -> Bool
    func notify(_ id: UUID, _ characteristic: UInt64, _ on: Bool) async -> Bool
}

/// CoreBluetooth on the main queue. Every delegate callback answers the oldest call
/// waiting for it; CoreBluetooth answers each attribute's requests in order.
@MainActor final class CoreBluetoothBackend: NSObject, BluetoothBackend {
    var onEvent: ((BluetoothEvent) -> Void)?
    private var central: CBCentralManager?
    private var scanning = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var attributes: [UInt64: (peripheral: UUID, attribute: CBAttribute)] = [:]
    private var instances: [ObjectIdentifier: UInt64] = [:]
    private var next: UInt64 = 0
    private var powered: [CheckedContinuation<Bool, Never>] = []
    private var connecting: [UUID: [CheckedContinuation<Bool, Never>]] = [:]
    /// Each connection attempt's id, for its timeout to know it is still the one waiting.
    private var attempts: [UUID: UUID] = [:]
    /// Peripherals we cancelled: their late `didDisconnect` is that cancel's, already handled,
    /// and must not take down a connection another document has started since.
    private var cancelled: Set<UUID> = []
    /// How long a connection attempt may take, as in Chromium's.
    static let connectTimeout: Duration = .seconds(30)
    private var waiting: [String: [(peripheral: UUID, done: (Any?) -> Void)]] = [:]

    /// macOS ends a process that touches CoreBluetooth without saying why in its Info.plist,
    /// which an unbundled `swift build` has none of.
    private let described = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil

    var available: Bool {
        guard described, ![.denied, .restricted].contains(CBCentralManager.authorization) else { return false }
        guard let central else { return true }
        return central.state == .poweredOn || central.state == .unknown || central.state == .resetting
    }

    /// The manager, created on first use: that is when macOS asks the user about Bluetooth.
    private func ready() async -> CBCentralManager? {
        guard described else { return nil }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        guard let central else { return nil }
        if central.state == .unknown || central.state == .resetting {
            _ = await withCheckedContinuation { powered.append($0) }
        }
        return central.state == .poweredOn ? central : nil
    }

    private func instance(_ attribute: CBAttribute, of peripheral: UUID) -> UInt64 {
        if let known = instances[ObjectIdentifier(attribute)] { return known }
        next += 1
        instances[ObjectIdentifier(attribute)] = next
        attributes[next] = (peripheral, attribute)
        return next
    }

    /// CoreBluetooth's objects are not Sendable; they never leave the main actor, only this box does.
    private struct Answer: @unchecked Sendable { let value: Any? }

    private func wait<T>(_ key: String, peripheral: UUID, start: () -> Void) async -> T? {
        let answer = await withCheckedContinuation { (done: CheckedContinuation<Answer, Never>) in
            waiting[key, default: []].append((peripheral, { done.resume(returning: Answer(value: $0)) }))
            start()
        }
        return answer.value as? T
    }

    private func answerAll(_ key: String) {
        waiting.removeValue(forKey: key)?.forEach { $0.done(nil) }
    }

    /// A known attribute's instance, never a new one: a callback after `lost` must not
    /// leave an entry behind.
    private func known(_ attribute: CBAttribute) -> UInt64? { instances[ObjectIdentifier(attribute)] }

    private func answer(_ key: String, _ value: Any?) {
        guard var queue = waiting[key], !queue.isEmpty else { return }
        let first = queue.removeFirst()
        waiting[key] = queue.isEmpty ? nil : queue
        first.done(value)
    }

    func startScan() {
        scanning = true
        Task {
            guard let central = await ready(), scanning else { return }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func stopScan(keeping: Set<UUID>) {
        scanning = false
        central?.stopScan()
        // Everything the scan heard would otherwise stay for the life of the app.
        peripherals = peripherals.filter { id, peripheral in
            keeping.contains(id) || peripheral.state != .disconnected || connecting[id] != nil
        }
    }

    func connect(_ id: UUID) async -> Bool {
        guard let central = await ready(),
              let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return false }
        peripherals[id] = peripheral
        peripheral.delegate = self
        // Not while our own cancel is still on its way: the link is about to drop, so connect
        // again (CoreBluetooth reconnects once the cancel completes).
        if peripheral.state == .connected, !cancelled.contains(id) { return true }
        return await withCheckedContinuation { done in
            connecting[id, default: []].append(done)
            guard connecting[id]?.count == 1 else { return }
            central.connect(peripheral)
            let attempt = UUID()
            attempts[id] = attempt
            Task { [weak self] in
                try? await Task.sleep(for: Self.connectTimeout)
                guard let self, self.attempts[id] == attempt, self.connecting[id] != nil else { return }
                central.cancelPeripheralConnection(peripheral)
                self.cancelled.insert(id)
                self.attempts[id] = nil
                self.connecting.removeValue(forKey: id)?.forEach { $0.resume(returning: false) }
            }
        }
    }

    func disconnect(_ id: UUID) {
        if let peripheral = peripherals[id], peripheral.state != .disconnected {
            central?.cancelPeripheralConnection(peripheral)
            cancelled.insert(id)
        }
        lost(id)
    }

    /// Everything waiting on this peripheral fails, and its attributes are forgotten.
    private func lost(_ id: UUID) {
        attempts[id] = nil
        connecting.removeValue(forKey: id)?.forEach { $0.resume(returning: false) }
        for (key, queue) in waiting {
            let (gone, kept) = (queue.filter { $0.peripheral == id }, queue.filter { $0.peripheral != id })
            waiting[key] = kept.isEmpty ? nil : kept
            gone.forEach { $0.done(nil) }
        }
        for (key, entry) in attributes where entry.peripheral == id {
            attributes.removeValue(forKey: key)
            instances.removeValue(forKey: ObjectIdentifier(entry.attribute))
        }
    }

    func services(_ id: UUID) async -> [BluetoothAttribute]? {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { return nil }
        let found: [CBService]? = await wait("services." + id.uuidString, peripheral: id) { peripheral.discoverServices(nil) }
        // Lost while this task waited to resume: nothing new may be numbered for it.
        guard peripherals[id]?.state == .connected else { return nil }
        return found?.map { BluetoothAttribute(instance: instance($0, of: id), uuid: BluetoothUUID.from($0.uuid)) }
    }

    func characteristics(_ id: UUID, service: UInt64) async -> [BluetoothAttribute]? {
        guard let peripheral = peripherals[id], let service = attributes[service]?.attribute as? CBService else { return nil }
        let found: [CBCharacteristic]? = await wait("characteristics.\(instance(service, of: id))", peripheral: id) {
            peripheral.discoverCharacteristics(nil, for: service)
        }
        guard peripherals[id]?.state == .connected else { return nil }
        return found?.map {
            BluetoothAttribute(instance: instance($0, of: id), uuid: BluetoothUUID.from($0.uuid),
                               properties: UInt16(truncatingIfNeeded: $0.properties.rawValue & 0xff))
        }
    }

    func descriptors(_ id: UUID, characteristic: UInt64) async -> [BluetoothAttribute]? {
        guard let peripheral = peripherals[id], let characteristic = attributes[characteristic]?.attribute as? CBCharacteristic else { return nil }
        let found: [CBDescriptor]? = await wait("descriptors.\(instance(characteristic, of: id))", peripheral: id) {
            peripheral.discoverDescriptors(for: characteristic)
        }
        guard peripherals[id]?.state == .connected else { return nil }
        return found?.map { BluetoothAttribute(instance: instance($0, of: id), uuid: BluetoothUUID.from($0.uuid)) }
    }

    func read(_ id: UUID, _ attribute: UInt64) async -> Data? {
        guard let peripheral = peripherals[id], let target = attributes[attribute]?.attribute else { return nil }
        return await wait("read.\(attribute)", peripheral: id) {
            if let characteristic = target as? CBCharacteristic { peripheral.readValue(for: characteristic) }
            else if let descriptor = target as? CBDescriptor { peripheral.readValue(for: descriptor) }
        }
    }

    func write(_ id: UUID, _ attribute: UInt64, _ data: Data, withResponse: Bool) async -> Bool {
        guard let peripheral = peripherals[id], let target = attributes[attribute]?.attribute else { return false }
        if let characteristic = target as? CBCharacteristic, !withResponse {
            // No answer comes for these; the radio's queue is the only thing that can say no.
            // A full queue drains: wait for it, a little.
            if !peripheral.canSendWriteWithoutResponse {
                let key = "ready." + id.uuidString
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.answerAll(key)
                }
                let _: Bool? = await wait(key, peripheral: id) {}
                timeout.cancel()
                guard peripherals[id] === peripheral, peripheral.canSendWriteWithoutResponse else { return false }
            }
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return true
        }
        let ok: Bool? = await wait("write.\(attribute)", peripheral: id) {
            if let characteristic = target as? CBCharacteristic { peripheral.writeValue(data, for: characteristic, type: .withResponse) }
            else if let descriptor = target as? CBDescriptor { peripheral.writeValue(data, for: descriptor) }
        }
        return ok == true
    }

    func notify(_ id: UUID, _ characteristic: UInt64, _ on: Bool) async -> Bool {
        guard let peripheral = peripherals[id], let target = attributes[characteristic]?.attribute as? CBCharacteristic else { return false }
        let ok: Bool? = await wait("notify.\(characteristic)", peripheral: id) { peripheral.setNotifyValue(on, for: target) }
        return ok == true
    }
}

extension CoreBluetoothBackend: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown, central.state != .resetting else { return }
        let waiting = powered
        powered = []
        waiting.forEach { $0.resume(returning: central.state == .poweredOn) }
        if central.state != .poweredOn { for id in Array(peripherals.keys) { lost(id); onEvent?(.disconnected(id)) } }
        if central.state == .poweredOn, scanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
        onEvent?(.availability(available))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        var found = BluetoothAdvertisement(id: peripheral.identifier,
                                           name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name)
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        found.services = uuids.map(BluetoothUUID.from)
        if let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, data.count >= 2 {
            found.manufacturer[Int(data[data.startIndex]) | Int(data[data.startIndex + 1]) << 8] = data.dropFirst(2)
        }
        onEvent?(.found(found))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelled.remove(peripheral.identifier)
        attempts[peripheral.identifier] = nil
        connecting.removeValue(forKey: peripheral.identifier)?.forEach { $0.resume(returning: true) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        attempts[peripheral.identifier] = nil
        connecting.removeValue(forKey: peripheral.identifier)?.forEach { $0.resume(returning: false) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Our own cancel, already handled by `disconnect`: a connect begun since must survive it.
        if cancelled.remove(peripheral.identifier) != nil { return }
        lost(peripheral.identifier)
        onEvent?(.disconnected(peripheral.identifier))
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        answer("services." + peripheral.identifier.uuidString, error == nil ? peripheral.services ?? [] : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let key = known(service) else { return }
        answer("characteristics.\(key)", error == nil ? service.characteristics ?? [] : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = known(characteristic) else { return }
        answer("descriptors.\(key)", error == nil ? characteristic.descriptors ?? [] : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = known(characteristic) else { return }
        let value = error == nil ? characteristic.value ?? Data() : nil
        // A read's answer and a notification look the same: a pending read takes it, and
        // whoever subscribed hears it too.
        let read = waiting["read.\(key)"]?.isEmpty == false
        if read { answer("read.\(key)", value) }
        if let value, !read || characteristic.isNotifying { onEvent?(.value(peripheral.identifier, key, value)) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        let value: Data? = switch descriptor.value {
        case let data as Data: data
        case let text as String: Data(text.utf8)
        case let number as NSNumber: withUnsafeBytes(of: number.uint16Value.littleEndian) { Data($0) }
        default: Data()
        }
        guard let key = known(descriptor) else { return }
        answer("read.\(key)", error == nil ? value : nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = known(characteristic) else { return }
        answer("write.\(key)", error == nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        guard let key = known(descriptor) else { return }
        answer("write.\(key)", error == nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let key = known(characteristic) else { return }
        answer("notify.\(key)", error == nil)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        answerAll("ready." + peripheral.identifier.uuidString)
    }
}
