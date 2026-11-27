import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// The native half of WebUSB: what a device's descriptors say, which devices and interfaces
/// a page may never touch, which devices this Mac has, and one open device. Nothing here
/// knows about pages, origins or grants; see WebUSB.swift for those.

/// What a page is told when something fails: a DOMException name (or `TypeError`) and text.
struct USBError: Error, Equatable, Sendable {
    let name: String
    let message: String

    static func type(_ message: String) -> USBError { USBError(name: "TypeError", message: message) }
    static func state(_ message: String) -> USBError { USBError(name: "InvalidStateError", message: message) }
    static func security(_ message: String) -> USBError { USBError(name: "SecurityError", message: message) }
    static func notFound(_ message: String) -> USBError { USBError(name: "NotFoundError", message: message) }
    static func network(_ message: String) -> USBError { USBError(name: "NetworkError", message: message) }
    static func notSupported(_ message: String) -> USBError { USBError(name: "NotSupportedError", message: message) }
}

struct USBEndpoint: Equatable, Sendable {
    /// The address: the number in the low four bits, 0x80 for IN.
    let address: UInt8
    /// bmAttributes' low two bits: 0 control, 1 isochronous, 2 bulk, 3 interrupt.
    let kind: UInt8
    let packetSize: Int

    var number: UInt8 { address & 0x0f }
    var isIn: Bool { address & 0x80 != 0 }
    var json: [String: Any] {
        ["endpointNumber": Int(number), "direction": isIn ? "in" : "out",
         "type": ["control", "isochronous", "bulk", "interrupt"][Int(kind & 3)], "packetSize": packetSize]
    }
}

struct USBAlternate: Equatable, Sendable {
    let setting: UInt8
    let interfaceClass: UInt8
    let subclass: UInt8
    let `protocol`: UInt8
    var endpoints: [USBEndpoint] = []

    var json: [String: Any] {
        ["alternateSetting": Int(setting), "interfaceClass": Int(interfaceClass), "interfaceSubclass": Int(subclass),
         "interfaceProtocol": Int(`protocol`), "interfaceName": NSNull(), "endpoints": endpoints.map(\.json)]
    }
}

struct USBInterface: Equatable, Sendable {
    let number: UInt8
    var alternates: [USBAlternate]

    /// Chromium's rule: an interface any of whose alternates is one of these classes is the
    /// system's (the audio, keyboard, disk, card reader, camera or Bluetooth radio it is),
    /// and no page may claim it or send it requests.
    var isProtected: Bool { alternates.contains { USBBlocklist.protectedClasses.contains($0.interfaceClass) } }
    var json: [String: Any] { ["interfaceNumber": Int(number), "alternates": alternates.map(\.json)] }
}

struct USBConfiguration: Equatable, Sendable {
    let value: UInt8
    var interfaces: [USBInterface]

    var json: [String: Any] {
        ["configurationValue": Int(value), "configurationName": NSNull(), "interfaces": interfaces.map(\.json)]
    }

    /// One configuration descriptor with everything after it (`wTotalLength` bytes), as
    /// `GET_DESCRIPTOR` returns it. Nil when it is not one; whatever is malformed after a
    /// good header ends the walk there rather than failing the device.
    init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes[1] == 2 else { return nil }
        value = bytes[5]
        interfaces = []
        let total = min(bytes.count, Int(bytes[2]) | Int(bytes[3]) << 8)
        var at = Int(bytes[0])
        var current: (interface: Int, alternate: Int)?
        while at + 2 <= total {
            let length = Int(bytes[at]), type = bytes[at + 1]
            guard length >= 2, at + length <= total else { break }
            if type == 4, length >= 9 {
                let number = bytes[at + 2]
                let alternate = USBAlternate(setting: bytes[at + 3], interfaceClass: bytes[at + 5],
                                             subclass: bytes[at + 6], protocol: bytes[at + 7])
                if let i = interfaces.firstIndex(where: { $0.number == number }) {
                    interfaces[i].alternates.append(alternate)
                    current = (i, interfaces[i].alternates.count - 1)
                } else {
                    interfaces.append(USBInterface(number: number, alternates: [alternate]))
                    current = (interfaces.count - 1, 0)
                }
            } else if type == 5, length >= 7, let current {
                let size = Int(bytes[at + 4]) | Int(bytes[at + 5]) << 8
                // Bits 11-12 are extra transactions per microframe, not bytes per packet.
                interfaces[current.interface].alternates[current.alternate].endpoints.append(
                    USBEndpoint(address: bytes[at + 2], kind: bytes[at + 3] & 3, packetSize: size & 0x7ff))
            }
            at += length
        }
    }

    init(value: UInt8, interfaces: [USBInterface]) {
        self.value = value
        self.interfaces = interfaces
    }
}

