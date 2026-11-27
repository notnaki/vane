import AppKit
import os
import WebKit
import XCTest
@testable import vane

/// Devices as their descriptors describe them.
enum USBFixtures {
    /// A debug probe: a vendor interface with a bulk pair (and an interrupt alternate), a HID
    /// interface, and a vendor interface whose only endpoint is isochronous (wMaxPacketSize
    /// 0x13C0: 960 bytes, two extra transactions).
    static let probeConfiguration: [UInt8] = [
        9, 2, 80, 0, 3, 1, 0, 0x80, 50,
        9, 4, 0, 0, 2, 0xFF, 0, 0, 0,
        7, 5, 0x04, 2, 64, 0, 0,
        7, 5, 0x85, 2, 64, 0, 0,
        9, 4, 0, 1, 1, 0xFF, 0, 0, 0,
        7, 5, 0x86, 3, 16, 0, 1,
        9, 4, 1, 0, 1, 0x03, 0, 0, 0,
        7, 5, 0x81, 3, 8, 0, 10,
        9, 4, 2, 0, 1, 0xFF, 1, 0, 0,
        7, 5, 0x03, 1, 0xC0, 0x13, 1,
    ]

    static func device(entryID: UInt64, vendorID: Int, productID: Int, product: String, serialNumber: String = "",
                       configuration: [UInt8] = probeConfiguration) -> USBDeviceInfo {
        var info = USBDeviceInfo(entryID: entryID, vendorID: vendorID, productID: productID)
        info.usbVersion = 0x0210
        info.deviceVersion = 0x0102
        info.manufacturer = "Raspberry Pi"
        info.product = product
        info.serialNumber = serialNumber
        info.locationID = 0x01100000
        info.configurations = USBConfiguration(Data(configuration)).map { [$0] } ?? []
        info.activeConfiguration = 1
        return info
    }

    static let probe = device(entryID: 201, vendorID: 0x2e8a, productID: 0x000c, product: "Picoprobe", serialNumber: "E6614103")
    static let yubikey = device(entryID: 202, vendorID: 0x1050, productID: 0x0407, product: "YubiKey OTP+FIDO+CCID", serialNumber: "1")
    static let serialless = device(entryID: 203, vendorID: 0x16c0, productID: 0x05dc, product: "USBasp")

    /// The probe with a second configuration, and nothing set when it was plugged in.
    static let twoConfigurations: USBDeviceInfo = {
        var info = device(entryID: 204, vendorID: 0x2e8a, productID: 0x000d, product: "Two Configs", serialNumber: "TC1")
        var second = probeConfiguration
        second[5] = 2
        info.configurations += USBConfiguration(Data(second)).map { [$0] } ?? []
        info.activeConfiguration = nil
        return info
    }()
}

/// Stands in for an open device: records what reached it and answers like one.
final class FakeUSBTransport: USBTransport, @unchecked Sendable {
    /// What the device itself says when opened; nil is a fresh, unconfigured device.
    let configuration: UInt8?
    /// How long state changes and transfers take, to let calls overlap.
    let delay: Duration
    init(configuration: UInt8? = nil, delay: Duration = .zero) {
        self.configuration = configuration
        self.delay = delay
    }
    private func pause() async { if delay > .zero { try? await Task.sleep(for: delay) } }
    enum Call: Equatable {
        case configure(UInt8), claim(UInt8), release(UInt8), alternate(UInt8, UInt8)
        case control(USBSetup, [UInt8]?, Int), transfer(UInt8, [UInt8]?, Int), clearHalt(UInt8), reset
    }
    private let state = OSAllocatedUnfairLock(initialState: (calls: [Call](), closed: false, releases: 0))
    var calls: [Call] { state.withLock { $0.calls } }
    var closed: Bool { state.withLock { $0.closed } }
    private func record(_ call: Call) -> Bool { state.withLock { $0.calls.append(call); return !$0.closed } }

