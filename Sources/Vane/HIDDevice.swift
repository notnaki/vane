import Foundation
import IOKit
import IOKit.hid
import Synchronization

/// The native half of WebHID: what a report descriptor says, which reports a page may never
/// touch, which HID interfaces this Mac has, and one open device. Nothing here knows about
/// pages, origins or grants; see WebHID.swift for those.

/// What a page is told when something fails: a DOMException name (or `TypeError`) and text.
struct HIDError: Error, Equatable, Sendable {
    let name: String
    let message: String

    static func type(_ message: String) -> HIDError { HIDError(name: "TypeError", message: message) }
    static func state(_ message: String) -> HIDError { HIDError(name: "InvalidStateError", message: message) }
    static func security(_ message: String) -> HIDError { HIDError(name: "SecurityError", message: message) }
    static func notAllowed(_ message: String) -> HIDError { HIDError(name: "NotAllowedError", message: message) }
}

enum HIDReportType: String, CaseIterable, Sendable { case input, output, feature }

/// One Input, Output or Feature main item, with the global and local state it was declared under.
struct HIDReportItem: Equatable, Sendable {
    /// The main item's data: bit 0 constant, 1 variable, 2 relative, 3 wrap, 4 non-linear,
    /// 5 no preferred state, 6 null state, 7 volatile, 8 buffered bytes.
    var flags: UInt32 = 0
    /// Each usage is its page in the high 16 bits and its id in the low 16.
    var usages: [UInt32] = []
    var usageMinimum: UInt32 = 0
    var usageMaximum: UInt32 = 0
    var logicalMinimum: Int32 = 0
    var logicalMaximum: Int32 = 0
    var physicalMinimum: Int32 = 0
    var physicalMaximum: Int32 = 0
    var unitExponent: UInt32 = 0
    var unit: UInt32 = 0
    var reportSize: UInt32 = 0
    var reportCount: UInt32 = 0

    var isRange: Bool { usageMinimum != usageMaximum }

    private static let unitSystems = [0: "none", 1: "si-linear", 2: "si-rotation", 3: "english-linear",
                                      4: "english-rotation", 0xF: "vendor-defined"]

    /// The spec's `HIDReportItem`, with the members Chrome sets.
    var json: [String: Any] {
        func bit(_ index: UInt32) -> Bool { flags >> index & 1 == 1 }
        /// A four-bit two's complement exponent.
        func exponent(_ nibble: UInt32) -> Int { nibble & 0xF >= 8 ? Int(nibble & 0xF) - 16 : Int(nibble & 0xF) }
        var out: [String: Any] = [
            "isAbsolute": !bit(2), "isArray": !bit(1), "isBufferedBytes": bit(8), "isConstant": bit(0),
            "isLinear": !bit(4), "isRange": isRange, "isVolatile": bit(7), "hasNull": bit(6),
            "hasPreferredState": !bit(5), "wrap": bit(3),
            "reportSize": Int(reportSize), "reportCount": Int(reportCount), "unitExponent": exponent(unitExponent),
            "logicalMinimum": Int(logicalMinimum), "logicalMaximum": Int(logicalMaximum),
            "physicalMinimum": Int(physicalMinimum), "physicalMaximum": Int(physicalMaximum),
            "unitSystem": Self.unitSystems[Int(unit & 0xF)] ?? "reserved",
            "unitFactorLengthExponent": exponent(unit >> 4), "unitFactorMassExponent": exponent(unit >> 8),
            "unitFactorTimeExponent": exponent(unit >> 12), "unitFactorTemperatureExponent": exponent(unit >> 16),
            "unitFactorCurrentExponent": exponent(unit >> 20), "unitFactorLuminousIntensityExponent": exponent(unit >> 24),
        ]
        if isRange {
            out["usageMinimum"] = Int(usageMinimum)
            out["usageMaximum"] = Int(usageMaximum)
        } else {
            out["usages"] = usages.map { Int($0) }
        }
        return out
    }
}

struct HIDReport: Equatable, Sendable {
    var id: UInt8
    var items: [HIDReportItem] = []

    var json: [String: Any] { ["reportId": Int(id), "items": items.map(\.json)] }
}