/// Chromium's WebUSB rules (`usb_blocklist.cc`, and the protected classes in Blink's
/// `usb_device.cc`): a page must not be able to talk to a security key, nor to the part of
/// a device macOS already uses as a keyboard, disk, microphone or camera.
enum USBBlocklist {
    /// Audio, HID, mass storage, smart card, video, audio/video, wireless controller.
    static let protectedClasses: Set<UInt8> = [0x01, 0x03, 0x08, 0x0B, 0x0E, 0x10, 0xE0]

    static func isBlocked(vendorID: Int, productID: Int) -> Bool {
        HIDBlocklist.securityKeys.contains { $0.vendorID == vendorID && $0.productID == productID }
    }
}

/// One USB device: what the registry and its descriptors say about it.
struct USBDeviceInfo: Equatable, Sendable {
    /// The same physical device again: a serial number names it in any socket; without one
    /// it is the same model at the same place.
    struct Identity: Hashable, Codable, Sendable {
        var vendorID: Int
        var productID: Int
        var serialNumber: String
        var locationID: Int
    }

    /// The IORegistry entry: unique while the device stays attached, never shown to a page.
    let entryID: UInt64
    let vendorID: Int
    let productID: Int
    var usbVersion = 0x0200
    var deviceClass: UInt8 = 0
    var subclass: UInt8 = 0
    var `protocol`: UInt8 = 0
    var deviceVersion = 0
    var manufacturer = ""
    var product = ""
    var serialNumber = ""
    var locationID = 0
    var configurations: [USBConfiguration] = []
    /// The configuration macOS set, or nil while the device is unconfigured.
    var activeConfiguration: UInt8?

    var identity: Identity {
        Identity(vendorID: vendorID, productID: productID, serialNumber: serialNumber,
                 locationID: serialNumber.isEmpty ? locationID : 0)
    }

    /// The chooser's and Site Controls' name for it.
    var label: String {
        product.isEmpty ? String(format: "Unknown Device (%04x:%04x)", vendorID, productID) : product
    }

    /// Never offered to a page: Chromium's list of security keys.
    var isBlocked: Bool { USBBlocklist.isBlocked(vendorID: vendorID, productID: productID) }

    func configuration(_ value: UInt8?) -> USBConfiguration? {
        value.flatMap { value in configurations.first { $0.value == value } }
    }

    func json(id: String, active: UInt8?) -> [String: Any] {
        func bcd(_ value: Int) -> [Int] { [value >> 8 & 0xff, value >> 4 & 0xf, value & 0xf] }
        return ["id": id, "usbVersion": bcd(usbVersion), "deviceVersion": bcd(deviceVersion),
                "deviceClass": Int(deviceClass), "deviceSubclass": Int(subclass), "deviceProtocol": Int(`protocol`),
                "vendorId": vendorID, "productId": productID,
                "manufacturerName": manufacturer.isEmpty ? NSNull() : manufacturer,
                "productName": product.isEmpty ? NSNull() : product,
                "serialNumber": serialNumber.isEmpty ? NSNull() : serialNumber,
                "configuration": active.map { Int($0) } ?? NSNull(),
                "configurations": configurations.map(\.json)]
    }
}

