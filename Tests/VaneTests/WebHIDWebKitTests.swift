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

    private func load(_ path: String, host: String = "127.0.0.1", in existing: Tab? = nil, isPrivate: Bool = false) async throws -> Tab {
        let tab = existing ?? Tab(isPrivate: isPrivate, profileID: profile)
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

    /// The page came back from the back/forward cache: its old ids died with its old
    /// document, so it starts over with closed devices and a live listener.
    func testABackForwardCacheRestoreStartsOverClosed() async throws {
        let tab = try await load("/hid")
        _ = try await js(tab, connect + """
            window.shown = []; window.lost = 0;
            addEventListener('pageshow', event => shown.push(event.persisted));
            navigator.hid.ondisconnect = () => lost++;
            return 'open';
            """)
        let first = try XCTUnwrap(transports.first)
        _ = try await load("/next", in: tab)
        XCTAssertTrue(first.closed)
        let url = try server.url("/hid")
        tab.web.goBack()
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        let restored = try await js(tab, """
            while (!shown.length) await new Promise(resolve => setTimeout(resolve, 20));
            const [again] = await navigator.hid.getDevices();
            const result = [shown[0], device.opened, again !== device, again.opened];
            await again.open();
            window.device = again;
            return result.concat(again.opened).join(',');
            """)
        XCTAssertEqual(restored, "true,false,true,false,true", "A restored page must not believe its old devices are open")
        plug([])
        let lost = try await js(tab, """
            while (!lost) await new Promise(resolve => setTimeout(resolve, 20));
            return String(lost);
            """)
        XCTAssertEqual(lost, "1", "The restored page must hear of devices again")
    }

    func testACrossOriginFramePostingToTheBridgeIsRefused() async throws {
        let frame = try server.url("/frame", host: "localhost")
        server.pages["/frame"] = """
            <script>
            webkit.messageHandlers.\(WebHID.messageName).postMessage({ op: 'devices' })
              .then(reply => parent.postMessage(reply && reply.error ? reply.error[0] : 'answered', '*'),
                    () => parent.postMessage('rejected', '*'));
            </script>
            """
        server.pages["/framed"] = """
            <script>window.answer = null; addEventListener('message', event => window.answer = event.data);</script>
            <iframe src="\(frame.absoluteString)"></iframe>
            """
        let tab = try await load("/framed")
        WebHID.grant(HIDFixtures.via, scope: try XCTUnwrap(WebHID.Scope(url: frame, profileID: profile)))
        try await compatibilityWait { try await tab.web.evaluateJavaScript("window.answer") as? String != nil }
        let answer = try await tab.web.evaluateJavaScript("window.answer") as? String
        XCTAssertEqual(answer, "SecurityError", "Only the main frame may use the bridge, whatever origin it is")
    }

    /// The gaming mouse: its pointer is report 2, its settings channel 0x10.
    private let mouse = HIDFixtures.device(HIDFixtures.mouseAndVendor, entryID: 106, vendorID: 0x046d, productID: 0xc077,
                                           product: "Gaming Mouse", serialNumber: "M-1")

    func testProtectedReportsNeverCrossTheBridgeEitherWay() async throws {
        plug([mouse])
        let tab = try await load("/hid")
        _ = try await js(tab, """
            [window.device] = await navigator.hid.requestDevice({ filters: [{ vendorId: 0x046d }] });
            await device.open();
            window.reports = [];
            device.oninputreport = event => reports.push(event.reportId);
            return 'open';
            """)
        let transport = try XCTUnwrap(transports.first)
        transport.input(2, Data([1, 0, 0]))
        transport.input(0x11, Data([1]))
        transport.input(0x10, Data([1, 2, 3, 4, 5, 6]))
        let seen = try await js(tab, """
            while (!reports.length) await new Promise(resolve => setTimeout(resolve, 20));
            await new Promise(resolve => setTimeout(resolve, 200));
            return reports.join(',');
            """)
        XCTAssertEqual(seen, "16", "The pointer report and an undeclared one are dropped")

        let refused = try await js(tab, """
            const bridge = webkit.messageHandlers.\(WebHID.messageName);
            const [{ id }] = (await bridge.postMessage({ op: 'devices' })).value;
            const send = reportId => bridge.postMessage({ op: 'send', id, type: 'output', reportId, data: 'AQ==' })
              .then(reply => reply.error ? reply.error[0] : 'sent');
            return [await send(2), await send(0x11), await send(0x10)].join(',');
            """)
        XCTAssertEqual(refused, "NotAllowedError,NotAllowedError,sent")
        XCTAssertEqual(transport.sent, [.init(type: .output, id: 0x10, data: [1])], "Only the declared, unprotected report reaches the device")
    }

    func testAPrivateTabsGrantWorksAndGoesWithTheTab() async throws {
        let tab = try await load("/hid", isPrivate: true)
        let opened = try await js(tab, connect + "await device.sendReport(0, new Uint8Array(32)); return String(device.opened);")
        XCTAssertEqual(opened, "true")
        XCTAssertEqual(transports.first?.sent.count, 1)
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertEqual(WebHID.grants(scope: scope).count, 1)
        XCTAssertTrue(WebHID.all(profileID: profile).isEmpty, "A private grant is not the profile's")
        XCTAssertFalse(UserDefaults.vane.dictionaryRepresentation().keys.contains { $0.hasPrefix("hidDevice.v1." + profile.uuidString.lowercased()) })
        let regular = try await load("/hid")
        let unshared = try await js(regular, "return String((await navigator.hid.getDevices()).length);")
        XCTAssertEqual(unshared, "0", "A regular tab must not see the private tab's device")
        tab.tearDown()
        tabs.removeAll { $0 === tab }
        XCTAssertTrue(try XCTUnwrap(transports.first).closed)
        XCTAssertTrue(WebHID.grants(scope: scope).isEmpty)
    }

    func testForgetClosesTheDeviceInEveryTabOfTheOrigin() async throws {
        let one = try await load("/hid")
        _ = try await js(one, connect + "return 'open';")
        WebHID.chooserForTesting = { _ in XCTFail("A granted device needs no chooser"); return nil }
        let two = try await load("/hid")
        let opened = try await js(two, "[window.device] = await navigator.hid.getDevices(); await device.open(); return String(device.opened);")
        XCTAssertEqual(opened, "true")
        XCTAssertEqual(transports.count, 2)
        _ = try await js(one, "await device.forget(); return 'gone';")
        XCTAssertTrue(transports.allSatisfy(\.closed), "Forgetting closes it in the other tab too")
        let after = try await js(two, """
            while (device.opened) await new Promise(resolve => setTimeout(resolve, 20));
            return String((await navigator.hid.getDevices()).length);
            """)
        XCTAssertEqual(after, "0")
    }
}