/// One collection. Its reports include those declared in the collections nested inside it.
struct HIDCollection: Equatable, Sendable {
    var usagePage: UInt16
    var usage: UInt16
    var type: UInt8
    var children: [HIDCollection] = []
    var input: [HIDReport] = []
    var output: [HIDReport] = []
    var feature: [HIDReport] = []

    func reports(_ type: HIDReportType) -> [HIDReport] {
        switch type {
        case .input: input
        case .output: output
        case .feature: feature
        }
    }

    /// The spec's `HIDCollectionInfo`.
    var json: [String: Any] {
        ["usagePage": Int(usagePage), "usage": Int(usage), "type": Int(type), "children": children.map(\.json),
         "inputReports": input.map(\.json), "outputReports": output.map(\.json), "featureReports": feature.map(\.json)]
    }
}

/// A parsed report descriptor (Device Class Definition for HID 1.11, section 6.2.2). The
/// reading of malformed descriptors follows Chromium's `HidCollection::BuildCollections`,
/// so a page sees the same `collections` here as it does there.
struct HIDDescriptor: Equatable, Sendable {
    var collections: [HIDCollection] = []

    /// Whether any report carries an id. Such a device prefixes every report with one.
    var usesReportIDs: Bool {
        collections.contains { collection in HIDReportType.allCases.contains { collection.reports($0).contains { $0.id != 0 } } }
    }

    /// The longest report of one type, in bytes, without its id.
    func maxBytes(_ type: HIDReportType) -> Int {
        var longest: UInt64 = 0
        for report in collections.flatMap({ $0.reports(type) }) {
            var bits: UInt64 = 0
            for item in report.items {
                let size = UInt64(item.reportSize) * UInt64(item.reportCount)
                // A report longer than 65535 bytes is not one any transport carries.
                guard size <= Self.maxReportBits, bits <= Self.maxReportBits - size else { bits = 0; break }
                bits += size
            }
            longest = max(longest, bits)
        }
        return Int((longest + 7) / 8)
    }

    private static let maxReportBits: UInt64 = 65535 * 8
    private static let maxDepth = 50

    /// Collections are built as a tree of references and copied out once it is complete.
    private final class Node {
        let usagePage: UInt16, usage: UInt16, type: UInt8
        weak var parent: Node?
        var children: [Node] = []
        var reports: [HIDReportType: [HIDReport]] = [:]
        init(usagePage: UInt16, usage: UInt16, type: UInt8, parent: Node?) {
            self.usagePage = usagePage; self.usage = usage; self.type = type; self.parent = parent
        }
        var value: HIDCollection {
            HIDCollection(usagePage: usagePage, usage: usage, type: type, children: children.map(\.value),
                          input: reports[.input] ?? [], output: reports[.output] ?? [], feature: reports[.feature] ?? [])
        }
    }

    private struct Globals {
        var usagePage: UInt32 = 0
        var item = HIDReportItem()
        /// The maxima as written: `25 FF` is 255 when the minimum is not negative, not -1.
        var logicalMaximum: UInt32 = 0, logicalMaximumSize = 0
        var physicalMaximum: UInt32 = 0, physicalMaximumSize = 0
    }

    /// A maximum read as unsigned when its minimum is not negative and it fits.
    private static func maximum(_ signed: Int32, raw: UInt32, size: Int, minimum: Int32) -> Int32 {
        guard minimum >= 0, signed < 0, size < 4 else { return signed }
        return Int32(raw)
    }

    init(collections: [HIDCollection] = []) { self.collections = collections }