    func selectConfiguration(_ value: UInt8) async -> Bool { record(.configure(value)) }
    func claim(_ interface: UInt8) async -> Bool { await pause(); return record(.claim(interface)) }
    func release(_ interface: UInt8) async -> Bool { state.withLock { $0.releases += 1 }; return record(.release(interface)) }
    func selectAlternate(_ interface: UInt8, setting: UInt8) async -> Bool { record(.alternate(interface, setting)) }
    func control(_ setup: USBSetup, data: Data?, length: Int) async -> USBTransfer {
        guard record(.control(setup, data.map(Array.init), length)) else { return .failed }
        return data.map { USBTransfer(status: .ok, written: $0.count) } ?? USBTransfer(status: .ok, data: Data([9, 8, 7, 6, 5].prefix(length)))
    }
    func transfer(endpoint: UInt8, data: Data?, length: Int) async -> USBTransfer {
        guard record(.transfer(endpoint, data.map(Array.init), length)) else { return .failed }
        // As IOUSBLib does: releasing an interface or closing aborts what is waiting on it.
        let releases = state.withLock { $0.releases }
        await pause()
        guard state.withLock({ !$0.closed && $0.releases == releases }) else { return .failed }
        return data.map { USBTransfer(status: .ok, written: $0.count) } ?? USBTransfer(status: .ok, data: Data([0xAB, 0xCD].prefix(length)))
    }
    func clearHalt(endpoint: UInt8) async -> Bool { record(.clearHalt(endpoint)) }
    func reset() async -> Bool { record(.reset) }
    func close() { state.withLock { $0.closed = true } }
}

