import AppKit
import WebKit
import XCTest
@testable import vane

/// Stands in for CoreBluetooth: advertises fixed peripherals, serves a fixed GATT table, and
/// records what reached the radio. Nothing here asks macOS for Bluetooth.
@MainActor final class FakeBluetooth: BluetoothBackend {
    struct Service { let attribute: BluetoothAttribute; var characteristics: [(BluetoothAttribute, [BluetoothAttribute])] }
    var onEvent: ((BluetoothEvent) -> Void)?
    var available = true
    var advertisements: [BluetoothAdvertisement] = []
    var gatt: [UUID: [Service]] = [:]
    var values: [UInt64: Data] = [:]
    var connected: Set<UUID> = []
    var calls: [String] = []

    func startScan() { calls.append("scan"); advertisements.forEach { onEvent?(.found($0)) } }
    func stopScan(keeping: Set<UUID>) { calls.append("stop") }
    func connect(_ id: UUID) async -> Bool {
        calls.append("connect")
        guard gatt[id] != nil else { return false }
        connected.insert(id)
        return true
    }
    func disconnect(_ id: UUID) { calls.append("disconnect"); connected.remove(id) }
    func services(_ id: UUID) async -> [BluetoothAttribute]? { connected.contains(id) ? gatt[id]?.map(\.attribute) : nil }
    func characteristics(_ id: UUID, service: UInt64) async -> [BluetoothAttribute]? {
        gatt[id]?.first { $0.attribute.instance == service }?.characteristics.map(\.0)
    }
    func descriptors(_ id: UUID, characteristic: UInt64) async -> [BluetoothAttribute]? {
        gatt[id]?.flatMap(\.characteristics).first { $0.0.instance == characteristic }?.1
    }
    func read(_ id: UUID, _ attribute: UInt64) async -> Data? { calls.append("read:\(attribute)"); return values[attribute] }
    func write(_ id: UUID, _ attribute: UInt64, _ data: Data, withResponse: Bool) async -> Bool {
        calls.append("write:\(attribute):\(withResponse ? "with" : "without"):\([UInt8](data))")
        values[attribute] = data
        return true
    }
    func notify(_ id: UUID, _ characteristic: UInt64, _ on: Bool) async -> Bool { calls.append("notify:\(characteristic):\(on)"); return true }
}

@MainActor enum BluetoothFixtures {
    static let strap = UUID(uuidString: "6E400001-0000-4000-8000-000000000001")!
    static let lamp = UUID(uuidString: "6E400001-0000-4000-8000-000000000002")!
    static func id(_ short: UInt32) -> String { BluetoothUUID.alias(short) }
    static func attribute(_ instance: UInt64, _ short: UInt32, _ properties: UInt16 = 0) -> BluetoothAttribute {
        BluetoothAttribute(instance: instance, uuid: id(short), properties: properties)
    }

    /// A heart-rate strap, with a HID service, a serial number and a privacy flag it must keep.
    static func install(_ radio: FakeBluetooth) {
        radio.advertisements = [
            BluetoothAdvertisement(id: strap, name: "Polar H10", services: [id(0x180D)], manufacturer: [0x006B: Data([1, 2])]),
            BluetoothAdvertisement(id: lamp, name: "Desk Lamp"),
        ]
        radio.gatt[strap] = [
            .init(attribute: attribute(1, 0x180D), characteristics: [
                (attribute(2, 0x2A37, 0x10), [attribute(3, 0x2902)]),
                (attribute(4, 0x2A38, 0x02), []),
                (attribute(5, 0x2A39, 0x08), []),
            ]),
            .init(attribute: attribute(6, 0x180F), characteristics: [(attribute(7, 0x2A19, 0x12), [])]),
            .init(attribute: attribute(8, 0x1812), characteristics: [(attribute(9, 0x2A4D, 0x1A), [])]),
            .init(attribute: attribute(10, 0x180A), characteristics: [(attribute(11, 0x2A25, 0x02), []), (attribute(12, 0x2A29, 0x02), [])]),
            .init(attribute: attribute(13, 0x1800), characteristics: [(attribute(14, 0x2A00, 0x02), [])]),
        ]
        radio.values = [4: Data([1]), 7: Data([87]), 12: Data("Polar".utf8)]
    }
}

