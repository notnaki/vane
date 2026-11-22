import AppKit
import WebKit
import XCTest
@testable import vane

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
            chrome.action.onClicked.addListener(tab => {
                chrome.sidePanel.setOptions({tabId: tab.id, path: 'panel.html?tabId=' + tab.id, enabled: true});
                chrome.sidePanel.open({tabId: tab.id});
            });
            // A worker has no gesture of its own: this open succeeds only after the button.
            chrome.runtime.onMessage.addListener((message, sender, respond) => {
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
        let window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 900, height: 500),
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
            let sidePanelNotes = (host.entries.first?.compatibility ?? []).filter { $0.localizedCaseInsensitiveContains("side") }
            XCTAssertEqual(sidePanelNotes.count, 1, "\(sidePanelNotes)")
            XCTAssertFalse(sidePanelNotes.contains(where: ExtensionDiagnostics.isUnsupported), "Provided, not missing")
            host.sync()

            // No gesture, no panel: a worker cannot open one on its own.
            let page = try await page(context)
            defer { page.stopLoading() }
            let ask = "return String(await chrome.runtime.sendMessage({windowId: (await chrome.windows.getCurrent()).id}))"
            let refused = try await run(ask, in: page)
            XCTAssertTrue(refused?.contains("user gesture") == true, "\(refused ?? "nil")")
            XCTAssertTrue(host.sidePanels.isEmpty)

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
            let gaps = try await run("""
                const managed = JSON.stringify(await chrome.storage.managed.get(null));
                return [typeof chrome.debugger.onEvent.addListener, typeof chrome.debugger?.attach,
                        chrome.notifications?.create ? 'chromium' : 'fallback', typeof chrome.tabs.group, managed,
                        chrome.tabGroups.TAB_GROUP_ID_NONE, typeof chrome.downloads, chrome.runtime.ContextType.SIDE_PANEL].join('|');
                """, in: panel.web)
            XCTAssertEqual(gaps, "function|undefined|fallback|undefined|{}|-1|undefined|SIDE_PANEL")

            // A tab's own panel belongs to that tab alone.
            let other = store.newBlankTab()
            XCTAssertEqual(store.current, other.id)
            XCTAssertNil(host.sidePanel(in: store))
            store.current = tab.id
            XCTAssertTrue(host.sidePanel(in: store) === panel)

            // Without openPanelOnActionClick the button is the extension's: its click
            // reaches `onClicked` again, which leaves the open panel open.
            host.run(context, for: tab, from: nil)
            try await Task.sleep(for: .milliseconds(300))
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

            second.window?.close()
            second.window = nil
            host.sync()
            XCTAssertTrue(host.sidePanels.isEmpty)
        }
    }
}
