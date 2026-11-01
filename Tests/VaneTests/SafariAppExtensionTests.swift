import AppKit
import WebKit
import XCTest
@testable import vane

/// Signed fixture tests are opt-in because CI has no signing identity. No native code
/// from the fixture is executed: WebKit reads only its bundled web resources.
@MainActor final class SafariAppExtensionTests: XCTestCase {
    private var profile: UUID!
    private var ownedProfiles = Set<UUID>()
    private var root: URL!
    private var app: URL!
    private var appex: URL!
    private var signingIdentity: String!
    private var previousUserAgent: Any?
    private var team: String!
    private var appID: String!
    private var extensionID: String!
    private var stores: [TabStore] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        guard let identity = ProcessInfo.processInfo.environment["VANE_TEST_SIGNING_IDENTITY"],
              let expectedTeam = ProcessInfo.processInfo.environment["VANE_TEST_SIGNING_TEAM"] else {
            throw XCTSkip("Set VANE_TEST_SIGNING_IDENTITY and VANE_TEST_SIGNING_TEAM for signed Safari fixture checks")
        }
        signingIdentity = identity; team = expectedTeam
        previousUserAgent = UserDefaults.vane.object(forKey: "userAgent")
        profile = UUID()
        ownedProfiles.insert(profile)
        appID = "test.vane.safari-" + UUID().uuidString.lowercased()
        extensionID = appID + ".extension"
        root = Store.directory.appendingPathComponent("signed-safari-\(UUID())")
        app = root.appendingPathComponent("Safari Fixture.app")
        appex = app.appendingPathComponent("Contents/PlugIns/Fixture.appex")
        for bundle in [app!, appex!] {
            print("Safari fixture setup: creating " + bundle.path)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let executable = bundle.appendingPathComponent("Contents/MacOS/fixture")
            try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            var info: [String: Any] = ["CFBundleIdentifier": bundle == app ? appID! : extensionID!,
                "CFBundleExecutable": "fixture", "CFBundlePackageType": bundle == app ? "APPL" : "XPC!",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
            if bundle == appex {
                info["NSExtension"] = ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension", "NSExtensionPrincipalClass": "NSObject"]
                // A claimed team must never supply the runtime identity.
                info["TeamIdentifier"] = "IMPERSONATE"
            }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        print("Safari fixture setup: signing")
        try write(version: "1.0")
        print("Safari fixture setup: ready")
        _ = NSApplication.shared
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        do { try process.run() } catch { throw ExtensionHost.Failure("Could not launch fixture signer: " + String(describing: error)) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtensionHost.Failure(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }

    private func write(version: String, permissions: [String] = ["storage"], worker: Bool = false) throws {
        let resources = appex.appendingPathComponent("Contents/Resources")
        let background: [String: Any] = worker ? ["service_worker": "background.js"] : ["scripts": ["background.js"], "persistent": false]
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Signed Safari Fixture", "version": version,
            "permissions": permissions, "background": background,
            "options_ui": ["page": "options.html"], "externally_connectable": ["matches": ["https://handoff.example.test/*"]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("manifest.json"))
        let script = worker
            ? "const startup = navigator.userAgent; browser.runtime.onMessage.addListener(() => Promise.resolve({ua:startup, id:browser.runtime.id}));"
            : "browser.runtime.onMessageExternal.addListener((message, sender, reply) => { reply({received:message.nonce, id:browser.runtime.id}); });"
        try Data(script.utf8)
            .write(to: resources.appendingPathComponent("background.js"))
        try Data("<title>Signed Safari fixture</title>".utf8).write(to: resources.appendingPathComponent("options.html"))
        try run("/usr/bin/codesign", ["--force", "--sign", signingIdentity, "--timestamp=none", appex.path])
        try run("/usr/bin/codesign", ["--force", "--sign", signingIdentity, "--timestamp=none", app.path])
    }

    override func tearDown() async throws {
        guard profile != nil else { return }
        for store in stores {
            store.everyTab.forEach { $0.tearDown() }; store.window = nil
            TabStore.all.removeAll { $0 === store }
        }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        stores.removeAll(); windows.removeAll()
        func removeInstallations() {
            let host = ExtensionHost.host(for: profile)
            for entry in host.entries { try? host.remove(folder: entry.path) }
            ExtensionHost.forget(profile)
        }
        removeInstallations()
        UserDefaults.vane.set(previousUserAgent, forKey: "userAgent")
        Settings.apply()
        if let root { try? FileManager.default.removeItem(at: root) }
        let released = ownedProfiles
        ownedProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    func testSignedMV3WorkerUsesSelectedNavigatorAndExactResourceSeal() async throws {
        try write(version: "1.0", worker: true)
        let resourceURL = appex.appendingPathComponent("Contents/Resources")
        let store = ExtensionCodeStore(profileID: profile)
        let resources = try store.resources(in: resourceURL)
        let signature = try SafariExtensionSource.verify(appex)
        try ExtensionWorkerIdentity.validateSignedResources(resources, bundleURL: appex, signatureHash: signature.hash)
        var tampered = resources
        tampered["background.js"] = Data("changed after verification".utf8)
        XCTAssertThrowsError(try ExtensionWorkerIdentity.validateSignedResources(tampered, bundleURL: appex, signatureHash: signature.hash),
                             "A valid bundle signature must not authorize different in-memory bytes")
        Settings.userAgent = "Vane Signed Worker/1.0"
        let host = ExtensionHost.host(for: profile)
        #if DEBUG
        host.backgroundCreationObserver = { web, _ in web.customUserAgent = "Vane Wrong Signed Native Worker/0" }
        #endif
        let accepted = try await host.load(app, installing: true) { _ in true }
        XCTAssertTrue(accepted)
        let context = try XCTUnwrap(host.installed.first)
        let web = try await options(context)
        let reply = try await web.callAsyncJavaScript("return await browser.runtime.sendMessage('identity');",
                                                     arguments: [:], in: nil, contentWorld: .page) as? [String: String]
        XCTAssertEqual(reply?["ua"], "Vane Signed Worker/1.0")
        XCTAssertEqual(reply?["id"], extensionID + " (\(team!))")
        XCTAssertEqual(try store.resources(in: resourceURL), resources, "Signed source bytes must remain unchanged")
        XCTAssertNoThrow(try SafariExtensionSource.verify(appex))
    }

    func testSignedSafariAppLoadsReviewedIdentityAndRoutesExternalHandoffInRealTab() async throws {
        let host = ExtensionHost.host(for: profile)
        var reviews = 0
        let accepted = try await host.load(app, installing: true) { request in
            reviews += 1; XCTAssertTrue(request.installing); return true
        }
        XCTAssertTrue(accepted); XCTAssertEqual(reviews, 1)
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(context.uniqueIdentifier, extensionID + " (\(team!))")
        XCTAssertFalse(context.uniqueIdentifier.contains("IMPERSONATE"))
        let store = TabStore(profileID: profile, session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; store.window = window
        stores.append(store); windows.append(window)
        let tab = store.newBlankTab()
        let web = tab.web
        window.contentView = web
        host.sync()
        web.loadHTMLString("<title>Local sign-in handoff</title>", baseURL: URL(string: "https://handoff.example.test/auth"))
        let deadline = ContinuousClock.now + .seconds(10)
        while web.isLoading || web.title != "Local sign-in handoff" {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Local handoff page timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await web.callAsyncJavaScript("return await browser.runtime.sendMessage(id, {nonce:'local-handoff-fixture'});",
            arguments: ["id": extensionID + " (\(team!))"], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["received"] as? String, "local-handoff-fixture")
        XCTAssertEqual(result?["id"] as? String, extensionID + " (\(team!))")
    }

    func testDecliningAppInstallDoesNotPersistOrExecute() async throws {
        let host = ExtensionHost.host(for: profile)
        let accepted = try await host.load(app, installing: true) { _ in false }
        XCTAssertFalse(accepted)
        XCTAssertTrue(host.installed.isEmpty); XCTAssertTrue(host.entries.isEmpty)
    }

    func testAppUpdateRequiresReviewAndKeepsIdentityAndOrigin() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let old = try XCTUnwrap(host.installed.first), path = try XCTUnwrap(host.entries.first?.path)
        try write(version: "2.0", permissions: ["storage", "cookies"])
        let declined = try await host.refresh(path) { review in
            XCTAssertEqual(review.candidateVersion, "2.0"); XCTAssertTrue(review.updating)
            XCTAssertTrue(review.requested.permissions.contains("cookies")); return false
        }
        XCTAssertFalse(declined)
        XCTAssertTrue(host.installed.first === old)
        let updated = try await host.refresh(path) { _ in true }
        XCTAssertTrue(updated)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, old.uniqueIdentifier)
        XCTAssertEqual(host.installed.first?.baseURL, old.baseURL)
        XCTAssertEqual(host.installed.first?.webExtension.version, "2.0")
    }

    func testModifiedSignedResourcesAreRejectedBeforeReview() async throws {
        try Data("tampered".utf8).write(to: appex.appendingPathComponent("Contents/Resources/background.js"))
        let host = ExtensionHost.host(for: profile)
        do { _ = try await host.load(app, installing: true) { _ in XCTFail("Signature failure must precede consent"); return true }; XCTFail("Tampered bundle accepted") }
        catch { }
        XCTAssertTrue(host.installed.isEmpty); XCTAssertTrue(host.entries.isEmpty)
    }
    func testDuplicateAppCopyUpdatesSingleInstallation() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let identity = try XCTUnwrap(host.installed.first?.uniqueIdentifier)
        let origin = try XCTUnwrap(host.installed.first?.baseURL)
        let copy = root.appendingPathComponent("Duplicate.app")
        try FileManager.default.copyItem(at: app, to: copy)
        _ = try await host.load(copy, installing: true) { _ in true }
        XCTAssertEqual(host.entries.count, 1)
        XCTAssertEqual(host.installed.count, 1)
        XCTAssertEqual(host.installed.first?.uniqueIdentifier, identity)
        XCTAssertEqual(host.installed.first?.baseURL, origin)
    }

    func testAcceptedSafariAppRestoresIdentityAndPersistentStorage() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let original = try XCTUnwrap(host.installed.first)
        var web: WKWebView? = try await options(original)
        _ = try await web!.callAsyncJavaScript("await browser.storage.local.set({restored:'accepted-install'}); return true;", arguments: [:], in: nil, contentWorld: .page)
        web = nil
        ExtensionHost.forget(profile)
        let restored = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(10)
        while restored.isBusy {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Accepted-app restore timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let current = try XCTUnwrap(restored.installed.first)
        XCTAssertEqual(current.uniqueIdentifier, original.uniqueIdentifier)
        XCTAssertEqual(current.baseURL, original.baseURL)
        web = try await options(current)
        let value = try await web!.callAsyncJavaScript("return (await browser.storage.local.get('restored')).restored;", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "accepted-install")
        web?.stopLoading()
    }

    func testMissingInstalledAppFailsClosedOnRestoreAndRetainsRecoveryEntry() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let path = try XCTUnwrap(host.entries.first?.path)
        ExtensionHost.forget(profile)
        try FileManager.default.removeItem(at: app)
        let restored = ExtensionHost.host(for: profile)
        let deadline = ContinuousClock.now + .seconds(10)
        while restored.isBusy {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Missing-app restore timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(restored.installed.isEmpty)
        XCTAssertEqual(restored.entries.first?.path, path)
        XCTAssertNotNil(restored.entries.first?.failure)
    }

    func testAdHocAppCannotClaimAnotherSigningTeam() async throws {
        try run("/usr/bin/codesign", ["--force", "--sign", "-", appex.path])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let host = ExtensionHost.host(for: profile)
        do { _ = try await host.load(app, installing: true) { _ in XCTFail("Ad-hoc identity cannot reach review"); return true }; XCTFail("Ad-hoc app accepted") }
        catch { }
        XCTAssertTrue(host.entries.isEmpty)
    }

    private func options(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(10)
        while web.isLoading || web.title != "Signed Safari fixture" {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Safari options timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
        return web
    }

    func testReinstallUsesSafariIdentityWithoutInheritingRemovedExtensionStorage() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let original = try XCTUnwrap(host.installed.first)
        var web: WKWebView? = try await options(original)
        _ = try await web!.callAsyncJavaScript("""
            await browser.storage.local.set({previous:'old-install'});
            await browser.storage.sync.set({previous:'old-install'});
            await browser.storage.session.set({previous:'old-install'}); return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        web = nil
        try host.remove(folder: XCTUnwrap(host.entries.first?.path))
        _ = try await host.load(app, installing: true) { _ in true }
        let current = try XCTUnwrap(host.installed.first)
        XCTAssertEqual(current.uniqueIdentifier, original.uniqueIdentifier)
        XCTAssertNotEqual(current.baseURL, original.baseURL)
        web = try await options(current)
        let value = try await web!.callAsyncJavaScript("""
            const values = await Promise.all([browser.storage.local, browser.storage.sync, browser.storage.session]
                .map(async store => (await store.get('previous')).previous ?? 'empty'));
            return values.join(',');
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "empty,empty,empty")
        web?.stopLoading()
    }

    func testCorruptAppMetadataCanBeReviewedAndRepairedWithoutChangingOrigin() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let origin = try XCTUnwrap(host.installed.first?.baseURL)
        ExtensionHost.forget(profile)
        let store = ExtensionCodeStore(profileID: profile)
        try Data("broken".utf8).write(to: store.root.appendingPathComponent("installations.json"))
        let restored = ExtensionHost.host(for: profile)
        XCTAssertTrue(restored.installed.isEmpty)
        var reviews = 0
        _ = try await restored.load(app, installing: true) { request in
            reviews += 1; XCTAssertTrue(request.updating); return true
        }
        XCTAssertEqual(reviews, 1)
        XCTAssertEqual(restored.installed.first?.baseURL, origin)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix("metadata-recovery-") })
    }