/// The USB devices attached to this Mac, kept current while anything is listening.
@MainActor final class USBDevices: ObservableObject {
    static let shared = USBDevices()
    @Published private(set) var devices: [USBDeviceInfo] = []
    /// Called after `devices` changes: a device was plugged in or pulled.
    var onChange: (() -> Void)?
    #if DEBUG
    /// Fixtures stand in for hardware.
    var listForTesting: (() -> [USBDeviceInfo])?
    #endif
    private var started = false
    /// Descriptors read once per attachment; the registry id changes when it is replugged.
    private var described: [UInt64: (configurations: [USBConfiguration], active: UInt8?)] = [:]

    func start() {
        guard !started else { return }
        started = true
        #if DEBUG
        if listForTesting != nil { return refresh() }
        #endif
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let changed: IOServiceMatchingCallback = { _, iterator in
            USBDevices.drain(iterator)
            MainActor.assumeIsolated { USBDevices.shared.refresh() }
        }
        // The iterators are kept for the life of the app: releasing one ends its notification.
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching(kIOUSBHostDeviceClassName),
                                                changed, nil, &iterator) == KERN_SUCCESS {
                Self.drain(iterator)    // arms it
            }
        }
        refresh()
    }

    func refresh() {
        #if DEBUG
        let found = listForTesting?() ?? list()
        #else
        let found = list()
        #endif
        guard found != devices else { return }
        devices = found
        onChange?()
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    /// Every USB device IOKit lists, in registry order. Reads the registry, and each new
    /// device's configuration descriptors from the copy macOS keeps: that makes a device user
    /// client for it, but never opens the device or sends it a request.
    private func list() -> [USBDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [USBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            func int(_ key: String) -> Int { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int ?? 0 }
            func string(_ key: String) -> String { IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String ?? "" }
            var info = USBDeviceInfo(entryID: entryID, vendorID: int(kUSBVendorID), productID: int(kUSBProductID))
            info.usbVersion = int("bcdUSB")
            info.deviceClass = UInt8(truncatingIfNeeded: int(kUSBDeviceClass))
            info.subclass = UInt8(truncatingIfNeeded: int(kUSBDeviceSubClass))
            info.protocol = UInt8(truncatingIfNeeded: int(kUSBDeviceProtocol))
            info.deviceVersion = int(kUSBDeviceReleaseNumber)
            info.manufacturer = string(kUSBVendorString)
            info.product = string(kUSBProductString)
            info.serialNumber = string(kUSBSerialNumberString)
            info.locationID = int(kUSBDevicePropertyLocationID)
            if described[entryID] == nil { described[entryID] = USBConnection.describe(service) }
            info.configurations = described[entryID]?.configurations ?? []
            info.activeConfiguration = described[entryID]?.active
            found.append(info)
        }
        let present = Set(found.map(\.entryID))
        described = described.filter { present.contains($0.key) }
        return found.sorted { $0.entryID < $1.entryID }
    }

    /// A page selected a configuration: what was read at attach time is stale now.
    func configurationChanged(entryID: UInt64, to value: UInt8?) {
        described[entryID]?.active = value
        if let index = devices.firstIndex(where: { $0.entryID == entryID }) { devices[index].activeConfiguration = value }
    }
}

/// A control transfer's setup packet, as the page described it.
struct USBSetup: Equatable, Sendable {
    /// bmRequestType without its direction bit: type in bits 5-6, recipient in 0-4.
    var requestType: UInt8
    var request: UInt8
    var value: UInt16
    var index: UInt16

    var recipient: UInt8 { requestType & 0x1f }
    var kind: UInt8 { requestType >> 5 & 3 }
}

/// How a transfer ended, as WebUSB names it; nil status is an error the page sees as one.
struct USBTransfer: Equatable, Sendable {
    enum Status: String, Sendable { case ok, stall, babble }
    var status: Status?
    var data = Data()
    var written = 0

    static let failed = USBTransfer(status: nil)
}