@MainActor final class WebBluetoothTests: XCTestCase {
    private func parse(_ body: [String: Any]) -> String {
        do { _ = try WebBluetooth.Request.parse(body); return "ok" } catch { return error.name + ": " + error.message }
    }

    func testRequestOptionsFollowChromiumsRules() throws {
        let hr = BluetoothFixtures.id(0x180D), hid = BluetoothFixtures.id(0x1812)
        XCTAssertEqual(parse([:]), "TypeError: Either 'filters' should be present or 'acceptAllDevices' should be true, but not both.")
        XCTAssertEqual(parse(["acceptAllDevices": true, "filters": [[String: Any]]()]),
                       "TypeError: Either 'filters' should be present or 'acceptAllDevices' should be true, but not both.")
        XCTAssertEqual(parse(["filters": [[String: Any]]()]), "TypeError: 'filters' member must be non-empty to find any devices.")
        XCTAssertEqual(parse(["filters": [[String: Any]()]]), "TypeError: A filter must restrict the devices in some way.")
        XCTAssertEqual(parse(["filters": [["services": [String]()]]]), "TypeError: 'services', if present, must contain at least one service.")
        XCTAssertEqual(parse(["filters": [["services": ["heart_rate"]]]]), "TypeError: Invalid service UUID.", "Names are resolved in the page")
        XCTAssertEqual(parse(["filters": [["services": [hid]]]]),
                       "SecurityError: requestDevice() called with a filter containing a blocklisted UUID. https://goo.gl/4NeimX")
        XCTAssertEqual(parse(["filters": [["namePrefix": ""]]]), "TypeError: 'namePrefix', if present, must be non-empty.")
        XCTAssertEqual(parse(["filters": [["name": String(repeating: "x", count: 249)]]]), "TypeError: A device name can't be longer than 248 bytes.")
        XCTAssertEqual(parse(["filters": [["manufacturerData": [["companyIdentifier": 0x6B, "dataPrefix": "AQI=", "mask": "AQ=="]]]]]),
                       "TypeError: 'mask' size must be equal to 'dataPrefix' size.")
        XCTAssertEqual(parse(["filters": [["manufacturerData": [["companyIdentifier": 0x4C, "dataPrefix": "AhU="]]]]]),
                       "SecurityError: requestDevice() called with a filter containing a blocklisted manufacturer data.", "No iBeacon tracking")
        XCTAssertEqual(parse(["acceptAllDevices": true, "exclusionFilters": [["name": "x"]]]),
                       "TypeError: 'exclusionFilters' cannot be used with 'acceptAllDevices'.")

        let request = try WebBluetooth.Request.parse(["filters": [["services": [hr]]], "optionalServices": [hid, BluetoothFixtures.id(0x180F)]])
        XCTAssertEqual(request.services, [BluetoothFixtures.id(0x180D), BluetoothFixtures.id(0x180F)],
                       "A blocklisted optional service is dropped, not granted")
    }

    func testFiltersMatchServicesNamesAndManufacturerData() throws {
        let strap = BluetoothAdvertisement(id: UUID(), name: "Polar H10", services: [BluetoothFixtures.id(0x180D)], manufacturer: [0x6B: Data([1, 0xF2])])
        func matches(_ filter: [String: Any]) throws -> Bool { try WebBluetooth.Request.parse(["filters": [filter]]).matches(strap) }
        XCTAssertTrue(try matches(["services": [BluetoothFixtures.id(0x180D)]]))
        XCTAssertFalse(try matches(["services": [BluetoothFixtures.id(0x180D), BluetoothFixtures.id(0x180F)]]), "Every listed service must be advertised")
        XCTAssertTrue(try matches(["name": "Polar H10"]))
        XCTAssertFalse(try matches(["name": "Polar"]))
        XCTAssertTrue(try matches(["namePrefix": "Polar"]))
        XCTAssertTrue(try matches(["manufacturerData": [["companyIdentifier": 0x6B, "dataPrefix": "AQI=", "mask": "/w8="]]]), "The mask ignores bits")
        XCTAssertFalse(try matches(["manufacturerData": [["companyIdentifier": 0x6B, "dataPrefix": "AQI="]]]))
        XCTAssertFalse(try WebBluetooth.Request.parse(["filters": [["namePrefix": "Polar"]], "exclusionFilters": [["name": "Polar H10"]]]).matches(strap))
    }

