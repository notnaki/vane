import AppKit
import WebKit
import XCTest
@testable import vane

/// A public-API boundary probe, independent of ExtensionHost, package rewriting,
/// private WebKit selectors, native messaging, and the user's extension stores.
@MainActor final class ICloudExtensionBoundaryTests: XCTestCase {
    private struct ProbeFailure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private final class Reply<Value> {
        var result: Result<Value, any Error>?
    }

    private final class Navigation: NSObject, WKNavigationDelegate {
        var finished = false
        var error: (any Error)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { self.error = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { self.error = error }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            error = ProbeFailure(message: "The synthetic extension page's web process terminated.")
        }
    }

    private func wait(_ stage: String, until deadline: ContinuousClock.Instant,
                      condition: () throws -> Bool) async throws {
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw ProbeFailure(message: "Extension boundary probe timed out: \(stage)") }
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func call(_ view: WKWebView, _ source: String, arguments: [String: Any] = [:],
                      until deadline: ContinuousClock.Instant) async throws -> [String: Any] {
        guard ContinuousClock.now < deadline else { throw ProbeFailure(message: "Extension boundary deadline expired before JavaScript admission.") }
        let reply = Reply<Any>()
        view.callAsyncJavaScript(source, arguments: arguments, in: nil, in: .page) { reply.result = $0 }
        try await wait("public callAsyncJavaScript reply", until: deadline) { reply.result != nil }
        let value = try XCTUnwrap(reply.result).get()
        print("ICLOUD_BOUNDARY_CALL source=\(source.prefix(90)) type=\(String(reflecting: type(of: value))) value=\(value)")
        let string = try XCTUnwrap(value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    func testUnshownSyntheticExtensionPageCanRoundTripOnlySyncStorageForWorkerOnlyExtension() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let originalPolicy = app.activationPolicy()
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vane-icloud-extension-boundary-\(UUID())")
        var controller: WKWebExtensionController?
        var context: WKWebExtensionContext?
        var view: WKWebView?
        var failure: (any Error)?
        do {
            let deadline = ContinuousClock.now + .seconds(20)
            let nonce = UUID().uuidString
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "manifest_version": 3, "name": "Synthetic iCloud boundary", "version": "1.0",
                "description": "Isolated public extension storage boundary fixture",
                "permissions": ["storage"], "background": ["service_worker": "worker.js"]
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
            try Data("""
                browser.runtime.onMessage.addListener(async message => {
                    if (message.kind !== 'vane-sync-boundary') return;
                    return {runtimeID: browser.runtime.id,
                        sync: await browser.storage.sync.get(null),
                        local: await browser.storage.local.get(null),
                        session: await browser.storage.session.get(null)};
                });
                """.utf8).write(to: folder.appendingPathComponent("worker.js"))

            let parsed = Reply<WKWebExtension>()
            let parsing = Task { @MainActor in
                do {
                    let ext = try await WKWebExtension(resourceBaseURL: folder)
                    try Task.checkCancellation()
                    parsed.result = .success(ext)
                } catch { parsed.result = .failure(error) }
            }
            defer { parsing.cancel() }
            try await wait("synthetic extension parsing", until: deadline) { parsed.result != nil }
            let ext = try XCTUnwrap(parsed.result).get()
            let manifestDiagnostics = ext.errors.map { error -> String in
                let value = error as NSError
                return "domain=\(value.domain), code=\(value.code), description=\(value.localizedDescription)"
            }
            print("ICLOUD_EXTENSION_MANIFEST_DIAGNOSTICS \(manifestDiagnostics)")
            XCTAssertTrue(ext.errors.isEmpty, "The probe must begin with a valid synthetic manifest: \(manifestDiagnostics)")

            let isolated = WKWebsiteDataStore.nonPersistent()
            let configuration = WKWebExtensionController.Configuration.nonPersistent()
            configuration.defaultWebsiteDataStore = isolated
            configuration.webViewConfiguration.websiteDataStore = isolated
            let owner = WKWebExtensionController(configuration: configuration)
            controller = owner
            let loaded = WKWebExtensionContext(for: ext)
            context = loaded
            // This probe's page and worker use only an isolated ephemeral store.
            loaded.hasAccessToPrivateData = true
            loaded.uniqueIdentifier = UUID().uuidString.lowercased()
            loaded.baseURL = URL(string: "webkit-extension://\(UUID().uuidString.lowercased())/")!
            loaded.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "storage"))
            loaded.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "nativeMessaging"))
            try owner.load(loaded)
            XCTAssertNil(loaded.optionsPageURL, "This path must work without a declared extension page")
            XCTAssertFalse(configuration.isPersistent)
            let pageConfiguration = try XCTUnwrap(loaded.webViewConfiguration)
            XCTAssertFalse(pageConfiguration.websiteDataStore.isPersistent)
            let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16), configuration: pageConfiguration)
            view = page
            page.isHidden = true
            let navigation = Navigation()
            page.navigationDelegate = navigation
            let synthetic = loaded.baseURL.appendingPathComponent("__vane_host_sync_probe__.html")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(synthetic.lastPathComponent).path))
            XCTAssertNotNil(page.loadHTMLString("<!doctype html><title>Host sync boundary ready</title><p>Synthetic host document</p>", baseURL: synthetic))
            try await wait("synthetic extension document didFinish", until: deadline) {
                if let error = navigation.error { throw error }
                return navigation.finished && !page.isLoading && page.title == "Host sync boundary ready"
            }
            XCTAssertNil(page.window, "The probe must not display or activate a window")
            let document = try await call(page, """
                return JSON.stringify({ready: document.readyState, href: location.href, base: document.baseURI,
                    origin: location.origin, runtimeID: typeof browser === 'object' ? browser.runtime?.id : null,
                    sync: typeof browser === 'object' ? typeof browser.storage?.sync : 'missing'});
                """, until: deadline)
            print("ICLOUD_EXTENSION_PUBLIC_BOUNDARY \(document)")
            XCTAssertEqual(document["ready"] as? String, "complete")
            XCTAssertEqual(document["runtimeID"] as? String, loaded.uniqueIdentifier)
            XCTAssertEqual(document["sync"] as? String, "object")
            guard document["runtimeID"] as? String == loaded.uniqueIdentifier,
                  document["sync"] as? String == "object" else {
                throw ProbeFailure(message: "An unshown loadHTMLString document did not receive extension storage APIs: \(document)")
            }

            let startup = Reply<Void>()
            loaded.loadBackgroundContent { error in
                Task { @MainActor in
                    if let error { startup.result = .failure(error) }
                    else { startup.result = .success(()) }
                }
            }
            try await wait("worker background completion", until: deadline) { startup.result != nil }
            try XCTUnwrap(startup.result).get()
            let captured = try await call(page, """
                await browser.storage.local.set({localOnly: nonce});
                await browser.storage.session.set({sessionOnly: nonce});
                await browser.storage.sync.set({portable: nonce});
                return JSON.stringify(await browser.storage.sync.get(null));
                """, arguments: ["nonce": nonce], until: deadline)
            XCTAssertEqual(captured as? [String: String], ["portable": nonce], "Only the sync namespace is exported")
            let remote = "remote-" + nonce
            let applied = try await call(page, """
                await browser.storage.sync.clear();
                await browser.storage.sync.set(incoming);
                return JSON.stringify({sync: await browser.storage.sync.get(null),
                    local: await browser.storage.local.get(null), session: await browser.storage.session.get(null)});
                """, arguments: ["incoming": ["portable": remote]], until: deadline)
            XCTAssertEqual(applied["sync"] as? [String: String], ["portable": remote])
            XCTAssertEqual(applied["local"] as? [String: String], ["localOnly": nonce])
            XCTAssertEqual(applied["session"] as? [String: String], ["sessionOnly": nonce])
            let worker = try await call(page, """
                return JSON.stringify(await browser.runtime.sendMessage({kind: 'vane-sync-boundary'}));
                """, until: deadline)
            XCTAssertEqual(worker["runtimeID"] as? String, loaded.uniqueIdentifier)
            XCTAssertEqual(worker["sync"] as? [String: String], ["portable": remote], "The synthetic host page and actual MV3 worker must share sync storage")
            XCTAssertEqual(worker["local"] as? [String: String], ["localOnly": nonce])
            XCTAssertEqual(worker["session"] as? [String: String], ["sessionOnly": nonce])
        } catch {
            print("ICLOUD_BOUNDARY_CONTEXT_ERRORS \(String(describing: context?.errors))")
            failure = error
        }

        // Retire the exact view and context before joining the owned AppKit loop.
        view?.stopLoading()
        view?.navigationDelegate = nil
        view?.uiDelegate = nil
        view?.removeFromSuperview()
        view = nil
        if let owner = controller, let loaded = context, loaded.isLoaded {
            do { try owner.unload(loaded) }
            catch { if failure == nil { failure = error } else { XCTFail("Boundary context cleanup also failed: \(error)") } }
            XCTAssertFalse(loaded.isLoaded)
            XCTAssertTrue(owner.extensionContexts.isEmpty)
        }
        context = nil
        controller = nil
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) }
            catch { if failure == nil { failure = error } else { XCTFail("Boundary files cleanup also failed: \(error)") } }
        }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Boundary AppKit loop cleanup also failed: \(error)") } }
        XCTAssertEqual(app.activationPolicy(), originalPolicy)
        if let failure { throw failure }
    }
}
