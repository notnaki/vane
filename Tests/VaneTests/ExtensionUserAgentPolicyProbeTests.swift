import AppKit
import WebKit
import XCTest
@testable import vane

/// Diagnostic only: the previously passing framework fixture, with one optional
/// full-UA webpage policy. No ExtensionHost, Tab, Settings or startup workaround.
///
/// VANE_WEBKIT_UA_POLICY_PROBE_ARM=control|policy selects one arm in a fresh host.
/// Without it, both run control-first in the full suite's existing process. That
/// comparison can carry worker-process state between arms; fresh hosts are needed
/// to separate that ordering effect. Neither mode exposes WebKit's cached client
/// UA or proves which fallback WebKit selected. The class sorts after the original
/// ExtensionUserAgentTests, preserving their existing predecessors.
@MainActor final class WebKitExtensionUserAgentPolicyProbeTests: XCTestCase {
    // One finite owner avoids the independently observed legacy pool-retirement trap.
    private static let pool = WKProcessPool()
    // Keep the exact Safari-shaped fixture identity used by the prior passing probe.
    private static let suffix = "Version/26.0 Safari/605.1.15"
    private static let safariIdentity = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(suffix)"
    private static let policySetter = NSSelectorFromString("_setCustomUserAgent:")
    private static let backgroundSelector = NSSelectorFromString("_webExtensionController:didCreateBackgroundWebView:forExtensionContext:")

    private enum Arm: String, CaseIterable { case control, policy }
    private enum Failure: Error {
        case timeout(String)
        case invalidArm
        case policyUnavailable
    }

    private var ownedProfile: UUID!
    private var directory: URL!
    private var store: WKWebsiteDataStore?
    private var controller: WKWebExtensionController?
    private var delegate: BackgroundDelegate?
    private var policy: WKWebpagePreferences?
    private var contexts: [WKWebExtensionContext] = []
    private var actions: [WKWebExtension.Action] = []
    private var views: [WKWebView] = []

    @MainActor private final class BackgroundDelegate: NSObject, WKWebExtensionControllerDelegate {
        private var selectedIdentity = ""
        private(set) weak var context: WKWebExtensionContext?
        private(set) weak var landing: WKWebView?
        private(set) var callbacks = 0
        private(set) var appliedIdentity: String?

        func reset(to identity: String) {
            selectedIdentity = identity
            context = nil
            landing = nil
            callbacks = 0
            appliedIdentity = nil
        }

        // The known optional callback applies only the public property, before load.
        @objc(_webExtensionController:didCreateBackgroundWebView:forExtensionContext:)
        func extensionController(_ controller: WKWebExtensionController, didCreateBackgroundWebView web: WKWebView,
                                 forExtensionContext context: WKWebExtensionContext) {
            web.customUserAgent = selectedIdentity
            self.context = context
            landing = web
            callbacks += 1
            appliedIdentity = web.customUserAgent
        }
    }