@MainActor final class WebUSBTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }

    func testAConfigurationDescriptorParsesIntoInterfacesAlternatesAndEndpoints() throws {
        let config = try XCTUnwrap(USBConfiguration(Data(USBFixtures.probeConfiguration)))
        XCTAssertEqual(config.value, 1)
        XCTAssertEqual(config.interfaces.map(\.number), [0, 1, 2])
        XCTAssertEqual(config.interfaces[0].alternates.map(\.setting), [0, 1])
        XCTAssertEqual(config.interfaces[0].alternates[0].endpoints.map(\.address), [0x04, 0x85])
        XCTAssertEqual(config.interfaces[0].alternates[1].endpoints.first?.kind, 3)
        XCTAssertEqual(config.interfaces[2].alternates[0].endpoints.first?.packetSize, 960, "The extra-transaction bits are not bytes")
        XCTAssertEqual(config.interfaces.map(\.isProtected), [false, true, false], "HID is the system's")
        let json = config.interfaces[0].alternates[0].endpoints[1].json
        XCTAssertEqual(json["direction"] as? String, "in")
        XCTAssertEqual(json["type"] as? String, "bulk")
        XCTAssertEqual(json["endpointNumber"] as? Int, 5)
    }

    func testMalformedDescriptorsParseWithoutTrapping() {
        XCTAssertNil(USBConfiguration(Data()))
        XCTAssertNil(USBConfiguration(Data([9, 4, 0, 0, 0, 0, 0, 0, 0])), "An interface descriptor is not a configuration")
        let cut = USBConfiguration(Data(USBFixtures.probeConfiguration.prefix(30)))
        XCTAssertEqual(cut?.interfaces.first?.alternates.first?.endpoints.count, 1, "A short read keeps what it got")
        XCTAssertEqual(USBConfiguration(Data([9, 2, 40, 0, 1, 1, 0, 0x80, 50, 0, 0, 9, 4]))?.interfaces, [], "A zero length ends the walk")
        XCTAssertEqual(USBConfiguration(Data([9, 2, 0xFF, 0xFF, 1, 1, 0, 0x80, 50, 7, 5, 0x81, 3, 8, 0, 1]))?.interfaces, [],
                       "An endpoint before any interface belongs to nothing")
    }

    func testFiltersFollowChromiumsRules() throws {
        func error(_ filters: [[String: Any]]) -> String? {
            do { _ = try WebUSB.Filter.parse(filters); return nil } catch { return error.message }
        }
        XCTAssertEqual(error([["productId": 1]]), "A filter containing a productId must also contain a vendorId.")
        XCTAssertEqual(error([["subclassCode": 1]]), "A filter containing a subclassCode must also contain a classCode.")
        XCTAssertEqual(error([["classCode": 1, "protocolCode": 1]]), "A filter containing a protocolCode must also contain a subclassCode.")
        XCTAssertEqual(error([["vendorId": 0x10000]]), "vendorId is not valid.")
        XCTAssertEqual(error([["classCode": true]]), "classCode is not valid.")
        XCTAssertNil(error([[:]]), "An empty filter matches every device, as in Chromium")

        let probe = USBFixtures.probe
        let vendor = try WebUSB.Filter.parse([["classCode": 0xFF]])
        XCTAssertTrue(vendor[0].matches(probe), "A class code matches an interface")
        XCTAssertFalse(try WebUSB.Filter.parse([["classCode": 0xFF, "subclassCode": 2]])[0].matches(probe))
        XCTAssertTrue(try WebUSB.Filter.parse([["classCode": 0xFF, "subclassCode": 1, "protocolCode": 0]])[0].matches(probe))
        XCTAssertTrue(try WebUSB.Filter.parse([["vendorId": 0x2e8a, "serialNumber": "E6614103"]])[0].matches(probe))
        XCTAssertFalse(try WebUSB.Filter.parse([["vendorId": 0x2e8a, "serialNumber": "other"]])[0].matches(probe))

        let all = [probe, USBFixtures.yubikey, USBFixtures.serialless]
        XCTAssertEqual(WebUSB.Filter.candidates(all, filters: []).map(\.entryID), [201, 203], "A security key is never offered")
        XCTAssertEqual(WebUSB.Filter.candidates(all, filters: [], excluding: try WebUSB.Filter.parse([["vendorId": 0x16c0]])).map(\.entryID), [201])
    }

    func testOnlyExactlyLocalhostAndLoopbackAreSecureOverHTTP() throws {
        func secure(_ url: String) -> Bool { DeviceAccess.isSecure(try! XCTUnwrap(SitePermissions.Scope(url: URL(string: url), profileID: UUID()))) }
        XCTAssertTrue(secure("https://example.com"))
        XCTAssertTrue(secure("http://localhost:8000"))
        XCTAssertTrue(secure("http://127.4.5.6"))
        XCTAssertTrue(secure("http://[::1]:3000"))
        XCTAssertFalse(secure("http://app.localhost"))
        XCTAssertFalse(secure("http://0.0.0.0"))
        XCTAssertFalse(secure("http://example.com"))
    }

    func testGrantsStayWithTheirOriginProfileAndPrivateTabAndSerialLessOnesAreNeverWritten() throws {
        let profile = UUID(), other = UUID(), privateTab = UUID()
        defer { WebUSB.forgetAll(profileID: profile); WebUSB.forgetAll(profileID: other); WebUSB.forgetPrivate(tabID: privateTab) }
        let scope = try XCTUnwrap(SitePermissions.Scope(url: URL(string: "https://flash.example"), profileID: profile))
        WebUSB.grant(USBFixtures.probe, scope: scope)
        WebUSB.grant(USBFixtures.probe, scope: scope)
        WebUSB.grant(USBFixtures.serialless, scope: scope)
        XCTAssertEqual(WebUSB.grants(scope: scope).map(\.name), ["Picoprobe", "USBasp"], "Picking a device again adds no second grant")
        XCTAssertEqual(WebUSB.all(profileID: profile).count, 2)
        XCTAssertTrue(WebUSB.grants(scope: SitePermissions.Scope(url: URL(string: "https://flash.example"), profileID: other)).isEmpty)
        XCTAssertTrue(WebUSB.grants(scope: SitePermissions.Scope(url: URL(string: "https://flash.example:8443"), profileID: profile)).isEmpty)
        let written = UserDefaults.vane.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("usbDevice.v1." + profile.uuidString.lowercased()) }.values.compactMap { $0 as? Data }
        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(String(decoding: written[0], as: UTF8.self).contains("USBasp"), "A device known only by its port is not written down")

        let hidden = try XCTUnwrap(SitePermissions.Scope(url: URL(string: "https://flash.example"), profileID: profile, privateTabID: privateTab))
        WebUSB.grant(USBFixtures.serialless, scope: hidden)
        XCTAssertEqual(WebUSB.grants(scope: hidden).count, 1)
        XCTAssertEqual(WebUSB.all(profileID: profile).count, 2, "A private grant is not the profile's")
        WebUSB.forgetPrivate(tabID: privateTab)
        XCTAssertTrue(WebUSB.grants(scope: hidden).isEmpty)

        DeviceAccess.forgetAll(profileID: profile)
        XCTAssertTrue(WebUSB.grants(scope: scope).isEmpty, "Reset Permissions and profile deletion take USB grants too")
    }

    func testInFlightWorkIsCappedInCallsAndBytes() {
        var budget = USBBudget()
        XCTAssertTrue(budget.admit(USBBudget.maxBytes - 10))
        XCTAssertFalse(budget.admit(11), "16 MiB of buffers at most")
        XCTAssertTrue(budget.admit(10))
        budget.done(USBBudget.maxBytes - 10)
        budget.done(10)
        XCTAssertEqual(budget, USBBudget())
        for _ in 0..<USBBudget.maxPending { XCTAssertTrue(budget.admit(0)) }
        XCTAssertFalse(budget.admit(0), "No more calls than maxPending")
        var fresh = USBBudget()
        XCTAssertFalse(fresh.admit(Int.max), "No overflow")
    }
}

