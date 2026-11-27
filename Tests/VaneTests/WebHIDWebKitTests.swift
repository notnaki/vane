import AppKit
import os
import WebKit
import XCTest
@testable import vane

/// Stands in for an open IOHIDDevice: records what the page sent, answers feature reports,
/// and plays input reports into the page.
final class FakeHIDTransport: HIDTransport, @unchecked Sendable {
    struct Sent: Equatable { var type: HIDReportType; var id: UInt8; var data: [UInt8] }
    private let state = OSAllocatedUnfairLock(initialState: (sent: [Sent](), closed: false))
    let input: @Sendable (UInt8, Data) -> Void

    init(input: @escaping @Sendable (UInt8, Data) -> Void) { self.input = input }

    var sent: [Sent] { state.withLock { $0.sent } }
    var closed: Bool { state.withLock { $0.closed } }

    func send(_ type: HIDReportType, id: UInt8, data: Data) async -> Bool {
        state.withLock { state in
            state.sent.append(Sent(type: type, id: id, data: [UInt8](data)))
            return !state.closed
        }
    }

    func feature(id: UInt8, length: Int) async -> Data? { closed ? nil : Data([id, 0xAB, 0xCD]) }
    func close() { state.withLock { $0.closed = true } }
}

/// `navigator.hid` as a real page sees it, in a real tab, against fake devices. The chooser
/// is answered by the fixture; nothing here shows a window or touches hardware.
@MainActor final class WebHIDWebKitTests: XCTestCase {
    private var server: NavigationHTTPFixture!
    private var profile = UUID()
    private var tabs: [Tab] = []
    private var transports: [FakeHIDTransport] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        plug([HIDFixtures.via, HIDFixtures.board, HIDFixtures.key])
        WebHID.chooserForTesting = { $0.first }
        WebHID.transportForTesting = { [weak self] _, input in
            let transport = FakeHIDTransport(input: input)
            MainActor.assumeIsolated { self?.transports.append(transport) }
            return transport
        }
    }

    override func tearDown() async throws {
        tabs.forEach { $0.tearDown() }
        tabs = []
        WebHID.chooserForTesting = nil
        WebHID.transportForTesting = nil
        HIDDevices.shared.listForTesting = nil
        HIDDevices.shared.refresh()
        WebHID.forgetAll(profileID: profile)
        server.stop()
        server = nil
        transports = []
    }

    /// What IOKit would report, and the notification that it changed.
    private func plug(_ devices: [HIDDeviceInfo]) {
        HIDDevices.shared.listForTesting = { devices }
        HIDDevices.shared.refresh()
    }

    private func load(_ path: String, host: String = "127.0.0.1", in existing: Tab? = nil) async throws -> Tab {
        let tab = existing ?? Tab(profileID: profile)
        if existing == nil { tabs.append(tab) }
        let url = try server.url(path, host: host)
        tab.navigate(to: url)
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        return tab
    }

    /// Runs as the body of an async function in the page. WebKit runs it as a user gesture,
    /// which is what a click on a Connect button is. A hung promise fails instead of stalling CI.
    private func js(_ tab: Tab, _ body: String) async throws -> String? {
        try await tab.web.callAsyncJavaScript("""
            return await Promise.race([(async () => { \(body) })(),
                new Promise((_, reject) => setTimeout(() => reject(new Error('hid fixture timed out')), 20000))]);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private let connect = """
        [window.device] = await navigator.hid.requestDevice({ filters: [{ usagePage: 0xFF60, usage: 0x61 }] });
        await device.open();
        """

    func testVIAConnectsSendsAndReceivesReports() async throws {
        let tab = try await load("/hid")
        let opened = try await js(tab, connect + """
            const c = device.collections[0], out = c.outputReports[0];
            await device.sendReport(0, new Uint8Array(32).fill(7));
            const again = await navigator.hid.getDevices();
            return JSON.stringify({ opened: device.opened, vendor: device.vendorId, product: device.productId,
                                    name: device.productName, page: c.usagePage, usage: c.usage,
                                    out: [out.reportId, out.items[0].reportSize, out.items[0].reportCount],
                                    same: again.length === 1 && again[0] === device, tag: String(device) });
            """)
        XCTAssertEqual(opened, #"{"opened":true,"vendor":13364,"product":321,"name":"Keychron Q1","page":65376,"usage":97,"out":[0,8,32],"same":true,"tag":"[object HIDDevice]"}"#)
        let transport = try XCTUnwrap(transports.first)
        XCTAssertEqual(transport.sent, [.init(type: .output, id: 0, data: [UInt8](repeating: 7, count: 32))])
        XCTAssertTrue(WebHID.hasOpenDevice(tabID: tab.id))
        XCTAssertEqual(SiteControlModel(tab).hidDevices, ["Keychron Q1"], "Site Controls must list the device the site was given")

        _ = try await js(tab, """
            window.reports = [];
            device.oninputreport = event => reports.push([event instanceof HIDInputReportEvent, event.device === device,
                                                          event.reportId, ...new Uint8Array(event.data.buffer)].join(','));
            return 'listening';
            """)
        transport.input(0, Data([1, 2, 3]))
        transport.input(0, Data([4, 5]))
        let reports = try await js(tab, """
            while (reports.length < 2) await new Promise(resolve => setTimeout(resolve, 20));
            return reports.join(' ');
            """)
        XCTAssertEqual(reports, "true,true,0,1,2,3 true,true,0,4,5", "Reports arrive whole and in order")

        let errors = try await js(tab, """
            const name = promise => promise.then(() => 'ok', error => error.name);
            return [await name(device.sendReport(0, new Uint8Array(33))), await name(device.sendReport(1, new Uint8Array(1))),
                    await name(device.receiveFeatureReport(0)), await name(device.sendReport(256, new Uint8Array(1))),
                    await name(device.open()), await name(device.close()), String(device.opened),
                    await name(device.sendReport(0, new Uint8Array(1)))].join(' ');
            """)
        XCTAssertEqual(errors, "NotAllowedError NotAllowedError NotAllowedError TypeError InvalidStateError ok false InvalidStateError")
        XCTAssertTrue(transport.closed)
        XCTAssertFalse(WebHID.hasOpenDevice(tabID: tab.id))
        XCTAssertEqual(transport.sent.count, 1, "Nothing refused may reach the device")
    }

    func testFeatureReportsCarryTheirIdLikeChrome() async throws {
        let lit = HIDFixtures.device(HIDFixtures.keyboardWithFeature, entryID: 105, vendorID: 0x3434, productID: 0x0141,
                                     product: "Keychron Q1", locationID: 0x2200000)
        plug([lit])
        let tab = try await load("/hid")
        let result = try await js(tab, """
            const [device] = await navigator.hid.requestDevice({ filters: [{ vendorId: 0x3434 }] });
            await device.open();
            const c = device.collections[0];
            await device.sendFeatureReport(0, new Uint8Array([9, 9]));
            const view = await device.receiveFeatureReport(0);
            return [c.inputReports.length, c.outputReports.length, c.featureReports.length,
                    view instanceof DataView, ...new Uint8Array(view.buffer)].join(',');
            """)
        XCTAssertEqual(result, "0,0,1,true,0,171,205", "A keyboard shows its settings, never its keys")
        XCTAssertEqual(transports.first?.sent, [.init(type: .feature, id: 0, data: [9, 9])])
        _ = try await js(tab, """
            const [device] = await navigator.hid.getDevices();
            window.typed = 0;
            device.addEventListener('inputreport', () => typed++);
            return 'listening';
            """)
        transports.first?.input(0, Data([0, 0, 4, 0, 0, 0, 0, 0]))
        let typed = try await js(tab, "await new Promise(resolve => setTimeout(resolve, 300)); return String(typed);")
        XCTAssertEqual(typed, "0", "A keystroke must never reach the page")
    }

    func testBlockedDevicesAreNeverOfferedAndOnlyAGestureCanAsk() async throws {
        var offered: [[UInt64]] = []
        WebHID.chooserForTesting = { candidates in
            MainActor.assumeIsolated { offered.append(candidates.map(\.entryID)) }
            return candidates.first
        }
        server.pages["/eager"] = """
            <iframe srcdoc="<p>frame</p>"></iframe>
            <script>
            window.results = {};
            navigator.hid.requestDevice({ filters: [] }).then(() => results.api = 'granted', error => results.api = error.name);
            const bridge = webkit.messageHandlers.\(WebHID.messageName);
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.raw = reply.error ? reply.error[0] : 'granted');
            bridge.postMessage({ op: 'open', id: 'not-granted' }).then(reply => results.open = reply.error ? reply.error[0] : 'opened');
            dispatchEvent(new Event('\(WebHID.gestureEvent)'));
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.forged = reply.error ? reply.error[0] : 'granted');
            </script>
            """
        let tab = try await load("/eager")
        try await compatibilityWait {
            try await tab.web.evaluateJavaScript("Object.keys(window.results).length") as? Int == 4
        }
        let results = try await tab.web.evaluateJavaScript("JSON.stringify(results, Object.keys(results).sort())") as? String
        XCTAssertEqual(results, #"{"api":"SecurityError","forged":"SecurityError","open":"TypeError","raw":"SecurityError"}"#)
        XCTAssertTrue(offered.isEmpty, "No chooser without a gesture")
        let frame = try await tab.web.evaluateJavaScript("String(frames[0].navigator.hid) + ',' + ('hid' in navigator)") as? String
        XCTAssertEqual(frame, "undefined,true", "Only the main frame gets the API")

        let all = try await js(tab, "return String((await navigator.hid.requestDevice({ filters: [] })).length);")
        XCTAssertEqual(offered, [[101]], "The keyboard's keys and the security key are never in the list")
        XCTAssertEqual(all, "1")
        let excluded = try await js(tab, """
            return String((await navigator.hid.requestDevice({ filters: [], exclusionFilters: [{ vendorId: 0x3434 }] })).length);
            """)
        XCTAssertEqual(excluded, "0")
        XCTAssertEqual(offered.last, [])
    }

    func testNavigationClosesTheDeviceAndTheGrantStaysWithItsOrigin() async throws {
        let tab = try await load("/hid")
        _ = try await js(tab, connect + "return 'open';")
        let first = try XCTUnwrap(transports.first)

        WebHID.chooserForTesting = { _ in XCTFail("A granted device needs no chooser"); return nil }
        _ = try await load("/next", in: tab)
        XCTAssertTrue(first.closed, "A new document must not inherit an open device")
        XCTAssertFalse(WebHID.hasOpenDevice(tabID: tab.id))
        let reopened = try await js(tab, """
            const devices = await navigator.hid.getDevices();
            if (devices.length !== 1) return 'devices: ' + devices.length;
            window.device = devices[0];
            await device.open();
            return 'open';
            """)
        XCTAssertEqual(reopened, "open")

        // Forgetting it from Site Controls closes it under the page and takes it off the list.
        XCTAssertEqual(SiteControlModel(tab).rows.first { $0.id == .hid(0) }?.control, .toggle(true))
        SiteControl.act(.hid(0), on: tab)
        XCTAssertTrue(try XCTUnwrap(transports.last).closed)
        XCTAssertTrue(WebHID.grants(scope: SitePermissions.scope(for: tab)).isEmpty)
        let after = try await js(tab, """
            while (device.opened) await new Promise(resolve => setTimeout(resolve, 20));
            return String((await navigator.hid.getDevices()).length);
            """)
        XCTAssertEqual(after, "0")

        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        WebHID.grant(HIDFixtures.via, scope: scope)
        _ = try await load("/hid", host: "localhost", in: tab)
        let elsewhere = try await js(tab, "return String((await navigator.hid.getDevices()).length);")
        XCTAssertEqual(elsewhere, "0", "Another origin must not see this origin's device")
    }

    func testUnpluggingFiresDisconnectAndReplugFiresConnect() async throws {
        let tab = try await load("/hid")
        _ = try await js(tab, connect + """
            window.events = [];
            navigator.hid.addEventListener('disconnect', event => events.push('disconnect:' + (event.device === device)));
            navigator.hid.onconnect = event => events.push('connect:' + (event.device === device));
            return 'listening';
            """)
        plug([])
        let lost = try await js(tab, """
            while (events.length < 1) await new Promise(resolve => setTimeout(resolve, 20));
            return [events[0], device.opened, (await navigator.hid.getDevices()).length].join(',');
            """)
        XCTAssertEqual(lost, "disconnect:true,false,0")
        XCTAssertTrue(try XCTUnwrap(transports.first).closed)

        plug([HIDFixtures.via])
        let back = try await js(tab, """
            while (events.length < 2) await new Promise(resolve => setTimeout(resolve, 20));
            const devices = await navigator.hid.getDevices();
            return [events[1], devices[0] === device].join(',');
            """)
        XCTAssertEqual(back, "connect:true,true", "The same device comes back as the same object")
    }
}
