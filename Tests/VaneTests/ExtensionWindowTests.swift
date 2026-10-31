import AppKit
import WebKit
import XCTest
@testable import vane

/// These controls exercise real SDK views and WindowServer presentation. In particular,
/// an SDK popover must not satisfy the compact native-window contract.
@MainActor final class ExtensionWindowTests: XCTestCase {
    @MainActor private final class CloseCounter { var count = 0 }
    private var profile = UUID()
    private var ownedProfiles: Set<UUID> = []
    private var folder: URL!
    private var stores: [TabStore] = []
    private var originalPolicy: NSApplication.ActivationPolicy!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        originalPolicy = NSApp.activationPolicy()
        profile = UUID()
        ownedProfiles.insert(profile)
        folder = Store.directory.appendingPathComponent("extension-window-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Compact Window Fixture","version":"1.0","permissions":["tabs","storage","activeTab"],"action":{"default_popup":"popup.html"},"options_ui":{"page":"options.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Compact popup</title><style>html,body{margin:0;width:320px;height:230px}body{background:#ddd}</style><p>Extension popup</p>".utf8)
            .write(to: folder.appendingPathComponent("popup.html"))
        try Data("<title>Compact options</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    override func tearDown() async throws {
        for profile in ownedProfiles { ExtensionHost.forget(profile) }
        let trackedStores = Set(stores.map(ObjectIdentifier.init))
        for store in TabStore.all.filter({ ownedProfiles.contains($0.profileID) || trackedStores.contains(ObjectIdentifier($0)) }) {
            store.window?.close()
            store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        stores.removeAll()
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release(ownedProfiles)
        ownedProfiles.removeAll()
        NSApp.setActivationPolicy(originalPolicy)
    }

    private func wait(_ description: String, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func text(in view: NSView?) -> String {
        guard let view else { return "" }
        let own = (view as? NSTextField)?.stringValue ?? (view as? NSTextView)?.string ?? ""
        return ([own] + view.subviews.map { text(in: $0) }).joined(separator: "\n")
    }

    private func browser() async throws -> (TabStore, Tab, NSWindow) {
        let store = TabStore(profileID: profile, session: [])
        let tab = store.newBlankTab()
        let window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        stores.append(store)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("origin browser foreground") { NSApp.isActive && window.isKeyWindow && window.isVisible }
        return (store, tab, window)
    }

    private func installed() async throws -> (ExtensionHost, WKWebExtensionContext) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        return (host, try XCTUnwrap(host.installed.first))
    }

    /// A parked URL has no admitted document and is not a sufficient prerequisite
    /// for testing the SDK's user-gesture grant on a specific live tab.
    private func loadDocument(in tab: Tab, window: NSWindow, url: URL, title: String) async throws {
        let web = tab.web
        web.frame = try XCTUnwrap(window.contentView).bounds
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        tab.expectNavigation(web.loadHTMLString("<title>\(title)</title><p>Controlled parent document</p>", baseURL: url))
        try await wait("live originating document and adapter URL") {
            !web.isLoading && web.title == title && web.url == url && tab.currentURL == url
                && web.window === window && window.contentView === web
        }
        let ready = try await web.evaluateJavaScript("document.readyState") as? String
        guard ready == "complete" else { throw ExtensionHost.Failure("The originating document did not finish loading before the action") }
    }

    private func open(_ context: WKWebExtensionContext, host: ExtensionHost, tab: Tab, parent: NSWindow) async throws -> (WKWebExtension.Action, WKWebView, NSWindow) {
        parent.makeKeyAndOrderFront(nil)
        try await wait("origin browser key before invocation") { NSApp.isActive && parent.isKeyWindow }
        host.run(context, for: tab, from: parent.contentView)
        let action = try XCTUnwrap(host.action(context, for: tab))
        let web = try XCTUnwrap(action.popupWebView)
        try await wait("exact popup document in visible owner") {
            !web.isLoading && web.title == "Compact popup" && web.window?.isVisible == true
        }
        return (action, web, try XCTUnwrap(web.window))
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

    func testActionFocusUpdatesCachedSDKWindowAndEventsWithoutManualSync() async throws {
        try await withNativeWindowLoop {
            let (store, tab, parent) = try await browser()
            try await loadDocument(in: tab, window: parent, url: URL(string: "https://focus.example/parent")!, title: "Focus parent")
            let (host, context) = try await installed()
            host.sync() // Initial browser registration only; no sync after action presentation.
            let options = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
            defer { options.stopLoading() }
            options.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
            try await wait("focus listener document") { !options.isLoading && options.title == "Compact options" }
            let browserIDValue = try await options.callAsyncJavaScript("""
                window.focusEvents=[];
                browser.windows.onFocusChanged.addListener(id => window.focusEvents.push(id));
                return (await browser.windows.getLastFocused()).id;
                """, arguments: [:], in: nil, contentWorld: .page)
            let browserID = try XCTUnwrap(browserIDValue as? Int)
            let (_, web, window) = try await open(context, host: host, tab: tab, parent: parent)
            try await wait("action native key owner") { NSApp.isActive && window.isKeyWindow && web.window === window }
            XCTAssertTrue((context.focusedWindow as? ExtWindow)?.store === store,
                          "The SDK cache must identify the origin, independently of the delegate fallback")
            _ = try await options.evaluateJavaScript("window.focusEvents=[]")
            let unrelated = NSWindow(contentRect: NSRect(x: 300, y: 180, width: 220, height: 160),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
            unrelated.isReleasedWhenClosed = false
            defer { unrelated.close() }
            unrelated.makeKeyAndOrderFront(nil)
            try await wait("unrelated native key window") { NSApp.isActive && unrelated.isKeyWindow && !window.isKeyWindow }
            XCTAssertNil(context.focusedWindow, "An unrelated native window must clear the SDK's cached browser focus")
            window.makeKeyAndOrderFront(nil)
            try await wait("action regains native key focus") { NSApp.isActive && window.isKeyWindow }
            XCTAssertTrue((context.focusedWindow as? ExtWindow)?.store === store)
            let deadline = ContinuousClock.now + .seconds(5)
            var events: [Int] = []
            repeat {
                events = try await options.evaluateJavaScript("window.focusEvents") as? [Int] ?? []
                if events == [-1, browserID] { break }
                guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("The SDK focus events did not report native focus loss and origin restoration: \(events)") }
                try await Task.sleep(for: .milliseconds(20))
            } while true
            XCTAssertEqual(events, [-1, browserID])
            XCTAssertTrue(web.window === window && window.isVisible)
        }
    }

    func testMovedOriginPopupSurvivesOldParentCloseAndClosesWithCurrentParent() async throws {
        try await withNativeWindowLoop {
            let (source, tab, originalParent) = try await browser()
            try await loadDocument(in: tab, window: originalParent, url: URL(string: "https://move.example/parent")!, title: "Moving parent")
            let (destination, _, currentParent) = try await browser()
            let (host, context) = try await installed()
            host.sync()
            let (action, popup, popupWindow) = try await open(context, host: host, tab: tab, parent: originalParent)
            let page = try XCTUnwrap(tab.existingWeb)
            originalParent.contentView = NSView(frame: try XCTUnwrap(originalParent.contentView).bounds)
            currentParent.contentView = page
            source.tabs.removeAll { $0 === tab }
            destination.tabs.append(tab)
            destination.current = tab.id
            host.sync() // The production move notification, completed before either close.
            XCTAssertTrue((action.associatedTab as? ExtTab)?.store === destination)
            XCTAssertTrue(popup.window === popupWindow && popupWindow.isVisible)
            originalParent.close()
            XCTAssertTrue(popup.window === popupWindow && popupWindow.isVisible,
                          "A moved action must detach the original parent's close observer")
            currentParent.close()
            try await wait("current parent closes moved action") { !popupWindow.isVisible && popup.window == nil }
        }
    }

    func testOriginLeavingItsProfileOrEnteringPrivateStoreClosesTheAction() async throws {
        try await withNativeWindowLoop {
            let (host, context) = try await installed()
            for isPrivate in [false, true] {
                let (source, tab, parent) = try await browser()
                try await loadDocument(in: tab, window: parent, url: URL(string: "https://boundary.example/\(isPrivate)")!, title: "Boundary parent")
                host.sync()
                let (_, popup, popupWindow) = try await open(context, host: host, tab: tab, parent: parent)
                let foreignProfile = UUID()
                if !isPrivate { ownedProfiles.insert(foreignProfile) }
                let destination = TabStore(isPrivate: isPrivate, profileID: foreignProfile, session: [])
                let destinationWindow = NSWindow(contentRect: NSRect(x: 150, y: 160, width: 500, height: 350),
                                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                destinationWindow.isReleasedWhenClosed = false
                destination.window = destinationWindow
                stores.append(destination)
                source.tabs.removeAll { $0 === tab }
                destination.tabs.append(tab)
                host.sync()
                try await wait("profile/private boundary retires original action") { !popupWindow.isVisible && popup.window == nil }
                XCTAssertNil(host.actionPopupWindow(context, for: tab))
                XCTAssertFalse(context.hasAccessToPrivateData)
            }
        }
    }

    func testActionUsesNativeWindowRetainsParentAndClosesReopensWithoutChangingAccess() async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseActionWindow() } catch { failure = error }
        ExtensionHost.forget(profile)
        for store in stores { store.window?.orderOut(nil) }
        do { try await loop.close() } catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func exerciseActionWindow() async throws {
        let (store, tab, parent) = try await browser()
        let originURL = URL(string: "https://origin.example/parent")!
        let siblingURL = URL(string: "https://sibling.example/other")!
        try await loadDocument(in: tab, window: parent, url: originURL, title: "Origin")
        let (siblingStore, sibling, siblingWindow) = try await browser()
        try await loadDocument(in: sibling, window: siblingWindow, url: siblingURL, title: "Sibling")
        let (host, context) = try await installed()
        host.sync()
        let originAdapter = host.adapter(for: tab, in: store)
        let siblingAdapter = host.adapter(for: sibling, in: siblingStore)
        guard originAdapter.url(for: context) == originURL, siblingAdapter.url(for: context) == siblingURL else {
            throw ExtensionHost.Failure("The SDK adapters do not identify the admitted parent and sibling documents")
        }
        let granted = context.grantedPermissions
        XCTAssertTrue(context.grantedPermissionMatchPatterns.isEmpty)
        XCTAssertTrue(context.hasPermission(WKWebExtension.Permission(rawValue: "activeTab")))
        XCTAssertFalse(context.hasAccess(to: originURL, in: originAdapter))
        XCTAssertFalse(context.hasAccess(to: siblingURL, in: siblingAdapter))
        let (action, web, window) = try await open(context, host: host, tab: tab, parent: parent)
        // WebKit performs the activeTab gesture synchronously, before requesting
        // popup presentation. Its temporary grant belongs to this exact tab; the
        // global hasAccess(to:) overload cannot check that scoped permission.
        func assertGestureScope(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(context.hasAccess(to: originURL, in: originAdapter), file: file, line: line)
            XCTAssertFalse(context.hasAccess(to: siblingURL, in: originAdapter), file: file, line: line)
            XCTAssertFalse(context.hasAccess(to: siblingURL, in: siblingAdapter), file: file, line: line)
            XCTAssertFalse(context.hasAccess(to: originURL, in: siblingAdapter), file: file, line: line)
            XCTAssertFalse(context.hasAccess(to: originURL), file: file, line: line)
            XCTAssertFalse(context.hasAccess(to: siblingURL), file: file, line: line)
            XCTAssertFalse(context.hasPermission(WKWebExtension.Permission(rawValue: "nativeMessaging")), file: file, line: line)
        }
        assertGestureScope()
        let sites = context.grantedPermissionMatchPatterns
        XCTAssertTrue(sites.isEmpty, "An activeTab gesture must not become a permanent global host grant")
        XCTAssertTrue(window.styleMask.contains(.titled), "Action UI must have a native titlebar, not a popover")
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window === parent)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertTrue(content === web || web.isDescendant(of: content))
        XCTAssertTrue(action.popupWebView === web)
        XCTAssertTrue(host.actionPopupWindow(context, for: tab) === window)
        XCTAssertTrue((action.associatedTab as? ExtTab)?.tab === tab)
        XCTAssertLessThanOrEqual(window.contentLayoutRect.width, 800)
        XCTAssertLessThanOrEqual(window.contentLayoutRect.height, 600)
        window.makeKeyAndOrderFront(nil)
        try await wait("extension window foreground") { window.isKeyWindow && NSApp.isActive }
        XCTAssertTrue((host.webExtensionController(host.controller, focusedWindowFor: context) as? ExtWindow)?.store === store)
        // WebKit may ask for global URL access while serving tabs.query, even
        // though activeTab already grants this exact tab. This fixture approves
        // only the manifest/action gesture; deny any such additional prompt.
        let deniedPrompts = CloseCounter()
        let denyAdditionalURLAccess = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let modal = NSApp.modalWindow else { return }
                let text = Self.text(in: modal.contentView)
                guard text.contains("Compact Window Fixture"), text.contains(originURL.absoluteString) else { return }
                deniedPrompts.count += 1
                print("Extension window fixture: denied additional synthetic-origin URL prompt \(deniedPrompts.count)")
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
        }
        RunLoop.main.add(denyAdditionalURLAccess, forMode: .modalPanel)
        defer { denyAdditionalURLAccess.invalidate() }
        let parentURLs = try await web.callAsyncJavaScript("return (await browser.tabs.query({active:true,currentWindow:true})).map(t=>t.url);", arguments: [:], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(parentURLs, ["https://origin.example/parent"])
        assertGestureScope()
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites,
                       "Querying the parent must not grant an additional global host pattern")
        XCTAssertTrue(store.active === tab)
        _ = try await web.callAsyncJavaScript("await browser.storage.local.set({compactWindow:'retained'}); return true;", arguments: [:], in: nil, contentWorld: .page)
        host.run(context, for: tab, from: parent.contentView)
        XCTAssertTrue(action.popupWebView === web, "Repeated invocation must focus the existing UI")
        assertGestureScope()
        XCTAssertEqual(context.grantedPermissions, granted)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites)
        // No further gesture occurs between this baseline and native dismissal.
        let nativeClosePermissions = context.grantedPermissions
        let nativeCloseSites = context.grantedPermissionMatchPatterns
        let closes = CloseCounter()
        let closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { _ in MainActor.assumeIsolated { closes.count += 1 } }
        window.performClose(nil)
        try await wait("native close") { !window.isVisible && web.window == nil }
        NotificationCenter.default.removeObserver(closeObserver)
        XCTAssertEqual(closes.count, 1, "A user close must retire the presentation without reentering NSWindow.close")
        XCTAssertEqual(context.grantedPermissions, nativeClosePermissions)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, nativeCloseSites)
        assertGestureScope()
        let (reopenedAction, reopened, reopenedWindow) = try await open(context, host: host, tab: tab, parent: parent)
        XCTAssertFalse(reopened === web)
        assertGestureScope()
        let stored = try await reopened.callAsyncJavaScript("return (await browser.storage.local.get('compactWindow')).compactWindow;", arguments: [:], in: nil, contentWorld: .page) as? String
        XCTAssertEqual(stored, "retained")
        // This reopened UI has its own legitimate gesture. Compare its closure
        // against that baseline, rather than crossing another action invocation.
        let scriptClosePermissions = context.grantedPermissions
        let scriptCloseSites = context.grantedPermissionMatchPatterns
        _ = try await reopened.evaluateJavaScript("window.close()")
        try await wait("script closure closes native owner") { !reopenedWindow.isVisible && reopened.window == nil }
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.grantedPermissions, scriptClosePermissions)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, scriptCloseSites)
        XCTAssertEqual(scriptClosePermissions, granted)
        XCTAssertEqual(scriptCloseSites, sites)
        assertGestureScope()
        let (_, last, lastWindow) = try await open(context, host: host, tab: tab, parent: parent)
        try host.disable(folder.path)
        try await wait("disable closes owned native window") { !lastWindow.isVisible && last.window == nil }
        try await host.setEnabled(true, for: folder.path) { _ in true }
        let restored = try XCTUnwrap(host.installed.first)
        let (_, finalWeb, finalWindow) = try await open(restored, host: host, tab: tab, parent: parent)
        parent.close()
        try await wait("parent closure retires its action view") { !finalWindow.isVisible && finalWeb.window == nil }
        reopenedAction.closePopup()
    }

    func testRequestedPopupUsesOwnExtensionViewReportsPopupAndNormalizesPartialFrame() async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await exerciseRequestedPopup() } catch { failure = error }
        ExtensionHost.forget(profile)
        for store in TabStore.all.filter({ $0.profileID == profile }) { store.window?.orderOut(nil) }
        do { try await loop.close() } catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    func testSDKDelegatesForwardExternalLinksAndCloseTheOwnerOnTerminationCallback() async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let (store, tab, parent) = try await browser()
            let (host, context) = try await installed()
            let (_, web, window) = try await open(context, host: host, tab: tab, parent: parent)
            _ = try await web.evaluateJavaScript("""
                const link = document.createElement('a');
                link.href='https://example.invalid/extension-popup-link';
                link.target='_blank'; document.body.appendChild(link); link.click();
                """)
            try await wait("SDK delegate opens external link in originating browser") {
                store.tabs.contains { $0.currentURL?.absoluteString == "https://example.invalid/extension-popup-link" }
            }
            XCTAssertTrue(web.window === window && window.isVisible)
            let delegate = try XCTUnwrap(web.navigationDelegate)
            delegate.webViewWebContentProcessDidTerminate?(web)
            try await wait("public termination callback retires exact native owner") { !window.isVisible && web.window == nil }
        } catch { failure = error }
        ExtensionHost.forget(profile)
        for store in stores { store.window?.orderOut(nil) }
        do { try await loop.close() } catch { if failure == nil { failure = error } else { XCTFail("AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func exerciseRequestedPopup() async throws {
        let (_, _, parent) = try await browser()
        let (host, context) = try await installed()
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        func findWeb(_ view: NSView?) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view?.subviews.compactMap { findWeb($0) }.first
        }
        let options = try XCTUnwrap(NSApp.windows.compactMap { findWeb($0.contentView) }.first { $0.url == context.optionsPageURL })
        try await wait("options document in its own visible window") {
            !options.isLoading && options.title == "Compact options" && options.window?.isVisible == true
        }
        let result = try await options.callAsyncJavaScript("return await browser.windows.create({type:'popup',url:browser.runtime.getURL('popup.html'),width:345,left:110,focused:true});", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["type"] as? String, "popup")
        let id = try XCTUnwrap(result?["id"] as? Int)
        let popupURL = context.baseURL.appendingPathComponent("popup.html")
        try await wait("requested extension popup document") {
            NSApp.windows.compactMap { findWeb($0.contentView) }.contains { $0.url == popupURL && $0.title == "Compact popup" && $0.window?.isVisible == true }
        }
        let web = try XCTUnwrap(NSApp.windows.compactMap { findWeb($0.contentView) }.first { $0.url == popupURL })
        let window = try XCTUnwrap(web.window)
        let adapter = try XCTUnwrap(context.openWindows.compactMap { $0 as? ExtensionRequestedWindow }.first { $0.presentation.web === web })
        XCTAssertTrue(adapter.presentation.window === window)
        XCTAssertTrue(context.openTabs.contains { ($0 as AnyObject) === adapter.tab })
        XCTAssertEqual(web.configuration.websiteDataStore.identifier, context.webViewConfiguration?.websiteDataStore.identifier)
        let foreignProfile = UUID()
        ownedProfiles.insert(foreignProfile)
        let foreignHost = ExtensionHost.host(for: foreignProfile)
        _ = try await foreignHost.load(folder, installing: true) { _ in true }
        let foreign = try XCTUnwrap(foreignHost.installed.first)
        XCTAssertNil(adapter.activeTab(for: foreign))
        XCTAssertNil(adapter.tab.webView(for: foreign))
        XCTAssertFalse(foreign.openWindows.contains { ($0 as AnyObject) === adapter })
        window.makeKeyAndOrderFront(nil)
        try await wait("requested popup focus") { window.isKeyWindow && NSApp.isActive }
        host.sync()
        XCTAssertTrue((context.focusedWindow as AnyObject?) === adapter)
        XCTAssertFalse(window === parent)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.frame.origin.x.isFinite && window.frame.origin.y.isFinite && window.frame.width.isFinite && window.frame.height.isFinite)
        XCTAssertEqual(window.frame.width, 345, accuracy: 1)
        let queried = try await options.callAsyncJavaScript("return await browser.windows.get(id,{populate:true});", arguments: ["id": id], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(queried?["type"] as? String, "popup")
        let tabs = queried?["tabs"] as? [[String: Any]]
        XCTAssertEqual(tabs?.count, 1)
        XCTAssertEqual(tabs?.first?["url"] as? String, popupURL.absoluteString)
        _ = try await options.callAsyncJavaScript("await browser.windows.remove(id); return true;", arguments: ["id": id], in: nil, contentWorld: .page)
        try await wait("windows.remove closes exact requested owner") { !window.isVisible && web.window == nil }
        let rejected = try await options.callAsyncJavaScript("""
            const requests = [
                {type:'popup',url:[browser.runtime.getURL('popup.html'),browser.runtime.getURL('options.html')]},
                {type:'popup',url:'https://example.test/'},
                {type:'popup',url:browser.runtime.getURL('popup.html'),incognito:true},
                {type:'popup',url:browser.runtime.getURL('popup.html').replace('://','://user@')},
                {type:'popup',tabId:(await browser.tabs.query({}))[0].id}
            ];
            const outcomes=[];
            for (const request of requests) {
                try { await browser.windows.create(request); outcomes.push(false); }
                catch (_) { outcomes.push(true); }
            }
            return outcomes;
            """, arguments: [:], in: nil, contentWorld: .page) as? [Bool]
        XCTAssertEqual(rejected, [true, true, true, true, true], "Unsupported popup combinations must fail explicitly")
    }
    private final class EmptyPolicyDelegate: NSObject, WKNavigationDelegate {}

    func testCompactDelegateWithoutOriginalPolicyAllowsItsOwnedDocument() async throws {
        try await withNativeWindowLoop {
            let (store, tab, _) = try await browser()
            let (_, context) = try await installed()
            let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 230),
                                configuration: try XCTUnwrap(context.webViewConfiguration))
            let original = EmptyPolicyDelegate()
            web.navigationDelegate = original
            let presentation = ExtensionWindowPresentation(web: web, context: context,
                parentStore: store, parentTab: tab, title: "Policy fallback") { _ in }
            defer { presentation.close() }
            presentation.show()
            let url = try XCTUnwrap(context.optionsPageURL)
            web.load(URLRequest(url: url))
            try await wait("owned document with no original policy selector") {
                !web.isLoading && web.url == url && web.title == "Compact options"
                    && web.window === presentation.window && presentation.window.isVisible
            }
            XCTAssertTrue(context.isLoaded)
            presentation.close()
            XCTAssertTrue(web.navigationDelegate === original, "Closing restores the exact original delegate")
        }
    }

}