/// `navigator.usb` as a real page sees it, in a real tab, against fake devices. The chooser
/// is answered by the fixture; nothing here shows a window or touches hardware.
@MainActor final class WebUSBWebKitTests: XCTestCase {
    private var server: NavigationHTTPFixture!
    private var profile = UUID()
    private var tabs: [Tab] = []
    private var transports: [FakeUSBTransport] = []
    private var offered: [[UInt64]] = []
    private var makeTransport: () -> FakeUSBTransport = { FakeUSBTransport() }

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        plug([USBFixtures.probe, USBFixtures.yubikey, USBFixtures.serialless])
        offered = []
        WebUSB.chooserForTesting = { [weak self] candidates in
            MainActor.assumeIsolated { self?.offered.append(candidates.map(\.entryID)) }
            return candidates.first
        }
        WebUSB.transportForTesting = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return nil }
                let transport = self.makeTransport()
                self.transports.append(transport)
                return transport
            }
        }
    }

    override func tearDown() async throws {
        tabs.forEach { $0.tearDown() }
        tabs = []
        WebUSB.chooserForTesting = nil
        WebUSB.transportForTesting = nil
        // Never back to the real registry: listing reads every device's descriptors.
        plug([])
        WebUSB.forgetAll(profileID: profile)
        server.stop()
        server = nil
        transports = []
    }

    private func plug(_ devices: [USBDeviceInfo]) {
        USBDevices.shared.listForTesting = { devices }
        USBDevices.shared.refresh()
    }

    private func load(_ path: String, host: String = "127.0.0.1", in existing: Tab? = nil, isPrivate: Bool = false) async throws -> Tab {
        let tab = existing ?? Tab(isPrivate: isPrivate, profileID: profile)
        if existing == nil { tabs.append(tab) }
        let url = try server.url(path, host: host)
        tab.navigate(to: url)
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        return tab
    }

    /// Runs as the body of an async function in the page, as a user gesture.
    private func js(_ tab: Tab, _ body: String) async throws -> String? {
        try await tab.web.callAsyncJavaScript("""
            const name = promise => promise.then(() => 'ok', error => error.name);
            return await Promise.race([(async () => { \(body) })(),
                new Promise((_, reject) => setTimeout(() => reject(new Error('usb fixture timed out')), 20000))]);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private let connect = """
        window.device = await navigator.usb.requestDevice({ filters: [{ vendorId: 0x2e8a }] });
        await device.open();
        await device.selectConfiguration(1);
        await device.claimInterface(0);
        """

    func testAProbeOpensClaimsAndTransfers() async throws {
        let tab = try await load("/usb")
        let shown = try await js(tab, connect + """
            const c = device.configuration, i = c.interfaces[0], e = i.alternate.endpoints;
            const out = await device.transferOut(4, new Uint8Array([1, 2, 3]));
            const got = await device.transferIn(5, 64);
            const control = await device.controlTransferIn({ requestType: 'vendor', recipient: 'device', request: 1, value: 2, index: 3 }, 4);
            const sent = await device.controlTransferOut({ requestType: 'class', recipient: 'interface', request: 0x22, value: 1, index: 0 });
            const again = await navigator.usb.getDevices();
            return JSON.stringify({ name: device.productName, maker: device.manufacturerName, serial: device.serialNumber,
              usb: [device.usbVersionMajor, device.usbVersionMinor], version: [device.deviceVersionMajor, device.deviceVersionMinor, device.deviceVersionSubminor],
              config: c.configurationValue, interfaces: c.interfaces.length, claimed: i.claimed, other: c.interfaces[1].claimed,
              endpoints: e.map(x => x.direction + x.endpointNumber + x.type), out: [out.status, out.bytesWritten],
              in: [got.status, ...new Uint8Array(got.data.buffer)], control: [...new Uint8Array(control.data.buffer)],
              sent: sent.bytesWritten, same: again.length === 1 && again[0] === device, tag: String(device),
              result: got instanceof USBInTransferResult });
            """)
        XCTAssertEqual(shown, #"{"name":"Picoprobe","maker":"Raspberry Pi","serial":"E6614103","usb":[2,1],"version":[1,0,2],"config":1,"interfaces":3,"claimed":true,"other":false,"endpoints":["out4bulk","in5bulk"],"out":["ok",3],"in":["ok",171,205],"control":[9,8,7,6],"sent":0,"same":true,"tag":"[object USBDevice]","result":true}"#)
        let transport = try XCTUnwrap(transports.first)
        XCTAssertEqual(transport.calls, [
            .configure(1), .claim(0), .transfer(0x04, [1, 2, 3], 0), .transfer(0x85, nil, 64),
            .control(USBSetup(requestType: 0x40, request: 1, value: 2, index: 3), nil, 4),
            .control(USBSetup(requestType: 0x21, request: 0x22, value: 1, index: 0), [], 0),
        ])
        XCTAssertTrue(WebUSB.hasOpenDevice(tabID: tab.id))
        XCTAssertTrue(DeviceAccess.inUse(tabID: tab.id), "A tab with an open device is not suspended")
        XCTAssertEqual(SiteControlModel(tab).usbDevices, ["Picoprobe"])

        let alternate = try await js(tab, """
            await device.selectAlternateInterface(0, 1);
            return [device.configuration.interfaces[0].alternate.alternateSetting, await name(device.transferIn(6, 16)),
                    await name(device.transferIn(5, 64)), await name(device.releaseInterface(0)),
                    await name(device.transferIn(6, 16)), await name(device.close()), String(device.opened)].join(' ');
            """)
        XCTAssertEqual(alternate, "1 ok NotFoundError ok NotFoundError ok false", "Endpoints follow the selected alternate and the claim")
        XCTAssertTrue(transport.closed)
        XCTAssertFalse(WebUSB.hasOpenDevice(tabID: tab.id))
    }

    func testProtectedInterfacesAndUnclaimedEndpointsNeverReachTheDevice() async throws {
        let tab = try await load("/usb")
        let refused = try await js(tab, connect + """
            return [await name(device.claimInterface(1)), await name(device.transferIn(1, 8)), await name(device.transferOut(5, new Uint8Array(1))),
                    await name(device.transferOut(3, new Uint8Array(1))), await name(device.claimInterface(9)),
                    await name(device.controlTransferIn({ requestType: 'class', recipient: 'interface', request: 1, value: 0, index: 1 }, 8)),
                    await name(device.controlTransferIn({ requestType: 'standard', recipient: 'endpoint', request: 0, value: 0, index: 0x81 }, 2)),
                    await name(device.controlTransferOut({ requestType: 'standard', recipient: 'device', request: 9, value: 2, index: 0 })),
                    await name(device.controlTransferOut({ requestType: 'bogus', recipient: 'device', request: 0, value: 0, index: 0 })),
                    await name(device.selectConfiguration(7)), await name(device.isochronousTransferIn(3, [960]))].join(' ');
            """)
        XCTAssertEqual(refused, "SecurityError NotFoundError NotFoundError NotFoundError NotFoundError InvalidStateError NotFoundError SecurityError TypeError NotFoundError NotSupportedError")

        // The page script is the page's: the bridge checks the same things itself.
        let raw = try await js(tab, """
            const bridge = webkit.messageHandlers.\(WebUSB.messageName);
            const [{ id }] = (await bridge.postMessage({ op: 'devices' })).value;
            const ask = body => bridge.postMessage({ id, ...body }).then(reply => reply.error ? reply.error[0] : 'done');
            return [await ask({ op: 'claim', interface: 1 }), await ask({ op: 'transfer', direction: 'out', endpoint: 3, data: 'AQ==' }),
                    await ask({ op: 'transfer', direction: 'in', endpoint: 1, length: 8 }),
                    await ask({ op: 'controlOut', setup: { requestType: 1, recipient: 1, request: 9, value: 0, index: 1 }, data: '' }),
                    await ask({ op: 'transfer', direction: 'in', endpoint: 5, length: 5000000 }),
                    await ask({ op: 'open', id: 'not-granted' })].join(' ');
            """)
        XCTAssertEqual(raw, "SecurityError NotFoundError NotFoundError InvalidStateError TypeError TypeError")
        XCTAssertEqual(try XCTUnwrap(transports.first).calls, [.configure(1), .claim(0)], "Nothing refused may reach the device")
    }

    func testSecurityKeysAreNeverOfferedAndOnlyAGestureCanAsk() async throws {
        server.pages["/eager"] = """
            <iframe srcdoc="<p>frame</p>"></iframe>
            <script>
            window.results = {};
            navigator.usb.requestDevice({ filters: [] }).then(() => results.api = 'granted', error => results.api = error.name);
            const bridge = webkit.messageHandlers.\(WebUSB.messageName);
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.raw = reply.error ? reply.error[0] : 'granted');
            dispatchEvent(new Event('\(WebUSB.gestureEvent)'));
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.forged = reply.error ? reply.error[0] : 'granted');
            </script>
            """
        let tab = try await load("/eager")
        try await compatibilityWait { try await tab.web.evaluateJavaScript("Object.keys(window.results).length") as? Int == 3 }
        let results = try await tab.web.evaluateJavaScript("JSON.stringify(results, Object.keys(results).sort())") as? String
        XCTAssertEqual(results, #"{"api":"SecurityError","forged":"SecurityError","raw":"SecurityError"}"#)
        XCTAssertTrue(offered.isEmpty, "No chooser without a gesture")
        let frame = try await tab.web.evaluateJavaScript("String(frames[0].navigator.usb) + ',' + ('usb' in navigator)") as? String
        XCTAssertEqual(frame, "undefined,true", "Only the main frame gets the API")

        let picked = try await js(tab, "return (await navigator.usb.requestDevice({ filters: [] })).productName;")
        XCTAssertEqual(picked, "Picoprobe")
        XCTAssertEqual(offered, [[201, 203]], "The YubiKey is never in the list")
        WebUSB.chooserForTesting = { _ in nil }
        let cancelled = try await js(tab, "return await name(navigator.usb.requestDevice({ filters: [{ vendorId: 0x16c0 }] }));")
        XCTAssertEqual(cancelled, "NotFoundError", "Cancelling rejects")
    }

    func testNavigationUnplugAndForgetEachEndTheDevice() async throws {
        let tab = try await load("/usb")
        _ = try await js(tab, connect + "return 'open';")
        let first = try XCTUnwrap(transports.first)
        WebUSB.chooserForTesting = { _ in XCTFail("A granted device needs no chooser"); return nil }
        _ = try await load("/next", in: tab)
        XCTAssertTrue(first.closed, "A new document must not inherit an open device")
        let reopened = try await js(tab, """
            [window.device] = await navigator.usb.getDevices();
            await device.open();
            window.events = [];
            navigator.usb.ondisconnect = event => events.push('disconnect:' + (event.device === device));
            navigator.usb.addEventListener('connect', event => events.push('connect:' + (event.device === device)));
            return String(device.opened);
            """)
        XCTAssertEqual(reopened, "true")

        plug([USBFixtures.yubikey])
        let lost = try await js(tab, """
            while (events.length < 1) await new Promise(resolve => setTimeout(resolve, 20));
            return [events[0], device.opened, (await navigator.usb.getDevices()).length].join(',');
            """)
        XCTAssertEqual(lost, "disconnect:true,false,0")
        XCTAssertTrue(try XCTUnwrap(transports.last).closed)
        plug([USBFixtures.probe])
        let back = try await js(tab, """
            while (events.length < 2) await new Promise(resolve => setTimeout(resolve, 20));
            return events[1];
            """)
        XCTAssertEqual(back, "connect:true", "A device with a serial number keeps its grant across a replug")

        _ = try await js(tab, "await device.open(); return 'open';")
        XCTAssertEqual(SiteControlModel(tab).rows.first { $0.id == .usb(0) }?.control, .toggle(true))
        SiteControl.act(.usb(0), on: tab)
        XCTAssertTrue(try XCTUnwrap(transports.last).closed, "Forgetting from Site Controls closes it under the page")
        let after = try await js(tab, """
            while (device.opened) await new Promise(resolve => setTimeout(resolve, 20));
            return String((await navigator.usb.getDevices()).length);
            """)
        XCTAssertEqual(after, "0")

        // A device without a serial number is known by its port, and only until it leaves it.
        plug([USBFixtures.serialless])
        WebUSB.chooserForTesting = { $0.first }
        _ = try await js(tab, "await navigator.usb.requestDevice({ filters: [{ vendorId: 0x16c0 }] }); return 'granted';")
        XCTAssertEqual(WebUSB.grants(scope: SitePermissions.scope(for: tab)).map(\.name), ["USBasp"])
        plug([])
        XCTAssertTrue(WebUSB.grants(scope: SitePermissions.scope(for: tab)).isEmpty)
    }

    func testTheConfigurationIsTheDevicesOwnAndChangingItReleasesClaims() async throws {
        plug([USBFixtures.twoConfigurations])
        makeTransport = { FakeUSBTransport(configuration: 2) }
        let tab = try await load("/usb")
        let shown = try await js(tab, """
            window.device = await navigator.usb.requestDevice({ filters: [{ productId: 0x000d, vendorId: 0x2e8a }] });
            const before = String(device.configuration);
            await device.open();
            const opened = device.configuration.configurationValue;
            await device.selectConfiguration(2);
            await device.claimInterface(0);
            await device.selectConfiguration(1);
            return [before, opened, device.configuration.configurationValue, device.configuration.interfaces[0].claimed,
                    await name(device.transferIn(5, 8))].join(' ');
            """)
        XCTAssertEqual(shown, "null 2 1 false NotFoundError", "Plugged in unconfigured, macOS set 2 since: the device's answer wins")
        XCTAssertEqual(try XCTUnwrap(transports.first).calls, [.claim(0), .release(0), .configure(1)],
                       "Selecting the current configuration sends nothing; a new one releases claims first")
        XCTAssertEqual(USBDevices.shared.devices.first?.activeConfiguration, 1, "What was read at attach time is stale now")

        makeTransport = { FakeUSBTransport(configuration: nil) }
        let fresh = try await js(tab, """
            await device.close();
            await device.open();
            return [String(device.configuration), await name(device.claimInterface(0))].join(' ');
            """)
        XCTAssertEqual(fresh, "null InvalidStateError", "An unconfigured device is not taken for configured")
        let raw = try await js(tab, """
            const bridge = webkit.messageHandlers.\(WebUSB.messageName);
            const [{ id }] = (await bridge.postMessage({ op: 'devices' })).value;
            const reply = await bridge.postMessage({ op: 'claim', id, interface: 0 });
            return reply.error ? reply.error[0] : 'claimed';
            """)
        XCTAssertEqual(raw, "InvalidStateError", "The bridge does not trust the page's mirror either")
    }

    func testStateChangesOnOneDeviceNeverOverlap() async throws {
        plug([USBFixtures.twoConfigurations])
        makeTransport = { FakeUSBTransport(configuration: 1, delay: .milliseconds(300)) }
        let tab = try await load("/usb")
        let raced = try await js(tab, """
            window.device = await navigator.usb.requestDevice({ filters: [{ vendorId: 0x2e8a }] });
            await device.open();
            const bridge = webkit.messageHandlers.\(WebUSB.messageName);
            const [{ id }] = (await bridge.postMessage({ op: 'devices' })).value;
            const ask = body => bridge.postMessage({ id, ...body }).then(reply => reply.error ? reply.error[0] : 'done');
            const claim = ask({ op: 'claim', interface: 0 });
            const others = await Promise.all([ask({ op: 'configure', value: 2 }), ask({ op: 'claim', interface: 2 }),
                                              ask({ op: 'reset' }), ask({ op: 'alternate', interface: 0, setting: 1 })]);
            return [await claim, ...others, await ask({ op: 'claim', interface: 2 })].join(' ');
            """)
        XCTAssertEqual(raced, "done InvalidStateError InvalidStateError InvalidStateError InvalidStateError done",
                       "A configure racing a claim could land the claim on the old configuration")
        XCTAssertEqual(try XCTUnwrap(transports.first).calls, [.claim(0), .claim(2)])
    }

    func testReleasingOrClosingUnderAPendingTransferEndsIt() async throws {
        makeTransport = { FakeUSBTransport(configuration: 1, delay: .milliseconds(300)) }
        let tab = try await load("/usb")
        let ended = try await js(tab, connect + """
            const pending = name(device.transferIn(5, 64));
            await device.releaseInterface(0);
            const after = await name(device.transferIn(5, 64));
            await device.claimInterface(0);
            const second = name(device.transferIn(5, 64));
            await device.close();
            return [await pending, after, await second].join(' ');
            """)
        XCTAssertEqual(ended, "NetworkError NotFoundError NetworkError",
                       "A released interface takes no new transfer; closing fails the one in flight")
        let transport = try XCTUnwrap(transports.first)
        XCTAssertEqual(transport.calls, [.claim(0), .transfer(0x85, nil, 64), .release(0), .claim(0), .transfer(0x85, nil, 64)])
        XCTAssertTrue(transport.closed)
    }

    func testAPrivateTabsGrantGoesWithTheTab() async throws {
        let tab = try await load("/usb", isPrivate: true)
        _ = try await js(tab, connect + "return 'open';")
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertEqual(WebUSB.grants(scope: scope).count, 1)
        XCTAssertTrue(WebUSB.all(profileID: profile).isEmpty, "A private grant is not the profile's")
        let regular = try await load("/usb")
        let unshared = try await js(regular, "return String((await navigator.usb.getDevices()).length);")
        XCTAssertEqual(unshared, "0")
        tab.tearDown()
        tabs.removeAll { $0 === tab }
        XCTAssertTrue(try XCTUnwrap(transports.first).closed)
        XCTAssertTrue(WebUSB.grants(scope: scope).isEmpty)
    }
}
