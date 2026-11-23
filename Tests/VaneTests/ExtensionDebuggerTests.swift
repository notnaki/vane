import AppKit
import WebKit
import XCTest
@testable import vane

/// Key on the test's word: an accessory test host cannot count on real focus.
@MainActor private final class DebuggerFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class MenuProbe: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

/// `chrome.debugger` is Vane's own: a script in the extension's worker and pages, requests
/// the host intercepts, and WebKit calls that stand in for the DevTools protocol.
@MainActor final class ExtensionDebuggerTests: XCTestCase {
    private var profile = UUID()
    private var folder: URL!
    private var stores: [TabStore] = []
    /// `TabStore.window` is weak: the fixture owns its windows until they are closed.
    private var windows: [NSWindow] = []
    private var server: NavigationHTTPFixture!
    private var originalPolicy: NSApplication.ActivationPolicy!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        originalPolicy = NSApp.activationPolicy()
        profile = UUID()
        server = try NavigationHTTPFixture()
        server.pages["/page"] = """
            <!doctype html><title>Driven page</title>
            <style>body { margin: 0; height: 4000px; } #b { position: fixed; left: 40px; top: 30px; width: 120px; height: 40px; }
            #i { position: fixed; left: 40px; top: 100px; width: 200px; height: 24px; }
            #l { position: fixed; left: 300px; top: 30px; font-size: 20px; }</style>
            <button id="b">Press</button><input id="i"><a id="l" href="/page">A link to drag</a>
            <script>
              window.log = [];
              b.addEventListener('click', e => log.push('click:' + e.isTrusted + ':' + e.detail));
              i.addEventListener('keydown', e => log.push('key:' + e.isTrusted + ':' + e.key + ':' + e.code));
              addEventListener('wheel', e => log.push('wheel:' + e.isTrusted), {passive: true});
              addEventListener('dragstart', e => log.push('drag:' + e.defaultPrevented));
              var pageGlobal = 'from the page';
            </script>
            """
        folder = Store.directory.appendingPathComponent("extension-debugger-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // No `tabs` permission: the answers must be readable without it.
        try Data(#"{"manifest_version":3,"name":"Debugger Fixture","version":"1.0","permissions":["debugger"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        // The worker has the API too, in Chrome's callback style with `runtime.lastError`.
        try Data("""
            const detached = [];
            chrome.debugger.onDetach.addListener((source, reason) => detached.push(source.tabId + ':' + reason));
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
                if (message.detached) { respond(detached.join(',')); return; }
                if (message.attach) {
                    chrome.debugger.attach({tabId: message.attach}, '1.3', () => respond(chrome.runtime.lastError?.message ?? 'attached'));
                    return true;
                }
                chrome.debugger.sendCommand({tabId: message.tabId}, message.method, message.params, result =>
                    respond(chrome.runtime.lastError ? 'error: ' + chrome.runtime.lastError.message : JSON.stringify(result)));
                return true;
            });
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        for store in TabStore.all.filter({ store in store.profileID == profile || stores.contains { $0 === store } }) {
            store.window?.close()
            store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        stores.removeAll()
        windows.forEach { $0.close() }
        windows.removeAll()
        server.stop()
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release([profile])
        NSApp.setActivationPolicy(originalPolicy)
    }

    private func wait(_ description: String, until ready: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(try await ready()) {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func run(_ script: String, in page: WKWebView) async throws -> String? {
        try await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    func testBridgeRequestsBelongToTheOwningExtensionOnly() throws {
        let base = URL(string: "webkit-extension://abc/")!
        let request = try XCTUnwrap(ExtensionDebuggerAPI.Request(
            URL(string: "webkit-extension://abc/__vane_bridge__?op=sendCommand&tabId=4&method=Page.enable&params=%7B%22a%22%3A%221+%2B+1%22%7D"), base: base))
        XCTAssertEqual(request.operation, "sendCommand")
        XCTAssertEqual(request.values["method"], "Page.enable")
        XCTAssertEqual(request.values["params"], #"{"a":"1 + 1"}"#, "URLSearchParams writes a space as +")
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "webkit-extension://other/__vane_bridge__?op=attach"), base: base))
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "https://abc/__vane_bridge__?op=attach"), base: base))
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "webkit-extension://abc/page.html?op=attach"), base: base))
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "webkit-extension://abc/__vane_bridge__?tabId=4"), base: base))

        XCTAssertTrue(ExtensionDebuggerAPI.declared(["permissions": ["debugger"]]))
        XCTAssertFalse(ExtensionDebuggerAPI.declared(["optional_permissions": ["debugger"]]), "Accepted at install, or not at all")
        for command in ["selectAll", "paste", "moveToBeginningOfLine", "deleteBackward"] {
            XCTAssertTrue(ExtensionDebuggerAPI.isEditingCommand(command), command)
        }
        for command in ["terminate", "print", "release", "move:", "performClose", ""] {
            XCTAssertFalse(ExtensionDebuggerAPI.isEditingCommand(command), command)
        }
    }

    func testTheLastExpressionIsReturnedWithoutEval() {
        func rewritten(_ source: String) -> String? { ExtensionDebuggerAPI.returningLast(source, box: "B") }
        XCTAssertEqual(rewritten("1 + 1"), "return new B((\n1 + 1\n))")
        XCTAssertEqual(rewritten("const a = 1; a + 1;"), "const a = 1; return new B((\na + 1\n));")
        XCTAssertEqual(rewritten("const a = await f()\na.b // done"), "const a = await f()\nreturn new B((\na.b\n)) // done")
        XCTAssertEqual(rewritten("f()\n  .then(r => r.json())"), "return new B((\nf()\n  .then(r => r.json())\n))")
        XCTAssertEqual(rewritten("if (x) { y() } z"), "if (x) { y() } return new B((\nz\n))")
        XCTAssertEqual(rewritten("const s = `a;${b ? '}' : \"{\"}`; s.length"), "const s = `a;${b ? '}' : \"{\"}`; return new B((\ns.length\n))")
        XCTAssertEqual(rewritten("x = 5 / 2; /a;b/.test(s)"), "x = 5 / 2; return new B((\n/a;b/.test(s)\n))")
        XCTAssertEqual(rewritten("function f() { return 1 }\nf()"), "function f() { return 1 }\nreturn new B((\nf()\n))")
        // Claude's wrapper: a guard, then the caller's code in a labelled block.
        XCTAssertEqual(rewritten("if(location.origin!==\"o\")throw\"_l\";_l:{{document.title\n};break _l}"),
                       "if(location.origin!==\"o\")throw\"_l\";_l:{{return new B((\ndocument.title\n))\n};break _l}")
        // Nothing to return: a declaration, a loop, the caller's own `return`.
        for source in ["const a = 1", "for (const a of b) { a }", "return 5", "for (;;)\n{ a }", ""] {
            XCTAssertNil(rewritten(source), source)
        }
        // Bounded: nesting past the limit and oversized text run unchanged, for no value.
        XCTAssertNotNil(rewritten(String(repeating: "{", count: 30) + "1" + String(repeating: "}", count: 30)))
        XCTAssertNil(rewritten(String(repeating: "{", count: 40) + "1" + String(repeating: "}", count: 40)))
        XCTAssertNil(rewritten(String(repeating: " ", count: ExtensionDebuggerAPI.rewriteLimit) + "1"))
        XCTAssertNil(rewritten(String(repeating: "`${", count: 20_000)), "A stack the tokenizer exhausts is no crash")
    }

    func testOnlyAWholeFunctionBodyIsEvaluated() async {
        for body in ["return 5", "const a = await f(); a + 1", "", "label: { break label }", "'use strict'; x"] {
            XCTAssertNil(ExtensionDebuggerAPI.syntaxError(in: body), body)
        }
        // Text that closes the wrapper it is placed in, to run ahead of the origin check or
        // answer in the page's place, is refused before any page sees it.
        let escape = "}).call(globalThis); return '{\"result\":{}}'; (async function(){"
        for body in [escape, "}", "} {", "/*", "`", "x => {", "}); evil(); (function(){"] {
            XCTAssertNotNil(ExtensionDebuggerAPI.syntaxError(in: body), body)
        }
        let refused = await ExtensionDebuggerAPI.body(for: escape, box: "B")
        guard case .syntax(let message) = refused else { return XCTFail("\(refused)") }
        XCTAssertTrue(message.hasPrefix("SyntaxError"), message)
        let last = await ExtensionDebuggerAPI.body(for: "1 + 1", box: "B")
        XCTAssertEqual(last, .run("return new B((\n1 + 1\n))"))
        let written = await ExtensionDebuggerAPI.body(for: "return 5", box: "B")
        XCTAssertEqual(written, .run("return 5"))
        XCTAssertTrue(ExtensionDebuggerAPI.evaluation("x", token: "T").hasPrefix("if (location.origin !== T_options.origin) return"),
                      "The origin check is the first statement")
    }

    func testAnExtensionDrivesAPageThroughTheDebugger() async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await drive() } catch { failure = error }
        ExtensionHost.forget(profile)
        for window in windows { window.close() }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func drive() async throws {
        let store = TabStore(profileID: profile, session: [])
        let tab = store.newBlankTab()
        let window = DebuggerFixtureWindow(contentRect: NSRect(x: 120, y: 150, width: 600, height: 400),
                                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        store.window = window
        windows.append(window)
        stores.append(store)
        tab.web.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView?.addSubview(tab.web)
        window.makeKeyAndOrderFront(nil)
        tab.navigate(to: try server.url("/page"))
        try await wait("driven page") { !tab.web.isLoading && tab.web.title == "Driven page" }

        let host = ExtensionHost.host(for: profile)
        var reviewed = ""
        _ = try await host.load(folder, installing: true) { review in reviewed = "\(review)"; return true }
        XCTAssertTrue(reviewed.contains("debugger"), "The install review names the capability: \(reviewed)")
        let context = try XCTUnwrap(host.installed.first)
        let notes = (host.entries.first?.compatibility ?? []).filter { $0.hasPrefix("debugger") }
        XCTAssertEqual(notes.count, 1, "\(notes)")
        XCTAssertFalse(notes.contains(where: ExtensionDiagnostics.isUnsupported), "Provided in part, not missing")
        host.sync()

        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        try await wait("extension page") { !page.isLoading && page.title == "Fixture page" }
        defer { page.stopLoading() }

        // Helpers in the extension page: the tab, one command, one evaluation by value.
        _ = try await run("""
            window.tabId = (await chrome.tabs.query({}))[0].id;
            window.send = (method, params) => chrome.debugger.sendCommand({tabId}, method, params);
            window.evaluate = async (expression, extra = {}) =>
                JSON.stringify(await send('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true, replMode: true, ...extra}));
            window.failure = promise => promise.then(() => 'resolved', error => error.message);
            window.events = [];
            chrome.debugger.onDetach.addListener((source, reason) => events.push(source.tabId + ':' + reason));
            return 'ready';
            """, in: page)

        let found = try await run("return String(tabId)", in: page)
        let id = try XCTUnwrap(found)

        // Nothing before attach; one debugger per tab.
        let refused = try await run("return await failure(send('Page.enable'))", in: page)
        XCTAssertEqual(refused, "Debugger is not attached to the tab with id: \(id).")
        let attach = try await run("""
            await chrome.debugger.attach({tabId}, '1.3');
            const again = await failure(chrome.debugger.attach({tabId}, '1.3'));
            const targets = await chrome.debugger.getTargets();
            return again + '|' + JSON.stringify(targets.map(target => [target.tabId === tabId, target.attached, target.type]));
            """, in: page)
        XCTAssertEqual(attach, "Another debugger is already attached to the tab with id: \(id).|[[true,true,\"page\"]]")
        XCTAssertNotNil(host.debugger.session(on: tab.id), "The banner has a session to show")
        XCTAssertEqual(store.tabs.count, 1, "Bridge requests never become tabs")

        // Runtime.evaluate: the page's own world, REPL values, promises, errors.
        let values = try await run("""
            return [await evaluate('1 + 1'), await evaluate('pageGlobal'),
                    await evaluate('const a = await Promise.resolve(20); a + 1'),
                    await evaluate('fetch(location.href).then(response => response.status)'),
                    await evaluate('({a: [1, "two"], b: null})'), await evaluate('document.body'), await evaluate('return 5'),
                    await evaluate('undefined')].join('\\n');
            """, in: page)
        XCTAssertEqual(values?.components(separatedBy: "\n"), [
            #"{"result":{"description":"2","type":"number","value":2}}"#,
            #"{"result":{"type":"string","value":"from the page"}}"#,
            #"{"result":{"description":"21","type":"number","value":21}}"#,
            #"{"result":{"description":"200","type":"number","value":200}}"#,
            #"{"result":{"className":"Object","description":"Object","type":"object","value":{"a":[1,"two"],"b":null}}}"#,
            #"{"result":{"className":"HTMLBodyElement","description":"body","subtype":"node","type":"object","value":{}}}"#,
            #"{"result":{"description":"5","type":"number","value":5}}"#,
            #"{"result":{"type":"undefined"}}"#
        ])
        let errors = try await run("""
            const thrown = JSON.parse(await evaluate('throw new TypeError("nope")'));
            const text = JSON.parse(await evaluate('throw "plain"'));
            const syntax = JSON.parse(await evaluate('let let = ;'));
            const pending = JSON.parse(await evaluate('new Promise(() => {})', {awaitPromise: false}));
            const late = JSON.parse(await evaluate('new Promise(() => {})', {timeout: 50}));
            return [thrown.exceptionDetails.exception.className, thrown.exceptionDetails.exception.description.split('\\n')[0],
                    text.exceptionDetails.exception.value, syntax.exceptionDetails.exception.className, syntax.exceptionDetails.scriptId,
                    pending.result.subtype, late.exceptionDetails.exception.description.split('\\n')[0]].join('|');
            """, in: page)
        XCTAssertEqual(errors, "TypeError|TypeError: nope|plain|SyntaxError|0|promise|Error: Script execution was terminated")

        // Code cannot close the wrapper to run outside it, and nothing of the caller's runs
        // in a document of another origin than the one that was checked.
        let escaped = try await run("""
            const out = JSON.parse(await evaluate("}).call(globalThis); window.escaped = 1; return '{}'; (async function(){"));
            return out.exceptionDetails.exception.className + '|' + await evaluate('typeof escaped');
            """, in: page)
        XCTAssertEqual(escaped, #"SyntaxError|{"result":{"type":"string","value":"undefined"}}"#)
        let elsewhere = try await tab.web.callAsyncJavaScript(
            ExtensionDebuggerAPI.evaluation("window.ranElsewhere = true", token: "T"),
            arguments: ["T_options": ["origin": "http://elsewhere.example"]], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(elsewhere, #"{"moved":true}"#)
        let ran = try await tab.web.evaluateJavaScript("typeof ranElsewhere") as? String
        XCTAssertEqual(ran, "undefined")

        // Page.captureScreenshot: the viewport, and a clip at a scale.
        let scale = Double(window.backingScaleFactor)
        let shots = try await run("""
            const size = async params => {
                const {data} = await send('Page.captureScreenshot', params);
                const image = await createImageBitmap(await (await fetch('data:image/' + params.format + ';base64,' + data)).blob());
                return image.width + 'x' + image.height;
            };
            return [await size({format: 'png'}), await size({format: 'jpeg', quality: 60, clip: {x: 40, y: 30, width: 120, height: 40, scale: 0.5}}),
                    await failure(send('Page.captureScreenshot', {format: 'webp'}))].join('|');
            """, in: page)
        XCTAssertEqual(shots, "\(Int(600 * scale))x\(Int(400 * scale))|\(Int(60 * scale))x\(Int(20 * scale))|"
                       + #"{"code":-32602,"message":"Invalid parameters: Vane captures png and jpeg only"}"#)

        // Input: a click the page trusts, keys and text into the field it focused.
        let typed = try await run("""
            const mouse = (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', {type, x, y, button: 'left', buttons: 0, clickCount: 1, modifiers: 0, ...extra});
            const click = async (x, y) => {
                await mouse('mouseMoved', x, y, {button: 'none'});
                await mouse('mousePressed', x, y, {buttons: 1});
                await mouse('mouseReleased', x, y);
            };
            const key = async (key, code, text, extra = {}) => {
                await send('Input.dispatchKeyEvent', {type: text ? 'keyDown' : 'rawKeyDown', key, code, text: text ?? '', unmodifiedText: text ?? '', modifiers: 0, ...extra});
                await send('Input.dispatchKeyEvent', {type: 'keyUp', key, code, modifiers: 0, ...extra});
            };
            await click(100, 50);
            await click(140, 112);
            await key('h', 'KeyH', 'h');
            await key('I', 'KeyI', 'I', {modifiers: 8});
            await send('Input.insertText', {text: ' ✓'});
            const first = JSON.parse(await evaluate('i.value + "|" + (document.activeElement === i) + "|" + log.join(",")')).result.value;
            await key('ArrowLeft', 'ArrowLeft', undefined, {commands: ['moveLeft']});
            await key('Backspace', 'Backspace', undefined, {commands: ['deleteBackward']});
            const edited = JSON.parse(await evaluate('i.value')).result.value;
            await key('a', 'KeyA', undefined, {modifiers: 4, commands: ['selectAll']});
            await key('x', 'KeyX', 'x');
            const replaced = JSON.parse(await evaluate('i.value')).result.value;
            return [first, edited, replaced].join('\\n');
            """, in: page)
        XCTAssertEqual(typed?.components(separatedBy: "\n"), [
            "hI ✓|true|click:true:1,key:true:h:KeyH,key:true:I:KeyI", "hI✓", "x"
        ])

        try await keysStayInThePage(page)

        // After a synthesized press, a drag the page would start is cancelled: AppKit's drag
        // session would follow the real pointer. Asked of the page directly, since whether
        // WebKit begins a drag from these moves depends on the host's focus and timing.
        let dragged = try await run("""
            const mouse = (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', {type, x, y, button: 'left', buttons: 0, clickCount: 1, modifiers: 0, ...extra});
            const allowed = 'String(l.dispatchEvent(new DragEvent("dragstart", {bubbles: true, cancelable: true})))';
            const before = JSON.parse(await evaluate(allowed)).result.value;
            await mouse('mouseMoved', 320, 42, {button: 'none'});
            await mouse('mousePressed', 320, 42, {buttons: 1});
            await mouse('mouseReleased', 380, 130);
            return before + '|' + JSON.parse(await evaluate(allowed)).result.value;
            """, in: page)
        XCTAssertEqual(dragged, "true|false")

        // A wheel event the page trusts, and the scroll it causes.
        _ = try await run("await send('Input.dispatchMouseEvent', {type: 'mouseWheel', x: 300, y: 300, deltaX: 0, deltaY: 240, modifiers: 0}); return 'sent'", in: page)
        try await wait("wheel scroll") {
            try await self.run("return JSON.parse(await evaluate('scrollY + \"|\" + log.includes(\"wheel:true\")')).result.value", in: page)
                .map { $0.hasSuffix("|true") && !$0.hasPrefix("0|") } ?? false
        }

        // What Vane does not answer fails in the protocol's own shape, at once.
        let unsupported = try await run("""
            return [await failure(send('DOM.getDocument')), await failure(send('Page.handleJavaScriptDialog', {accept: true})),
                    JSON.stringify(await send('Network.enable', {})), JSON.stringify((await send('Page.getFrameTree')).frameTree.frame.url)].join('|');
            """, in: page)
        let address = try server.url("/page").absoluteString
        XCTAssertEqual(unsupported, #"{"code":-32601,"message":"'DOM.getDocument' wasn't found"}|{"code":-32602,"message":"No dialog is showing"}|{}|"#
                       + "\"\(address)\"")

        // The worker has the same API, with Chrome's callbacks and `runtime.lastError`.
        let worker = try await run("""
            const ok = await chrome.runtime.sendMessage({tabId, method: 'Runtime.evaluate', params: {expression: 'document.title', returnByValue: true}});
            const bad = await chrome.runtime.sendMessage({tabId, method: 'DOM.getDocument'});
            const taken = await chrome.runtime.sendMessage({attach: tabId});
            return [ok, bad, taken].join('|');
            """, in: page)
        XCTAssertEqual(worker, #"{"result":{"type":"string","value":"Driven page"}}|error: Invalid call to tabs.create(). {"code":-32601,"message":"'DOM.getDocument' wasn't found"}.|"#
                       + "Invalid call to tabs.create(). Another debugger is already attached to the tab with id: \(id).")

        // runtime.getContexts: the background, and no side panel while none is open.
        let contexts = try await run("""
            return JSON.stringify((await chrome.runtime.getContexts({})).map(context => context.contextType)) + '|'
                + (await chrome.runtime.getContexts({contextTypes: ['SIDE_PANEL']})).length;
            """, in: page)
        XCTAssertEqual(contexts, #"["BACKGROUND"]|0"#)

        // With eight event calls held open, one more is answered late rather than at once,
        // so its caller's loop does not spin.
        let crowded = try await run("""
            const began = performance.now();
            await Promise.race(Array.from({length: 9}, () =>
                chrome.tabs.create({url: chrome.runtime.getURL('/__vane_bridge__?op=events&after=1000000'), active: false})));
            return String(performance.now() - began >= 900);
            """, in: page)
        XCTAssertEqual(crowded, "true")

        // An answer nobody reads gives its reply object back after a while.
        let targets = try XCTUnwrap(ExtensionDebuggerAPI.Request(
            URL(string: "__vane_bridge__?op=targets", relativeTo: context.baseURL)?.absoluteURL, base: context.baseURL))
        host.debugger.replyPatience = 0.05
        let first = try await host.debugger.handle(targets, tab: nil, panels: [], for: context)
        let second = try await host.debugger.handle(targets, tab: nil, panels: [], for: context)
        XCTAssertFalse(first === second, "An unread answer is not overwritten")
        try await Task.sleep(for: .milliseconds(120))
        let third = try await host.debugger.handle(targets, tab: nil, panels: [], for: context)
        XCTAssertTrue(third === first || third === second, "An abandoned reply serves again")
        host.debugger.replyPatience = 30

        // The debugger takes the tab only where its extension has host access.
        let away = try await run("return await failure(send('Page.navigate', {url: '\(try server.url("/page", host: "localhost").absoluteString)'}))", in: page)
        XCTAssertEqual(away, #"{"code":-32000,"message":"Cannot navigate to a page this extension has no access to"}"#)
        XCTAssertEqual(tab.web.url?.host, "127.0.0.1")

        // Host access is checked against the page that is loaded, on every command.
        tab.navigate(to: try server.url("/page", host: "localhost"))
        try await wait("unpermitted page") { !tab.web.isLoading && tab.web.url?.host == "localhost" && tab.web.title == "Driven page" }
        let outside = try await run("return await failure(send('Runtime.evaluate', {expression: 'document.title'}))", in: page)
        XCTAssertEqual(outside, "Cannot access contents of the page. Extension manifest must request permission to access the respective host.")

        // The banner's Stop detaches and tells the extension; so does closing the tab.
        host.debugger.stop(try XCTUnwrap(host.debugger.session(on: tab.id)))
        XCTAssertNil(host.debugger.session(on: tab.id))
        try await wait("canceled_by_user") { try await self.run("return events.join(',')", in: page)?.hasSuffix(":canceled_by_user") == true }
        let stopped = try await run("return await failure(send('Page.enable'))", in: page)
        XCTAssertTrue(stopped?.hasPrefix("Debugger is not attached") == true, "\(stopped ?? "nil")")
        tab.navigate(to: try server.url("/page"))
        try await wait("permitted page again") { !tab.web.isLoading && tab.web.url?.host == "127.0.0.1" }
        _ = try await run("await chrome.debugger.attach({targetId: 'vane-tab-' + tabId}, '1.3'); return 'attached'", in: page)
        XCTAssertNotNil(host.debugger.session(on: tab.id))
        _ = store.newBlankTab()
        store.close(tab.id)
        host.sync()
        XCTAssertTrue(host.debugger.sessions.isEmpty)
        try await wait("target_closed") { try await self.run("return events.join(',')", in: page)?.hasSuffix(":target_closed") == true }
        let heard = try await run("return await chrome.runtime.sendMessage({detached: true})", in: page)
        XCTAssertTrue(heard?.contains("canceled_by_user") == true, "The worker hears detaches too: \(heard ?? "nil")")
    }

    /// A key the page leaves alone comes back from WebKit through `NSApp.sendEvent`. Vane's
    /// key monitor drops it there, as this one does: no shortcut, no menu item.
    private func keysStayInThePage(_ page: WKWebView) async throws {
        let probe = MenuProbe()
        let menu = NSMenu(), items = NSMenu()
        let item = items.addItem(withTitle: "Probe", action: #selector(MenuProbe.fire(_:)), keyEquivalent: "j")
        item.target = probe
        menu.addItem(withTitle: "Probe", action: nil, keyEquivalent: "").submenu = items
        let previous = NSApp.mainMenu
        NSApp.mainMenu = menu
        var swallow = false, returned = 0, strangers = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard ExtensionDebuggerAPI.isSynthesized(event) else { strangers += 1; return event }
            returned += 1
            return swallow ? nil : event
        }
        defer { monitor.map(NSEvent.removeMonitor); NSApp.mainMenu = previous }
        let chord = "await send('Input.dispatchKeyEvent', {type: 'rawKeyDown', key: 'j', code: 'KeyJ', modifiers: 4}); return 'sent'"
        // The control: let through, the same event reaches the main menu.
        _ = try await run(chord, in: page)
        try await wait("the key equivalent an unguarded application performs") { probe.fired == 1 }
        swallow = true
        _ = try await run(chord, in: page)
        try await wait("the synthesized key to come back") { returned == 2 }
        // Plain keys come back too, and are dropped the same way.
        _ = try await run("await send('Input.dispatchKeyEvent', {type: 'rawKeyDown', key: 'F6', code: 'F6', modifiers: 0}); return 'sent'", in: page)
        try await wait("the plain key to come back") { returned == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.fired, 1, "A swallowed key performs nothing")
        XCTAssertEqual(strangers, 0)
        let seen = try await run("return JSON.parse(await evaluate('log.filter(line => line.endsWith(\":KeyJ\")).length')).result.description", in: page)
        XCTAssertEqual(seen, "2", "The page still hears both")
    }

    func testAnExtensionWithoutThePermissionHasNoDebugger() async throws {
        try Data(#"{"manifest_version":3,"name":"Debugger Fixture","version":"1.0","optional_permissions":["debugger"],"host_permissions":["http://127.0.0.1/*"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data().write(to: folder.appendingPathComponent("worker.js"))
        let store = TabStore(profileID: profile, session: [])
        stores.append(store)
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        host.sync()
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        try await wait("extension page") { !page.isLoading && page.title == "Fixture page" }
        defer { page.stopLoading() }
        try Data("<title>Fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
        let denied = try await run("""
            return typeof chrome.debugger + '|' + await chrome.tabs.create({url: chrome.runtime.getURL('/__vane_bridge__?op=targets')})
                .then(() => 'answered', error => error.message);
            """, in: page)
        XCTAssertEqual(denied, "undefined|Invalid call to tabs.create(). This extension has not requested the debugger permission.")
        XCTAssertTrue(store.tabs.isEmpty)
    }
}