/// What one open device has in flight, in calls and in buffered bytes. A page that outruns
/// a stalled device is refused rather than queueing without bound.
struct USBBudget: Equatable, Sendable {
    static let maxPending = 16
    static let maxBytes = 16 << 20
    private(set) var pending = 0
    private(set) var bytes = 0

    mutating func admit(_ bytes: Int) -> Bool {
        guard pending < Self.maxPending, bytes <= Self.maxBytes - self.bytes else { return false }
        pending += 1
        self.bytes += bytes
        return true
    }

    mutating func done(_ bytes: Int) {
        pending -= 1
        self.bytes -= bytes
    }
}

/// One open device, as WebUSB.swift uses it. The fixtures have one of their own. Every
/// call has been checked against the device's descriptors and claims before it gets here.
protocol USBTransport: AnyObject, Sendable {
    /// The configuration the device reported when it was opened, or nil while unconfigured.
    var configuration: UInt8? { get }
    func selectConfiguration(_ value: UInt8) async -> Bool
    func claim(_ interface: UInt8) async -> Bool
    func release(_ interface: UInt8) async -> Bool
    func selectAlternate(_ interface: UInt8, setting: UInt8) async -> Bool
    /// IN when `data` is nil (reading up to `length` bytes), OUT otherwise.
    func control(_ setup: USBSetup, data: Data?, length: Int) async -> USBTransfer
    /// `endpoint` is the address, direction bit included.
    func transfer(endpoint: UInt8, data: Data?, length: Int) async -> USBTransfer
    func clearHalt(endpoint: UInt8) async -> Bool
    func reset() async -> Bool
    func close()
}

/// IOUSBLib: the user clients the App Sandbox lets `com.apple.security.device.usb` open
/// (`IOUSBDeviceUserClientV2` and `IOUSBInterfaceUserClientV3` in application.sb; the
/// IOUSBHost framework's are not on that list).
private enum USBLib {
    // Constant UUIDs are never freed or changed; CFUUID just is not marked Sendable.
    typealias Device = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface650>?>
    typealias Interface = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface650>?>