    init(_ descriptor: Data) {
        let bytes = [UInt8](descriptor)
        var roots: [Node] = [], current: Node?
        var depth = 0
        // Empty until the first global item: Push and Pop do nothing before then.
        var globals: [Globals] = []
        var reportID: UInt8 = 0
        var usages: [UInt32] = [], usageMinimum: UInt32 = 0, usageMaximum: UInt32 = 0
        func resetLocals() { usages = []; usageMinimum = 0; usageMaximum = 0 }

        var at = 0
        while at < bytes.count {
            let header = bytes[at]
            if header == 0xFE {    // a long item: its length is the next byte, and it means nothing here
                guard at + 1 < bytes.count else { break }
                at += 3 + Int(bytes[at + 1])
                continue
            }
            let size = header & 3 == 3 ? 4 : Int(header & 3)
            var value: UInt32 = 0
            if at + 1 + size <= bytes.count {
                for index in 0..<size { value |= UInt32(bytes[at + 1 + index]) << (8 * UInt32(index)) }
            }
            at += 1 + size
            var signed: Int32 {
                switch size {
                case 1: Int32(Int8(truncatingIfNeeded: value))
                case 2: Int32(Int16(truncatingIfNeeded: value))
                default: Int32(bitPattern: value)
                }
            }
            /// A usage without a page of its own takes the global one.
            var usage: UInt32 {
                guard value <= 0xFFFF, let page = globals.last?.usagePage else { return value }
                return page << 16 | value
            }
            func global(_ change: (inout Globals) -> Void) {
                if globals.isEmpty { globals.append(Globals()) }
                change(&globals[globals.count - 1])
            }

            // The tag is four bits and the type two; together they name the item.
            switch header & 0xFC {
            case 0xA0:    // Collection
                depth += 1
                if depth <= Self.maxDepth {
                    let first = usages.first ?? 0
                    let page = first >> 16 != 0 ? first >> 16 : (globals.last?.usagePage ?? 0)
                    let node = Node(usagePage: UInt16(truncatingIfNeeded: page), usage: UInt16(truncatingIfNeeded: first),
                                    type: UInt8(truncatingIfNeeded: value), parent: current)
                    if let current { current.children.append(node) } else { roots.append(node) }
                    current = node
                }
                resetLocals()
            case 0xC0:    // End Collection
                if depth <= Self.maxDepth { current = current?.parent }
                if depth > 0 { depth -= 1 }
                resetLocals()
            case 0x80, 0x90, 0xB0:    // Input, Output, Feature
                let type: HIDReportType = header & 0xFC == 0x80 ? .input : header & 0xFC == 0x90 ? .output : .feature
                var item = globals.last?.item ?? HIDReportItem()
                if let top = globals.last {
                    item.logicalMaximum = Self.maximum(item.logicalMaximum, raw: top.logicalMaximum,
                                                       size: top.logicalMaximumSize, minimum: item.logicalMinimum)
                    item.physicalMaximum = Self.maximum(item.physicalMaximum, raw: top.physicalMaximum,
                                                        size: top.physicalMaximumSize, minimum: item.physicalMinimum)
                }
                item.flags = value
                item.usages = usages
                item.usageMinimum = usageMinimum
                item.usageMaximum = usageMaximum
                // A report belongs to the collection it is declared in and to every one around that.
                var node = current
                while let target = node {
                    var reports = target.reports[type] ?? []
                    if let index = reports.firstIndex(where: { $0.id == reportID }) { reports[index].items.append(item) }
                    else { reports.append(HIDReport(id: reportID, items: [item])) }
                    target.reports[type] = reports
                    node = target.parent
                }
                resetLocals()
            case 0xA4: if let top = globals.last { globals.append(top) }    // Push
            case 0xB4: if !globals.isEmpty { globals.removeLast() }         // Pop
            case 0x84:    // Report ID: 1 to 255, and not part of what Push saves
                if (1...255).contains(value) { reportID = UInt8(value) }
            case 0x04: global { $0.usagePage = value }
            case 0x14: global { $0.item.logicalMinimum = signed }
            case 0x24: global { $0.item.logicalMaximum = signed; $0.logicalMaximum = value; $0.logicalMaximumSize = size }
            case 0x34: global { $0.item.physicalMinimum = signed }
            case 0x44: global { $0.item.physicalMaximum = signed; $0.physicalMaximum = value; $0.physicalMaximumSize = size }
            case 0x54: global { $0.item.unitExponent = value }
            case 0x64: global { $0.item.unit = value }
            case 0x74: global { $0.item.reportSize = value }
            case 0x94: global { $0.item.reportCount = value }
            case 0x08: usages.append(usage)
            case 0x18: usageMinimum = usage
            case 0x28: usageMaximum = usage
            default: break    // designators, strings and delimiters are not part of what a page is shown
            }
        }
        collections = roots.map(\.value)
    }
}

