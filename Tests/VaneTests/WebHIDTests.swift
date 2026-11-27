import Foundation
import os
import XCTest
@testable import vane

/// Report descriptors as real devices send them.
enum HIDFixtures {
    /// QMK's raw HID interface, the one VIA talks to: usage page 0xFF60, usage 0x61, one
    /// unnumbered 32-byte report each way.
    static let viaRawHID: [UInt8] = [
        0x06, 0x60, 0xFF, 0x09, 0x61, 0xA1, 0x01,
        0x09, 0x62, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x95, 0x20, 0x75, 0x08, 0x81, 0x02,
        0x09, 0x63, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x95, 0x20, 0x75, 0x08, 0x91, 0x02,
        0xC0,
    ]

    /// A generic gamepad: 16 buttons, a stick in a Pointer physical collection, a hat with a
    /// null state and a unit, padding, and a vendor output report for rumble.
    static let gamepad: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02,
        0x05, 0x01, 0x09, 0x01, 0xA1, 0x00,
        0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
        0xC0,
        0x09, 0x39, 0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42,
        0x65, 0x00, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03,
        0x85, 0x02, 0x06, 0x00, 0xFF, 0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x07, 0x91, 0x02,
        0xC0,
    ]

    /// A boot keyboard: modifiers, keys, LEDs.
    static let keyboard: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
        0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
        0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
        0xC0,
    ]

    /// …and the same keyboard with a vendor feature report for its backlight.
    static let keyboardWithFeature: [UInt8] = Array(keyboard.dropLast()) + [
        0x06, 0x00, 0xFF, 0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0xB1, 0x02, 0xC0,
    ]

    /// A security key's CTAPHID interface.
    static let fido: [UInt8] = [
        0x06, 0xD0, 0xF1, 0x09, 0x01, 0xA1, 0x01,
        0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02,
        0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02,
        0xC0,
    ]

    /// A gaming mouse's one interface: the mouse as report 2, its settings channel as 0x10.
    static let mouseAndVendor: [UInt8] = [
        0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, 0x09, 0x01, 0xA1, 0x00,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
        0x75, 0x05, 0x95, 0x01, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
        0xC0, 0xC0,
        0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x10,
        0x09, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x06, 0x81, 0x00, 0x09, 0x01, 0x91, 0x00,
        0xC0,
    ]

    static func device(_ descriptor: [UInt8], entryID: UInt64, vendorID: Int, productID: Int, product: String,
                       serialNumber: String = "", locationID: Int = 0x1400000) -> HIDDeviceInfo {
        HIDDeviceInfo(entryID: entryID, vendorID: vendorID, productID: productID, product: product,
                      serialNumber: serialNumber, locationID: locationID, descriptor: Data(descriptor))
    }

    static let via = device(viaRawHID, entryID: 101, vendorID: 0x3434, productID: 0x0141, product: "Keychron Q1",
                            serialNumber: "Q1-1")
    static let pad = device(gamepad, entryID: 102, vendorID: 0x054c, productID: 0x05c4, product: "Wireless Controller",
                            serialNumber: "PAD-1")
    static let board = device(keyboard, entryID: 103, vendorID: 0x3434, productID: 0x0141, product: "Keychron Q1",
                              serialNumber: "Q1-1")
    static let key = device(fido, entryID: 104, vendorID: 0x1209, productID: 0xbeee, product: "Security Key")
}

/// Descriptors, the blocklist, filters and the grant store: no device, no page.
@MainActor final class WebHIDTests: XCTestCase {
    private var profile = UUID()

    override func setUp() async throws {
        TestEnvironment.prepare()
        profile = UUID()
    }

    override func tearDown() async throws { WebHID.forgetAll(profileID: profile) }