    nonisolated(unsafe) static let deviceClient = CFUUIDGetConstantUUIDWithBytes(nil, 0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4,
                                                             0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    nonisolated(unsafe) static let interfaceClient = CFUUIDGetConstantUUIDWithBytes(nil, 0x2d, 0x97, 0x86, 0xc6, 0x9e, 0xf3, 0x11, 0xD4,
                                                                0xad, 0x51, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    nonisolated(unsafe) static let plugIn = CFUUIDGetConstantUUIDWithBytes(nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
                                                       0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    nonisolated(unsafe) static let device650 = CFUUIDGetConstantUUIDWithBytes(nil, 0x4A, 0xAC, 0x1B, 0x2E, 0x24, 0xC2, 0x47, 0x6A,
                                                          0x96, 0x4D, 0x91, 0x33, 0x35, 0x34, 0xF2, 0xCC)
    nonisolated(unsafe) static let interface650 = CFUUIDGetConstantUUIDWithBytes(nil, 0x08, 0x15, 0x1A, 0x89, 0x80, 0x81, 0x40, 0x87,
                                                             0x8F, 0x9E, 0x0A, 0xFE, 0xDF, 0xDB, 0x5D, 0x9F)

    /// The COM interface `id` of `service`'s user client of type `type`; the caller releases it.
    static func open<T>(_ service: io_service_t, type: CFUUID?, id: CFUUID?) -> UnsafeMutablePointer<UnsafeMutablePointer<T>?>? {
        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(service, type, plugIn, &plugin, &score) == kIOReturnSuccess,
              let plugin, let vtable = plugin.pointee?.pointee else { return nil }
        defer { _ = vtable.Release(plugin) }
        var raw: LPVOID?
        guard vtable.QueryInterface(plugin, CFUUIDGetUUIDBytes(id), &raw) == S_OK, let raw else { return nil }
        return raw.assumingMemoryBound(to: UnsafeMutablePointer<T>?.self)
    }
}

/// One device a page opened, through IOUSBLib. Each blocking call runs on a queue of its
/// own so a `transferIn` waiting for data does not hold up a `transferOut` (WebUSB transfers
/// have no timeout). Closing aborts what is waiting and lets go once the last call returns.
final class USBConnection: USBTransport, @unchecked Sendable {
    let configuration: UInt8?

    private let device: USBLib.Device
    /// Whether macOS let us have the device itself; a composite device's driver may keep it,
    /// which leaves control transfers and its interfaces usable but not its configuration.
    private let owned: Bool
    private let lock = NSLock()
    private var state = State()
    private let group = DispatchGroup()

    private struct State {
        var closed = false
        var budget = USBBudget()
        /// Claimed interfaces, and their pipes by endpoint address.
        var interfaces: [UInt8: (interface: USBLib.Interface, pipes: [UInt8: UInt8])] = [:]
    }

    /// The configuration descriptors and the active configuration, from the copy macOS
    /// keeps: no request goes to the device and the device is not opened.
    static func describe(_ service: io_service_t) -> (configurations: [USBConfiguration], active: UInt8?)? {
        guard let device: USBLib.Device = USBLib.open(service, type: USBLib.deviceClient, id: USBLib.device650),
              let vtable = device.pointee?.pointee else { return nil }
        defer { _ = vtable.Release(device) }
        return (configurations(device), active(device))
    }

    private static func configurations(_ device: USBLib.Device) -> [USBConfiguration] {
        let vtable = device.pointee!.pointee
        var count: UInt8 = 0
        _ = vtable.GetNumberOfConfigurations(device, &count)
        var configurations: [USBConfiguration] = []
        for index in 0..<count {
            var descriptor: IOUSBConfigurationDescriptorPtr?
            guard vtable.GetConfigurationDescriptorPtr(device, index, &descriptor) == kIOReturnSuccess, let descriptor else { continue }
            let length = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
            if let parsed = USBConfiguration(Data(bytes: descriptor, count: max(length, 9))) { configurations.append(parsed) }
        }
        return configurations
    }

    private static func active(_ device: USBLib.Device) -> UInt8? {
        var active: UInt8 = 0
        return device.pointee!.pointee.GetConfiguration(device, &active) == kIOReturnSuccess && active != 0 ? active : nil
    }

    /// Nil when the device is gone or the sandbox refuses the user client.
    static func open(_ info: USBDeviceInfo) async -> USBConnection? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(info.entryID))
                guard service != 0 else { return done.resume(returning: nil) }
                defer { IOObjectRelease(service) }
                guard let device: USBLib.Device = USBLib.open(service, type: USBLib.deviceClient, id: USBLib.device650),
                      let vtable = device.pointee?.pointee else { return done.resume(returning: nil) }
                // Exclusive access is refused when a driver holds the whole device; libusb
                // carries on the same way, with what does not need it.
                let owned = vtable.USBDeviceOpen(device) == kIOReturnSuccess
                // The device's own answer now, not what was read when it was plugged in.
                done.resume(returning: USBConnection(device, owned: owned, configuration: active(device)))
            }
        }
    }

    private init(_ device: USBLib.Device, owned: Bool, configuration: UInt8?) {
        self.device = device
        self.owned = owned
        self.configuration = configuration
    }

    private var vtable: IOUSBDeviceInterface650 { device.pointee!.pointee }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    /// One blocking call, off the main thread, and none once closed. `bytes` is what it buffers.
    private func run<T: Sendable>(_ refused: T, bytes: Int = 0, _ call: @escaping @Sendable () -> T) async -> T {
        let admitted = locked { state -> Bool in
            !state.closed && state.budget.admit(bytes)
        }
        guard admitted else { return refused }
        group.enter()
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let result = call()
                locked { $0.budget.done(bytes) }
                group.leave()
                done.resume(returning: result)
            }
        }
    }

    private static func status(_ result: IOReturn) -> USBTransfer.Status? {
        switch result {
        case kIOReturnSuccess: .ok
        case IOReturn(bitPattern: 0xe000404f): .stall    // kIOUSBPipeStalled
        case kIOReturnOverrun: .babble
        default: nil
        }
    }

    func selectConfiguration(_ value: UInt8) async -> Bool {
        await run(false) { [self] in
            var current: UInt8 = 0
            if vtable.GetConfiguration(device, &current) == kIOReturnSuccess, current == value { return true }
            return owned && locked { $0.interfaces.isEmpty } && vtable.SetConfiguration(device, value) == kIOReturnSuccess
        }
    }

    func claim(_ number: UInt8) async -> Bool {
        await run(false) { [self] in
            var request = IOUSBFindInterfaceRequest(bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
                                                    bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
                                                    bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
                                                    bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))
            // Checked again against the device as it is now, every alternate of it: the bridge
            // checked its own copy of the descriptors, which a replug or reconfigure could stale.
            guard let active = Self.active(device),
                  let live = Self.configurations(device).first(where: { $0.value == active })?.interfaces.first(where: { $0.number == number }),
                  !live.isProtected else { return false }
            var iterator: io_iterator_t = 0
            guard vtable.CreateInterfaceIterator(device, &request, &iterator) == kIOReturnSuccess else { return false }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let interface: USBLib.Interface = USBLib.open(service, type: USBLib.interfaceClient, id: USBLib.interface650),
                      let table = interface.pointee?.pointee else { continue }
                var found: UInt8 = 0, kind: UInt8 = 0
                guard table.GetInterfaceNumber(interface, &found) == kIOReturnSuccess, found == number,
                      table.GetInterfaceClass(interface, &kind) == kIOReturnSuccess, !USBBlocklist.protectedClasses.contains(kind),
                      // Refused when a kernel driver has it: macOS is using it.
                      table.USBInterfaceOpen(interface) == kIOReturnSuccess else { _ = table.Release(interface); continue }
                let pipes = Self.pipes(interface)
                locked { $0.interfaces[number] = (interface, pipes) }
                return true
            }
            return false
        }
    }

    /// IOUSBLib numbers pipes 1… in the current alternate's order; a page names endpoints.
    private static func pipes(_ interface: USBLib.Interface) -> [UInt8: UInt8] {
        let table = interface.pointee!.pointee
        var count: UInt8 = 0
        _ = table.GetNumEndpoints(interface, &count)
        var out: [UInt8: UInt8] = [:]
        for pipe in UInt8(1)...max(count, 1) where count > 0 {
            var direction: UInt8 = 0, number: UInt8 = 0, kind: UInt8 = 0, interval: UInt8 = 0
            var size: UInt16 = 0
            guard table.GetPipeProperties(interface, pipe, &direction, &number, &kind, &size, &interval) == kIOReturnSuccess else { continue }
            out[number | (direction == UInt8(kUSBIn) ? 0x80 : 0)] = pipe
        }
        return out
    }

    func release(_ number: UInt8) async -> Bool {
        await run(false) { [self] in
            guard let claimed = locked({ $0.interfaces.removeValue(forKey: number) }) else { return false }
            let table = claimed.interface.pointee!.pointee
            _ = table.USBInterfaceClose(claimed.interface)
            _ = table.Release(claimed.interface)
            return true
        }
    }

    /// The claimed interface, retained so a `release` or `close` while the call runs cannot
    /// free it under the call; the caller releases it.
    private func retained(_ find: (State) -> (USBLib.Interface, UInt8)?) -> (USBLib.Interface, UInt8)? {
        locked { state in
            guard let found = find(state) else { return nil }
            _ = found.0.pointee!.pointee.AddRef(found.0)
            return found
        }
    }

    private func retained(endpoint: UInt8) -> (USBLib.Interface, UInt8)? {
        retained { state in
            state.interfaces.values.lazy.compactMap { claimed in claimed.pipes[endpoint].map { (claimed.interface, $0) } }.first
        }
    }

    func selectAlternate(_ number: UInt8, setting: UInt8) async -> Bool {
        await run(false) { [self] in
            guard let (interface, _) = retained({ state in state.interfaces[number].map { ($0.interface, 0) } }) else { return false }
            let table = interface.pointee!.pointee
            defer { _ = table.Release(interface) }
            guard table.SetAlternateInterface(interface, setting) == kIOReturnSuccess else { return false }
            let pipes = Self.pipes(interface)
            locked { state in if state.interfaces[number]?.interface == interface { state.interfaces[number]?.pipes = pipes } }
            return true
        }
    }

    func control(_ setup: USBSetup, data: Data?, length: Int) async -> USBTransfer {
        await run(.failed, bytes: data?.count ?? length) { [self] in
            let count = data?.count ?? length
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
            defer { buffer.deallocate() }
            data?.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: count)
            var request = IOUSBDevRequest(bmRequestType: setup.requestType | (data == nil ? 0x80 : 0), bRequest: setup.request,
                                          wValue: setup.value, wIndex: setup.index, wLength: UInt16(count),
                                          pData: buffer, wLenDone: 0)
            guard let status = Self.status(vtable.DeviceRequest(device, &request)) else { return .failed }
            let done = Int(request.wLenDone)
            return data == nil ? USBTransfer(status: status, data: Data(bytes: buffer, count: min(done, count)))
                : USBTransfer(status: status, written: done)
        }
    }

    func transfer(endpoint: UInt8, data: Data?, length: Int) async -> USBTransfer {
        await run(.failed, bytes: data?.count ?? length) { [self] in
            guard let (interface, pipe) = retained(endpoint: endpoint) else { return .failed }
            let table = interface.pointee!.pointee
            defer { _ = table.Release(interface) }
            if let data {
                // WritePipe does not write to the buffer; no copy is made for it.
                let result = data.withUnsafeBytes { table.WritePipe(interface, pipe, UnsafeMutableRawPointer(mutating: $0.baseAddress), UInt32($0.count)) }
                return Self.status(result).map { USBTransfer(status: $0, written: $0 == .ok ? data.count : 0) } ?? .failed
            }
            var bytes = Data(count: max(length, 1))
            var size = UInt32(length)
            let result = bytes.withUnsafeMutableBytes { table.ReadPipe(interface, pipe, $0.baseAddress, &size) }
            guard let status = Self.status(result) else { return .failed }
            bytes.count = Int(min(size, UInt32(length)))
            return USBTransfer(status: status, data: bytes)
        }
    }

    func clearHalt(endpoint: UInt8) async -> Bool {
        await run(false) { [self] in
            guard let (interface, pipe) = retained(endpoint: endpoint) else { return false }
            defer { _ = interface.pointee!.pointee.Release(interface) }
            return interface.pointee!.pointee.ClearPipeStallBothEnds(interface, pipe) == kIOReturnSuccess
        }
    }

    func reset() async -> Bool {
        await run(false) { [self] in owned && vtable.ResetDevice(device) == kIOReturnSuccess }
    }

    /// Aborts what is waiting, then gives every interface and the device back once the
    /// calls that were running have returned.
    func close() {
        // Under the lock: a `release` running now cannot free an interface mid-abort.
        let closing = locked { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            for claimed in state.interfaces.values {
                for pipe in claimed.pipes.values { _ = claimed.interface.pointee!.pointee.AbortPipe(claimed.interface, pipe) }
            }
            return true
        }
        guard closing else { return }
        group.notify(queue: .global()) { [self] in
            let left = locked { state in
                defer { state.interfaces = [:] }
                return Array(state.interfaces.values)
            }
            for claimed in left {
                _ = claimed.interface.pointee!.pointee.USBInterfaceClose(claimed.interface)
                _ = claimed.interface.pointee!.pointee.Release(claimed.interface)
            }
            if owned { _ = vtable.USBDeviceClose(device) }
            _ = vtable.Release(device)
        }
    }
}