    func testAnyFilterThatCouldMatchAnIBeaconIsRefused() {
        func blocked(_ company: Int, _ prefix: [UInt8], _ mask: [UInt8]? = nil) -> Bool {
            BluetoothBlocklist.blocksManufacturer(company: company, prefix: Data(prefix), mask: mask.map { Data($0) })
        }
        XCTAssertTrue(blocked(0x4C, []), "An empty prefix matches every Apple frame")
        XCTAssertTrue(blocked(0x4C, [0x02]))
        XCTAssertTrue(blocked(0x4C, [0x02, 0x15, 0xAA]))
        XCTAssertTrue(blocked(0x4C, [0x00, 0x15], [0x00, 0xFF]), "A masked-out byte rules nothing out")
        XCTAssertTrue(blocked(0x4C, [0x03, 0x15], [0xFC, 0xFF]), "Nor do masked-out bits")
        XCTAssertFalse(blocked(0x4C, [0x03]))
        XCTAssertFalse(blocked(0x4C, [0x02, 0x16]))
        XCTAssertFalse(blocked(0x4C, [0x12, 0x15], [0x10, 0x00]))
        XCTAssertFalse(blocked(0x6B, []), "Only Apple's company id carries iBeacons")
        XCTAssertEqual(parse(["filters": [["manufacturerData": [["companyIdentifier": 0x4C]]]]]),
                       "SecurityError: requestDevice() called with a filter containing a blocklisted manufacturer data.")
        XCTAssertEqual(parse(["filters": [["manufacturerData": [["companyIdentifier": 0x4C, "dataPrefix": "EAA=", "mask": "8AA="]]]]]), "ok",
                       "10 00 under f0 00 can never be 02 15")
    }

    func testUUIDsAreCanonicalAndTheBlocklistSortsReadsFromWrites() {
        XCTAssertEqual(BluetoothUUID.alias(0x180D), "0000180d-0000-1000-8000-00805f9b34fb")
        XCTAssertNil(BluetoothUUID.canonical("0000180D-0000-1000-8000-00805F9B34FB"), "Only the lowercase form crosses")
        XCTAssertNil(BluetoothUUID.canonical(0x180D))
        XCTAssertTrue(BluetoothBlocklist.blocks(BluetoothBlocklist.characteristics[BluetoothUUID.alias(0x2A02)], write: true))
        XCTAssertFalse(BluetoothBlocklist.blocks(BluetoothBlocklist.characteristics[BluetoothUUID.alias(0x2A02)], write: false))
        XCTAssertTrue(BluetoothBlocklist.blocks(BluetoothBlocklist.characteristics[BluetoothUUID.alias(0x2A25)], write: false))
        XCTAssertTrue(BluetoothBlocklist.blocks(BluetoothBlocklist.descriptors[BluetoothUUID.alias(0x2902)], write: true))
        XCTAssertFalse(BluetoothBlocklist.blocks(BluetoothBlocklist.descriptors[BluetoothUUID.alias(0x2902)], write: false))
    }
}

