import AppKit
import WebKit
import XCTest
@testable import vane

/// `navigator.serial` as a real page sees it, in a real tab, against a pty. The chooser is
/// answered by the fixture; nothing here shows a window or touches hardware.
@MainActor final class WebSerialWebKitTests: XCTestCase {
    private var server: NavigationHTTPFixture!
    private var profile = UUID()
    private var tabs: [Tab] = []
    private var pty: SerialPty!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        pty = try SerialPty()
        plug([pty.device])
        WebSerial.chooserForTesting = { $0.first }
    }

    override func tearDown() async throws {
        tabs.forEach { $0.tearDown() }
        tabs = []
        WebSerial.chooserForTesting = nil
        SerialDevices.shared.listForTesting = nil
        SerialDevices.shared.refresh()
        WebSerial.forgetAll(profileID: profile)
        server.stop()
        server = nil; pty = nil
    }

    /// What IOKit would report, and the notification that it changed.
    private func plug(_ devices: [SerialDevice]) {
        SerialDevices.shared.listForTesting = { devices }
        SerialDevices.shared.refresh()
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
                new Promise((_, reject) => setTimeout(() => reject(new Error('serial fixture timed out')), 20000))]);
            """, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    private let connect = """
        window.port = await navigator.serial.requestPort({ filters: [{ usbVendorId: 0x10c4 }] });
        await port.open({ baudRate: 115200 });
        """

    func testAPageOpensThePortItWasGrantedAndTalksToIt() async throws {
        let tab = try await load("/serial")
        let opened = try await js(tab, connect + """
            const writer = port.writable.getWriter();
            await writer.write(new Uint8Array([1, 2, 3, 250]));
            writer.releaseLock();
            const again = await navigator.serial.getPorts();
            return JSON.stringify({ info: port.getInfo(), same: again.length === 1 && again[0] === port, tag: String(port),
                                    streams: port.readable instanceof ReadableStream && port.writable instanceof WritableStream });
            """)
        XCTAssertEqual(opened, #"{"info":{"usbVendorId":4292,"usbProductId":60000},"same":true,"tag":"[object SerialPort]","streams":true}"#)
        let heard = try await pty.receive(4)
        XCTAssertEqual(heard, [1, 2, 3, 250])
        XCTAssertTrue(WebSerial.hasOpenPort(tabID: tab.id))
        XCTAssertEqual(SiteControlModel(tab).serialPorts, [pty.device.label], "Site Controls must list the port the site was given")

        try await pty.send([9, 8, 0, 255])
        let read = try await js(tab, """
            const reader = port.readable.getReader(), got = [];
            while (got.length < 4) {
              const { value, done } = await reader.read();
              if (done) break;
              if (!(value instanceof Uint8Array)) return 'not bytes';
              got.push(...value);
            }
            reader.releaseLock();
            return got.join(',');
            """)
        XCTAssertEqual(read, "9,8,0,255")

        // A pty has no modem lines, so this is the error path: a DOMException with the right name.
        let states = try await js(tab, """
            const name = promise => promise.then(() => 'ok', error => error.constructor.name + ':' + error.name);
            const locked = port.readable.getReader();
            const whileLocked = await name(port.close());
            locked.releaseLock();
            return [await name(port.setSignals({ dataTerminalReady: false, requestToSend: true })), await name(port.setSignals({})),
                    await name(port.open({ baudRate: 9600 })), whileLocked, await name(port.close()), String(port.readable),
                    await name(port.close()), await name(port.open({ baudRate: 0 }))].join(' ');
            """)
        XCTAssertEqual(states, "DOMException:NetworkError TypeError:TypeError DOMException:InvalidStateError TypeError:TypeError "
                       + "ok null DOMException:InvalidStateError TypeError:TypeError")
        XCTAssertFalse(WebSerial.hasOpenPort(tabID: tab.id))
    }

    func testAQuarterMegabyteGoesRoundThroughThePage() async throws {
        let tab = try await load("/serial")
        let size = 262_144
        pty.echo(size)
        let result = try await js(tab, connect + """
            const size = \(size), data = new Uint8Array(size);
            for (let i = 0; i < size; i++) data[i] = i * 7;
            const started = performance.now();
            const writer = port.writable.getWriter(), reader = port.readable.getReader();
            const writing = writer.write(data);
            let count = 0, intact = true;
            while (count < size) {
              const { value, done } = await reader.read();
              if (done) break;
              for (const byte of value) { intact = intact && byte === ((count * 7) & 255); count++; }
            }
            await writing;
            return JSON.stringify({ count, intact, ms: Math.round(performance.now() - started) });
            """)
        let data = try XCTUnwrap(result?.data(using: .utf8))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["count"] as? Int, size)
        XCTAssertEqual(report["intact"] as? Bool, true)
        // Reported, not asserted: 921600 baud needs 90 KB/s each way, and the pty is the slow part here.
        let ms = max(report["ms"] as? Double ?? 1, 1)
        print(String(format: "Web Serial page loopback: %.0f KB/s each way", Double(size) / 1024 / (ms / 1000)))
    }

    func testOnlyAUserGestureCanAskAndFramesHaveNoSerial() async throws {
        server.pages["/eager"] = """
            <iframe srcdoc="<p>frame</p>"></iframe>
            <script>
            window.results = {};
            navigator.serial.requestPort().then(() => results.api = 'granted', error => results.api = error.name);
            // A page that skips the script and calls the bridge itself gets no further.
            const bridge = webkit.messageHandlers.\(WebSerial.messageName);
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.raw = reply.error ? reply.error[0] : 'granted');
            bridge.postMessage({ op: 'open', id: 'not-granted', options: { baudRate: 9600 } })
              .then(reply => results.open = reply.error ? reply.error[0] : 'opened');
            dispatchEvent(new Event('\(WebSerial.gestureEvent)'));
            bridge.postMessage({ op: 'request', filters: [] }).then(reply => results.forged = reply.error ? reply.error[0] : 'granted');
            </script>
            """
        let tab = try await load("/eager")
        try await compatibilityWait {
            try await tab.web.evaluateJavaScript("Object.keys(window.results).length") as? Int == 4
        }
        let results = try await tab.web.evaluateJavaScript("JSON.stringify(results, Object.keys(results).sort())") as? String
        XCTAssertEqual(results, #"{"api":"SecurityError","forged":"SecurityError","open":"NetworkError","raw":"SecurityError"}"#)
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertTrue(WebSerial.grants(scope: scope).isEmpty, "Nothing may be granted without the user asking for it")
        let frame = try await tab.web.evaluateJavaScript("String(frames[0].navigator.serial) + ',' + ('serial' in navigator)") as? String
        XCTAssertEqual(frame, "undefined,true", "Only the main frame gets the API")
    }

    func testNavigationClosesThePortAndTheGrantStaysWithItsOrigin() async throws {
        let tab = try await load("/serial")
        _ = try await js(tab, connect + "return 'open';")
        XCTAssertTrue(WebSerial.hasOpenPort(tabID: tab.id))

        // The chooser must not be needed again, and must not be offered to another origin.
        WebSerial.chooserForTesting = { _ in XCTFail("A granted port needs no chooser"); return nil }
        _ = try await load("/next", in: tab)
        XCTAssertFalse(WebSerial.hasOpenPort(tabID: tab.id), "A new document must not inherit an open port")
        let reopened = try await js(tab, """
            const ports = await navigator.serial.getPorts();
            if (ports.length !== 1) return 'ports: ' + ports.length;
            window.port = ports[0];
            await port.open({ baudRate: 9600 });
            return 'open';
            """)
        XCTAssertEqual(reopened, "open")

        // Forgetting it from Site Controls closes it under the page and takes it off the list.
        XCTAssertEqual(SiteControlModel(tab).rows.first { $0.id == .serial(0) }?.control, .toggle(true))
        SiteControl.act(.serial(0), on: tab)
        XCTAssertFalse(WebSerial.hasOpenPort(tabID: tab.id))
        XCTAssertTrue(WebSerial.grants(scope: SitePermissions.scope(for: tab)).isEmpty)
        let after = try await js(tab, """
            const read = await port.readable.getReader().read().then(() => 'data', error => error.name);
            return read + ',' + (await navigator.serial.getPorts()).length;
            """)
        XCTAssertEqual(after, "NetworkError,0")

        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        WebSerial.grant(pty.device, scope: scope)
        _ = try await load("/serial", host: "localhost", in: tab)
        let elsewhere = try await js(tab, "return String((await navigator.serial.getPorts()).length);")
        XCTAssertEqual(elsewhere, "0", "Another origin must not see this origin's port")
    }

    func testUnpluggingFailsTheReadAndFiresDisconnectThenConnect() async throws {
        let tab = try await load("/serial")
        _ = try await js(tab, connect + """
            window.events = [];
            navigator.serial.addEventListener('disconnect', event => events.push('serial-disconnect:' + (event.target === port)));
            port.ondisconnect = () => events.push('port-disconnect');
            navigator.serial.onconnect = event => events.push('connect:' + (event.target === port));
            window.pending = port.readable.getReader().read().then(() => 'data', error => error.name);
            return 'listening';
            """)
        plug([])
        let lost = try await js(tab, """
            const read = await pending;
            while (events.length < 2) await new Promise(resolve => setTimeout(resolve, 20));
            return [read, events.join(' '), port.connected, String(port.readable), (await navigator.serial.getPorts()).length].join(',');
            """)
        XCTAssertEqual(lost, "NetworkError,port-disconnect serial-disconnect:true,false,null,0")
        XCTAssertFalse(WebSerial.hasOpenPort(tabID: tab.id))

        plug([pty.device])
        let back = try await js(tab, """
            while (events.length < 3) await new Promise(resolve => setTimeout(resolve, 20));
            const ports = await navigator.serial.getPorts();
            return [events[2], port.connected, ports[0] === port].join(',');
            """)
        XCTAssertEqual(back, "connect:true,true,true")
    }
}
