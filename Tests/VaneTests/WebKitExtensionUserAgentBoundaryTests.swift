import AppKit
import WebKit
import XCTest
@testable import vane

/// Diagnostic boundary reproducer. Vane helpers provide only an owned data-store
/// namespace and retirement; all controller, context and UA behavior below is WebKit.
@MainActor final class WebKitExtensionUserAgentBoundaryTests: XCTestCase {
    // Retain one finite pool through the test process, avoiding the independently
    // observed legacy-WebKit pool-destruction trap during controller retirement.
    private static let processPool = WKProcessPool()
    private static let suffix = "Version/26.0 Safari/605.1.15"
    private static let safariIdentity = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(suffix)"
    private static let backgroundSelector = NSSelectorFromString("_webExtensionController:didCreateBackgroundWebView:forExtensionContext:")

    private var ownedProfile: UUID!
    private var directory: URL!
    private var store: WKWebsiteDataStore?
    private var controller: WKWebExtensionController?
    private var delegate: PublicDelegate?
    private var contexts: [WKWebExtensionContext] = []
    private var actions: [WKWebExtension.Action] = []
    private var views: [WKWebView] = []

    @MainActor private class PublicDelegate: NSObject, WKWebExtensionControllerDelegate { }

    @MainActor private final class BackgroundDelegate: PublicDelegate {
        var selectedIdentity = ""
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

        // This optional hook is present in the pinned official WebKit source. The
        // separate PublicDelegate above deliberately does not implement it.
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

    @MainActor private final class Reply<Value> {
        var value: Result<Value, Error>?
    }

    private struct Identity {
        let popupStartup: String
        let workerStartup: String
        let workerCurrent: String
        let generation: String
    }

    private enum Failure: Error {
        case timeout(String)
        case invalidReply
    }

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        ownedProfile = UUID()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("webkit-extension-ua-boundary-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // These Vane calls only select/retire a disposable named store under the
        // test namespace. No ExtensionHost, Tab, Settings or UA helper is involved.
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
            catch { XCTFail("WebKit could not unload an owned boundary-repro context") }
        }
        contexts.removeAll()
        controller?.delegate = nil
        controller = nil
        delegate = nil
        store = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        if let profile = ownedProfile {
            ownedProfile = nil
            try await NativeFixtureProfileCleanup.release([profile])
        }
    }

    private func configure(_ delegate: PublicDelegate) throws {
        let store = try XCTUnwrap(store)
        // Only extension bookkeeping is non-persistent. Its explicit website data
        // store below is the owned normal named store, not a private session.
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let seed: WKWebViewConfiguration = configuration.webViewConfiguration
        seed.websiteDataStore = store
        seed.processPool = Self.processPool
        seed.applicationNameForUserAgent = Self.suffix
        // No private WKWebpagePreferences/full-UA policy setter.
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = delegate
        self.delegate = delegate
        self.controller = controller
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
        var manifest: [String: Any] = ["manifest_version": version, "name": "WebKit UA Boundary", "description": "Synthetic user-agent boundary fixture", "version": "1.0"]
        manifest[version == 2 ? "browser_action" : "action"] = ["default_popup": "popup.html"]
        manifest["background"] = version == 2
            ? ["scripts": ["background.js"], "persistent": true] as [String: Any]
            : ["service_worker": "background.js"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        // generation is an internally generated UUID, not extension/user input.
        try Data("""
            const startup = navigator.userAgent;
            const generation = '\(generation)';
            browser.runtime.onMessage.addListener(async () => ({startup, current:navigator.userAgent, generation}));
            """.utf8).write(to: folder.appendingPathComponent("background.js"))
        try Data("<script src='popup.js'></script>".utf8).write(to: folder.appendingPathComponent("popup.html"))
        try Data("""
            window.popupStartup = navigator.userAgent;
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
        let expectedStore = try XCTUnwrap(store)
        XCTAssertTrue(actualStore.identifier == expectedStore.identifier)
        XCTAssertEqual(actualStore.isPersistent, expectedStore.isPersistent)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !web.isLoading,
               let result = try await evaluate("({popup:window.popupStartup, worker:window.identityResult})", in: web, until: deadline) as? [String: Any],
               let popup = result["popup"] as? String,
               let worker = result["worker"] as? [String: String],
               let startup = worker["startup"], let current = worker["current"], let generation = worker["generation"] {
                return (Identity(popupStartup: popup, workerStartup: startup, workerCurrent: current, generation: generation), web)
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

    func testPublicSafariSuffixReachesMV2AndMV3Backgrounds() async throws {
        let delegate = PublicDelegate()
        XCTAssertFalse(delegate.responds(to: Self.backgroundSelector), "This arm must remain public-only")
        try configure(delegate)
        for version in [2, 3] {
            let generation = UUID().uuidString
            let context = try await load(version: version, generation: generation)
            let (identity, _) = try await popupIdentity(context)
            XCTAssertTrue(identity.popupStartup.hasSuffix(Self.suffix), "MV\(version) popup Safari product suffix")
            XCTAssertEqual(identity.popupStartup.components(separatedBy: " Version/").count, 2)
            XCTAssertEqual(identity.popupStartup.components(separatedBy: " Safari/").count, 2)
            XCTAssertEqual(identity.workerStartup, identity.popupStartup, "MV\(version) background startup")
            XCTAssertEqual(identity.workerCurrent, identity.popupStartup, "MV\(version) background current")
            XCTAssertEqual(identity.generation, generation)
            print("WebKit UA boundary public suffix MV\(version): popup=\(identity.popupStartup), workerStartup=\(identity.workerStartup), workerCurrent=\(identity.workerCurrent)")
            try close(context)
        }
    }

    func testPublicBackgroundCustomUserAgentReachesNewMV3Workers() async throws {
        let delegate = BackgroundDelegate()
        XCTAssertTrue(delegate.responds(to: Self.backgroundSelector))
        try configure(delegate)
        for selected in ["VaneWorkerUARepro/1.0", Self.safariIdentity] {
            delegate.reset(to: selected)
            let generation = UUID().uuidString
            let context = try await load(version: 3, generation: generation)
            let (identity, web) = try await popupIdentity(context)
            XCTAssertTrue(delegate.context === context)
            let landing = try XCTUnwrap(delegate.landing)
            XCTAssertTrue(landing.configuration.websiteDataStore.identifier == store?.identifier)
            XCTAssertEqual(landing.configuration.websiteDataStore.isPersistent, true)
            XCTAssertGreaterThan(delegate.callbacks, 0, "The optional hook must actually run")
            XCTAssertEqual(delegate.appliedIdentity, selected)
            // The public popup getter starts navigation. Its startup is the public
            // suffix control; only its current UA is changed after the real reply.
            XCTAssertTrue(identity.popupStartup.hasSuffix(Self.suffix))
            web.customUserAgent = selected
            let current = try await evaluate("navigator.userAgent", in: web, until: ContinuousClock.now + .seconds(10)) as? String
            XCTAssertEqual(current, selected, "Public page setter control")
            XCTAssertEqual(identity.workerStartup, selected, "MV3 worker startup after public background setter")
            XCTAssertEqual(identity.workerCurrent, selected, "MV3 worker current after public background setter")
            XCTAssertEqual(identity.generation, generation)
            print("WebKit UA boundary optional callback: callbacks=\(delegate.callbacks), selected=\(selected), popupCurrent=\(current ?? "<nil>"), workerStartup=\(identity.workerStartup), workerCurrent=\(identity.workerCurrent)")
            try close(context)
        }
    }
}
