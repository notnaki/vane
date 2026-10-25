import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionUserAgentTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles: Set<UUID> = []
    private var folder: URL!
    private var previousUserAgent: Any?
    #if DEBUG
    private var backgroundObservations: [ObjectIdentifier: BackgroundObservation] = [:]
    private var backgroundObservers: [BackgroundObserver] = []

    @MainActor private final class BackgroundObserver {
        weak var host: ExtensionHost?
        let previous: ((WKWebView, WKWebExtensionContext) -> Void)?

        init(host: ExtensionHost, previous: ((WKWebView, WKWebExtensionContext) -> Void)?) {
            self.host = host
            self.previous = previous
        }

        func restore() { host?.backgroundCreationObserver = previous }
    }

    private func observeBackgroundCreation(of host: ExtensionHost) throws {
        guard !backgroundObservers.contains(where: { $0.host === host }) else { return }
        let expectedStore = try XCTUnwrap(host.controller.configuration.defaultWebsiteDataStore)
        let previous = host.backgroundCreationObserver
        backgroundObservers.append(BackgroundObserver(host: host, previous: previous))
        // The observer stays active through the actual popup/worker reply, including
        // WebKit background recreation. Teardown restores every still-live host.
        host.backgroundCreationObserver = { [weak self] web, context in
            previous?(web, context)
            guard let self else { return }
            let identity = ObjectIdentifier(context)
            let observation: BackgroundObservation
            if let existing = self.backgroundObservations[identity], existing.context === context {
                observation = existing
            } else {
                observation = BackgroundObservation()
            }
            observation.capture(web, context: context, expectedStore: expectedStore)
            self.backgroundObservations[identity] = observation
        }
    }

    // A snapshot never keeps the background page, its context, or its host alive.
    @MainActor private final class BackgroundObservation {
        weak var web: WKWebView?
        weak var context: WKWebExtensionContext?
        var count = 0
        private weak var initialWeb: WKWebView?
        var matchesInitialWeb = true
        var customUserAgent: String?
        var poolMatchesApplication = false
        var storeMatchesProfile = false
        var expectedNamed = false
        var actualNamed = false
        var identifiersMatch = false
        var expectedPersistent = false
        var actualPersistent = false

        func capture(_ web: WKWebView, context: WKWebExtensionContext, expectedStore: WKWebsiteDataStore) {
            if count == 0 { initialWeb = web }
            matchesInitialWeb = initialWeb === web
            self.web = web
            self.context = context
            count += 1
            customUserAgent = web.customUserAgent
            let configuration = web.configuration
            poolMatchesApplication = configuration.processPool === WebKitStartup.extensionProcessPool
            let actualStore = configuration.websiteDataStore
            storeMatchesProfile = actualStore === expectedStore
            expectedNamed = expectedStore.identifier != nil
            actualNamed = actualStore.identifier != nil
            identifiersMatch = actualStore.identifier == expectedStore.identifier
            expectedPersistent = expectedStore.isPersistent
            actualPersistent = actualStore.isPersistent
        }
    }
    #endif

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        previousUserAgent = UserDefaults.vane.object(forKey: "userAgent")
        UserDefaults.vane.removeObject(forKey: "userAgent")
        profile = UUID()
        ownedProfiles.insert(profile)
        folder = Store.directory.appendingPathComponent("user-agent-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        #if DEBUG
        for observer in backgroundObservers { observer.restore() }
        backgroundObservers.removeAll()
        #endif
        func removeInstallations() {
            let host = ExtensionHost.host(for: profile)
            for context in host.installed { host.remove(context) }
            ExtensionHost.forget(profile)
        }
        removeInstallations()
        #if DEBUG
        backgroundObservations.removeAll()
        #endif
        UserDefaults.vane.set(previousUserAgent, forKey: "userAgent")
        Settings.apply()
        try? FileManager.default.removeItem(at: folder)
        let released = ownedProfiles
        ownedProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    private func install(version: Int, in targetProfile: UUID? = nil) async throws -> WKWebExtensionContext {
        #if DEBUG
        backgroundObservations.removeAll()
        #endif
        var manifest: [String: Any] = ["manifest_version": version, "name": "User Agent Fixture",
            "version": "1.0", "permissions": ["storage"]]
        manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "popup.html"]
        manifest["background"] = version == 2
            ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
            : ["service_worker": "background.js"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("""
            const startupUserAgent = navigator.userAgent;
            browser.runtime.onMessage.addListener(async () => ({startup: startupUserAgent, current: navigator.userAgent}));
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<title>UA fixture</title><script src='popup.js'></script>".utf8)
            .write(to: folder.appendingPathComponent("popup.html"))
        try Data("""
            window.startupUserAgent = navigator.userAgent;
            browser.runtime.sendMessage('identity').then(reply => { window.backgroundIdentity = reply; });
            """.utf8).write(to: folder.appendingPathComponent("popup.js"))
        let host = ExtensionHost.host(for: targetProfile ?? profile)
        #if DEBUG
        try observeBackgroundCreation(of: host)
        #endif
        let accepted = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        #if DEBUG
        if backgroundObservations[ObjectIdentifier(context)]?.context !== context {
            let missing = BackgroundObservation()
            missing.context = context
            backgroundObservations[ObjectIdentifier(context)] = missing
        }
        if let observation = backgroundObservations[ObjectIdentifier(context)], observation.context === context {
            XCTAssertGreaterThan(observation.count, 0, "Installing a background must observe its real view")
            XCTAssertTrue(observation.poolMatchesApplication, "Background must use the application's extension pool")
            XCTAssertTrue(observation.identifiersMatch, "Background must use the selected profile's store identifier")
            XCTAssertEqual(observation.actualPersistent, observation.expectedPersistent,
                           "Background must retain the selected profile's persistence")
        }
        #endif
        return context
    }

    private func popup(_ context: WKWebExtensionContext) async throws -> (WKWebExtension.Action, WKWebView) {
        let action = try XCTUnwrap(context.action(for: nil))
        let web = try XCTUnwrap(action.popupWebView)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !web.isLoading {
                let ready = (try? await web.evaluateJavaScript("typeof window.backgroundIdentity === 'object'")) as? Bool == true
                if ready { return (action, web) }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ExtensionUserAgentTests.PopupTimeout", code: 1)
    }

    private func assertIdentity(in web: WKWebView, context: WKWebExtensionContext, expected: String, startup: String? = nil,
                                scenario: String = "Extension", expectedStore: WKWebsiteDataStore? = nil,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let configuration = web.configuration
        XCTAssertTrue(configuration.processPool === WebKitStartup.extensionProcessPool,
                      "\(scenario): popup must use the application's extension pool", file: file, line: line)
        assertStore(configuration.websiteDataStore,
                    matches: expectedStore ?? ExtensionHost.host(for: profile).controller.configuration.defaultWebsiteDataStore,
                    scenario: "\(scenario) popup", file: file, line: line)
        let identity = try await web.evaluateJavaScript("({popup:window.startupUserAgent, background:window.backgroundIdentity.startup, current:window.backgroundIdentity.current})") as? [String: String]
        reportCallbackObservation(for: context, scenario: scenario)
        XCTAssertEqual(identity?["popup"], expected, "\(scenario): Popup startup", file: file, line: line)
        XCTAssertEqual(identity?["background"], startup ?? expected, "\(scenario): Background startup", file: file, line: line)
        XCTAssertEqual(identity?["current"], expected, "\(scenario): Background current", file: file, line: line)
        if identity?["background"] != (startup ?? expected) || identity?["current"] != expected {
            await reportBackgroundObservation(for: context, scenario: scenario)
        }
    }

    private func reportCallbackObservation(for context: WKWebExtensionContext, scenario: String) {
        #if DEBUG
        guard let observation = backgroundObservations[ObjectIdentifier(context)], observation.context === context else {
            print("UA fixture \(scenario): no matching live context observation")
            return
        }
        print("UA fixture \(scenario): callbackCount=\(observation.count), landingLive=\(observation.web != nil), matchesInitialLanding=\(observation.matchesInitialWeb), customUA=\(observation.customUserAgent ?? "<nil>"), applicationPool=\(observation.poolMatchesApplication), profileStore=\(observation.storeMatchesProfile), expectedNamed=\(observation.expectedNamed), actualNamed=\(observation.actualNamed), identifiersMatch=\(observation.identifiersMatch), expectedPersistent=\(observation.expectedPersistent), actualPersistent=\(observation.actualPersistent)")
        #endif
    }

    private func reportBackgroundObservation(for context: WKWebExtensionContext, scenario: String) async {
        #if DEBUG
        guard let observation = backgroundObservations[ObjectIdentifier(context)], observation.context === context else { return }
        guard let landing = observation.web else {
            print("UA fixture \(scenario): existing landing view released")
            return
        }
        // Observe the existing landing document only after the worker has replied.
        // Never fetch a context/popup getter or create/load another page for diagnostics.
        var result: [String: String]?
        do {
            try await ExtensionBackgroundStartup.wait(timeout: .seconds(2), start: { completion in
                landing.callAsyncJavaScript("return {ua:navigator.userAgent, href:location.href}", arguments: [:], in: nil, in: .page) { reply in
                    do { result = try reply.get() as? [String: String]; completion(nil) }
                    catch { completion(error) }
                }
            }, check: {})
            let href = result?["href"].flatMap(URL.init(string:))
            // This is a synthetic extension. Print its own URL only, never another page.
            let fixtureURL = href?.scheme == context.baseURL.scheme && href?.host == context.baseURL.host
                ? href?.absoluteString ?? "<nil>" : "<outside fixture>"
            print("UA fixture \(scenario): landingUA=\(result?["ua"] ?? "<nil>"), landingURL=\(fixtureURL), latestLandingAtRead=\(observation.web === landing), callbackCountAfterRead=\(observation.count)")
        } catch {
            print("UA fixture \(scenario): landing observation unavailable (\(type(of: error)))")
        }
        #endif
    }


    private func assertStore(_ actual: WKWebsiteDataStore, matches expected: WKWebsiteDataStore,
                             scenario: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual.identifier == expected.identifier, "\(scenario): store identifier", file: file, line: line)
        XCTAssertEqual(actual.isPersistent, expected.isPersistent, "\(scenario): persistence", file: file, line: line)
        // Nil identifiers alone cannot distinguish different ephemeral stores.
        if !expected.isPersistent {
            XCTAssertTrue(actual === expected, "\(scenario): private session", file: file, line: line)
        }
    }

    func testBrowserAndExtensionPoolsShareOwnershipWithoutSharingProfileStorage() async throws {
        let otherProfile = UUID()
        ownedProfiles.insert(otherProfile)
        defer { ExtensionHost.forget(otherProfile) }
        let browser = Tab.configuration(profileID: profile, blocking: false)
        let otherBrowser = Tab.configuration(profileID: otherProfile, blocking: false)
        let privateBrowser = Tab.configuration(isPrivate: true, blocking: false)
        let extensions = ExtensionHost.host(for: profile).controller
        let otherExtensions = ExtensionHost.host(for: otherProfile).controller
        let privateExtensions = ExtensionHost.host(for: Profile.incognito.id).controller
        let seed = try XCTUnwrap(extensions.configuration.webViewConfiguration)
        let otherSeed = try XCTUnwrap(otherExtensions.configuration.webViewConfiguration)
        let privateSeed = try XCTUnwrap(privateExtensions.configuration.webViewConfiguration)

        XCTAssertTrue(browser.processPool === WebKitStartup.processPool)
        for configuration in [otherBrowser, privateBrowser] {
            XCTAssertTrue(configuration.processPool === browser.processPool,
                          "Browser pages must retain the application's browser pool")
        }
        XCTAssertFalse(WebKitStartup.extensionProcessPool === browser.processPool)
        for configuration in [seed, otherSeed, privateSeed] {
            XCTAssertTrue(configuration.processPool === WebKitStartup.extensionProcessPool,
                          "WebKit-owned extension pages must retain the application's extension pool")
        }
        XCTAssertFalse(extensions === otherExtensions)
        XCTAssertFalse(extensions === privateExtensions)
        XCTAssertFalse(otherExtensions === privateExtensions)
        XCTAssertTrue(browser.websiteDataStore === ProfileManager.dataStore(for: profile))
        XCTAssertTrue(otherBrowser.websiteDataStore === ProfileManager.dataStore(for: otherProfile))
        XCTAssertFalse(browser.websiteDataStore === otherBrowser.websiteDataStore)
        XCTAssertTrue(extensions.configuration.defaultWebsiteDataStore === browser.websiteDataStore)
        XCTAssertTrue(otherExtensions.configuration.defaultWebsiteDataStore === otherBrowser.websiteDataStore)
        XCTAssertTrue(browser.websiteDataStore.isPersistent)
        XCTAssertTrue(otherBrowser.websiteDataStore.isPersistent)
        XCTAssertFalse(privateBrowser.websiteDataStore.isPersistent)
        XCTAssertFalse(privateExtensions.configuration.defaultWebsiteDataStore.isPersistent)
        XCTAssertFalse(privateBrowser.websiteDataStore === browser.websiteDataStore)
        XCTAssertFalse(privateExtensions.configuration.defaultWebsiteDataStore === browser.websiteDataStore)
        XCTAssertNotNil(browser.websiteDataStore.identifier)
        XCTAssertNotNil(otherBrowser.websiteDataStore.identifier)
        XCTAssertFalse(browser.websiteDataStore.identifier == otherBrowser.websiteDataStore.identifier)
        assertStore(seed.websiteDataStore, matches: browser.websiteDataStore, scenario: "Normal seed")
        assertStore(otherSeed.websiteDataStore, matches: otherBrowser.websiteDataStore, scenario: "Other profile seed")
        assertStore(privateSeed.websiteDataStore, matches: privateExtensions.configuration.defaultWebsiteDataStore,
                    scenario: "Private seed")
        XCTAssertNil(privateSeed.websiteDataStore.identifier)
        do {
            _ = try await ExtensionHost.host(for: Profile.incognito.id).load(folder, installing: true) { _ in true }
            XCTFail("Private hosts must continue rejecting extension installation")
        } catch is CancellationError { }
        XCTAssertTrue(privateExtensions.extensionContexts.isEmpty)

        ExtensionHost.forget(otherProfile)
        let replacement = ExtensionHost.host(for: otherProfile).controller
        XCTAssertFalse(replacement === otherExtensions)
        XCTAssertTrue(replacement.configuration.webViewConfiguration.processPool === WebKitStartup.extensionProcessPool)
        XCTAssertTrue(replacement.configuration.defaultWebsiteDataStore === otherBrowser.websiteDataStore)
        assertStore(replacement.configuration.webViewConfiguration.websiteDataStore,
                    matches: otherBrowser.websiteDataStore, scenario: "Recreated other profile seed")
        let context = try await install(version: 2, in: otherProfile)
        let (action, web) = try await popup(context)
        try await assertIdentity(in: web, context: context, expected: safariUA,
                                 scenario: "Other profile", expectedStore: otherBrowser.websiteDataStore)
        action.closePopup()
        ExtensionHost.host(for: otherProfile).remove(context)
    }

    @MainActor private final class ReleasedInstallation {
        weak var host: ExtensionHost?
        weak var controller: WKWebExtensionController?
        weak var context: WKWebExtensionContext?

        init(host: ExtensionHost, context: WKWebExtensionContext) {
            self.host = host
            controller = host.controller
            self.context = context
        }

        var isReleased: Bool { host == nil && controller == nil && context == nil }
    }

    // Keep strong fixture references inside this async scope. The caller observes only
    // weak references after unload, so a shared pool cannot hide a retained old host.
    private func installAndForget() async throws -> ReleasedInstallation {
        let context = try await install(version: 2)
        let host = ExtensionHost.host(for: profile)
        let released = ReleasedInstallation(host: host, context: context)
        host.remove(context)
        XCTAssertFalse(context.isLoaded)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        ExtensionHost.forget(profile)
        return released
    }

    func testRepeatedBackgroundTeardownReleasesRetiredHostsControllersAndContexts() async throws {
        for _ in 0..<3 {
            let released = try await installAndForget()
            let deadline = ContinuousClock.now + .seconds(10)
            while !released.isReleased && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNil(released.host)
            XCTAssertNil(released.controller)
            XCTAssertNil(released.context)
        }
    }

    func testDefaultSafariIdentityReachesBackgroundAndPopupBeforeTheirScriptsRun() async throws {
        for version in [2, 3] {
            let context = try await install(version: version)
            let (action, web) = try await popup(context)
            try await assertIdentity(in: web, context: context, expected: safariUA, scenario: "Manifest v\(version)")
            let ua = try await web.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(ua?.components(separatedBy: " Safari/").count, 2, "Safari must appear once")
            XCTAssertEqual(ua?.components(separatedBy: " Version/").count, 2, "Version must appear once")
            action.closePopup()
            ExtensionHost.host(for: profile).remove(context)
        }
    }

    func testServiceWorkerIdentityFollowsSelectionWhenSharedPoolIsReused() async throws {
        let host = ExtensionHost.host(for: profile)
        let controller = host.controller
        let custom = "Vane Prior Worker Identity/1.0 (no Safari token)"
        for (identity, stage) in [(custom, "Manifest v3 custom worker"),
                                  (safariUA, "Manifest v3 Safari worker after custom worker")] {
            Settings.userAgent = identity
            let context = try await install(version: 3)
            let (action, web) = try await popup(context)
            try await assertIdentity(in: web, context: context, expected: identity, scenario: stage)
            XCTAssertTrue(host.controller === controller, "Changing UA must retain the profile's controller")
            action.closePopup()
            host.remove(context)
        }
    }

    func testDevelopChangeUpdatesLiveBackgroundAndRecreatedPopupWithoutChangingAccess() async throws {
        let context = try await install(version: 2)
        let host = ExtensionHost.host(for: profile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 440, y: 250, width: 28, height: 28))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
        }

        host.run(context, for: nil, from: anchor)
        let (action, web) = try await popup(context)
        try await waitForPresentation(action)
        try await assertIdentity(in: web, context: context, expected: safariUA)
        let controller = host.controller
        let granted = context.grantedPermissions
        let sites = context.grantedPermissionMatchPatterns
        let custom = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.0; rv:135.0) Gecko/20100101 Firefox/135.0"
        Settings.userAgent = custom
        let live = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(live, custom)
        Settings.userAgent = safariUA
        let defaultLive = try await web.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(defaultLive, safariUA)
        Settings.userAgent = custom
        try await closePresentedPopup(action)
        let (recreatedAction, recreated) = try await popup(context)
        XCTAssertFalse(recreated === web, "Recreation must inspect a fresh popup, not cached startup values")
        try await assertIdentity(in: recreated, context: context, expected: custom, startup: safariUA)
        XCTAssertTrue(ExtensionHost.host(for: profile).controller === controller)
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.grantedPermissions, granted)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites)
        recreatedAction.closePopup()
    }

    private func waitForPresentation(_ action: WKWebExtension.Action) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while action.popupPopover?.isShown != true {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ExtensionUserAgentTests.PresentationTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func closePresentedPopup(_ action: WKWebExtension.Action) async throws {
        let popover = try XCTUnwrap(action.popupPopover)
        XCTAssertTrue(popover.isShown)
        let closed = XCTNSNotificationExpectation(name: NSPopover.didCloseNotification, object: popover)
        action.closePopup()
        await fulfillment(of: [closed], timeout: 5)
    }

    func testExplicitCustomIdentitySurvivesHostRestoration() async throws {
        let custom = "Vane Identity Fixture/1.0 (no Safari token)"
        Settings.userAgent = custom
        let context = try await install(version: 2)
        let identity = context.uniqueIdentifier
        let (action, web) = try await popup(context)
        try await assertIdentity(in: web, context: context, expected: custom)
        action.closePopup()
        ExtensionHost.forget(profile)
        let restoredHost = ExtensionHost.host(for: profile)
        #if DEBUG
        try observeBackgroundCreation(of: restoredHost)
        #endif
        let deadline = ContinuousClock.now + .seconds(10)
        while restoredHost.installed.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try XCTUnwrap(restoredHost.installed.first)
        XCTAssertEqual(restored.uniqueIdentifier, identity)
        let (restoredAction, restoredWeb) = try await popup(restored)
        try await assertIdentity(in: restoredWeb, context: restored, expected: custom)
        restoredAction.closePopup()
    }
}
