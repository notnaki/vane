import AppKit
import CryptoKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionUserAgentTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles: Set<UUID> = []
    private var folder: URL!
    private var previousUserAgent: Any?
    private var forcedBackgroundUserAgent: String?
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
            if let forced = self.forcedBackgroundUserAgent { web.customUserAgent = forced }
        }
    }

    // Inspect only the real callback view. The snapshot retains no WebKit object.
    @MainActor private final class BackgroundObservation {
        weak var context: WKWebExtensionContext?
        let poolMatchesApplication: Bool
        let identifiersMatch: Bool
        let persistenceMatches: Bool

        init(_ web: WKWebView, context: WKWebExtensionContext, expectedStore: WKWebsiteDataStore) {
            self.context = context
            let configuration = web.configuration
            poolMatchesApplication = configuration.processPool === WebKitStartup.extensionProcessPool
            let actualStore = configuration.websiteDataStore
            identifiersMatch = actualStore.identifier == expectedStore.identifier
            persistenceMatches = actualStore.isPersistent == expectedStore.isPersistent
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

    private func install(version: Int, in targetProfile: UUID? = nil, module: Bool = false, generated: Bool = false, workerPath: String = "background.js", hashbang: Bool = false, strict: Bool = false, reusePage: Bool = false, cycle: Bool = false, importsDependency: Bool = false) async throws -> WKWebExtensionContext {
        #if DEBUG
        backgroundObservations.removeAll()
        #endif
        var manifest: [String: Any] = ["manifest_version": version, "name": "User Agent Fixture",
            "version": "1.0", "permissions": ["storage"], "optional_permissions": ["alarms", "notifications"]]
        manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "popup.html"]
        manifest["background"] = version == 2
            ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
            : (module ? ["service_worker": workerPath, "type": "module"] : ["service_worker": workerPath])
        if generated {
            var background: [String: Any] = ["scripts": [workerPath], "preferred_environment": ["service_worker"]]
            if module { background["type"] = "module" }
            manifest["background"] = background
        }
        if reusePage { manifest["options_ui"] = ["page": "reused.html"] }
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let workerURL = folder.appendingPathComponent(workerPath)
        try FileManager.default.createDirectory(at: workerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dependencySource = (module && cycle ? "import './\(workerURL.lastPathComponent)';\n" : "") + "globalThis.dependencyStartupIdentity = navigator.userAgent;" + (module ? " globalThis.dependencyURL = import.meta.url;" : "")
        let dependencyDirectory = generated && !module && importsDependency ? folder! : workerURL.deletingLastPathComponent()
        try Data(dependencySource.utf8).write(to: dependencyDirectory.appendingPathComponent("dependency.js"))
        try Data("<title>Reused worker source</title><script \(module ? "type='module'" : "") src='/\(workerPath)'></script>".utf8)
            .write(to: folder.appendingPathComponent("reused.html"))
        let dependency = (hashbang ? "#!/usr/bin/env javascript\n" : "") + (strict ? "'use strict';\n" : "") + (module ? "import './dependency.js';\n" : importsDependency ? "importScripts('./dependency.js');\n" : "")
        let cycleCounter = cycle ? "globalThis.vendorEntryExecutions = (globalThis.vendorEntryExecutions ?? 0) + 1;\n" : ""
        try Data((dependency + cycleCounter + """
            const startupUserAgent = globalThis.dependencyStartupIdentity ?? navigator.userAgent;
            globalThis.entryStartupIdentity = startupUserAgent;
            const birthNonce = crypto.randomUUID();
            const sourceURL = \(module ? "import.meta.url" : "self.location.href");
            const strictAtStartup = (function() { return this === undefined; })();
            browser.runtime.onMessage.addListener(async () => ({startup: startupUserAgent, current: navigator.userAgent,
              nonce: birthNonce, saved: (await chrome.storage.local.get('workerSaved')).workerSaved ?? 'missing',
              aliases: String(chrome.runtime.id === browser.runtime.id), strict: String(strictAtStartup),
              url: sourceURL, workerURL: self.location.href, entryRuns: String(globalThis.vendorEntryExecutions ?? 1), revision: globalThis.packageRevision ?? 'initial', cache: self.registration?.updateViaCache ?? 'none', scope: self.registration?.scope ?? 'none', activeURL: self.registration?.active?.scriptURL ?? 'none', dependencyURL: globalThis.dependencyURL ?? 'none'}));
            """).utf8).write(to: workerURL)
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
        assertBackgroundOwnership(for: context)
        #endif
        return context
    }

    private func popup(_ context: WKWebExtensionContext, for tab: Tab? = nil) async throws -> (WKWebExtension.Action, WKWebView) {
        let action = try XCTUnwrap(ExtensionHost.host(for: profile).action(context, for: tab))
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
                                checkingBackgroundIdentity: Bool = true,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let configuration = web.configuration
        XCTAssertTrue(configuration.processPool === WebKitStartup.extensionProcessPool,
                      "\(scenario): popup must use the application's extension pool", file: file, line: line)
        assertStore(configuration.websiteDataStore,
                    matches: expectedStore ?? ExtensionHost.host(for: profile).controller.configuration.defaultWebsiteDataStore,
                    scenario: "\(scenario) popup", file: file, line: line)
        let identity = try await web.evaluateJavaScript("({popup:window.startupUserAgent, background:window.backgroundIdentity.startup, current:window.backgroundIdentity.current})") as? [String: String]
        #if DEBUG
        assertBackgroundOwnership(for: context, file: file, line: line)
        #endif
        XCTAssertEqual(identity?["popup"], expected, "\(scenario): Popup startup", file: file, line: line)
        if checkingBackgroundIdentity {
            XCTAssertEqual(identity?["background"], startup ?? expected, "\(scenario): Background startup", file: file, line: line)
            XCTAssertEqual(identity?["current"], expected, "\(scenario): Background current", file: file, line: line)
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

    func testDefaultSafariIdentityReachesPopupAndManifestTwoBackgroundBeforeScriptsRun() async throws {
        for version in [2, 3] {
            let context = try await install(version: version)
            let (action, web) = try await popup(context)
            try await assertIdentity(in: web, context: context, expected: safariUA, scenario: "Manifest v\(version)",
                                     checkingBackgroundIdentity: version == 2)
            let ua = try await web.evaluateJavaScript("navigator.userAgent") as? String
            XCTAssertEqual(ua?.components(separatedBy: " Safari/").count, 2, "Safari must appear once")
            XCTAssertEqual(ua?.components(separatedBy: " Version/").count, 2, "Version must appear once")
            action.closePopup()
            ExtensionHost.host(for: profile).remove(context)
        }
    }

    func testServiceWorkerPopupIdentityAndOwnershipFollowSelectionWhenSharedPoolIsReused() async throws {
        let host = ExtensionHost.host(for: profile)
        let controller = host.controller
        let custom = "Vane Prior Worker Identity/1.0 (no Safari token)"
        for (identity, stage) in [(custom, "Manifest v3 custom worker"),
                                  (safariUA, "Manifest v3 Safari worker after custom worker")] {
            Settings.userAgent = identity
            let context = try await install(version: 3)
            let (action, web) = try await popup(context)
            try await assertIdentity(in: web, context: context, expected: identity, scenario: stage,
                                     checkingBackgroundIdentity: false)
            XCTAssertTrue(host.controller === controller, "Changing UA must retain the profile's controller")
            action.closePopup()
            host.remove(context)
        }
    }

    func testClassicWorkerNavigatorIdentityAtFirstInstruction() async throws {
        Settings.userAgent = "Vane MV3 Navigator Probe/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: Settings.userAgent)
        let aliases = try await web.evaluateJavaScript("window.backgroundIdentity.aliases") as? String
        XCTAssertEqual(aliases, "true", "WebKit must retain its real chrome/browser API aliases")
    }

    func testModuleWorkerNavigatorIdentityInFirstDependency() async throws {
        Settings.userAgent = "Vane MV3 Module Probe/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        // A module dependency executes before the entry body. Capture in that
        // dependency, before messaging or any later diagnostic can repair it.
        let context = try await install(version: 3, module: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: Settings.userAgent)
    }

    func testNestedClassicImportsRetainTheWorkerBaseDirectory() async throws {
        Settings.userAgent = "Vane Nested Classic/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, workerPath: "nested/background.js", hashbang: true, strict: true, importsDependency: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Nested Classic/1.0")
        let identity = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        XCTAssertEqual(identity?["strict"], "true")
        let creationURL = try XCTUnwrap(identity?["workerURL"].flatMap(URL.init(string:)))
        XCTAssertEqual(creationURL.deletingLastPathComponent().path, "/nested")
    }

    func testGeneratedClassicImportsRetainTheVirtualWorkerRoot() async throws {
        Settings.userAgent = "Vane Generated Nested Classic/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, generated: true, workerPath: "nested/background.js", importsDependency: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Generated Nested Classic/1.0")
        let identity = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        let creationURL = try XCTUnwrap(identity?["workerURL"].flatMap(URL.init(string:)))
        XCTAssertEqual(creationURL.deletingLastPathComponent(), context.baseURL)
    }

    func testModuleCycleUsesSingleCanonicalVendorEntry() async throws {
        Settings.userAgent = "Vane Cyclic Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, module: true, cycle: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Cyclic Worker/1.0")
        let identity = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        XCTAssertEqual(identity?["entryRuns"], "1", "A module back-reference must not evaluate a query-distinct copy of the vendor entry")
        XCTAssertEqual(identity?["url"], context.baseURL.appendingPathComponent("background.js").absoluteString)
    }

    func testModuleResourceUpdateRefreshesCanonicalDependency() async throws {
        try await checkCanonicalDependencyUpdate(version: "1.0")
    }

    func testModuleVersionBumpedResourceUpdateRefreshesCanonicalDependency() async throws {
        try await checkCanonicalDependencyUpdate(version: "2.0")
    }

    private func checkCanonicalDependencyUpdate(version: String) async throws {
        Settings.userAgent = "Vane Updated Module/1.0"
        print("MV3_CACHE_POLICY alwaysRevalidatesExtensionResources=\(WebKitStartup.revalidatesExtensionResources)")
        XCTAssertTrue(WebKitStartup.revalidatesExtensionResources)
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let before = try await install(version: 3, module: true)
        let (action, web) = try await popup(before)
        let original = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        XCTAssertEqual(original?["revision"], "initial")
        action.closePopup()
        let dependency = folder.appendingPathComponent("dependency.js")
        let originalBytes = try String(contentsOf: dependency, encoding: .utf8)
        try Data((originalBytes + "\nglobalThis.packageRevision = 'updated';").utf8).write(to: dependency)
        if version != "1.0" {
            let manifestURL = folder.appendingPathComponent("manifest.json")
            var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            manifest["version"] = version
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        }
        let host = ExtensionHost.host(for: profile)
        let accepted = try await host.load(folder, installing: false, replacing: true) { _ in true }
        XCTAssertTrue(accepted)
        let after = try XCTUnwrap(host.installed.first)
        let (newAction, newWeb) = try await popup(after)
        defer { newAction.closePopup() }
        try await assertIdentity(in: newWeb, context: after, expected: "Vane Updated Module/1.0")
        let updated = try await newWeb.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        XCTAssertEqual(updated?["revision"], "updated", "A new wrapper must not reuse cached canonical vendor imports")
        let codeStore = ExtensionCodeStore(profileID: profile)
        let record = try XCTUnwrap(try codeStore.records()[folder.path])
        let sourceBytes = try Data(contentsOf: dependency)
        let acceptedBytes = try Data(contentsOf: codeStore.code(for: record).appendingPathComponent("dependency.js"))
        XCTAssertEqual(acceptedBytes, sourceBytes, "The replacement snapshot must contain the actual changed dependency")
        XCTAssertFalse(after === before)
        print("MV3_CACHE_DIAGNOSTIC version=\(version), sourceSHA=\(SHA256.hash(data: sourceBytes)), acceptedSHA=\(SHA256.hash(data: acceptedBytes)), beforeLoaded=\(before.isLoaded), afterLoaded=\(after.isLoaded), original=\(original ?? [:]), updated=\(updated ?? [:])")
        if updated?["revision"] != "updated" {
            // Observe fresh bytes AFTER the original failed response/assertion.
            // This never turns that failed outcome into an acceptance verdict.
            let box = CacheDiagnosticResult()
            do {
                try await ExtensionBackgroundStartup.wait(timeout: .seconds(5), start: { complete in
                    newWeb.callAsyncJavaScript("""
                        const url = browser.runtime.getURL('dependency.js');
                        const body = await (await fetch(url, {cache:'no-store'})).text();
                        let registrations;
                        try { registrations = await navigator.serviceWorker.getRegistrations().then(items => items.map(r => ({scope:r.scope, active:r.active?.scriptURL, cache:r.updateViaCache}))); }
                        catch(error) { registrations = {unavailable:String(error)}; }
                        return {url, body, registrations};
                        """, arguments: [:], in: nil, in: .page) { value in
                            MainActor.assumeIsolated { box.value = value; complete(nil) }
                        }
                }, check: {})
                print("MV3_CACHE_AFTER_FAILURE_FETCH \(try box.value?.get() as Any)")
            } catch { print("MV3_CACHE_AFTER_FAILURE_FETCH unavailable: \(error)") }
        }
        XCTAssertEqual(updated?["url"], original?["url"], "Vendor module identity remains canonical")
        XCTAssertNotEqual(updated?["workerURL"], original?["workerURL"], "Changed dependency bytes require a new worker registration URL")
        XCTAssertEqual(after.uniqueIdentifier, before.uniqueIdentifier)
        XCTAssertEqual(after.baseURL, before.baseURL)
    }

    @MainActor private final class CacheDiagnosticResult { var value: Result<Any, Error>? }

    func testWorkerRecreationRetainsNavigatorIdentityAndStorage() async throws {
        Settings.userAgent = "Vane Recreated Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3)
        let host = ExtensionHost.host(for: profile)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        _ = try await web.callAsyncJavaScript("await browser.storage.local.set({workerSaved:'persisted worker value'}); return true;",
                                             arguments: [:], in: nil, contentWorld: .page)
        let beforeValue = try await web.evaluateJavaScript("window.backgroundIdentity.nonce") as? String
        let before = try XCTUnwrap(beforeValue)
        let identity = context.uniqueIdentifier, origin = context.baseURL
        let selector = NSSelectorFromString("_reloadBackgroundContentForTesting")
        if context.responds(to: selector) { _ = context.perform(selector) }
        else {
            // Reusing the exact same native context also exercises a fresh worker
            // birth on SDKs without the idle-timeout testing selector.
            try host.controller.unload(context)
            try host.controller.load(context)
        }
        try await ExtensionBackgroundStartup.load(context, checkLifetime: {})
        let deadline = ContinuousClock.now + .seconds(10)
        var reply: [String: String]?
        repeat {
            reply = try await web.callAsyncJavaScript("return await chrome.runtime.sendMessage('identity');",
                                                     arguments: [:], in: nil, contentWorld: .page) as? [String: String]
            if reply?["nonce"] != before { break }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        XCTAssertNotEqual(reply?["nonce"], before)
        XCTAssertNotNil(reply?["nonce"])
        XCTAssertEqual(reply?["startup"], "Vane Recreated Worker/1.0")
        XCTAssertEqual(reply?["saved"], "persisted worker value")
        XCTAssertEqual(context.uniqueIdentifier, identity)
        XCTAssertEqual(context.baseURL, origin)
        #if DEBUG
        assertBackgroundOwnership(for: context)
        #endif
    }

    func testDevelopChangeRecreatesMV3ContextWithoutLosingAccessOrStorage() async throws {
        Settings.userAgent = "Vane Worker Before Change/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let before = try await install(version: 3)
        let host = ExtensionHost.host(for: profile)
        let controller = host.controller
        let (action, web) = try await popup(before)
        _ = try await web.callAsyncJavaScript("await chrome.storage.local.set({workerSaved:'kept across identity change'}); return true;",
                                             arguments: [:], in: nil, contentWorld: .page)
        before.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "alarms"))
        before.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "notifications"))
        let grants = before.grantedPermissions, denials = before.deniedPermissions
        let grantedSites = before.grantedPermissionMatchPatterns, deniedSites = before.deniedPermissionMatchPatterns
        let identifier = before.uniqueIdentifier, origin = before.baseURL
        action.closePopup()
        Settings.userAgent = "Vane Worker After Change/2.0"
        let deadline = ContinuousClock.now + .seconds(10)
        while (host.installed.first.map { $0 === before } ?? true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = try XCTUnwrap(host.installed.first, "Identity restart: " + host.entries.map { $0.status + " " + ($0.failure ?? "no failure") }.joined(separator: "; "))
        XCTAssertFalse(after === before, "Develop changes must rebuild the worker bootstrap")
        let (newAction, newWeb) = try await popup(after)
        defer { newAction.closePopup() }
        try await assertIdentity(in: newWeb, context: after, expected: "Vane Worker After Change/2.0")
        XCTAssertTrue(host.controller === controller)
        XCTAssertEqual(after.uniqueIdentifier, identifier)
        XCTAssertEqual(after.baseURL, origin)
        XCTAssertEqual(after.grantedPermissions, grants)
        XCTAssertEqual(after.deniedPermissions, denials)
        XCTAssertEqual(after.grantedPermissionMatchPatterns, grantedSites)
        XCTAssertEqual(after.deniedPermissionMatchPatterns, deniedSites)
        let saved = try await newWeb.evaluateJavaScript("window.backgroundIdentity.saved") as? String
        XCTAssertEqual(saved, "kept across identity change")
    }

    func testRapidDevelopSelectionsSettleOnLatestWorkerIdentity() async throws {
        Settings.userAgent = "Vane Initial Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let before = try await install(version: 3)
        let host = ExtensionHost.host(for: profile)
        for value in ["Vane Intermediate/2.0", "Vane Intermediate/3.0", "Vane Latest Worker/4.0"] {
            Settings.userAgent = value
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while ExtensionWorkerIdentity.identity(of: host.installed.first?.webExtension ?? before.webExtension) != "Vane Latest Worker/4.0",
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let after = try XCTUnwrap(host.installed.first)
        XCTAssertFalse(after === before)
        let (action, web) = try await popup(after)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: after, expected: "Vane Latest Worker/4.0")
        XCTAssertEqual(after.uniqueIdentifier, before.uniqueIdentifier)
        XCTAssertEqual(after.baseURL, before.baseURL)
        XCTAssertEqual(host.controller.extensionContexts.count, 1)
    }

    #if DEBUG
    func testRemovalDuringIdentityRestartCannotRepublishTheWorker() async throws {
        Settings.userAgent = "Vane Before Removal/1.0"
        let before = try await install(version: 3)
        let host = ExtensionHost.host(for: profile)
        let previous = host.backgroundCreationObserver
        var replacement: WKWebExtensionContext?
        var removal: Task<Void, Error>?
        host.backgroundCreationObserver = { web, context in
            previous?(web, context)
            if context !== before, removal == nil {
                replacement = context
                removal = Task { @MainActor in try host.remove(folder: self.folder.path) }
            }
        }
        defer { host.backgroundCreationObserver = previous }
        Settings.userAgent = "Vane During Removal/2.0"
        let deadline = ContinuousClock.now + .seconds(10)
        while removal == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let task = try XCTUnwrap(removal)
        try await task.value
        let retired = try XCTUnwrap(replacement)
        while retired.isLoaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(retired.isLoaded, "Cancelled restart must unload its provisional native context")
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(host.controller.extensionContexts.isEmpty)
        XCTAssertTrue(host.entries.isEmpty)
        XCTAssertNil(try ExtensionCodeStore(profileID: profile).records()[folder.path])
    }
    #endif

    func testGeneratedMV3WorkerStartsWithSelectedNavigatorIdentity() async throws {
        Settings.userAgent = "Vane Generated Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, generated: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Generated Worker/1.0")
        let accepted = try XCTUnwrap(try ExtensionCodeStore(profileID: profile).records()[folder.path])
        let acceptedURL = ExtensionCodeStore(profileID: profile).code(for: accepted)
        XCTAssertEqual(try Data(contentsOf: acceptedURL.appendingPathComponent("background.js")),
                       try Data(contentsOf: folder.appendingPathComponent("background.js")))
        XCTAssertEqual(try Data(contentsOf: acceptedURL.appendingPathComponent("manifest.json")),
                       try Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    func testNestedModuleImportsAndHashbangRetainURLsAndFirstIdentity() async throws {
        Settings.userAgent = "Vane Nested Module/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, module: true, workerPath: "nested/background.js", hashbang: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Nested Module/1.0")
        let reply = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
        let workerURL = try XCTUnwrap(reply?["url"].flatMap(URL.init(string:)))
        XCTAssertEqual(workerURL.path, "/nested/background.js")
        XCTAssertEqual(workerURL.host, context.baseURL.host)
        XCTAssertNil(workerURL.query, "Vendor module identity must remain canonical")
        let creationURL = try XCTUnwrap(reply?["workerURL"].flatMap(URL.init(string:)))
        XCTAssertEqual(creationURL.deletingLastPathComponent().path, "/nested")
        XCTAssertTrue(creationURL.lastPathComponent.hasPrefix("__vane_worker_entry_"))
        XCTAssertEqual(reply?["dependencyURL"], context.baseURL.appendingPathComponent("nested/dependency.js").absoluteString)
        XCTAssertEqual(reply?["strict"], "true")
    }

    func testClassicWorkerRetainsHashbangAndStrictMode() async throws {
        Settings.userAgent = "Vane Strict Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, hashbang: true, strict: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Strict Worker/1.0")
        let strict = try await web.evaluateJavaScript("window.backgroundIdentity.strict") as? String
        XCTAssertEqual(strict, "true")
    }

    func testWorkerSourceReusedInExtensionPagesKeepsPageNavigator() async throws {
        Settings.userAgent = "Vane Worker Scope/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        for module in [false, true] {
            let context = try await install(version: 3, module: module, reusePage: true)
            let config = try XCTUnwrap(context.webViewConfiguration)
            config.defaultWebpagePreferences = WKWebpagePreferences()
            let view = WKWebView(frame: .zero, configuration: config)
            view.customUserAgent = "Vane Reused Page/1.0"
            view.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
            let deadline = ContinuousClock.now + .seconds(10)
            var identity: String?
            repeat {
                identity = try? await view.evaluateJavaScript("globalThis.entryStartupIdentity") as? String
                if identity != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            XCTAssertEqual(identity, "Vane Reused Page/1.0", "Reusing a worker resource must not spoof page navigators")
            view.stopLoading(); view.removeFromSuperview()
            ExtensionHost.host(for: profile).remove(context)
        }
    }

    func testMV3HostRestorationRetainsIdentityStorageAndContentVersion() async throws {
        Settings.userAgent = "Vane Restored Worker/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let before = try await install(version: 3)
        let beforeURL = (before.webExtension.manifest["background"] as? [String: Any])?["service_worker"] as? String
        let (action, web) = try await popup(before)
        _ = try await web.callAsyncJavaScript("await browser.storage.local.set({workerSaved:'restored worker value'}); return true;",
                                             arguments: [:], in: nil, contentWorld: .page)
        action.closePopup()
        ExtensionHost.forget(profile)
        let host = ExtensionHost.host(for: profile)
        #if DEBUG
        try observeBackgroundCreation(of: host)
        #endif
        let deadline = ContinuousClock.now + .seconds(10)
        while host.installed.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let restored = try XCTUnwrap(host.installed.first, host.entries.compactMap(\.failure).joined(separator: "; "))
        let (newAction, newWeb) = try await popup(restored)
        defer { newAction.closePopup() }
        try await assertIdentity(in: newWeb, context: restored, expected: "Vane Restored Worker/1.0")
        XCTAssertEqual(restored.uniqueIdentifier, before.uniqueIdentifier)
        XCTAssertEqual(restored.baseURL, before.baseURL)
        let afterURL = (restored.webExtension.manifest["background"] as? [String: Any])?["service_worker"] as? String
        XCTAssertEqual(afterURL, beforeURL, "Identical inputs should retain the same worker content version")
        let saved = try await newWeb.evaluateJavaScript("window.backgroundIdentity.saved") as? String
        XCTAssertEqual(saved, "restored worker value")
    }

    func testGeneratedModuleWorkerDependenciesUseSelectedIdentity() async throws {
        Settings.userAgent = "Vane Generated Module/1.0"
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let context = try await install(version: 3, module: true, generated: true)
        let (action, web) = try await popup(context)
        defer { action.closePopup() }
        try await assertIdentity(in: web, context: context, expected: "Vane Generated Module/1.0")
        let dependency = try await web.evaluateJavaScript("window.backgroundIdentity.dependencyURL") as? String
        XCTAssertEqual(dependency, context.baseURL.appendingPathComponent("dependency.js").absoluteString)
    }

    func testUnmodifiedBitwardenMV3PackageStartsWithNavigatorCompatibilityWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["VANE_MV3_BITWARDEN_PACKAGE"] else {
            throw XCTSkip("Set VANE_MV3_BITWARDEN_PACKAGE to the verified upstream Chrome fixture")
        }
        let source = URL(fileURLWithPath: path)
        let manifest = try ExtensionHost.validate(source)
        XCTAssertEqual(manifest["manifest_version"] as? Int, 3)
        XCTAssertEqual(manifest["version"] as? String, "2026.10.0")
        XCTAssertNotNil((manifest["background"] as? [String: Any])?["service_worker"] as? String)
        Settings.userAgent = safariUA
        forcedBackgroundUserAgent = "Vane Wrong Native Worker/0"
        let store = ExtensionCodeStore(profileID: profile)
        let original = try store.resources(in: source)
        let host = ExtensionHost.host(for: profile)
        #if DEBUG
        try observeBackgroundCreation(of: host)
        #endif
        let accepted = try await host.load(source, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(ExtensionWorkerIdentity.identity(of: context.webExtension), safariUA)
        #if DEBUG
        assertBackgroundOwnership(for: context)
        #endif
        XCTAssertEqual(try store.resources(in: source), original, "Do not patch the upstream package on disk")
        // The native synthetic and signed-worker fixtures capture the first
        // vendor instruction. This package check covers normal SDK startup with
        // the original bytes; no authentication or vault workflow is inferred.
    }

    /// The former advisory is required coverage for the selected worker identity
    /// at startup and after a custom-to-Safari selection change.
    func testServiceWorkerNavigatorIdentityAcrossSelections() async throws {
        for (identity, stage) in [(safariUA, "default Safari worker"),
                                  ("Vane Prior Worker Identity/1.0 (no Safari token)", "custom worker"),
                                  (safariUA, "Safari worker after custom worker")] {
            Settings.userAgent = identity
            let context = try await install(version: 3)
            let (action, web) = try await popup(context)
            let result = try await web.evaluateJavaScript("window.backgroundIdentity") as? [String: String]
            XCTAssertEqual(result?["startup"], identity, "MV3 navigator identity: \(stage) startup")
            XCTAssertEqual(result?["current"], identity, "MV3 navigator identity: \(stage) current")
            action.closePopup()
            ExtensionHost.host(for: profile).remove(context)
        }
    }

    func testDevelopChangeUpdatesLiveBackgroundAndRecreatedPopupWithoutChangingAccess() async throws {
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exerciseDevelopChangeWithPresentedWindow() } catch { failure = error }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Popup AppKit cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func exerciseDevelopChangeWithPresentedWindow() async throws {
        let context = try await install(version: 2)
        let host = ExtensionHost.host(for: profile)
        let store = TabStore(profileID: profile, session: [])
        let tab = store.newBlankTab()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let anchor = NSView(frame: NSRect(x: 440, y: 250, width: 28, height: 28))
        try XCTUnwrap(window.contentView).addSubview(anchor)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.close()
            store.window = nil
            TabStore.all.removeAll { $0 === store }
            store.everyTab.forEach { $0.tearDown() }
        }
        let admissionDeadline = ContinuousClock.now + .seconds(5)
        while !NSApp.isActive || !window.isKeyWindow || !window.isVisible {
            guard ContinuousClock.now < admissionDeadline else { throw ExtensionHost.Failure("Popup parent foreground admission timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }

        host.run(context, for: tab, from: anchor)
        let (action, web) = try await popup(context, for: tab)
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
        try await closePresentedPopup(action, host: host, context: context, tab: tab)
        let (recreatedAction, recreated) = try await popup(context, for: tab)
        XCTAssertFalse(recreated === web, "Recreation must inspect a fresh popup, not cached startup values")
        try await assertIdentity(in: recreated, context: context, expected: custom, startup: safariUA)
        XCTAssertTrue(ExtensionHost.host(for: profile).controller === controller)
        XCTAssertTrue(context.isLoaded)
        XCTAssertEqual(context.grantedPermissions, granted)
        XCTAssertEqual(context.grantedPermissionMatchPatterns, sites)
        recreatedAction.closePopup()
    }

    private func waitForPresentation(_ action: WKWebExtension.Action) async throws {
        let web = try XCTUnwrap(action.popupWebView)
        let deadline = ContinuousClock.now + .seconds(5)
        while web.window?.isVisible != true || web.window?.styleMask.contains(.titled) != true {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ExtensionUserAgentTests.PresentationTimeout", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func closePresentedPopup(_ action: WKWebExtension.Action, host: ExtensionHost,
                                     context: WKWebExtensionContext, tab: Tab) async throws {
        let web = try XCTUnwrap(action.popupWebView)
        let window = try XCTUnwrap(web.window)
        XCTAssertTrue(window.isVisible && window.styleMask.contains(.titled))
        let closed = XCTNSNotificationExpectation(name: NSWindow.willCloseNotification, object: window)
        host.closeActionPopup(context, for: tab)
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertFalse(window.isVisible)
        XCTAssertNil(web.window)
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