/// Which reports no page may read or write, whatever the user picked. Chromium's rules
/// (`hid_blocklist.cc`, `hid_report_utils.cc`): a page must not be able to log keystrokes,
/// move the pointer, sleep the Mac or talk to a security key.
enum HIDBlocklist {
    static let fidoPage: UInt16 = 0xF1D0

    /// A top-level usage whose reports are the user's typing, pointing or power buttons.
    /// A keyboard's or mouse's feature reports are left alone: they carry settings such as
    /// backlight and polling rate, not input.
    static func alwaysProtected(usagePage: UInt16, usage: UInt16, type: HIDReportType) -> Bool {
        if usagePage == fidoPage || usagePage == 0x07 { return true }    // FIDO; keyboard/keypad
        guard usagePage == 0x01 else { return false }                    // generic desktop
        switch usage {
        case 0x01, 0x02, 0x06, 0x07: return type != .feature    // pointer, mouse, keyboard, keypad
        case 0x80...0x8F: return true                           // system control … warm restart
        case 0xA0...0xB6: return true                           // system dock … display swap
        default: return false
        }
    }

    struct Entry: Sendable {
        var vendorID: Int
        var productID: Int?
        var usagePage: UInt16?
        var reportID: UInt8?
        var type: HIDReportType?
    }

    /// Security keys and password devices, by vendor and product, and one vendor report.
    static let entries: [Entry] = ([
        (0x096e, 0x0850), (0x096e, 0x0852), (0x096e, 0x0853), (0x096e, 0x0854), (0x096e, 0x0856), (0x096e, 0x0858),
        (0x096e, 0x085a), (0x096e, 0x085b), (0x096e, 0x0880),                                    // KEY-ID, Feitian, HyperFIDO
        (0x09c3, 0x0023),                                                                        // HID Global BlueTrust
        (0x1050, 0x0010), (0x1050, 0x0018), (0x1050, 0x0030), (0x1050, 0x0110), (0x1050, 0x0111), (0x1050, 0x0112),
        (0x1050, 0x0113), (0x1050, 0x0114), (0x1050, 0x0115), (0x1050, 0x0116), (0x1050, 0x0120), (0x1050, 0x0200),
        (0x1050, 0x0211), (0x1050, 0x0401), (0x1050, 0x0402), (0x1050, 0x0403), (0x1050, 0x0404), (0x1050, 0x0405),
        (0x1050, 0x0406), (0x1050, 0x0407), (0x1050, 0x0410),                                    // YubiKey
        (0x10c4, 0x8acf),                                                                        // U2F Zero
        (0x1209, 0x4321), (0x1209, 0x4322),                                                      // Mooltipass
        (0x18d1, 0x5026),                                                                        // Titan
        (0x1a44, 0x00bb),                                                                        // VASCO
        (0x1d50, 0x60fc),                                                                        // OnlyKey
        (0x1e0d, 0xf1ae), (0x1e0d, 0xf1d0),                                                      // Keydo
        (0x1ea8, 0xf025),                                                                        // Thetis
        (0x20a0, 0x4287),                                                                        // Nitrokey
        (0x24dc, 0x0101),                                                                        // JaCarta
        (0x2581, 0xf1d0),                                                                        // Happlink
        (0x2abe, 0x1002),                                                                        // Bluink
        (0x2ccf, 0x0880),                                                                        // Feitian USB, HyperFIDO
    ] as [(Int, Int)]).map { Entry(vendorID: $0.0, productID: $0.1) } + [
        // Jabra's proprietary firmware channel.
        Entry(vendorID: 0x0b0e, usagePage: 0xff00, reportID: 0x05, type: .output),
    ]
}

/// One HID interface: what the registry says about it, and what a page may be shown of it.
struct HIDDeviceInfo: Equatable, Sendable {
    /// The same physical device again: a serial number names it in any socket; without one
    /// it is the same model at the same place.
    struct Identity: Hashable, Codable, Sendable {
        var vendorID: Int
        var productID: Int
        var serialNumber: String
        var locationID: Int
    }

