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
        try Data(#"{"manifest_version":3,"name":"Side Panel Fixture","version":"1.0","permissions":["sidePanel","notifications","debugger","tabGroups","storage"],"background":{"service_worker":"worker.js"},"action":{},"side_panel":{"default_path":"shared.html"}}"#.utf8)
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
            """.utf8).write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Fixture panel</title><p>Panel</p>".utf8).write(to: folder.appendingPathComponent("panel.html"))
        try Data("<title>Shared panel</title><p>Shared</p>".utf8).write(to: folder.appendingPathComponent("shared.html"))
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        for store in TabStore.all.filter({ $0.profileID == profile }) {
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

    func testWorkerOpensTabPanelAndActionAndPageCloseIt() async throws {
        try await withNativeWindowLoop {
            let store = TabStore(profileID: profile, session: [])
            let tab = store.newBlankTab()
            let window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 900, height: 500),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            stores.append(store)
            window.makeKeyAndOrderFront(nil)
            let host = ExtensionHost.host(for: profile)
            _ = try await host.load(folder, installing: true) { _ in true }
            let context = try XCTUnwrap(host.installed.first)
            let sidePanelNotes = (host.entries.first?.compatibility ?? []).filter { $0.localizedCaseInsensitiveContains("side") }
            XCTAssertEqual(sidePanelNotes.count, 1, "\(sidePanelNotes)")
            XCTAssertFalse(sidePanelNotes.contains(where: ExtensionDiagnostics.isUnsupported), "Provided, not missing")
            host.sync()

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
            let read = try await panel.web.callAsyncJavaScript(
                "return (await chrome.sidePanel.getOptions({})).path + '|' + typeof chrome.runtime.id",
                arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(read as? String, "shared.html|string")

            // What WebKit lacks fails explicitly, and only what the manifest declared exists.
            let gaps = try await panel.web.callAsyncJavaScript("""
                const failure = await chrome.debugger.attach({tabId: 1}, '1.3').then(() => 'attached', error => error.message);
                const managed = JSON.stringify(await chrome.storage.managed.get(null));
                return [failure, managed, chrome.tabGroups.TAB_GROUP_ID_NONE, typeof chrome.downloads,
                        chrome.runtime.ContextType.SIDE_PANEL].join('|');
                """, arguments: [:], in: nil, contentWorld: .page)
            XCTAssertEqual(gaps as? String, "Vane does not support chrome.debugger.attach|{}|-1|undefined|SIDE_PANEL")

            // A tab's own panel belongs to that tab alone.
            let other = store.newBlankTab()
            XCTAssertEqual(store.current, other.id)
            XCTAssertNil(host.sidePanel(in: store))
            store.current = tab.id
            XCTAssertTrue(host.sidePanel(in: store) === panel)

            // The button that opened it closes it, without asking the extension again.
            host.run(context, for: tab, from: nil)
            XCTAssertNil(host.sidePanel(in: store))
            XCTAssertTrue(host.sidePanels.isEmpty)

            host.run(context, for: tab, from: nil)
            try await wait("reopened panel document") {
                guard let panel = host.sidePanel(in: store) else { return false }
                return !panel.web.isLoading && panel.web.title == "Fixture panel"
            }
            let reopened = try XCTUnwrap(host.sidePanel(in: store))
            XCTAssertFalse(reopened === panel)
            // An extension dismisses its own panel with window.close().
            _ = try? await reopened.web.evaluateJavaScript("window.close()")
            try await wait("page-closed panel") { host.sidePanels.isEmpty }

            // The shared panel and openPanelOnActionClick, asked for from an extension page.
            let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
            defer { page.stopLoading() }
            page.load(URLRequest(url: context.baseURL.appendingPathComponent("shared.html")))
            try await wait("extension page") { !page.isLoading && page.title == "Shared panel" }
            _ = try await page.callAsyncJavaScript("await chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true})",
                                                   arguments: [:], in: nil, contentWorld: .page)
            host.run(context, for: other, from: nil)
            try await wait("action-opened shared panel") {
                host.sidePanels.first.map { !$0.web.isLoading && $0.web.title == "Shared panel" } ?? false
            }
            XCTAssertNil(try XCTUnwrap(host.sidePanels.first).tabID, "A tab without its own path shares the window's panel")
            store.current = other.id
            XCTAssertNotNil(host.sidePanel(in: store))

            // Closing the tab forgets its panel options; unloading closes every panel.
            try host.remove(folder: folder.path)
            XCTAssertTrue(host.sidePanels.isEmpty)
        }
    }
}