    @MainActor private final class Reply<Value> { var value: Result<Value, Error>? }
    private struct Identity {
        let popupStartup: String
        let popupGeneration: String
        let popupRuntime: String
        let popupHost: String
        let worker: [String: String]
    }

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        ownedProfile = UUID()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-ua-policy-probe-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Vane helpers select only a disposable named store and its safe retirement.
        store = ProfileManager.dataStore(for: ownedProfile)
        XCTAssertNotNil(store?.identifier)
        XCTAssertEqual(store?.isPersistent, true)
    }

    override func tearDown() async throws {
        for action in actions { action.closePopup() }
        actions.removeAll()
        for view in views { view.stopLoading() }
        views.removeAll()
        for context in contexts where context.isLoaded {
            do { try controller?.unload(context) }
            catch { XCTFail("WebKit could not unload an owned policy-probe context") }
        }
        contexts.removeAll()
        releaseController()
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let profile = ownedProfile {
            ownedProfile = nil
            try await NativeFixtureProfileCleanup.release([profile])
        }
    }

    private func releaseController() {
        controller?.delegate = nil
        controller = nil
        delegate = nil
        policy = nil
    }

    private func configure(_ arm: Arm) throws -> BackgroundDelegate {
        let store = try XCTUnwrap(store)
        let delegate = BackgroundDelegate()
        delegate.reset(to: Self.safariIdentity)
        XCTAssertTrue(delegate.responds(to: Self.backgroundSelector))
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let seed: WKWebViewConfiguration = configuration.webViewConfiguration
        seed.websiteDataStore = store
        seed.processPool = Self.pool
        seed.applicationNameForUserAgent = Self.suffix
        // The sole arm difference: Vane's guarded full-UA policy, shared through
        // configuration copies and updated before each new context starts.
        if arm == .policy {
            let policy = WKWebpagePreferences()
            guard policy.responds(to: Self.policySetter) else { throw Failure.policyUnavailable }
            _ = policy.perform(Self.policySetter, with: Self.safariIdentity)
            seed.defaultWebpagePreferences = policy
            self.policy = policy
        }
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = delegate
        self.controller = controller
        self.delegate = delegate
        return delegate
    }

    private func wait<Value>(_ reply: Reply<Value>, stage: String, until deadline: ContinuousClock.Instant) async throws -> Value {
        while reply.value == nil && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let result = reply.value else { throw Failure.timeout(stage) }
        return try result.get()
    }

    private func evaluate(_ script: String, in web: WKWebView, until deadline: ContinuousClock.Instant) async throws -> Any? {
        let reply = Reply<Any?>()
        web.evaluateJavaScript(script) { value, error in
            if let error { reply.value = .failure(error) }
            else { reply.value = .success(value) }
        }
        return try await wait(reply, stage: "existing popup JavaScript", until: deadline)
    }

    private func load(version: Int, generation: String) async throws -> WKWebExtensionContext {
        let folder = try XCTUnwrap(directory).appendingPathComponent(generation)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["manifest_version": version, "name": "WebKit UA Policy Probe",
            "description": "Synthetic user-agent policy comparison", "version": "1.0"]
        manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "popup.html"]
        manifest["background"] = version == 2
            ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
            : ["service_worker": "background.js"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // Only an internally generated UUID is interpolated. These checks bind the
        // real message to the accepted generation/runtime/origin, not a prior worker.
        try Data("""
            const startup = navigator.userAgent;
            const generation = '\(generation)';
            browser.runtime.onMessage.addListener(async message => {
                if (message === 'popup-visibility') {
                    const result = {generation, runtime:browser.runtime.id, available:false, visible:false};
                    try {
                        if (typeof clients !== 'undefined' && typeof clients.matchAll === 'function') {
                            const popupURL = new URL('/popup.html', location.href).href;
                            const windows = await clients.matchAll({includeUncontrolled:true, type:'window'});
                            result.available = true;
                            result.visible = windows.some(client => client.url === popupURL);
                        }
                    } catch { }
                    return result;
                }
                return {startup, current:navigator.userAgent, generation, runtime:browser.runtime.id,
                    scheme:location.protocol, host:location.host,
                    version:String(browser.runtime.getManifest().manifest_version)};
            });
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<script src='popup.js'></script>".utf8).write(to: folder.appendingPathComponent("popup.html"))
        try Data("""
            window.popupStartup = navigator.userAgent;
            window.popupGeneration = '\(generation)';
            browser.runtime.sendMessage('identity').then(worker => { window.identityResult = worker; });
            """.utf8).write(to: folder.appendingPathComponent("popup.js"))
        let webExtension = try await WKWebExtension(resourceBaseURL: folder)
        XCTAssertTrue(webExtension.errors.isEmpty, "Synthetic manifest errors: \(webExtension.errors)")
        let context = WKWebExtensionContext(for: webExtension)
        context.uniqueIdentifier = generation
        context.baseURL = URL(string: "webkit-extension://\(generation.lowercased())/")!
        try XCTUnwrap(controller).load(context)
        contexts.append(context)
        let loaded = Reply<Void>()
        context.loadBackgroundContent { error in
            if let error { loaded.value = .failure(error) }
            else { loaded.value = .success(()) }
        }
        try await wait(loaded, stage: "background content", until: ContinuousClock.now + .seconds(10))
        return context
    }

    private func popupIdentity(_ context: WKWebExtensionContext) async throws -> (Identity, WKWebView) {
        let action = try XCTUnwrap(context.action(for: nil))
        actions.append(action)
        let web = try XCTUnwrap(action.popupWebView)
        views.append(web)
        let actualStore = web.configuration.websiteDataStore
        XCTAssertTrue(actualStore.identifier == store?.identifier)
        XCTAssertEqual(actualStore.isPersistent, true)
        XCTAssertTrue(web.configuration.processPool === Self.pool)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !web.isLoading,
               let result = try await evaluate("({popup:window.popupStartup, generation:window.popupGeneration, runtime:browser.runtime.id, host:location.host, worker:window.identityResult})", in: web, until: deadline) as? [String: Any],
               let popup = result["popup"] as? String, let generation = result["generation"] as? String,
               let runtime = result["runtime"] as? String, let host = result["host"] as? String,
               let worker = result["worker"] as? [String: String], worker["startup"] != nil, worker["current"] != nil {
                return (Identity(popupStartup: popup, popupGeneration: generation, popupRuntime: runtime, popupHost: host, worker: worker), web)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.timeout("popup/background identity reply")
    }

    private func close(_ context: WKWebExtensionContext) throws {
        for action in actions { action.closePopup() }
        actions.removeAll()
        for view in views { view.stopLoading() }
        views.removeAll()
        try XCTUnwrap(controller).unload(context)
        contexts.removeAll { $0 === context }
        XCTAssertFalse(context.isLoaded)
    }

    private func observePopupVisibility(in web: WKWebView, context: WKWebExtensionContext,
                                        generation: String, label: String) async {
        // Observation only, after the original identity checks. Popup registration
        // can differ independently of worker UA; false/unavailable is inconclusive.
        // Query only the existing popup's exact same-origin URL, never another page.
        let reply = Reply<Any?>()
        web.callAsyncJavaScript("return await browser.runtime.sendMessage('popup-visibility')",
                                arguments: [:], in: nil, in: .page) { result in
            do { reply.value = .success(try result.get()) }
            catch { reply.value = .failure(error) }
        }
        do {
            let result = try await wait(reply, stage: "popup visibility observation",
                                        until: ContinuousClock.now + .seconds(10)) as? [String: Any]
            let associated = result?["generation"] as? String == generation
                && result?["runtime"] as? String == context.uniqueIdentifier
            let available = associated && result?["available"] as? Bool == true
            let visible = available && result?["visible"] as? Bool == true
            print("WebKit UA policy probe \(label): popupClientAssociated=\(associated), popupClientAvailable=\(available), popupClientVisible=\(visible); observation only, false/unavailable inconclusive")
        } catch {
            // Never log a raw JavaScript error, client URL or client identifier.
            print("WebKit UA policy probe \(label): popupClientAssociated=false, popupClientAvailable=false, popupClientVisible=false; observation unavailable, inconclusive")
        }
    }

    func testFullUserAgentPolicyAgainstPublicBackgroundCallbackControl() async throws {
        let arms: [Arm]
        if let selected = ProcessInfo.processInfo.environment["VANE_WEBKIT_UA_POLICY_PROBE_ARM"] {
            guard let arm = Arm(rawValue: selected) else { throw Failure.invalidArm }
            arms = [arm]
        } else { arms = Arm.allCases }
        // Public local metadata only; no subprocess, new page or raw file path.
        func bounded(_ value: String, limit: Int) -> String {
            String(value.components(separatedBy: CharacterSet.controlCharacters).joined().prefix(limit))
        }
        let webKitVersion = Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable"
        print("WebKit UA policy probe: WebKit=\(bounded(webKitVersion, limit: 96)); OS=\(bounded(ProcessInfo.processInfo.operatingSystemVersionString, limit: 160))")
        for arm in arms {
            let delegate = try configure(arm)
            let stages: [(Int, String, String)] = [
                (2, Self.safariIdentity, "default Safari MV2"),
                (3, Self.safariIdentity, "default Safari MV3"),
                (3, "VaneWorkerUARepro/1.0", "custom MV3"),
                (3, Self.safariIdentity, "Safari MV3 after custom")
            ]
            for (version, selected, stage) in stages {
                delegate.reset(to: selected)
                if let policy { _ = policy.perform(Self.policySetter, with: selected) }
                let generation = UUID().uuidString
                let context = try await load(version: version, generation: generation)
                let (identity, web) = try await popupIdentity(context)
                let label = "\(arm.rawValue): \(stage)"
                XCTAssertTrue(delegate.context === context, label)
                let landing = try XCTUnwrap(delegate.landing)
                XCTAssertTrue(landing.configuration.websiteDataStore.identifier == store?.identifier, label)
                XCTAssertEqual(landing.configuration.websiteDataStore.isPersistent, true, label)
                XCTAssertTrue(landing.configuration.processPool === Self.pool, label)
                XCTAssertGreaterThan(delegate.callbacks, 0, label)
                XCTAssertEqual(delegate.appliedIdentity, selected, label)
                XCTAssertTrue(identity.popupGeneration == generation, "\(label): popup generation")
                XCTAssertTrue(identity.worker["generation"] == generation, "\(label): actual background generation")
                XCTAssertTrue(identity.popupRuntime == context.uniqueIdentifier, "\(label): popup runtime")
                XCTAssertTrue(identity.worker["runtime"] == context.uniqueIdentifier, "\(label): actual background runtime")
                XCTAssertTrue(identity.popupHost == context.baseURL.host, "\(label): popup origin")
                XCTAssertTrue(identity.worker["host"] == context.baseURL.host, "\(label): actual background origin")
                XCTAssertEqual(identity.worker["scheme"], "webkit-extension:", label)
                XCTAssertEqual(identity.worker["version"], String(version), label)
                XCTAssertEqual(identity.popupStartup, arm == .policy ? selected : Self.safariIdentity, "\(label): popup startup control")
                XCTAssertEqual(identity.worker["startup"], selected, "\(label): background startup")
                XCTAssertEqual(identity.worker["current"], selected, "\(label): background current")
                // As in the prior probe, exercise the public popup property only
                // AFTER the actual worker reply. It cannot repair these assertions.
                web.customUserAgent = selected
                let current = try await evaluate("navigator.userAgent", in: web, until: ContinuousClock.now + .seconds(10)) as? String
                XCTAssertEqual(current, selected, "\(label): public popup setter control")
                if version == 3 {
                    await observePopupVisibility(in: web, context: context, generation: generation, label: label)
                }
                print("WebKit UA policy probe \(label): callback=\(delegate.callbacks > 0), generation=\(identity.worker["generation"] == generation), runtime=\(identity.worker["runtime"] == context.uniqueIdentifier), origin=\(identity.worker["host"] == context.baseURL.host), workerStartup=\(identity.worker["startup"] ?? "<missing>"), workerCurrent=\(identity.worker["current"] ?? "<missing>")")
                try close(context)
            }
            releaseController()
        }
    }
}
