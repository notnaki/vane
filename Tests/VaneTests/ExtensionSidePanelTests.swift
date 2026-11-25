import AppKit
import WebKit
import XCTest
@testable import vane

/// Key or not on the test's word: an accessory test host cannot count on real focus.
@MainActor private final class SidePanelFixtureWindow: NSWindow {
    var key = true
    override var isKeyWindow: Bool { key }
}

/// `chrome.sidePanel` is Vane's own: a script in the extension's worker and pages, a
/// request the host intercepts, and a panel docked beside the page.
@MainActor final class ExtensionSidePanelTests: XCTestCase {
    private var profile = UUID()
    private var folder: URL!
    private var stores: [TabStore] = []
    private var originalPolicy: NSApplication.ActivationPolicy!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        originalPolicy = NSApp.activationPolicy()
        profile = UUID()
        folder = Store.directory.appendingPathComponent("extension-side-panel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Side Panel Fixture","version":"1.0","permissions":["sidePanel","notifications","debugger","tabGroups","storage"],"optional_permissions":["downloads"],"background":{"service_worker":"worker.js"},"action":{},"side_panel":{"default_path":"shared.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        // The shape of a real extension: a path per tab, then open, from the action's event.
        try Data("""
            // Chromium-only namespaces at the top level, as real workers use them: without
            // Vane's stand-ins the first line throws and the background never loads.
            chrome.notifications.onClicked.addListener(() => {});
            chrome.debugger.onEvent.addListener(() => {});
            chrome.runtime.onUpdateAvailable.addListener(() => {});
            let handled = 0;
            chrome.action.onClicked.addListener(tab => {
                chrome.sidePanel.setOptions({tabId: tab.id, path: 'panel.html?tabId=' + tab.id, enabled: true});
                chrome.sidePanel.open({tabId: tab.id}).finally(() => handled++);
            });
            // A worker has no gesture of its own: this open succeeds only after the button.
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
                if (message.handled) { respond(String(handled)); return; }
                chrome.sidePanel.open({windowId: message.windowId}).then(() => respond('opened'), error => respond(String(error.message)));
                return true;
            });
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Fixture panel</title><p>Panel</p>".utf8).write(to: folder.appendingPathComponent("panel.html"))
        try Data("<title>Shared panel</title><p>Shared</p>".utf8).write(to: folder.appendingPathComponent("shared.html"))
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
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release([profile])
        NSApp.setActivationPolicy(originalPolicy)
    }

    private func wait(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func withNativeWindowLoop(_ body: () async throws -> Void) async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await body() } catch { failure = error }
        ExtensionHost.forget(profile)
        for store in stores { store.window?.orderOut(nil) }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    func testBridgeRequestsBelongToTheOwningExtensionOnly() throws {
        let base = URL(string: "webkit-extension://abc/")!
        let request = try XCTUnwrap(ExtensionSidePanelAPI.Request(
            URL(string: "webkit-extension://abc/__vane_side_panel__?op=setOptions&path=panel.html%3FtabId%3D4&enabled=false"), base: base))
        XCTAssertEqual(request.operation, .setOptions)
        XCTAssertEqual(request.options, .init(path: "panel.html?tabId=4", enabled: false))
        XCTAssertFalse(request.gesture)
        XCTAssertTrue(try XCTUnwrap(ExtensionSidePanelAPI.Request(
            URL(string: "webkit-extension://abc/__vane_side_panel__?op=open&gesture=true"), base: base)).gesture)
        XCTAssertNil(ExtensionSidePanelAPI.Request(URL(string: "webkit-extension://other/__vane_side_panel__?op=open"), base: base))
        XCTAssertNil(ExtensionSidePanelAPI.Request(URL(string: "https://abc/__vane_side_panel__?op=open"), base: base))
        XCTAssertNil(ExtensionSidePanelAPI.Request(URL(string: "webkit-extension://abc/panel.html?op=open"), base: base))
        XCTAssertNil(ExtensionSidePanelAPI.Request(URL(string: "webkit-extension://abc/__vane_side_panel__?op=erase"), base: base))

        XCTAssertEqual(ExtensionSidePanelAPI.page("panel.html?tabId=4", base: base)?.absoluteString,
                       "webkit-extension://abc/panel.html?tabId=4")
        XCTAssertEqual(ExtensionSidePanelAPI.page("/ui/panel.html", base: base)?.absoluteString,
                       "webkit-extension://abc/ui/panel.html")
        for outside in ["https://example.com/panel.html", "//example.com/panel.html", "__vane_side_panel__?op=open", ""] {
            XCTAssertNil(ExtensionSidePanelAPI.page(outside, base: base), outside)
        }
    }

    func testPanelNarrowsThenHidesToKeepThePageItsMinimumWidth() {
        XCTAssertEqual(ExtensionSidePanelAPI.width(sharing: 1200), 360)
        XCTAssertEqual(ExtensionSidePanelAPI.width(sharing: 740), 320, "The page keeps 420")
        XCTAssertEqual(ExtensionSidePanelAPI.width(sharing: 700), 280)
        XCTAssertNil(ExtensionSidePanelAPI.width(sharing: 699), "Hidden rather than squeezing the page")
        XCTAssertNil(ExtensionSidePanelAPI.width(sharing: 459), "The narrowest window")
    }

    private func open(_ store: TabStore) -> Tab {
        let tab = store.newBlankTab()
        let window = SidePanelFixtureWindow(contentRect: NSRect(x: 120, y: 150, width: 900, height: 500),
                                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        stores.append(store)
        window.makeKeyAndOrderFront(nil)
        return tab
    }

    private func page(_ context: WKWebExtensionContext, title: String = "Shared panel") async throws -> WKWebView {
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("shared.html")))
        try await wait("extension page") { !page.isLoading && page.title == title }
        return page
    }

    private func run(_ script: String, in page: WKWebView) async throws -> String? {
        try await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    func testWorkerOpensTabPanelAndActionAndPageCloseIt() async throws {
        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            let tab = open(store)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            let sidePanelNotes = (host.entries.first?.compatibility ?? []).filter { $0.hasPrefix("sidePanel") }
            XCTAssertEqual(sidePanelNotes.count, 1, "\(sidePanelNotes)")
            XCTAssertFalse(sidePanelNotes.contains(where: ExtensionDiagnostics.isUnsupported), "Provided, not missing")
            host.sync()
            // Somebody may be using this machine: the test answers for the mouse.
            host.secondsSinceClick = { 60 }

            // No gesture, no panel: a worker cannot open one on its own.
            let page = try await page(context)
            defer { page.stopLoading() }
            let ask = "return String(await chrome.runtime.sendMessage({windowId: (await chrome.tabs.query({}))[0].windowId}))"
            let refused = try await run(ask, in: page)
            XCTAssertTrue(refused?.contains("user gesture") == true, "\(refused ?? "nil")")
            XCTAssertTrue(host.sidePanels.isEmpty)

            // Chrome's documented pattern: a click in the page, a message, and the worker
            // opens. The click is the window's, so it counts only while that window is key.
            host.secondsSinceClick = { 1 }
            (store.window as? SidePanelFixtureWindow)?.key = false
            let background = try await run(ask, in: page)
            XCTAssertTrue(background?.contains("user gesture") == true, "\(background ?? "nil")")
            (store.window as? SidePanelFixtureWindow)?.key = true
            let clicked = try await run(ask, in: page)
            XCTAssertEqual(clicked, "opened")
            host.secondsSinceClick = { 60 }
            // The header's ✕ is the user's own way out, whatever the extension does.
            host.closeSidePanel(try XCTUnwrap(host.sidePanel(in: store)))
            XCTAssertTrue(host.sidePanels.isEmpty)

            // A click in an extension page is that page's own gesture to report. No test
            // can click, so the page says so itself — which is all the gate ever hears.
            let reported = try await run("""
                const windowId = (await chrome.tabs.query({}))[0].windowId;
                const open = () => chrome.sidePanel.open({windowId}).then(() => 'opened', () => 'refused');
                const idle = await open();
                Object.defineProperty(navigator, 'userActivation', {configurable: true, value: {isActive: true}});
                return idle + '|' + await open();
                """, in: page)
            XCTAssertEqual(reported, "refused|opened")
            host.closeSidePanel(try XCTUnwrap(host.sidePanel(in: store)))

            // The worker's own calls: `chrome.sidePanel` exists there and reaches the host.
            host.run(context, for: tab, from: nil)
            try await wait("worker-opened panel document") {
                guard let panel = host.sidePanel(in: store) else { return false }
                return !panel.web.isLoading && panel.web.title == "Fixture panel"
            }
            let panel = try XCTUnwrap(host.sidePanel(in: store))
            XCTAssertTrue(panel.context === context)
            XCTAssertEqual(panel.tabID, tab.id)
            XCTAssertEqual(panel.web.url?.path, "/panel.html")
            XCTAssertTrue(panel.web.url?.query?.hasPrefix("tabId=") == true)
            XCTAssertEqual(store.tabs.count, 1, "The bridge request must never become a tab")

            // The panel page runs in the extension's context, with the same API.
            let read = try await run("return (await chrome.sidePanel.getOptions({})).path + '|' + typeof chrome.runtime.id", in: panel.web)
            XCTAssertEqual(read, "shared.html|string")

            // What WebKit lacks keeps its events and constants and no methods, so feature
            // detection still finds it missing. Optional permissions get no stand-in.
            // `debugger` and `tabGroups` are Vane's own (ExtensionDebuggerTests,
            // ExtensionTabGroupsTests), so their methods exist.
            let gaps = try await run("""
                const managed = JSON.stringify(await chrome.storage.managed.get(null));
                return [typeof chrome.debugger.onEvent.addListener, typeof chrome.debugger?.attach,
                        chrome.notifications?.create ? 'chromium' : 'fallback', typeof chrome.tabs.group, managed,
                        chrome.tabGroups.TAB_GROUP_ID_NONE, typeof chrome.downloads, chrome.runtime.ContextType.SIDE_PANEL].join('|');
                """, in: panel.web)
            XCTAssertEqual(gaps, "function|function|fallback|function|{}|-1|undefined|SIDE_PANEL")

            // A tab's own panel belongs to that tab alone.
            let other = store.newBlankTab()
            XCTAssertEqual(store.current, other.id)
            XCTAssertNil(host.sidePanel(in: store))
            store.current = tab.id
            XCTAssertTrue(host.sidePanel(in: store) === panel)

            // Without openPanelOnActionClick the button is the extension's: its click
            // reaches `onClicked` again, which leaves the open panel open.
            let count = "return await chrome.runtime.sendMessage({handled: true})"
            let before = try await run(count, in: page)
            host.run(context, for: tab, from: nil)
            XCTAssertTrue(host.sidePanel(in: store) === panel)
            // Its `open()` is still on its way: let it land before the panel closes, or it
            // would open the panel again.
            let deadline = ContinuousClock.now + .seconds(10)
            while try await run(count, in: page) == before {
                guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: second click handled") }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(host.sidePanel(in: store) === panel)
            // An extension dismisses its own panel with window.close().
            _ = try? await panel.web.evaluateJavaScript("window.close()")
            try await wait("page-closed panel") { host.sidePanels.isEmpty }

            // The shared panel and openPanelOnActionClick, asked for from an extension page.
            _ = try await run("await chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true})", in: page)
            host.run(context, for: other, from: nil)
            try await wait("action-opened shared panel") {
                host.sidePanels.first.map { !$0.web.isLoading && $0.web.title == "Shared panel" } ?? false
            }
            let shared = try XCTUnwrap(host.sidePanels.first)
            XCTAssertNil(shared.tabID, "A tab without its own path shares the window's panel")
            store.current = other.id
            XCTAssertTrue(host.sidePanel(in: store) === shared)

            // A tab can turn the window's panel off for itself alone.
            _ = try await run("""
                const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
                await chrome.sidePanel.setOptions({tabId: tab.id, enabled: false});
                """, in: shared.web)
            try await wait("panel disabled on one tab") { host.sidePanel(in: store) == nil }
            XCTAssertEqual(host.sidePanels.count, 1)
            store.current = tab.id
            XCTAssertTrue(host.sidePanel(in: store) === shared)

            // Now the button toggles: it closes the panel it opened.
            host.run(context, for: tab, from: nil)
            XCTAssertTrue(host.sidePanels.isEmpty)

            try host.remove(folder: folder.path)
            XCTAssertTrue(host.sidePanels.isEmpty)
        }
    }

    func testPanelsLastAsLongAsTheirTabAndWindow() async throws {
        // No `sidePanel` permission: no namespace, and the bridge URL is not a request.
        let plain = Store.directory.appendingPathComponent("extension-no-side-panel-\(UUID())")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        try Data(#"{"manifest_version":3,"name":"No Panel Fixture","version":"1.0","background":{"service_worker":"worker.js"},"side_panel":{"default_path":"shared.html"}}"#.utf8)
            .write(to: plain.appendingPathComponent("manifest.json"))
        try Data().write(to: plain.appendingPathComponent("worker.js"))
        try Data("<title>Plain</title>".utf8).write(to: plain.appendingPathComponent("shared.html"))

        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            let tab = open(store)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            _ = try await host.load(plain, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first { $0.webExtension.displayName == "Side Panel Fixture" })
            let unpermitted = try XCTUnwrap(host.installed.first { $0.webExtension.displayName == "No Panel Fixture" })
            host.sync()

            let plainPage = try await page(unpermitted, title: "Plain")
            defer { plainPage.stopLoading() }
            let denied = try await run("""
                return typeof chrome.sidePanel + '|' + await chrome.tabs.create({url: chrome.runtime.getURL('/__vane_side_panel__?op=open&gesture=true')})
                    .then(() => 'opened', () => 'refused');
                """, in: plainPage)
            XCTAssertEqual(denied, "undefined|refused")
            XCTAssertTrue(host.sidePanels.isEmpty)
            XCTAssertEqual(store.tabs.count, 1)

            host.run(context, for: tab, from: nil)
            try await wait("tab panel") { host.sidePanel(in: store)?.web.title == "Fixture panel" }
            let panel = try XCTUnwrap(host.sidePanel(in: store))

            // A Space swiped away keeps its tabs alive in a stash, and their panels with them.
            let space = UUID()
            store.stashes[space] = Stash(tabs: [tab], pins: Pins(), todayShape: Pins(), splits: [], current: tab.id, fingerprint: "")
            store.tabs = []
            store.current = nil
            host.sync()
            XCTAssertTrue(host.sidePanels.contains { $0 === panel }, "A stashed tab is not a closed tab")
            XCTAssertNil(host.sidePanel(in: store))
            store.stashes[space] = nil
            store.tabs = [tab]
            store.current = tab.id
            host.sync()
            XCTAssertTrue(host.sidePanel(in: store) === panel)
            // Its options came through too: the button reopens the tab's own page.
            host.closeSidePanel(panel)
            host.run(context, for: tab, from: nil)
            try await wait("tab panel after the Space returned") { host.sidePanel(in: store)?.tabID == tab.id }

            // A panel follows its tab to another window.
            let second = TabStore(profileID: profile, session: [])
            _ = open(second)
            let moved = try XCTUnwrap(host.sidePanel(in: store))
            second.tabs.append(tab)
            second.current = tab.id
            store.tabs = []
            store.current = nil
            host.sync()
            XCTAssertTrue(host.sidePanel(in: second) === moved)
            XCTAssertNil(host.sidePanel(in: store))

            // Closing the tab closes its panel.
            second.tabs.removeAll { $0 === tab }
            host.sync()
            XCTAssertTrue(host.sidePanels.isEmpty)

            // Closing a window closes the panel it shared among its tabs.
            let page = try await page(context)
            defer { page.stopLoading() }
            _ = try await run("await chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true})", in: page)
            let last = try XCTUnwrap(second.tabs.first)
            host.run(context, for: last, from: nil)
            XCTAssertNil(try XCTUnwrap(host.sidePanel(in: second)).tabID)

            // A private window belongs to another profile's host: no panel reaches it.
            let hidden = TabStore(isPrivate: true, session: [])
            let secret = open(hidden)
            host.run(context, for: secret, from: nil)
            XCTAssertNil(host.sidePanel(in: hidden))
            XCTAssertEqual(host.sidePanels.count, 1)

            // Hopping to another profile's Space parks the store behind its window
            // (`Windows.hop`): the window's panel waits there, and is back on return.
            let shared = try XCTUnwrap(host.sidePanel(in: second))
            let window = try XCTUnwrap(second.window)
            second.parkedIn = window
            second.window = nil
            host.sync()
            XCTAssertTrue(host.sidePanels.contains { $0 === shared }, "A parked store is not a closed window")
            second.window = window
            second.parkedIn = nil
            host.sync()
            XCTAssertTrue(host.sidePanel(in: second) === shared)

            second.window?.close()
            second.window = nil
            host.sync()
            XCTAssertTrue(host.sidePanels.isEmpty)
        }
    }

    func testWorkerSetBehaviourShortcutAndContentScriptConstants() async throws {
        // What real extensions do at their worker's top level, and at their content scripts'.
        try Data(#"{"manifest_version":3,"name":"Side Panel Fixture","version":"1.0","permissions":["sidePanel"],"background":{"service_worker":"worker.js"},"action":{},"side_panel":{"default_path":"shared.html"},"commands":{"_execute_action":{"suggested_key":{"mac":"Command+Shift+Y"}}},"content_scripts":[{"matches":["https://example.test/*"],"js":["content.js"]},{"matches":["https://elsewhere.test/*"],"js":["main.js"],"world":"MAIN"},{"matches":["https://example.test/*"],"css":["content.css"]}]}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});".utf8)
            .write(to: folder.appendingPathComponent("worker.js"))
        try Data("document.documentElement.dataset.reason = chrome.runtime.OnInstalledReason.INSTALL + '|' + chrome.runtime.ContextType.TAB + '|' + typeof chrome.notifications;".utf8)
            .write(to: folder.appendingPathComponent("content.js"))
        try Data().write(to: folder.appendingPathComponent("content.css"))
        try Data().write(to: folder.appendingPathComponent("main.js"))

        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            let tab = open(store)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            host.sync()

            // The stand-in runs ahead of each group's scripts; a group without any is left alone.
            let groups = try XCTUnwrap(context.webExtension.manifest["content_scripts"] as? [[String: Any]])
            let scripts = try XCTUnwrap(groups.first?["js"] as? [String])
            XCTAssertEqual(scripts.count, 2)
            XCTAssertTrue(scripts[0].hasPrefix("__vane_content_gaps_"), "\(scripts)")
            XCTAssertEqual(scripts[1], "content.js")
            XCTAssertEqual(groups[1]["js"] as? [String], ["main.js"], "MAIN-world groups run in the page's world")
            XCTAssertNil(groups.last?["js"])
            tab.web.loadHTMLString("<title>Content fixture</title>", baseURL: URL(string: "https://example.test/page"))
            try await wait("content script") { !tab.web.isLoading && tab.web.title == "Content fixture" }
            var reason: String?
            let deadline = ContinuousClock.now + .seconds(10)
            while reason == nil, ContinuousClock.now < deadline {
                reason = try await tab.web.evaluateJavaScript("document.documentElement.dataset.reason ?? null") as? String
                if reason == nil { try await Task.sleep(for: .milliseconds(20)) }
            }
            XCTAssertEqual(reason, "install|TAB|undefined")

            // The worker's own top-level call arrives some time after it starts; until
            // then a press reaches `onClicked`, which this worker does not listen to.
            try await wait("worker-set openPanelOnActionClick") {
                host.run(context, for: tab, from: nil)
                return !host.sidePanels.isEmpty
            }
            XCTAssertNil(try XCTUnwrap(host.sidePanel(in: store)).tabID)

            // The action's shortcut is a press of its button: it closes, then opens.
            let window = try XCTUnwrap(store.window)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
            XCTAssertTrue(ExtensionCommands.handle(event))
            XCTAssertTrue(host.sidePanels.isEmpty)
            XCTAssertTrue(ExtensionCommands.handle(event))
            XCTAssertNotNil(host.sidePanel(in: store))
        }
    }

    func testWorkerReadsChromiumOnlyMembersAdBlockUsesAtItsTopLevel() async throws {
        // AdBlock's worker reads all of these at its top level; any one missing stops it.
        try Data(#"{"manifest_version":3,"name":"__MSG_name__","description":"Gaps","version":"2.5","permissions":["idle","webRequest","webNavigation","scripting","tabs","declarativeNetRequest"],"optional_permissions":["management"],"host_permissions":["<all_urls>"],"default_locale":"en","background":{"service_worker":"worker.js"},"action":{}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let locale = folder.appendingPathComponent("_locales/en")
        try FileManager.default.createDirectory(at: locale, withIntermediateDirectories: true)
        try Data(#"{"name":{"message":"Gaps Fixture"}}"#.utf8).write(to: locale.appendingPathComponent("messages.json"))
        try Data("""
            const types = Object.values(chrome.webRequest.ResourceType);
            // WebKit refuses a filter with a type it does not know.
            chrome.webRequest.onBeforeRequest.addListener(() => {}, {types, urls: ['<all_urls>']});
            // Nor a ws:// pattern, which Chrome accepts.
            chrome.webRequest.onCompleted.addListener(() => {}, {urls: ['http://*/*', 'ws://*/*', 'wss://*/*']});
            chrome.webNavigation.onHistoryStateUpdated.addListener(() => {});
            const targets = [];
            chrome.webNavigation.onCreatedNavigationTarget.addListener(details => targets.push(details));
            const top = [types.length, types.includes('webtransport'), Object.values(chrome.scripting.ExecutionWorld).includes('MAIN'),
                         chrome.idle.IdleState.LOCKED].join('|');
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
                (async () => {
                    const self = await chrome.management.getSelf();
                    const viaCallback = await new Promise(resolve => chrome.idle.queryState(30, resolve));
                    respond([top, await chrome.idle.queryState(30), viaCallback, self.name, self.id === chrome.runtime.id,
                             self.version, self.installType, await chrome.declarativeNetRequest.getAvailableStaticRuleCount(),
                             JSON.stringify(targets.map(target => [target.sourceTabId, target.tabId]))].join('|'));
                })();
                return true;
            });
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))

        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            let tab = open(store)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            XCTAssertTrue(context.errors.isEmpty, "\(context.errors)")
            let notes = host.entries.first?.compatibility ?? []
            XCTAssertTrue(notes.contains("idle: Vane always reports the user as active; state changes never fire."), "\(notes)")
            XCTAssertFalse(notes.contains(where: { $0.hasPrefix("idle") && ExtensionDiagnostics.isUnsupported($0) }), "\(notes)")
            host.sync()
            let page = try await page(context)
            defer { page.stopLoading() }
            let ask = "return String(await chrome.runtime.sendMessage({}))"
            _ = try await run(ask, in: page)

            // A tab another tab opened is a navigation target of its opener.
            _ = store.newBlankTab(parent: tab)
            host.sync()
            let listed = try await run("const tabs = await chrome.tabs.query({}); return JSON.stringify(tabs.map(t => t.id))", in: page)
            let tabIDs = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(XCTUnwrap(listed).utf8)) as? [Int])
            XCTAssertEqual(tabIDs.count, 2)
            var answer = try await run(ask, in: page)
            let deadline = ContinuousClock.now + .seconds(10)
            while answer?.hasSuffix("]]") != true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
                answer = try await run(ask, in: page)
            }
            XCTAssertEqual(answer, "13|false|true|locked|active|active|Gaps Fixture|true|2.5|normal|30000|[[\(tabIDs[0]),\(tabIDs[1])]]")
        }
    }

    func testWorkerGetsPromisedAlarmsContextsAndOffscreenFromTheHost() async throws {
        // Claude's worker chains `alarms.create(…).catch`, asks
        // getContexts which panels are open and keeps an offscreen document.
        try Data(#"{"manifest_version":3,"name":"Gaps Fixture","description":"Gaps","version":"1.0","permissions":["alarms","tabs","offscreen","sidePanel"],"background":{"service_worker":"worker.js"},"action":{},"side_panel":{"default_path":"shared.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Offscreen</title><script src='off.js'></script>".utf8).write(to: folder.appendingPathComponent("off.html"))
        try Data("chrome.runtime.onMessage.addListener((message, sender, respond) => { if (message.target === 'off') respond('ready'); });".utf8)
            .write(to: folder.appendingPathComponent("off.js"))
        try Data("""
            const created = chrome.alarms.create('refresh', {delayInMinutes: 1});
            const promised = typeof created?.then === 'function';
            created.catch(() => {});
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
                (async () => {
                    await chrome.offscreen.createDocument({url: 'off.html', reasons: [chrome.offscreen.Reason.BLOBS], justification: 'Test'});
                    // Chrome resolves once the document loaded: it answers at once.
                    const ready = await chrome.runtime.sendMessage({target: 'off'});
                    const types = (await chrome.runtime.getContexts({})).map(context => context.contextType).sort();
                    const twice = await chrome.offscreen.createDocument({url: 'off.html', reasons: ['BLOBS'], justification: 'Test'}).then(() => 'twice', error => error.message);
                    await chrome.offscreen.closeDocument();
                    respond(JSON.stringify([promised, types, ready, twice, await chrome.offscreen.hasDocument(), (await chrome.action.getUserSettings()).isOnToolbar]));
                })().catch(error => respond('failed: ' + error.message));
                return true;
            });
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))

        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            _ = open(store)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            XCTAssertTrue(ExtensionDiagnostics.runtimeErrors(context.errors, manifest: context.webExtension.manifest).isEmpty, "\(context.errors)")
            let notes = host.entries.first?.compatibility ?? []
            XCTAssertFalse(notes.contains(where: { $0.hasPrefix("offscreen") && ExtensionDiagnostics.isUnsupported($0) }), "\(notes)")
            host.sync()
            let page = try await page(context)
            defer { page.stopLoading() }
            let answer = try await run("return String(await chrome.runtime.sendMessage({}))", in: page)
            XCTAssertEqual(answer, #"[true,["BACKGROUND","OFFSCREEN_DOCUMENT"],"ready","Only a single offscreen document may be created.",false,true]"#)
        }
    }
}
