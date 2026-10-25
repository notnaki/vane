import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionUserAgentTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles: Set<UUID> = []
    private var folder: URL!
    private var previousUserAgent: Any?
    // Runtime identity survives host restoration; the accepted script generation does too.
    private var generations: [String: String] = [:]
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
            self.backgroundObservations[identity] = BackgroundObservation(web, context: context, expectedStore: expectedStore)
        }
    }

    // Inspect only the real callback view. The snapshot retains no WebKit object.
    @MainActor private final class BackgroundObservation {
        weak var context: WKWebExtensionContext?
        weak var web: WKWebView?
        let poolMatchesApplication: Bool
        let identifiersMatch: Bool
        let persistenceMatches: Bool
        let selectedIdentity: String
        let appliedIdentity: String?

        init(_ web: WKWebView, context: WKWebExtensionContext, expectedStore: WKWebsiteDataStore) {
            self.context = context
            self.web = web
            let configuration = web.configuration
            poolMatchesApplication = configuration.processPool === WebKitStartup.extensionProcessPool
            let actualStore = configuration.websiteDataStore
            identifiersMatch = actualStore.identifier == expectedStore.identifier
            persistenceMatches = actualStore.isPersistent == expectedStore.isPersistent
            selectedIdentity = Settings.userAgent
            appliedIdentity = web.customUserAgent
        }
    }

    private func assertBackgroundOwnership(for context: WKWebExtensionContext,
                                           file: StaticString = #filePath, line: UInt = #line) {
        guard let observation = backgroundObservations[ObjectIdentifier(context)], observation.context === context else {
            XCTFail("Background ownership must be observed for this actual context", file: file, line: line)
            return
        }
        XCTAssertTrue(observation.poolMatchesApplication, "Background must use the application's extension pool", file: file, line: line)
        XCTAssertTrue(observation.identifiersMatch, "Background must use the selected profile's store identifier", file: file, line: line)
        XCTAssertTrue(observation.persistenceMatches, "Background must retain the selected profile's persistence", file: file, line: line)
        XCTAssertEqual(observation.appliedIdentity, observation.selectedIdentity,
                       "The actual background callback must apply the identity selected when it ran", file: file, line: line)
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
        generations.removeAll()
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

    func testExtensionFixtureCompletesAppKitLaunchAcrossIdle() async throws {
        func assertLaunched(file: StaticString = #filePath, line: UInt = #line) {
            let app = NSApplication.shared
            let running = NSRunningApplication.current
            // Background extensions do not require activation or a visible window.
            // Report those states only to distinguish launch from presentation.
            XCTAssertTrue(running.isFinishedLaunching,
                          "The extension fixture must complete AppKit launch before creating controllers; " +
                          "appActive=\(app.isActive), runningActive=\(running.isActive), appRunning=\(app.isRunning), " +
                          "visibleWindow=\(app.windows.contains { $0.isVisible }), keyWindow=\(app.keyWindow != nil)",
                          file: file, line: line)
        }
        assertLaunched()
        try await Task.sleep(for: .milliseconds(100))
        assertLaunched()
    }

    private func install(version: Int, in targetProfile: UUID? = nil) async throws -> WKWebExtensionContext {
        let generation = UUID().uuidString
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
            const generation = '\(generation)';
            browser.runtime.onMessage.addListener(async () => ({startup: startupUserAgent, current: navigator.userAgent,
                generation, runtime: browser.runtime.id, host: location.host}));
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<title>UA fixture</title><script src='popup.js'></script>".utf8)
            .write(to: folder.appendingPathComponent("popup.html"))
        try Data("""
            window.startupUserAgent = navigator.userAgent;
            window.generation = '\(generation)';
            window.startupRuntime = browser.runtime.id;
            window.startupHost = location.host;
            browser.runtime.sendMessage('identity').then(reply => { window.backgroundIdentity = reply; });
            """.utf8).write(to: folder.appendingPathComponent("popup.js"))
        let host = ExtensionHost.host(for: targetProfile ?? profile)
        #if DEBUG
        try observeBackgroundCreation(of: host)
        #endif
        let accepted = try await host.load(folder, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        generations[context.uniqueIdentifier] = generation
        #if DEBUG
        assertBackgroundOwnership(for: context)
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
        let generation = try XCTUnwrap(generations[context.uniqueIdentifier],
                                       "\(scenario): the accepted script generation must be known", file: file, line: line)
        let identity = try await web.evaluateJavaScript("""
            ({popup:window.startupUserAgent, background:window.backgroundIdentity.startup, current:window.backgroundIdentity.current,
              popupGeneration:window.generation, backgroundGeneration:window.backgroundIdentity.generation,
              popupRuntime:window.startupRuntime, backgroundRuntime:window.backgroundIdentity.runtime,
              popupHost:window.startupHost, backgroundHost:window.backgroundIdentity.host})
            """) as? [String: String]
        #if DEBUG
        assertBackgroundOwnership(for: context, file: file, line: line)
        #endif
        XCTAssertEqual(identity?["popupGeneration"], generation, "\(scenario): actual popup generation", file: file, line: line)
        XCTAssertEqual(identity?["backgroundGeneration"], generation, "\(scenario): actual background generation", file: file, line: line)
        XCTAssertEqual(identity?["popupRuntime"], context.uniqueIdentifier, "\(scenario): actual popup runtime", file: file, line: line)
        XCTAssertEqual(identity?["backgroundRuntime"], context.uniqueIdentifier, "\(scenario): actual background runtime", file: file, line: line)
        XCTAssertEqual(identity?["popupHost"], context.baseURL.host, "\(scenario): actual popup origin", file: file, line: line)
        XCTAssertEqual(identity?["backgroundHost"], context.baseURL.host, "\(scenario): actual background origin", file: file, line: line)
        XCTAssertEqual(identity?["popup"], expected, "\(scenario): Popup startup", file: file, line: line)
        XCTAssertEqual(identity?["background"], startup ?? expected, "\(scenario): Background startup", file: file, line: line)
        XCTAssertEqual(identity?["current"], expected, "\(scenario): Background current", file: file, line: line)
        if WebKitComparatorAttestation.isRequested {
            #if DEBUG
            guard let observation = backgroundObservations[ObjectIdentifier(context)],
                  observation.context === context, let background = observation.web else {
                throw WebKitComparatorAttestation.unavailable("current user-agent fixture background is unavailable")
            }
            try WebKitComparatorAttestation.attestFixture(self, scope: .userAgentIdentity,
                views: [web, background], store: configuration.websiteDataStore)
            #else
            throw WebKitComparatorAttestation.unavailable("user-agent fixture background observation is unavailable")
            #endif
        }
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