    func testTheVIARawHIDInterfaceParsesAsVIAExpects() throws {
        let parsed = HIDDescriptor(Data(HIDFixtures.viaRawHID))
        XCTAssertEqual(parsed.collections.count, 1)
        let top = try XCTUnwrap(parsed.collections.first)
        XCTAssertEqual([top.usagePage, top.usage], [0xFF60, 0x61])
        XCTAssertEqual(top.type, 1, "An application collection")
        XCTAssertFalse(parsed.usesReportIDs)
        XCTAssertEqual(top.input.map(\.id), [0])
        XCTAssertEqual(top.output.map(\.id), [0])
        let item = try XCTUnwrap(top.output.first?.items.first)
        XCTAssertEqual(item.usages, [0xFF60_0063], "A usage carries its page in the high 16 bits")
        XCTAssertEqual([item.reportSize, item.reportCount], [8, 32])
        XCTAssertEqual([item.logicalMinimum, item.logicalMaximum], [0, 255])
        XCTAssertEqual([parsed.maxBytes(.input), parsed.maxBytes(.output), parsed.maxBytes(.feature)], [32, 32, 0])

        let json = item.json as NSDictionary
        XCTAssertEqual(json["isArray"] as? Bool, false)
        XCTAssertEqual(json["isAbsolute"] as? Bool, true)
        XCTAssertEqual(json["usages"] as? [Int], [0xFF60_0063])
        XCTAssertNil(json["usageMinimum"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(top.json), "The collection crosses to the page as it is")

        let device = HIDFixtures.via
        XCTAssertTrue(device.isExposable)
        XCTAssertTrue(device.maySend(.output, id: 0, length: 32))
        XCTAssertFalse(device.maySend(.output, id: 0, length: 33), "Longer than the descriptor allows")
        XCTAssertFalse(device.maySend(.output, id: 1, length: 32), "An unnumbered device has no report 1")
        XCTAssertFalse(device.maySend(.input, id: 0, length: 1), "Input reports are not the page's to send")
        XCTAssertFalse(device.mayReceiveFeature(id: 0), "No feature reports")
    }

    func testAGamepadParsesWithItsNestingUnitsAndRanges() throws {
        let parsed = HIDDescriptor(Data(HIDFixtures.gamepad))
        let top = try XCTUnwrap(parsed.collections.first)
        XCTAssertEqual([top.usagePage, top.usage], [0x01, 0x05])
        XCTAssertTrue(parsed.usesReportIDs)
        XCTAssertEqual(top.children.count, 1)
        let stick = try XCTUnwrap(top.children.first)
        XCTAssertEqual([stick.usagePage, stick.usage, UInt16(stick.type)], [0x01, 0x01, 0])
        XCTAssertEqual(stick.input.first?.items.count, 1, "The stick's own report holds the stick only")
        XCTAssertEqual(stick.input.first?.items.first?.usages, [0x0001_0030, 0x0001_0031])
        XCTAssertEqual(stick.input.first?.items.first?.logicalMinimum, -127)
        XCTAssertEqual(stick.input.first?.items.first?.logicalMaximum, 127)

        let items = try XCTUnwrap(top.input.first { $0.id == 1 }?.items)
        XCTAssertEqual(items.count, 4, "Buttons, stick, hat and padding, in order")
        let buttons = items[0]
        XCTAssertTrue(buttons.isRange)
        XCTAssertEqual([buttons.usageMinimum, buttons.usageMaximum], [0x0009_0001, 0x0009_0010])
        XCTAssertEqual((buttons.json as NSDictionary)["usageMaximum"] as? Int, 0x0009_0010)
        let hat = items[2].json as NSDictionary
        XCTAssertEqual(hat["hasNull"] as? Bool, true)
        XCTAssertEqual(hat["unitSystem"] as? String, "english-rotation")
        XCTAssertEqual(hat["unitFactorLengthExponent"] as? Int, 1)
        XCTAssertEqual(hat["physicalMaximum"] as? Int, 315)
        XCTAssertEqual((items[3].json as NSDictionary)["isConstant"] as? Bool, true)
        XCTAssertEqual(top.output.map(\.id), [2])
        XCTAssertEqual([parsed.maxBytes(.input), parsed.maxBytes(.output)], [5, 7])

        let device = HIDFixtures.pad
        XCTAssertTrue(device.isExposable, "A gamepad's stick is a Pointer, but it is not a mouse")
        XCTAssertFalse(device.isProtected(.input, id: 1))
        XCTAssertTrue(device.maySend(.output, id: 2, length: 7))
        XCTAssertFalse(device.maySend(.output, id: 0, length: 7), "A numbered device has no report 0")
    }

    func testAMaximumIsUnsignedWhenItsMinimumIsNot() throws {
        // `25 FF`: logical maximum 255, as one byte.
        let parsed = HIDDescriptor(Data([0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x15, 0x00, 0x25, 0xFF,
                                         0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xC0]))
        XCTAssertEqual(parsed.collections.first?.input.first?.items.first?.logicalMaximum, 255)
        let signed = HIDDescriptor(Data([0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x15, 0xFF, 0x25, 0xFF,
                                         0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xC0]))
        XCTAssertEqual(signed.collections.first?.input.first?.items.first?.logicalMaximum, -1,
                       "With a negative minimum the maximum is signed")
    }

    func testMalformedDescriptorsParseWithoutTrapping() {
        // Fixed seed: the same bytes every run.
        var state: UInt64 = 0x5EED
        func next() -> UInt8 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        for _ in 0..<2000 {
            let bytes = (0..<Int(next())).map { _ in next() }
            _ = HIDDeviceInfo(entryID: 1, vendorID: 1, productID: 1, descriptor: Data(bytes)).collections
        }
        let deep = HIDDescriptor(Data([UInt8](repeating: 0xA1, count: 400) + [0x81, 0x02]))
        XCTAssertFalse(deep.collections.isEmpty, "Nesting past the limit stops nesting, not parsing")
        XCTAssertTrue(HIDDescriptor(Data([0xFE, 0xFF, 0x00])).collections.isEmpty, "A long item that runs off the end")
        XCTAssertTrue(HIDDescriptor(Data()).collections.isEmpty)
        let huge = HIDDescriptor(Data([0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x77, 0xFF, 0xFF, 0xFF, 0xFF,
                                       0x97, 0xFF, 0xFF, 0xFF, 0xFF, 0x81, 0x02, 0xC0]))
        XCTAssertEqual(huge.maxBytes(.input), 0, "A report no transport carries counts as none")
    }

    func testTheBlocklistKeepsKeyboardsMiceAndSecurityKeysAway() {
        XCTAssertFalse(HIDFixtures.board.isExposable, "A keyboard's keys and LEDs are never a page's")
        XCTAssertFalse(HIDFixtures.key.isExposable, "The FIDO usage page is blocked outright")

        let lit = HIDFixtures.device(HIDFixtures.keyboardWithFeature, entryID: 1, vendorID: 0x3434, productID: 1, product: "Board")
        XCTAssertTrue(lit.isExposable, "A keyboard's feature reports carry settings, not typing")
        XCTAssertEqual(lit.collections.first?.input, [], "…but its input reports are not shown")
        XCTAssertEqual(lit.collections.first?.output, [])
        XCTAssertEqual(lit.collections.first?.feature.map(\.id), [0])
        XCTAssertTrue(lit.isProtected(.input, id: 0))
        XCTAssertTrue(lit.mayReceiveFeature(id: 0))
        XCTAssertTrue(lit.maySend(.feature, id: 0, length: 4))

        let mouse = HIDFixtures.device(HIDFixtures.mouseAndVendor, entryID: 2, vendorID: 0x046d, productID: 0xc539, product: "Mouse")
        XCTAssertTrue(mouse.isExposable)
        XCTAssertEqual(mouse.collections.map(\.usagePage), [0xFF00], "Only the settings channel is shown")
        XCTAssertTrue(mouse.isProtected(.input, id: 2), "The pointer's report")
        XCTAssertFalse(mouse.isProtected(.input, id: 0x10))
        XCTAssertTrue(mouse.isProtected(.input, id: 0x55), "An id the descriptor never declared, on a device with a mouse")
        XCTAssertTrue(mouse.maySend(.output, id: 0x10, length: 6))
        XCTAssertFalse(mouse.maySend(.output, id: 2, length: 1))

        // Named by vendor and product, whatever the descriptor says.
        let yubikey = HIDFixtures.device(HIDFixtures.viaRawHID, entryID: 3, vendorID: 0x1050, productID: 0x0407, product: "YubiKey")
        XCTAssertFalse(yubikey.isExposable)
        XCTAssertEqual(WebHID.Filter.candidates([yubikey, HIDFixtures.key, HIDFixtures.board],
                                                filters: []), [], "Nothing blocked is ever offered")

        let system = HIDFixtures.device([0x05, 0x01, 0x09, 0x80, 0xA1, 0x01, 0x09, 0x82, 0x15, 0x00, 0x25, 0x01,
                                         0x75, 0x01, 0x95, 0x01, 0x81, 0x02, 0x75, 0x07, 0x81, 0x03, 0xC0],
                                        entryID: 4, vendorID: 1, productID: 1, product: "Sleep")
        XCTAssertFalse(system.isExposable, "System control: a page must not sleep the Mac")
    }

    func testFiltersMatchByVendorProductAndUsage() throws {
        let all = [HIDFixtures.via, HIDFixtures.pad, HIDFixtures.board, HIDFixtures.key]
        func pick(_ filters: [[String: Any]], excluding: [[String: Any]] = []) throws -> [UInt64] {
            WebHID.Filter.candidates(all, filters: try WebHID.Filter.parse(filters),
                                     excluding: try WebHID.Filter.parse(excluding, name: "exclusionFilters")).map(\.entryID)
        }
        XCTAssertEqual(try pick([["usagePage": 0xFF60, "usage": 0x61]]), [101], "VIA's own filter")
        XCTAssertEqual(try pick([["vendorId": 0x3434, "usagePage": 0xFF60]]), [101])
        XCTAssertEqual(try pick([["vendorId": 0x054c]]), [102])
        XCTAssertEqual(try pick([["vendorId": 0x054c, "productId": 1]]), [])
        XCTAssertEqual(try pick([]), [101, 102], "No filters: every device a page may be shown")
        XCTAssertEqual(try pick([], excluding: [["vendorId": 0x054c]]), [101])
        XCTAssertEqual(try pick([["usagePage": 0x01, "usage": 0x06]]), [], "A keyboard matches and is still not offered")
        XCTAssertEqual(try pick([["usagePage": 0xF1D0]]), [])

        func typeError(_ body: Any?, _ message: String) {
            XCTAssertThrowsError(try WebHID.Filter.parse(body), message) { XCTAssertEqual(($0 as? HIDError)?.name, "TypeError") }
        }
        typeError([["productId": 1]], "a product needs its vendor")
        typeError([["usage": 1]], "a usage needs its page")
        typeError([[String: Any]()], "an empty filter filters nothing")
        typeError([["vendorId": "0x3434"]], "not a number")
        typeError([["vendorId": true]], "a boolean is no id")
        typeError([["usagePage": 0x10000]], "out of range")
        typeError("all", "not a sequence")
    }

    func testAGrantFollowsItsPhysicalDevice() {
        let pad = HIDFixtures.pad
        let moved = HIDDeviceInfo(entryID: 900, vendorID: pad.vendorID, productID: pad.productID, product: pad.product,
                                  serialNumber: "PAD-1", locationID: 0x2200000, descriptor: Data(HIDFixtures.gamepad))
        XCTAssertEqual(pad.identity, moved.identity, "A serial number names the device in any socket")
        let via = HIDFixtures.via
        let elsewhere = HIDDeviceInfo(entryID: 901, vendorID: via.vendorID, productID: via.productID,
                                      locationID: 0x2200000, descriptor: Data(HIDFixtures.viaRawHID))
        XCTAssertNotEqual(via.identity, elsewhere.identity, "Without one, another socket could be another keyboard")
        XCTAssertEqual(HIDFixtures.board.identity, via.identity, "Interfaces of one device share its identity")
        XCTAssertEqual(HIDDeviceInfo(entryID: 1, vendorID: 0x1234, productID: 0xabcd, descriptor: Data()).label,
                       "Unknown Device (1234:abcd)")
    }

    func testOnlySecureOriginsMayAsk() throws {
        func scope(_ url: String) throws -> WebHID.Scope { try XCTUnwrap(WebHID.Scope(url: URL(string: url), profileID: profile)) }
        for url in ["https://usevia.app", "http://localhost:8080", "http://127.0.0.1:3000", "http://[::1]:8000"] {
            XCTAssertTrue(WebHID.isSecure(try scope(url)), url)
        }
        for url in ["http://usevia.app", "http://127.evil.example", "http://192.168.1.4", "http://0.0.0.0:8080",
                    "http://app.localhost"] {
            XCTAssertFalse(WebHID.isSecure(try scope(url)), url)
        }
    }

    func testGrantsStayWithTheirOriginProfileAndPrivateTab() throws {
        let origin = URL(string: "https://usevia.app")
        let scope = try XCTUnwrap(WebHID.Scope(url: origin, profileID: profile))
        let grant = WebHID.grant(HIDFixtures.via, scope: scope)
        XCTAssertEqual(WebHID.grants(scope: scope), [grant])
        XCTAssertEqual(grant.name, "Keychron Q1")
        XCTAssertEqual(WebHID.grant(HIDFixtures.via, scope: scope).id, grant.id, "Picking a device again must not add a second grant")
        XCTAssertEqual(WebHID.grants(scope: scope).count, 1)
        for url in ["http://usevia.app", "https://usevia.app:8443", "https://beta.usevia.app"] {
            XCTAssertTrue(WebHID.grants(scope: WebHID.Scope(url: URL(string: url), profileID: profile)).isEmpty, url)
        }
        let otherProfile = UUID()
        defer { WebHID.forgetAll(profileID: otherProfile) }
        let elsewhere = try XCTUnwrap(WebHID.Scope(url: origin, profileID: otherProfile))
        XCTAssertTrue(WebHID.grants(scope: elsewhere).isEmpty)
        XCTAssertTrue(WebHID.grants(scope: nil).isEmpty)

        let privateTab = UUID()
        let privateScope = try XCTUnwrap(WebHID.Scope(url: origin, profileID: profile, privateTabID: privateTab))
        XCTAssertTrue(WebHID.grants(scope: privateScope).isEmpty, "A private tab must not inherit the profile's grants")
        WebHID.forget(scope: scope, id: grant.id)
        WebHID.grant(HIDFixtures.via, scope: privateScope)
        XCTAssertEqual(WebHID.grants(scope: privateScope).count, 1)
        XCTAssertTrue(WebHID.grants(scope: WebHID.Scope(url: origin, profileID: profile, privateTabID: UUID())).isEmpty)
        XCTAssertFalse(UserDefaults.vane.dictionaryRepresentation().keys.contains { $0.hasPrefix("hidDevice.v1." + profile.uuidString.lowercased()) },
                       "A private grant is never written down")
        WebHID.forgetPrivate(tabID: privateTab)
        XCTAssertTrue(WebHID.grants(scope: privateScope).isEmpty)

        WebHID.grant(HIDFixtures.via, scope: elsewhere)
        WebHID.grant(HIDFixtures.pad, scope: scope)
        WebHID.forgetAll(profileID: profile)
        XCTAssertTrue(WebHID.grants(scope: scope).isEmpty)
        XCTAssertEqual(WebHID.grants(scope: elsewhere).count, 1, "Removing a profile's grants leaves other profiles alone")
    }

    /// Chromium keeps these in memory and ends them on unplug: the next device in that port is not this one.
    func testASerialLessGrantIsNeverWrittenDownAndEndsWhenUnplugged() throws {
        let plain = HIDFixtures.device(HIDFixtures.viaRawHID, entryID: 120, vendorID: 0x1234, productID: 0x5678, product: "No Serial")
        HIDDevices.shared.listForTesting = { [plain, HIDFixtures.pad] }
        HIDDevices.shared.refresh()
        WebHID.watch()
        defer { HIDDevices.shared.listForTesting = nil; HIDDevices.shared.refresh() }
        let scope = try XCTUnwrap(WebHID.Scope(url: URL(string: "https://usevia.app"), profileID: profile))
        WebHID.grant(plain, scope: scope)
        WebHID.grant(HIDFixtures.pad, scope: scope)
        XCTAssertEqual(WebHID.grants(scope: scope).map(\.name), ["Wireless Controller", "No Serial"])
        XCTAssertEqual(WebHID.all(profileID: profile).map(\.scope), [scope, scope], "Settings lists both")
        let stored = UserDefaults.vane.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("hidDevice.v1." + profile.uuidString.lowercased()) }.values.compactMap { $0 as? Data }
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(stored.contains { String(decoding: $0, as: UTF8.self).contains("No Serial") }, "Only the serial-numbered one is saved")

        HIDDevices.shared.listForTesting = { [HIDFixtures.pad] }
        HIDDevices.shared.refresh()
        XCTAssertEqual(WebHID.grants(scope: scope).map(\.name), ["Wireless Controller"], "Unplugging ends the serial-less grant")
        HIDDevices.shared.listForTesting = { [] }
        HIDDevices.shared.refresh()
        XCTAssertEqual(WebHID.grants(scope: scope).count, 1, "A serial number keeps its grant across unplugging")

        WebHID.grant(plain, scope: scope)
        WebHID.forgetAll()
        XCTAssertTrue(WebHID.grants(scope: scope).isEmpty, "Reset with no profile clears every profile, memory too")
        XCTAssertTrue(WebHID.all(profileID: profile).isEmpty)
    }

    func testAProtectedReportIdStaysProtectedForEveryType() {
        // The gaming mouse protects report 2; any id it never declared is refused too.
        let mouse = HIDFixtures.device(HIDFixtures.mouseAndVendor, entryID: 130, vendorID: 0x046d, productID: 0xc077, product: "Mouse")
        XCTAssertTrue(mouse.isProtected(.input, id: 2))
        XCTAssertFalse(mouse.isProtected(.input, id: 0x10))
        XCTAssertTrue(mouse.isProtected(.input, id: 0x11), "An undeclared id on a device with a protected report")
    }

    func testSiteControlsListEachGrantedDeviceAsARowThatForgetsIt() {
        var model = SiteControlModel(host: "usevia.app", scheme: "https")
        XCTAssertFalse(model.rows.contains { $0.id == .hid(0) })
        model.hidDevices = ["Keychron Q1"]
        let row = model.rows.first { $0.id == .hid(0) }
        XCTAssertEqual(row?.title, "HID Device: Keychron Q1")
        XCTAssertEqual(row?.control, .toggle(true))
        XCTAssertEqual(model.settings.first { $0.id == .hid(0) }?.value, "Allowed")
    }
}