    func testSameSafariRuntimeIdentityHasSeparateProfileStorage() async throws {
        let first = ExtensionHost.host(for: profile)
        let secondProfile = UUID()
        ownedProfiles.insert(secondProfile)
        let second = ExtensionHost.host(for: secondProfile)
        defer {
            for entry in second.entries { try? second.remove(folder: entry.path) }
            ExtensionHost.forget(second.profileID)
        }
        _ = try await first.load(app, installing: true) { _ in true }
        _ = try await second.load(app, installing: true) { _ in true }
        let firstContext = try XCTUnwrap(first.installed.first), secondContext = try XCTUnwrap(second.installed.first)
        XCTAssertEqual(firstContext.uniqueIdentifier, secondContext.uniqueIdentifier)
        let firstWeb = try await options(firstContext), secondWeb = try await options(secondContext)
        _ = try await firstWeb.callAsyncJavaScript("await browser.storage.local.set({profileMarker:'first-profile'}); return true;", arguments: [:], in: nil, contentWorld: .page)
        let value = try await secondWeb.callAsyncJavaScript("return (await browser.storage.local.get('profileMarker')).profileMarker ?? 'isolated';", arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(value as? String, "isolated")
        firstWeb.stopLoading(); secondWeb.stopLoading()
    }

    func testRemoveDuringAppRefreshPreflightCannotResurrectInstallation() async throws {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(app, installing: true) { _ in true }
        let path = try XCTUnwrap(host.entries.first?.path)
        // Keep genuine signature resolution pending long enough to exercise the
        // preflight boundary rather than only the later staging/activation operation.
        try Data(repeating: 0x61, count: 16 * 1024 * 1024)
            .write(to: appex.appendingPathComponent("Contents/Resources/preflight.bin"))
        try write(version: "2.0")
        var started = false, reviews = 0
        let update = Task { @MainActor in
            started = true
            return try await host.refresh(path) { _ in reviews += 1; return true }
        }
        while !started { await Task.yield() }
        XCTAssertTrue(host.isBusy, "Signed source preflight must reserve the installation before awaiting verification")
        try host.remove(folder: path)
        do { _ = try await update.value; XCTFail("Removed installation’s preflight should be cancelled") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation after removal, got \(error)") }
        XCTAssertEqual(reviews, 0, "A removed installation cannot request update consent")
        XCTAssertTrue(host.entries.isEmpty)
        XCTAssertTrue(host.installed.isEmpty)
        XCTAssertTrue(try ExtensionCodeStore(profileID: profile).records().isEmpty)
    }

    #if DEBUG
    func testDisabledModeChangeInvalidatesEarlierVerifiedSafariDiscovery() async throws {
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let host = ExtensionHost.host(for: profile)
        let gate = VerifiedSafariDiscoveryGate()
        var discovery: Task<Bool, any Error>?
        var failure: (any Error)?
        do {
            try write(version: "1.0", permissions: ["storage", "nativeMessaging"])
            _ = try await host.load(app, installing: true) { _ in true }
            let path = try XCTUnwrap(host.entries.first?.path)
            try host.disable(path)
            let store = ExtensionCodeStore(profileID: profile)
            let before = try XCTUnwrap(store.records()[path])
            host.safariDiscoveryDidVerify = { await gate.enter() }
            let operation = Task { @MainActor in
                try await host.load(self.app, installing: true) { _ in
                    XCTFail("A stale discovery cannot reach another access review"); return true
                }
            }
            discovery = operation
            let deadline = ContinuousClock.now + .seconds(5)
            while !gate.entered {
                guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Verified Safari discovery did not enter its admission boundary") }
                await Task.yield()
            }
            let accepted = try await host.setNativeMessagingErrorCompatibility(true, for: path) { _ in true }
            XCTAssertTrue(accepted)
            let approvedIndex = try Data(contentsOf: store.root.appendingPathComponent("installations.json"))
            let changed = try XCTUnwrap(store.records()[path])
            XCTAssertEqual(changed.identity, before.identity)
            XCTAssertEqual(changed.revision, before.revision)
            XCTAssertEqual(changed.nativeMessagingErrorCompatibilityVersion, 1)
            XCTAssertTrue(host.installed.isEmpty)
            gate.release()
            do { _ = try await operation.value; XCTFail("A mode change must invalidate earlier signed discovery even while disabled") }
            catch is CancellationError { }
            catch { XCTFail("Expected stale-discovery cancellation, got \(error)") }
            XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent("installations.json")), approvedIndex)
            XCTAssertTrue(host.installed.isEmpty)
            XCTAssertEqual(host.entries.first?.status, "Disabled")
        } catch { failure = error }
        host.safariDiscoveryDidVerify = nil
        gate.release()
        if let discovery { discovery.cancel(); _ = try? await discovery.value }
        for entry in host.entries { try? host.remove(folder: entry.path) }
        ExtensionHost.forget(profile)
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Signed discovery loop cleanup: \(error)") } }
        if let failure { throw failure }
    }

    @MainActor private final class VerifiedSafariDiscoveryGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?
        func enter() async {
            await withCheckedContinuation { continuation in
                entered = true
                self.continuation = continuation
            }
        }
        func release() {
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }
    #endif

}