    /// The IORegistry entry: unique while this interface stays attached, never shown to a page.
    let entryID: UInt64
    let vendorID: Int
    let productID: Int
    let product: String
    let serialNumber: String
    let locationID: Int
    let descriptor: HIDDescriptor
    /// What a page sees: the descriptor's collections without their protected reports, and
    /// without the collections that leaves empty.
    let collections: [HIDCollection]
    private let declared: [HIDReportType: Set<UInt8>]
    private let protected: [HIDReportType: Set<UInt8>]
    /// The report types for which an id the descriptor never declared is refused too.
    private let guarded: Set<HIDReportType>

    init(entryID: UInt64, vendorID: Int, productID: Int, product: String = "", serialNumber: String = "",
         locationID: Int = 0, descriptor: Data) {
        self.entryID = entryID; self.vendorID = vendorID; self.productID = productID
        self.product = product; self.serialNumber = serialNumber; self.locationID = locationID
        let parsed = HIDDescriptor(descriptor)
        self.descriptor = parsed

        let top = parsed.collections
        // A security key is not offered at all, nor anything the list names without a usage.
        let excluded = top.contains { $0.usagePage == HIDBlocklist.fidoPage } || HIDBlocklist.entries.contains {
            $0.vendorID == vendorID && ($0.productID ?? productID) == productID && $0.usagePage == nil
        }
        var declared: [HIDReportType: Set<UInt8>] = [:], protected: [HIDReportType: Set<UInt8>] = [:]
        var guarded: Set<HIDReportType> = []
        for type in HIDReportType.allCases {
            let ids = Set(top.flatMap { $0.reports(type).map(\.id) })
            declared[type] = ids
            protected[type] = excluded ? ids : ids.filter { id in
                top.contains { Self.protects($0, id: id, type: type, vendorID: vendorID, productID: productID, top: true) }
            }
            if excluded || protected[type]?.isEmpty == false
                || top.contains(where: { HIDBlocklist.alwaysProtected(usagePage: $0.usagePage, usage: $0.usage, type: type) }) {
                guarded.insert(type)
            }
        }
        self.declared = declared; self.protected = protected; self.guarded = guarded

        func strip(_ collection: HIDCollection) -> HIDCollection? {
            var out = collection
            out.children = collection.children.compactMap(strip)
            out.input = collection.input.filter { !(protected[.input] ?? []).contains($0.id) }
            out.output = collection.output.filter { !(protected[.output] ?? []).contains($0.id) }
            out.feature = collection.feature.filter { !(protected[.feature] ?? []).contains($0.id) }
            return out.children.isEmpty && out.input.isEmpty && out.output.isEmpty && out.feature.isEmpty ? nil : out
        }
        collections = top.compactMap(strip)
    }

    /// Whether this collection, or one nested in it, puts the report out of a page's reach.
    /// A nested collection counts only as an application collection (or a FIDO one of any
    /// kind): a gamepad's stick is a "pointer" physical collection, and is not a mouse.
    private static func protects(_ collection: HIDCollection, id: UInt8, type: HIDReportType,
                                 vendorID: Int, productID: Int, top: Bool) -> Bool {
        guard collection.reports(type).contains(where: { $0.id == id }) else { return false }
        if top || collection.type == 1 || collection.usagePage == HIDBlocklist.fidoPage,
           HIDBlocklist.alwaysProtected(usagePage: collection.usagePage, usage: collection.usage, type: type) { return true }
        if HIDBlocklist.entries.contains(where: {
            $0.vendorID == vendorID && ($0.productID ?? productID) == productID
                && ($0.usagePage ?? collection.usagePage) == collection.usagePage
                && ($0.reportID ?? id) == id && ($0.type ?? type) == type
        }) { return true }
        return collection.children.contains {
            protects($0, id: id, type: type, vendorID: vendorID, productID: productID, top: false)
        }
    }

    /// Nothing of this interface may be shown to a page: it is a keyboard, a mouse, a
    /// security key, or has no descriptor.
    var isExposable: Bool { !collections.isEmpty }

