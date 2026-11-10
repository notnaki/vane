import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionFilterBridgeTests: XCTestCase {
    private var profiles = Set<UUID>()
    private var views: [WKWebView] = []
    private var folder: URL!
    private weak var observedBackground: WKWebView?
    private var stores: [TabStore] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        folder = Store.directory.appendingPathComponent("filter-bridge-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 2, "name": "uBlock Origin", "version": "1.0",
            "permissions": ["alarms", "storage", "tabs", "webNavigation", "webRequest", "webRequestBlocking", "<all_urls>"],
            "background": ["page": "background.html", "persistent": true], "options_ui": ["page": "options.html"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data(#"{"fixture":{"content":"filters","contentURL":"assets/filters.txt"}}"#.utf8)
            .write(to: folder.appendingPathComponent("assets/assets.json"))
        try Data("/blocked-resource\n/allowed-resource\n@@/allowed-resource".utf8)
            .write(to: folder.appendingPathComponent("assets/filters.txt"))
        try Data("<title>Bridge options</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
        try Data("<meta charset=utf-8><script src=background.js></script>".utf8).write(to: folder.appendingPathComponent("background.html"))
        try Data("""
            const privacySetting = chrome.privacy.network.networkPredictionEnabled;
            let privacyDenied = false;
            try { privacySetting.set({value:false}); } catch { privacyDenied = true; }
            if (!privacyDenied) throw new Error('Privacy settings must fail explicitly');
            self.chrome = self.browser;
            const detachedURL = {get:browser.runtime.getURL};
            if (typeof detachedURL.get('') !== 'string') throw new Error('Chrome runtime URL methods must allow a detached receiver');
            const updateListener = () => {};
            browser.runtime.onUpdateAvailable.addListener(updateListener);
            if (!browser.runtime.onUpdateAvailable.hasListener(updateListener)) throw new Error('Update listener registration failed');
            browser.runtime.onUpdateAvailable.removeListener(updateListener);
            browser.webRequest.handlerBehaviorChanged();
            browser.webNavigation.onCreatedNavigationTarget.addListener(details => {
                browser.storage.local.set({navigationTarget:details});
            });
            self.µBlock = {readyToFilter:false, selectedFilterLists:['fixture','user-filters']};
            self.vAPI = {cacheStorage:{get:keys => browser.storage.local.get(keys)}};
            browser.storage.local.get('selectedFilterLists').then(async bin => {
                if (!Array.isArray(bin.selectedFilterLists)) {
                    await browser.storage.local.set({selectedFilterLists:['fixture','user-filters'], 'user-filters':'/user-resource'});
                }
                await new Promise(resolve => requestIdleCallback(deadline => {
                    if (deadline.timeRemaining() < 0 || deadline.timeRemaining() > 50) throw new Error('Invalid cooperative deadline');
                    resolve();
                }));
                self.µBlock.readyToFilter = true;
            });
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
    }

    override func tearDown() async throws {
        for web in views { web.stopLoading(); web.removeFromSuperview() }
        views.removeAll()
        for profile in profiles {
            let host = ExtensionHost.host(for: profile)
            for context in host.installed { host.remove(context) }
            ExtensionHost.forget(profile)
        }
        for store in stores {
            store.window = nil
            TabStore.all.removeAll { $0 === store }
            store.everyTab.forEach { $0.tearDown() }
        }
        stores.removeAll()
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release(profiles)
        profiles.removeAll()
    }

    private func web(profile: UUID) -> WKWebView {
        profiles.insert(profile)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: Tab.configuration(isPrivate: profile == Profile.incognito.id, profileID: profile))
        views.append(web)
        return web
    }

    private func fetch(_ web: WKWebView, _ path: String) async throws -> Bool {
        try await web.callAsyncJavaScript("try { await fetch(path, {cache:'no-store'}); return true; } catch { return false; }",
            arguments: ["path": path], in: nil, contentWorld: .page) as? Bool == true
    }

    func testSelectedListsUserFiltersTrustedSitesAndDisableAffectOnlyOwningProfile() async throws {
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/page"] = "<title>Filter page</title>"
        let profile = UUID(), other = UUID()
        let page = web(profile: profile), unrelated = web(profile: other), privatePage = web(profile: Profile.incognito.id)
        profiles.remove(Profile.incognito.id)
        for web in [page, unrelated, privatePage] { web.load(URLRequest(url: try server.url("/page"))) }
        try await compatibilityWait { [page, unrelated, privatePage].allSatisfy { !$0.isLoading && $0.title == "Filter page" } }
        let host = ExtensionHost.host(for: profile)
        host.backgroundCreationObserver = { [weak self] web, _ in self?.observedBackground = web }
        let installed = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(installed)
        let context = try XCTUnwrap(host.installed.first)
        defer { print("Synthetic MV2 bridge final state: \(host.entries.first?.compatibility ?? [])") }
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }
        let blocked = try await fetch(page, "/blocked-resource"), allowed = try await fetch(page, "/allowed-resource")
        let user = try await fetch(page, "/user-resource"), otherLoaded = try await fetch(unrelated, "/blocked-resource")
        let privateLoaded = try await fetch(privatePage, "/blocked-resource")
        XCTAssertFalse(blocked); XCTAssertTrue(allowed); XCTAssertFalse(user)
        XCTAssertTrue(otherLoaded); XCTAssertTrue(privateLoaded)

        let config = try XCTUnwrap(context.webViewConfiguration)
        let options = WKWebView(frame: .zero, configuration: config)
        views.append(options)
        options.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        try await compatibilityWait { !options.isLoading && options.title == "Bridge options" }
        _ = try await options.callAsyncJavaScript("await browser.storage.local.set({netWhitelist:['127.0.0.1']}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await compatibilityWait { try await self.fetch(page, "/blocked-resource") }
        _ = try await options.callAsyncJavaScript("await browser.storage.local.set({netWhitelist:[], selectedFilterLists:[]}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("0 supported rules") } == true }
        let deselected = try await fetch(page, "/user-resource")
        XCTAssertTrue(deselected, "An empty selection must not restore defaults or user filters")
        _ = try await options.callAsyncJavaScript("await browser.storage.local.set({selectedFilterLists:['fixture','user-filters']}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await compatibilityWait { try await !self.fetch(page, "/blocked-resource") }
        try host.disable(try XCTUnwrap(host.entries.first?.path))
        let disabled = try await fetch(page, "/blocked-resource")
        XCTAssertTrue(disabled, "Disable must detach the bridge from already-created pages")
    }

    func testActualUBlockPackageUsesItsOwnCacheDecoderAndUserFilters() async throws {
        guard let path = ProcessInfo.processInfo.environment["VANE_UBLOCK_FIXTURE_DIR"] else {
            throw XCTSkip("Opt-in actual uBlock package fixture; synthetic compatibility remains required")
        }
        let profile = UUID()
        profiles.insert(profile)
        let host = ExtensionHost.host(for: profile)
        host.backgroundCreationObserver = { [weak self] web, _ in self?.observedBackground = web }
        let installed = try await host.load(URL(fileURLWithPath: path), installing: true) { _ in true }
        XCTAssertTrue(installed)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(context.webExtension.displayName, "uBlock Origin")
        defer { print("Actual uBlock errors: \(context.errors.map { ($0 as NSError).userInfo })") }
        let background = try XCTUnwrap(observedBackground)
        let startupDeadline = ContinuousClock.now + .seconds(90)
        while try await background.evaluateJavaScript("self.µBlock?.readyToFilter === true && typeof self.µBlock?.supportStats?.allReadyAfter === 'string'") as? Bool != true {
            if ContinuousClock.now >= startupDeadline {
                XCTFail("Actual uBlock startup failed: \(context.errors.map { ($0 as NSError).userInfo })")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await background.callAsyncJavaScript("""
            const cache = (await import(browser.runtime.getURL('js/cachestorage.js'))).default;
            await cache.set({'cache/vane-fixture':'/vane-cached-ubo-resource'});
            await browser.storage.local.set({selectedFilterLists:['user-filters','vane-fixture'],
                'user-filters':'/vane-actual-ubo-resource', netWhitelist:[]});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let deadline = ContinuousClock.now + .seconds(90)
        while host.entries.first?.compatibility.contains(where: { $0.contains("Static filters active · 2 supported rules ·") }) != true {
            if ContinuousClock.now >= deadline {
                XCTFail("Actual uBlock bridge did not become active: \(host.entries.first?.compatibility ?? [])")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/page"] = "<title>Actual uBlock fixture</title>"
        let store = TabStore(profileID: profile, session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        store.window = window
        stores.append(store); windows.append(window)
        let page = store.newBlankTab().web
        views.append(page)
        page.load(URLRequest(url: try server.url("/page")))
        try await compatibilityWait { !page.isLoading && page.title == "Actual uBlock fixture" }
        let blocked = try await fetch(page, "/vane-actual-ubo-resource")
        let cachedBlocked = try await fetch(page, "/vane-cached-ubo-resource")
        XCTAssertFalse(blocked)
        XCTAssertFalse(cachedBlocked)
        XCTAssertFalse(context.errors.contains { error in
            let description = error.localizedDescription
            return description.contains("TypeError") || description.contains("requestIdleCallback") || description.contains("onUpdateAvailable")
                || description.contains("handlerBehaviorChanged")
        }, "Completed startup and page initialization must not retain these missing-API failures")
        host.remove(context)
        let removed = try await fetch(page, "/vane-actual-ubo-resource")
        XCTAssertTrue(removed)
    }

    func testRestrictedGrantsInvalidTrustAndHostRestoreCannotLeaveGlobalRulesAttached() async throws {
        let server = try CompatibilityServer()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/page"] = "<title>Lifecycle page</title>"
        let profile = UUID()
        let page = web(profile: profile)
        page.load(URLRequest(url: try server.url("/page")))
        try await compatibilityWait { !page.isLoading && page.title == "Lifecycle page" }
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }
        let initial = try await fetch(page, "/blocked-resource")
        XCTAssertFalse(initial)

        let restricted = try XCTUnwrap(WKWebExtension.MatchPattern(string: "*://*/*.jpg"))
        context.grantedPermissionMatchPatterns = [restricted: .distantFuture]
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("paused until all website access") } == true }
        let restrictedLoad = try await fetch(page, "/blocked-resource")
        XCTAssertTrue(restrictedLoad, "All hosts with a restricted path must not authorize global rules")
        let all = try XCTUnwrap(WKWebExtension.MatchPattern(string: "<all_urls>"))
        context.grantedPermissionMatchPatterns = [all: .distantFuture]
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }

        let config = try XCTUnwrap(context.webViewConfiguration)
        let options = WKWebView(frame: .zero, configuration: config)
        views.append(options)
        options.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        try await compatibilityWait { !options.isLoading && options.title == "Bridge options" }
        _ = try await options.callAsyncJavaScript("await browser.storage.local.set({netWhitelist:['/unsupported-regex/']}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("trusted-site directive cannot be translated") } == true }
        let invalidPolicy = try await fetch(page, "/blocked-resource")
        XCTAssertTrue(invalidPolicy, "Untranslatable trust must detach the old policy")
        _ = try await options.callAsyncJavaScript("await browser.storage.local.set({netWhitelist:[]}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }

        let identity = context.uniqueIdentifier
        options.stopLoading()
        ExtensionHost.forget(profile)
        let retired = try await fetch(page, "/blocked-resource")
        XCTAssertTrue(retired, "Forgetting a host must clear all its bridge attachments immediately")
        let restored = ExtensionHost.host(for: profile)
        try await compatibilityWait { restored.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }
        XCTAssertEqual(restored.installed.first?.uniqueIdentifier, identity)
        let afterRestore = try await fetch(page, "/blocked-resource")
        XCTAssertFalse(afterRestore)
        restored.remove(try XCTUnwrap(restored.installed.first))
        let removed = try await fetch(page, "/blocked-resource")
        XCTAssertTrue(removed)
    }

    func testDerivedNavigationTargetsUseTheActualOpenerTabIdentity() async throws {
        let profile = UUID()
        profiles.insert(profile)
        let host = ExtensionHost.host(for: profile)
        host.backgroundCreationObserver = { [weak self] web, _ in self?.observedBackground = web }
        _ = try await host.load(folder, installing: true) { _ in true }
        try await compatibilityWait { host.entries.first?.compatibility.contains { $0.contains("Static filters active") } == true }
        let background = try XCTUnwrap(observedBackground)
        let store = TabStore(profileID: profile, session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        store.window = window
        stores.append(store); windows.append(window)
        let parent = store.newBlankTab()
        let before = try await background.callAsyncJavaScript("return (await browser.tabs.query({})).map(tab => tab.id);", arguments: [:], in: nil, contentWorld: .page) as? [Int]
        XCTAssertEqual(before?.count, 1)
        let child = store.newTabBeside(parent.id, focus: false)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertTrue((host.adapter(for: child, in: store).parentTab(for: context) as? ExtTab)?.tab === parent)
        var target: [String: Any]?
        try await compatibilityWait {
            target = try await background.callAsyncJavaScript("return (await browser.storage.local.get('navigationTarget')).navigationTarget ?? null;", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            return target != nil
        }
        XCTAssertEqual(target?["sourceTabId"] as? Int, before?.first)
        let childInfo = try await background.callAsyncJavaScript("return await browser.tabs.get(id);", arguments: ["id": try XCTUnwrap(target?["tabId"] as? Int)], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(childInfo?["openerTabId"] as? Int, before?.first)
        XCTAssertNil(target?["sourceFrameId"], "Unknown source frames must not be fabricated")
        store.tabs.removeAll { $0 === parent }
        host.sync()
        XCTAssertNil(host.adapter(for: child, in: store).parentTab(for: context), "A closed opener cannot remain accessible")
        parent.tearDown()
    }

    func testChromeAlarmCallbacksPreserveTheRealNamedAlarm() async throws {
        let profile = UUID()
        profiles.insert(profile)
        let host = ExtensionHost.host(for: profile)
        host.backgroundCreationObserver = { [weak self] web, _ in self?.observedBackground = web }
        _ = try await host.load(folder, installing: true) { _ in true }
        let background = try XCTUnwrap(observedBackground)
        let result = try await background.callAsyncJavaScript("""
            const probe = async (api, name, callback) => {
                try {
                    const fn = api.alarms.create;
                    if (callback) fn.call(api.alarms, name, {delayInMinutes:5}, () => {});
                    else await fn.call(api.alarms, name, {delayInMinutes:5});
                    const alarm = await api.alarms.get(name);
                    await api.alarms.clear(name);
                    return {name, found:alarm?.name === name};
                } catch (error) { return {name, error:String(error)}; }
            };
            return [await probe(chrome,'chrome-callback',true), await probe(browser,'browser-callback',true),
                await probe(chrome,'chrome-promise',false), await probe(browser,'browser-promise',false)];
            """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        print("Native alarm conventions: \(String(describing: result))")
        XCTAssertEqual(result?.count, 4)
        for sample in result ?? [] { XCTAssertEqual(sample["found"] as? Bool, true, String(describing: sample)) }
    }
}
