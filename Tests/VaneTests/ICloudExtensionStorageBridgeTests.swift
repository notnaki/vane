import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ICloudExtensionStorageBridgeTests: XCTestCase {
    private final class Parsed {
        var result: Result<WKWebExtension, any Error>?
    }
    private final class Admission { var valid = true }
    private final class Navigation: NSObject, WKNavigationDelegate {
        var finished = false
        var error: (any Error)?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { self.error = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { self.error = error }
    }
    private final class Reply { var result: Result<Any, any Error>? }

    func testProductionPublicBridgeUsesSelectedKeysAndRejectsRevokedLease() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let loop = try await NativeFixtureApplicationLoop.acquire()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vane-storage-bridge-\(UUID())")
        var owner: WKWebExtensionController?
        var context: WKWebExtensionContext?
        var bridges: [ICloudExtensionStorageBridge] = []
        var controlPage: WKWebView?
        var failure: (any Error)?
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "Public storage bridge fixture",
                "description": "Tests only synthetic storage", "version": "1.0", "permissions": ["storage"]])
                .write(to: folder.appendingPathComponent("manifest.json"))
            let parsed = Parsed()
            let task = Task { @MainActor in
                do { parsed.result = .success(try await WKWebExtension(resourceBaseURL: folder)) }
                catch { parsed.result = .failure(error) }
            }
            defer { task.cancel() }
            let deadline = ContinuousClock.now + .seconds(5)
            while parsed.result == nil {
                guard ContinuousClock.now < deadline else { throw ICloudFailure.unavailable("Synthetic bridge manifest parsing timed out") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let ext = try XCTUnwrap(parsed.result).get()
            XCTAssertTrue(ext.errors.isEmpty)
            let isolated = WKWebsiteDataStore.nonPersistent()
            let configuration = WKWebExtensionController.Configuration.nonPersistent()
            configuration.defaultWebsiteDataStore = isolated
            configuration.webViewConfiguration.websiteDataStore = isolated
            let controller = WKWebExtensionController(configuration: configuration)
            owner = controller
            let loaded = WKWebExtensionContext(for: ext)
            context = loaded
            loaded.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "storage"))
            loaded.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "nativeMessaging"))
            try controller.load(loaded)
            let ns = ICloudExtensionNamespace(profileID: UUID(), extensionID: UUID().uuidString.lowercased())
            let admission = Admission()
            let lease = ICloudExtensionStorageLease(namespace: ns, installationID: UUID().uuidString,
                context: loaded, check: { guard admission.valid else { throw CancellationError() } })
            let bridge = ICloudExtensionStorageBridge(lease: lease)
            bridges.append(bridge)
            let first = try await bridge.read()
            XCTAssertTrue(first.isEmpty)
            let keep = try JSONEncoder().encode("retain"), original = try JSONEncoder().encode("first")
            _ = try await bridge.apply([ICloudExtensionStorageMutation(key: "keep", value: keep, expected: .unknown)])
            _ = try await bridge.apply([ICloudExtensionStorageMutation(key: "theme", value: original, expected: .unknown)])
            let newer = try JSONEncoder().encode("new")
            let conditional = try await bridge.apply([
                ICloudExtensionStorageMutation(key: "theme", value: newer, expected: .value(try JSONEncoder().encode("stale")))])
            XCTAssertEqual(conditional["theme"], original, "A changed local value must survive a stale expected value")
            let removed = try await bridge.apply([ICloudExtensionStorageMutation(key: "theme", value: nil, expected: .unknown)])
            XCTAssertNil(removed["theme"])
            XCTAssertEqual(removed["keep"], keep, "A key tombstone must not clear the namespace")
            admission.valid = false
            do {
                _ = try await bridge.apply([ICloudExtensionStorageMutation(key: "keep", value: newer, expected: .unknown)])
                XCTFail("A revoked lease must not enqueue public storage IPC")
            } catch { }
            bridge.close()
            let verifier = ICloudExtensionStorageBridge(lease: ICloudExtensionStorageLease(namespace: ns,
                installationID: lease.installationID, context: loaded, check: {}))
            bridges.append(verifier)
            let retained = try await verifier.read()
            XCTAssertEqual(retained["keep"], keep)
            let prototypeValues: [Any] = ["ordinary data", 42, true, NSNull(),
                ["nested", 7], ["__proto__": ["polluted": true], "constructor": "plain data"]]
            _ = try await verifier.apply([.init(key: "proto", value: keep, expected: .unknown)])
            for value in prototypeValues {
                let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                let result = try await verifier.apply([.init(key: "__proto__", value: encoded, expected: .unknown)])
                XCTAssertEqual(result["__proto__"], encoded, "The literal key must round-trip every JSON value")
                XCTAssertEqual(result["proto"], keep, "Literal proto and __proto__ are distinct keys")
                XCTAssertEqual(result["keep"], keep)
            }
            let latest = try JSONSerialization.data(withJSONObject: prototypeValues.last!, options: [.sortedKeys])
            let stale = try await verifier.apply([.init(key: "__proto__", value: original, expected: .value(keep))])
            XCTAssertEqual(stale["__proto__"], latest, "The special key must preserve an intervening local value")
            let fresh = ICloudExtensionStorageBridge(lease: ICloudExtensionStorageLease(namespace: ns,
                installationID: lease.installationID, context: loaded, check: {}))
            bridges.append(fresh)
            let acrossPages = try await fresh.read()
            XCTAssertEqual(acrossPages["__proto__"], latest, "The value must live in native storage, not a page shadow")

            // A vendor page in the same extension keeps ordinary JavaScript semantics.
            let control = WKWebView(frame: CGRect(x: 0, y: 0, width: 16, height: 16),
                configuration: try XCTUnwrap(loaded.webViewConfiguration))
            controlPage = control; control.isHidden = true
            let navigation = Navigation(); control.navigationDelegate = navigation
            XCTAssertNotNil(control.loadHTMLString("<!doctype html><title>Realm control</title>",
                baseURL: loaded.baseURL.appendingPathComponent("realm-control.html")))
            let readyDeadline = ContinuousClock.now + .seconds(5)
            while !navigation.finished || control.isLoading || control.title != "Realm control" {
                if let error = navigation.error { throw error }
                guard ContinuousClock.now < readyDeadline else { throw ICloudFailure.unavailable("Control realm did not load") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let reply = Reply()
            control.callAsyncJavaScript("""
                const value = {}, prototype = {fixture:true};
                value.__proto__ = prototype;
                return JSON.stringify({changed:Object.getPrototypeOf(value) === prototype,
                    own:Object.hasOwn(value,'__proto__'),polluted:Object.hasOwn(Object.prototype,'polluted')});
                """, arguments: [:], in: nil, in: .page) { reply.result = $0 }
            let replyDeadline = ContinuousClock.now + .seconds(5)
            while reply.result == nil {
                guard ContinuousClock.now < replyDeadline else { throw ICloudFailure.unavailable("Control realm did not reply") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let controlJSON = try XCTUnwrap(try XCTUnwrap(reply.result).get() as? String)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(controlJSON.utf8)) as? [String: Bool])
            XCTAssertEqual(result, ["changed": true, "own": false, "polluted": false],
                "Host serialization compatibility must not alter vendor realms")
            let afterRemoval = try await verifier.apply([.init(key: "__proto__", value: nil, expected: .unknown)])
            XCTAssertNil(afterRemoval["__proto__"])
            XCTAssertEqual(afterRemoval["proto"], keep)
            XCTAssertEqual(afterRemoval["keep"], keep)

        } catch { failure = error }
        controlPage?.stopLoading(); controlPage?.navigationDelegate = nil; controlPage = nil
        for bridge in bridges { bridge.close() }
        bridges = []
        if let owner, let context, context.isLoaded {
            do { try owner.unload(context) }
            catch { if failure == nil { failure = error } else { XCTFail("Storage bridge context cleanup also failed: \(error)") } }
            XCTAssertFalse(context.isLoaded)
            XCTAssertTrue(owner.extensionContexts.isEmpty)
        }
        context = nil; owner = nil
        if FileManager.default.fileExists(atPath: folder.path) {
            do { try FileManager.default.removeItem(at: folder) }
            catch { if failure == nil { failure = error } else { XCTFail("Storage bridge file cleanup also failed: \(error)") } }
        }
        do { try await loop.close() }
        catch { if failure == nil { failure = error } else { XCTFail("Storage bridge loop cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }
}