    var identity: Identity {
        Identity(vendorID: vendorID, productID: productID, serialNumber: serialNumber,
                 locationID: serialNumber.isEmpty ? locationID : 0)
    }

    /// The chooser's and Site Controls' name for it.
    var label: String {
        product.isEmpty ? String(format: "Unknown Device (%04x:%04x)", vendorID, productID) : product
    }

    /// Whether a page may be given, or may send, this report. An id the descriptor does not
    /// declare is refused on a device that has anything to protect, and a device that
    /// numbers its reports has no report 0 (nor the other way round).
    func isProtected(_ type: HIDReportType, id: UInt8) -> Bool {
        if descriptor.usesReportIDs != (id != 0) { return true }
        if protected[type]?.contains(id) == true { return true }
        return declared[type]?.contains(id) != true && guarded.contains(type)
    }

    /// `sendReport` and `sendFeatureReport`: the device has reports of that type, this one
    /// fits, and it is not protected.
    func maySend(_ type: HIDReportType, id: UInt8, length: Int) -> Bool {
        let longest = descriptor.maxBytes(type)
        return type != .input && longest > 0 && length <= longest && !isProtected(type, id: id)
    }

    /// `receiveFeatureReport`.
    func mayReceiveFeature(id: UInt8) -> Bool { descriptor.maxBytes(.feature) > 0 && !isProtected(.feature, id: id) }
}

/// The HID interfaces attached to this Mac, kept current while anything is listening.
@MainActor final class HIDDevices: ObservableObject {
    static let shared = HIDDevices()
    @Published private(set) var devices: [HIDDeviceInfo] = []
    /// Called after `devices` changes: a device was plugged in or pulled.
    var onChange: (() -> Void)?
    #if DEBUG
    /// Fixtures stand in for hardware.
    var listForTesting: (() -> [HIDDeviceInfo])?
    #endif
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, .main)
        let changed: IOServiceMatchingCallback = { _, iterator in
            HIDDevices.drain(iterator)
            MainActor.assumeIsolated { HIDDevices.shared.refresh() }
        }
        // The iterators are kept for the life of the app: releasing one ends its notification.
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            if IOServiceAddMatchingNotification(port, kind, IOServiceMatching(kIOHIDDeviceKey),
                                                changed, nil, &iterator) == KERN_SUCCESS {
                Self.drain(iterator)    // arms it
            }
        }
        refresh()
    }

    func refresh() {
        #if DEBUG
        let found = listForTesting?() ?? Self.list()
        #else
        let found = Self.list()
        #endif
        guard found != devices else { return }
        devices = found
        onChange?()
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }

    /// Every HID interface IOKit lists, in registry order. Reads the registry only; opens nothing.
    nonisolated static func list() -> [HIDDeviceInfo] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [HIDDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            found.append(HIDDeviceInfo(
                entryID: entryID, vendorID: property(kIOHIDVendorIDKey) as? Int ?? 0, productID: property(kIOHIDProductIDKey) as? Int ?? 0,
                product: property(kIOHIDProductKey) as? String ?? "", serialNumber: property(kIOHIDSerialNumberKey) as? String ?? "",
                locationID: property(kIOHIDLocationIDKey) as? Int ?? 0, descriptor: property(kIOHIDReportDescriptorKey) as? Data ?? Data()))
        }
        return found.sorted { $0.entryID < $1.entryID }
    }
}

/// One open device, as WebHID.swift uses it. The fixtures have one of their own.
protocol HIDTransport: AnyObject, Sendable {
    /// False when the device refused the report, or is closed.
    func send(_ type: HIDReportType, id: UInt8, data: Data) async -> Bool
    /// The feature report as the device returned it: for a numbered report that starts
    /// with its id, as it does in Chrome.
    func feature(id: UInt8, length: Int) async -> Data?
    func close()
}

/// One open `IOHIDDevice`. Input reports arrive on a queue of their own; the calls that set
/// and get reports block until the device answers, so they have another.
final class HIDConnection: HIDTransport, @unchecked Sendable {
    /// What may wait to be sent to one device. A page that outruns a stalled device is refused.
    static let maxPending = 64