/// `navigator.bluetooth` as a real page sees it, in a real tab, against the fake radio.
@MainActor final class WebBluetoothWebKitTests: XCTestCase {
    private var server: NavigationHTTPFixture!
    private var profile = UUID()
    private var tabs: [Tab] = []
    private var radio = FakeBluetooth()
    private var offered: [[String]] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        radio = FakeBluetooth()
        BluetoothFixtures.install(radio)
        WebBluetooth.backendForTesting = radio
        offered = []
        WebBluetooth.chooserForTesting = { [weak self] candidates in
            MainActor.assumeIsolated { self?.offered.append(candidates.map(\.label)) }
            return candidates.first
        }
    }

    override func tearDown() async throws {
        tabs.forEach { $0.tearDown() }
        tabs = []
        WebBluetooth.chooserForTesting = nil
        WebBluetooth.forgetAll(profileID: profile)
        // Back to no radio at all, not to CoreBluetooth: its first use is what makes macOS ask.
        WebBluetooth.backendForTesting = FakeBluetooth()
        server.stop()
        server = nil
    }

    private func load(_ path: String, host: String = "127.0.0.1", in existing: Tab? = nil, isPrivate: Bool = false) async throws -> Tab {
        let tab = existing ?? Tab(isPrivate: isPrivate, profileID: profile)
        if existing == nil { tabs.append(tab) }
        let url = try server.url(path, host: host)
        tab.navigate(to: url)
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        return tab
    }

    private func js(_ tab: Tab, _ body: String) async throws -> String? {
        try await tab.web.callAsyncJavaScript("""
            const name = promise => promise.then(() => 'ok', error => error.name);
            return await Promise.race([(async () => { \(body) })(),
                new Promise((_, reject) => setTimeout(() => reject(new Error('bluetooth fixture timed out')), 20000))]);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private let connect = """
        window.device = await navigator.bluetooth.requestDevice({ filters: [{ services: ['heart_rate'] }],
          optionalServices: ['battery_service', 'human_interface_device', 0x180a] });
        await device.gatt.connect();
        """

    func testAHeartRateStrapConnectsReadsWritesAndNotifies() async throws {
        let tab = try await load("/bt")
        let shown = try await js(tab, connect + """
            const hr = await device.gatt.getPrimaryService('heart_rate');
            const location = await hr.getCharacteristic('body_sensor_location');
            const value = await location.readValue();
            const control = await hr.getCharacteristic(0x2a39);
            await control.writeValue(new Uint8Array([1]));
            const services = (await device.gatt.getPrimaryServices()).map(s => s.uuid.slice(4, 8));
            const info = await device.gatt.getPrimaryService('device_information');
            const maker = new TextDecoder().decode(await (await info.getCharacteristic('manufacturer_name_string')).readValue());
            return JSON.stringify({ name: device.name, opaque: device.id !== '\(BluetoothFixtures.strap.uuidString)' && device.id.length > 10,
              connected: device.gatt.connected, value: value.getUint8(0), cached: location.value.getUint8(0),
              props: [location.properties.read, location.properties.write, control.properties.write],
              services, maker, same: hr === await device.gatt.getPrimaryService(0x180d), uuid: BluetoothUUID.getService('heart_rate'),
              tag: String(hr) });
            """)
        XCTAssertEqual(shown, #"{"name":"Polar H10","opaque":true,"connected":true,"value":1,"cached":1,"props":[true,false,true],"services":["180d","180f","180a"],"maker":"Polar","same":true,"uuid":"0000180d-0000-1000-8000-00805f9b34fb","tag":"[object BluetoothRemoteGATTService]"}"#)
        XCTAssertTrue(radio.calls.contains("write:5:with:[1]"))
        XCTAssertEqual(radio.calls.prefix(3), ["scan", "stop", "connect"], "The radio scans only while the chooser is up")
        XCTAssertTrue(DeviceAccess.inUse(tabID: tab.id), "A tab with a connection is not suspended")
        XCTAssertEqual(SiteControlModel(tab).bluetoothDevices, ["Polar H10"])

        let notified = try await js(tab, """
            const measurement = await (await device.gatt.getPrimaryService('heart_rate')).getCharacteristic('heart_rate_measurement');
            window.beats = [];
            measurement.oncharacteristicvaluechanged = event => beats.push(event.target.value.getUint8(1));
            await measurement.startNotifications();
            return 'listening';
            """)
        XCTAssertEqual(notified, "listening")
        XCTAssertTrue(radio.calls.contains("notify:2:true"))
        radio.onEvent?(.value(BluetoothFixtures.strap, 2, Data([0, 72])))
        radio.onEvent?(.value(BluetoothFixtures.strap, 2, Data([0, 75])))
        radio.onEvent?(.value(BluetoothFixtures.strap, 4, Data([9])))
        let beats = try await js(tab, """
            while (beats.length < 2) await new Promise(resolve => setTimeout(resolve, 20));
            return beats.join(',');
            """)
        XCTAssertEqual(beats, "72,75", "Values arrive in order, and only for characteristics the page subscribed to")
    }

    func testTheBlocklistAndTheGrantedServicesBoundWhatAPageReaches() async throws {
        let tab = try await load("/bt")
        let refused = try await js(tab, connect + """
            const hr = await device.gatt.getPrimaryService('heart_rate');
            const measurement = await hr.getCharacteristic('heart_rate_measurement');
            const info = await device.gatt.getPrimaryService('device_information');
            const control = await hr.getCharacteristic('heart_rate_control_point');
            const cccd = await measurement.getDescriptor('gatt.client_characteristic_configuration');
            return [await name(device.gatt.getPrimaryService('human_interface_device')), await name(device.gatt.getPrimaryService('generic_access')),
                    await name(info.getCharacteristic('serial_number_string')), (await info.getCharacteristics()).length,
                    await name(cccd.writeValue(new Uint8Array([1, 0]))), await name(control.readValue()),
                    await name(control.writeValueWithoutResponse(new Uint8Array([1]))), await name(control.writeValue(new Uint8Array(513))),
                    await name(hr.getCharacteristic('battery_level')), await name(device.watchAdvertisements())].join(' ');
            """)
        XCTAssertEqual(refused, "SecurityError SecurityError SecurityError 1 SecurityError NotSupportedError NotSupportedError InvalidModificationError NotFoundError NotSupportedError")

        let raw = try await js(tab, """
            const bridge = webkit.messageHandlers.\(WebBluetooth.messageName);
            const ask = body => bridge.postMessage({ id: device.id, ...body }).then(reply => reply.error ? reply.error[0] : 'done');
            const services = (await bridge.postMessage({ op: 'services', id: device.id })).value;
            return [services.length, await ask({ op: 'services', uuid: '00001812-0000-1000-8000-00805f9b34fb' }),
                    await ask({ op: 'read', handle: 'made-up' }), await ask({ op: 'connect', id: 'not-granted' }),
                    await ask({ op: 'services', uuid: 'HEART' })].join(' ');
            """)
        XCTAssertEqual(raw, "3 SecurityError InvalidStateError SecurityError TypeError", "The bridge checks for itself")
        XCTAssertFalse(radio.calls.contains { $0.hasPrefix("read:11") || $0.hasPrefix("write:3") || $0.hasPrefix("read:5") },
                       "Nothing refused reaches the radio")
    }

    func testOnlyAGestureCanAskAndTheChooserListsWhatMatches() async throws {
        server.pages["/eager"] = """
            <iframe srcdoc="<p>frame</p>"></iframe>
            <script>
            window.results = {};
            navigator.bluetooth.requestDevice({ acceptAllDevices: true }).then(() => results.api = 'granted', error => results.api = error.name);
            const bridge = webkit.messageHandlers.\(WebBluetooth.messageName);
            bridge.postMessage({ op: 'request', acceptAllDevices: true }).then(reply => results.raw = reply.error ? reply.error[0] : 'granted');
            dispatchEvent(new Event('\(WebBluetooth.gestureEvent)'));
            bridge.postMessage({ op: 'request', acceptAllDevices: true }).then(reply => results.forged = reply.error ? reply.error[0] : 'granted');
            </script>
            """
        let tab = try await load("/eager")
        try await compatibilityWait { try await tab.web.evaluateJavaScript("Object.keys(window.results).length") as? Int == 3 }
        let results = try await tab.web.evaluateJavaScript("JSON.stringify(results, Object.keys(results).sort())") as? String
        XCTAssertEqual(results, #"{"api":"SecurityError","forged":"SecurityError","raw":"SecurityError"}"#)
        XCTAssertTrue(offered.isEmpty)
        XCTAssertFalse(radio.calls.contains("scan"), "No gesture, no scan")
        let frame = try await tab.web.evaluateJavaScript("String(frames[0].navigator.bluetooth) + ',' + ('bluetooth' in navigator)") as? String
        XCTAssertEqual(frame, "undefined,true")

        let picked = try await js(tab, """
            const all = await navigator.bluetooth.requestDevice({ acceptAllDevices: true });
            const prefixed = await navigator.bluetooth.requestDevice({ filters: [{ namePrefix: 'Desk' }] });
            return [all.name, prefixed.name, await name(navigator.bluetooth.requestDevice({ filters: [{ services: [0x1812] }] })),
                    await name(navigator.bluetooth.requestDevice({ filters: [{ services: ['no_such_service'] }] })),
                    await navigator.bluetooth.getAvailability()].join(',');
            """)
        XCTAssertEqual(picked, "Polar H10,Desk Lamp,SecurityError,TypeError,true")
        XCTAssertEqual(offered, [["Polar H10", "Desk Lamp"], ["Desk Lamp"]])
        WebBluetooth.chooserForTesting = { _ in nil }
        let cancelled = try await js(tab, "return await name(navigator.bluetooth.requestDevice({ acceptAllDevices: true }));")
        XCTAssertEqual(cancelled, "NotFoundError")
        let lampOnly = try await js(tab, """
            const [lamp] = (await navigator.bluetooth.getDevices()).filter(d => d.name === 'Desk Lamp');
            await name(lamp.gatt.connect());
            return [await name(lamp.gatt.getPrimaryServices())].join();
            """)
        XCTAssertEqual(lampOnly, "NetworkError", "A device that cannot be reached does not connect")
    }

    func testDisconnectForgetAndNavigationLetGoOfTheRadio() async throws {
        let one = try await load("/bt")
        _ = try await js(one, connect + """
            window.drops = 0;
            device.ongattserverdisconnected = () => drops++;
            return 'connected';
            """)
        WebBluetooth.chooserForTesting = { _ in XCTFail("A granted device needs no chooser"); return nil }
        let two = try await load("/bt")
        let shared = try await js(two, """
            [window.device] = await navigator.bluetooth.getDevices();
            await device.gatt.connect();
            return String(device.gatt.connected);
            """)
        XCTAssertEqual(shared, "true")
        let dropped = try await js(one, "device.gatt.disconnect(); return [device.gatt.connected, drops].join(',');")
        XCTAssertEqual(dropped, "false,1")
        XCTAssertFalse(radio.calls.contains("disconnect"), "The other tab still holds the connection")
        _ = try await load("/next", in: two)
        XCTAssertTrue(radio.calls.contains("disconnect"), "The last document to let go drops it")

        _ = try await js(one, "await device.gatt.connect(); return 'again';")
        radio.onEvent?(.disconnected(BluetoothFixtures.strap))
        let lost = try await js(one, """
            while (drops < 2) await new Promise(resolve => setTimeout(resolve, 20));
            return [drops, device.gatt.connected, await name(device.gatt.getPrimaryService('heart_rate'))].join(',');
            """)
        XCTAssertEqual(lost, "2,false,NetworkError", "Out of range: the page hears of it")

        _ = try await js(one, "await device.gatt.connect(); return 'again';")
        XCTAssertEqual(SiteControlModel(one).rows.first { $0.id == .bluetooth(0) }?.control, .toggle(true))
        SiteControl.act(.bluetooth(0), on: one)
        let forgotten = try await js(one, """
            while (device.gatt.connected) await new Promise(resolve => setTimeout(resolve, 20));
            return [(await navigator.bluetooth.getDevices()).length, await name(device.gatt.connect())].join(',');
            """)
        XCTAssertEqual(forgotten, "0,SecurityError", "Forgetting from Site Controls drops it and takes it back")
        XCTAssertFalse(radio.connected.contains(BluetoothFixtures.strap))
    }

    func testTwoOriginsShareOneConnectionAndHearOnlyTheirOwnSubscriptions() async throws {
        let one = try await load("/bt")
        let two = try await load("/bt", host: "localhost")
        let subscribe = """
            window.measurement = await (await device.gatt.getPrimaryService('heart_rate')).getCharacteristic('heart_rate_measurement');
            window.beats = [];
            measurement.oncharacteristicvaluechanged = event => beats.push(event.target.value.getUint8(1));
            """
        let first = try await js(one, connect + subscribe + "await measurement.startNotifications(); return device.id;")
        let second = try await js(two, connect + subscribe + "return device.id;")
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "Two origins never see the same id")
        XCTAssertEqual(radio.calls.filter { $0 == "notify:2:true" }.count, 1)

        radio.onEvent?(.value(BluetoothFixtures.strap, 2, Data([0, 60])))
        let heard = try await js(one, "while (beats.length < 1) await new Promise(r => setTimeout(r, 20)); return beats.join(',');")
        XCTAssertEqual(heard, "60")
        let unheard = try await js(two, "await new Promise(r => setTimeout(r, 200)); return String(beats.length);")
        XCTAssertEqual(unheard, "0", "Only the subscriber hears a value")

        _ = try await js(two, "await measurement.startNotifications(); return 'on';")
        XCTAssertEqual(radio.calls.filter { $0 == "notify:2:true" }.count, 1, "One subscription on the radio serves both")
        let dropped = try await js(one, "device.gatt.disconnect(); return String(device.gatt.connected);")
        XCTAssertEqual(dropped, "false")
        XCTAssertFalse(radio.calls.contains("disconnect"), "The other origin still holds the connection")
        XCTAssertFalse(radio.calls.contains("notify:2:false"), "…and its subscription")
        radio.onEvent?(.value(BluetoothFixtures.strap, 2, Data([0, 61])))
        let still = try await js(two, "while (beats.length < 1) await new Promise(r => setTimeout(r, 20)); return [beats.join(','), device.gatt.connected].join(' ');")
        XCTAssertEqual(still, "61 true")
        let quiet = try await js(one, "await new Promise(r => setTimeout(r, 200)); return beats.join(',');")
        XCTAssertEqual(quiet, "60", "A document that let go hears nothing more")

        _ = try await js(two, "device.gatt.disconnect(); return 'off';")
        XCTAssertTrue(radio.calls.contains("notify:2:false"))
        XCTAssertTrue(radio.calls.contains("disconnect"), "The last holder lets the radio go")
    }

    func testAPrivateTabsGrantGoesWithTheTab() async throws {
        let tab = try await load("/bt", isPrivate: true)
        _ = try await js(tab, connect + "return 'connected';")
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertEqual(WebBluetooth.grants(scope: scope).count, 1)
        XCTAssertTrue(WebBluetooth.all(profileID: profile).isEmpty)
        XCTAssertFalse(UserDefaults.vane.dictionaryRepresentation().keys.contains { $0.hasPrefix("bluetoothDevice.v1." + profile.uuidString.lowercased()) })
        let regular = try await load("/bt")
        let unshared = try await js(regular, "return String((await navigator.bluetooth.getDevices()).length);")
        XCTAssertEqual(unshared, "0")
        tab.tearDown()
        tabs.removeAll { $0 === tab }
        XCTAssertTrue(WebBluetooth.grants(scope: scope).isEmpty)
        XCTAssertTrue(radio.calls.contains("disconnect"), "Closing the tab drops its connection")
    }
}