    private let device: IOHIDDevice
    private let reports = DispatchQueue(label: "vane.hid.reports")
    private let work = DispatchQueue(label: "vane.hid.io")
    private let buffer: UnsafeMutableBufferPointer<UInt8>
    private let numbered: Bool
    private let onInput: @Sendable (UInt8, Data) -> Void
    private let closed = Atomic<Bool>(false)
    private let pending = Atomic<Int>(0)

    /// Opens the interface without seizing it: the system keeps using the device too. Nil
    /// when it is gone, or macOS refuses (the sandbox, or Input Monitoring for a keyboard).
    static func open(_ info: HIDDeviceInfo, onInput: @escaping @Sendable (UInt8, Data) -> Void) async -> HIDConnection? {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(info.entryID))
                guard service != 0 else { return done.resume(returning: nil) }
                defer { IOObjectRelease(service) }
                guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
                      IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
                    return done.resume(returning: nil)
                }
                done.resume(returning: HIDConnection(device, info: info, onInput: onInput))
            }
        }
    }

    private init(_ device: IOHIDDevice, info: HIDDeviceInfo, onInput: @escaping @Sendable (UInt8, Data) -> Void) {
        self.device = device
        self.onInput = onInput
        numbered = info.descriptor.usesReportIDs
        let longest = max(info.descriptor.maxBytes(.input), IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0)
        // The property is the device's to claim; a report past 64 KiB is cut short rather than allocated for.
        buffer = .allocate(capacity: min(max(longest, 64), 65536) + 1)
        // The callback holds this object until the device says it will call no more.
        let context = Unmanaged.passRetained(self)
        IOHIDDeviceRegisterInputReportCallback(device, buffer.baseAddress!, buffer.count, { context, result, _, _, _, report, length in
            guard result == kIOReturnSuccess, let context, length >= 0 else { return }
            let connection = Unmanaged<HIDConnection>.fromOpaque(context).takeUnretainedValue()
            var data = Data(bytes: report, count: length)
            // A numbered report arrives with its id in front; a page gets the id apart.
            let id = connection.numbered ? data.popFirst() ?? 0 : 0
            connection.onInput(id, data)
        }, context.toOpaque())
        IOHIDDeviceSetDispatchQueue(device, reports)
        IOHIDDeviceSetCancelHandler(device) {
            IOHIDDeviceClose(context.takeUnretainedValue().device, IOOptionBits(kIOHIDOptionsTypeNone))
            context.release()
        }
        IOHIDDeviceActivate(device)
    }

    deinit { buffer.deallocate() }

    func send(_ type: HIDReportType, id: UInt8, data: Data) async -> Bool {
        await run(false) { [self] in
            // macOS wants the id in front of a numbered report and nothing in front of report 0.
            let bytes = id == 0 ? [UInt8](data) : [id] + data
            return IOHIDDeviceSetReport(device, type == .feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput,
                                        CFIndex(id), bytes, bytes.count) == kIOReturnSuccess
        }
    }

    func feature(id: UInt8, length: Int) async -> Data? {
        await run(nil) { [self] in
            var bytes = [UInt8](repeating: 0, count: max(length, 1)), count = CFIndex(max(length, 1))
            guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &bytes, &count) == kIOReturnSuccess,
                  (0...bytes.count).contains(count) else { return nil }
            return Data(bytes[..<count])
        }
    }

    /// One blocking call at a time, off the main thread, and none once closed.
    private func run<T: Sendable>(_ refused: T, _ call: @escaping @Sendable () -> T) async -> T {
        guard pending.add(1, ordering: .relaxed).newValue <= Self.maxPending else {
            pending.subtract(1, ordering: .relaxed)
            return refused
        }
        return await withCheckedContinuation { done in
            work.async { [self] in
                defer { pending.subtract(1, ordering: .relaxed) }
                done.resume(returning: closed.load(ordering: .relaxed) ? refused : call())
            }
        }
    }

    /// Ends the input reports and gives the device back, after the call in flight (if any).
    func close() {
        guard !closed.exchange(true, ordering: .relaxed) else { return }
        work.async { [self] in IOHIDDeviceCancel(device) }
    }
}
