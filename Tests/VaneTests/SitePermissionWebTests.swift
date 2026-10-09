import AppKit
import Darwin
import WebKit
import XCTest
@testable import vane

/// All devices are WebKit's synthetic test sources; no camera, microphone, or screen
/// is opened and no system authorization settings are changed by these fixtures.
@MainActor final class SitePermissionWebTests: XCTestCase {
    private var tab: Tab!
    private var window: NSWindow!
    private var server: CompatibilityServer!
    private var profile = UUID()
    private var recorder: PermissionFrameRecorder!
    private var decision: Task<WKPermissionDecision, Never>?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        let configuration = Tab.configuration(profileID: profile)
        let preferences = configuration.preferences
        // Test-only WebKit SPI selects fake devices. Production uses public APIs only.
        XCTAssertTrue(preferences.responds(to: NSSelectorFromString("_setMockCaptureDevicesEnabled:")))
        preferences.setValue(true, forKey: "mockCaptureDevicesEnabled")
        preferences.setValue(false, forKey: "getUserMediaRequiresFocus")
        preferences.setValue(true, forKey: "mockCaptureDevicesPromptEnabled")
        tab = Tab(popup: configuration, isPrivate: false, profileID: profile)
        recorder = PermissionFrameRecorder()
        let controller = tab.web.configuration.userContentController
        controller.add(recorder, name: "permissionFixture")
        controller.addUserScript(WKUserScript(source: "webkit.messageHandlers.permissionFixture.postMessage(location.host)",
                                            injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
        server = try CompatibilityServer()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        tab.existingWeb?.configuration.userContentController.removeScriptMessageHandler(forName: "permissionFixture")
        tab.tearDown()
        if let decision { _ = await decision.value }
        decision = nil; recorder = nil
        SitePermissions.resetAll(profileID: profile)
        window.close()
        server.stop()
        tab = nil; window = nil; server = nil
    }

    private var mediaScript: String {
        """
        window.request = () => {
          window.result = 'pending';
          navigator.mediaDevices.getUserMedia({video:true,audio:true}).then(s => {
            window.stream = s; window.result = 'granted';
          }).catch(e => { window.result = e.name; });
        };
        """
    }

    private func load(_ html: String, path: String = "/media") async throws {
        server.pages[path] = "<title>Permission fixture</title>" + html
        tab.go(try server.url(path))
        try await compatibilityWait { self.tab.web.title == "Permission fixture" && !self.tab.web.isLoading }
    }

    private func evaluate(_ code: String, frame: WKFrameInfo? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.web.evaluateJavaScript(code, in: frame, in: .page) { result in
                continuation.resume(with: result.map { _ in () })
            }
        }
    }

    private func start(frame: WKFrameInfo? = nil) async throws {
        try await evaluate("request()", frame: frame)
        try await compatibilityWait { self.window.attachedSheet != nil }
    }

    private func answer(_ response: NSApplication.ModalResponse) throws {
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: response)
    }

    private func granted() async throws {
        try await compatibilityWait {
            let result = try await self.tab.web.evaluateJavaScript("window.result") as? String
            if result != "pending" && result != "granted" { throw NSError(domain: "MediaFixture-\(result ?? "missing")", code: 1) }
            return result == "granted"
        }
        XCTAssertEqual(tab.web.cameraCaptureState, .active)
        XCTAssertEqual(tab.web.microphoneCaptureState, .active)
    }

    func testAskRevokesActiveCameraAndPreservesMicrophone() async throws {
        try await load("<script>\(mediaScript)</script>")
        try await start()
        try answer(.alertSecondButtonReturn)
        try await granted()
        SiteControl.set(.camera, to: nil, on: tab)
        try await compatibilityWait { self.tab.web.cameraCaptureState == .none }
        let states = try await tab.web.evaluateJavaScript("stream.getTracks().map(t => t.kind + ':' + t.readyState).sort()") as? [String]
        XCTAssertEqual(states, ["audio:live", "video:ended"])
        XCTAssertEqual(tab.web.microphoneCaptureState, .active)
    }

    func testEmbeddedCaptureIsDeniedEvenWithSavedAllowForEitherOrigin() async throws {
        let child = try server.url("/child", host: "localhost")
        server.pages["/child"] = "<script>\(mediaScript)</script>"
        try await load("<iframe allow='camera *; microphone *' src='\(child.absoluteString)'></iframe>")
        try await compatibilityWait { self.recorder.frames[child.host()! + ":" + String(self.server.port!)] != nil }
        let frame = try XCTUnwrap(recorder.frames[child.host()! + ":" + String(server.port!)])
        let childScope = SitePermissions.Scope(url: child, profileID: profile)!
        let topScope = try XCTUnwrap(SitePermissions.scope(for: tab))
        SitePermissions.remember(scope: childScope, type: .cameraAndMicrophone, allow: true)
        SitePermissions.remember(scope: topScope, type: .cameraAndMicrophone, allow: true)
        try await evaluate("request()", frame: frame)
        try await compatibilityWait { try await self.value("window.result", frame: frame) == "NotAllowedError" }
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(tab.web.cameraCaptureState, .none)
        XCTAssertEqual(tab.web.microphoneCaptureState, .none)
    }

    private func value(_ code: String, frame: WKFrameInfo) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            tab.web.evaluateJavaScript(code, in: frame, in: .page) { result in
                continuation.resume(with: result.map { $0 as? String })
            }
        }
    }

    func testSameURLReplacedEmbeddedFrameCannotPresentOrSaveLatePermission() async throws {
        let child = try server.url("/child", host: "localhost")
        server.pages["/child"] = "<p>frame</p>"
        try await load("<iframe src='\(child.absoluteString)'></iframe>")
        let host = child.host()! + ":" + String(server.port!)
        try await compatibilityWait { self.recorder.frames[host] != nil }
        let oldFrame = try XCTUnwrap(recorder.frames[host])
        recorder.frames.removeValue(forKey: host)
        try await evaluate("document.querySelector('iframe').src = document.querySelector('iframe').src")
        try await compatibilityWait { self.recorder.frames[host] != nil }
        let main = try XCTUnwrap(recorder.mainFrame)
        var result: WKPermissionDecision?
        tab.webView(tab.web, requestMediaCapturePermissionFor: main.securityOrigin, initiatedByFrame: oldFrame,
                    type: .camera, decisionHandler: { result = $0 })
        XCTAssertEqual(result, .deny)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(SitePermissions.all(profileID: profile).isEmpty)
    }

    func testMainFrameNavigationBeforeInitialSnapshotCannotSavePermission() async throws {
        try await load("<p>original</p>")
        let main = try XCTUnwrap(recorder.mainFrame)
        decision = Task { await withCheckedContinuation { continuation in
            self.tab.webView(self.tab.web, requestMediaCapturePermissionFor: main.securityOrigin,
                             initiatedByFrame: main, type: .camera) { decision in
                // Invalidate synchronously before the handler's Task gets its first turn.
                continuation.resume(returning: decision)
            }
            self.tab.endPermissionDocument()
        } }
        let result = await decision!.value
        XCTAssertEqual(result, .deny)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(SitePermissions.all(profileID: profile).isEmpty)
    }

    func testAllowOnceExpiresAfterNavigationAndRejectionCannotStartCapture() async throws {
        let html = "<script>\(mediaScript)</script>"
        try await load(html)
        try await start()
        try answer(.alertFirstButtonReturn)
        try await granted()
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertNil(SitePermissions.remembered(scope: scope, type: .cameraAndMicrophone))
        try await load(html, path: "/next")
        try await compatibilityWait { self.tab.web.cameraCaptureState == .none && self.tab.web.microphoneCaptureState == .none }
        try await start()
        try answer(.alertThirdButtonReturn)
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("window.result") as? String == "NotAllowedError" }
        XCTAssertEqual(SitePermissions.effective(scope: scope, type: .cameraAndMicrophone), false)
    }

    func testPersistentAllowSurvivesNavigationWithoutAnotherSheet() async throws {
        let html = "<script>\(mediaScript)</script>"
        try await load(html)
        try await start()
        try answer(.alertSecondButtonReturn)
        try await granted()
        try await load(html, path: "/next")
        try await evaluate("request()")
        try await granted()
        XCTAssertNil(window.attachedSheet)
    }

    func testClosingPromptWindowPreservesCaptureOwnerWhenDocumentMovesToAnotherWindow() async throws {
        try await load("<script>\(mediaScript)</script>")
        try await start()
        try answer(.alertFirstButtonReturn)
        try await granted()
        SiteControl.set(.microphone, to: nil, on: tab)
        try await compatibilityWait { self.tab.web.microphoneCaptureState == .none }
        try await evaluate("navigator.mediaDevices.getUserMedia({audio:true}).catch(e => { window.micResult = e.name; }); true;")
        try await compatibilityWait { self.window.attachedSheet != nil }
        let original = window!
        original.close()
        let replacement = NSWindow(contentRect: original.frame, styleMask: [.titled], backing: .buffered, defer: false)
        replacement.isReleasedWhenClosed = false
        replacement.contentView = tab.web
        replacement.makeKeyAndOrderFront(nil)
        window = replacement
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("window.micResult") as? String == "NotAllowedError" }
        let live = try await tab.web.evaluateJavaScript("stream.getVideoTracks()[0].readyState") as? String
        XCTAssertEqual(live, "live", "Window closure did not destroy this shared document")
        SiteControl.set(.camera, to: nil, on: tab)
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("stream.getVideoTracks()[0].readyState") as? String == "ended" }
    }

    func testTeardownStopsSyntheticCaptureEvenWhenWebViewIsRetained() async throws {
        try await load("<script>\(mediaScript)</script>")
        try await start()
        try answer(.alertFirstButtonReturn)
        try await granted()
        let retained = tab.web
        tab.tearDown()
        try await compatibilityWait { retained.cameraCaptureState == .none && retained.microphoneCaptureState == .none }
    }


    func testTerminatingOwnedWebContentProcessExpiresTemporaryCapture() async throws {
        try await load("<script>\(mediaScript)</script>")
        try await start()
        try answer(.alertFirstButtonReturn)
        try await granted()
        let web = tab.web
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertTrue(web.responds(to: NSSelectorFromString("_webProcessIdentifier")))
        let pid = try XCTUnwrap(web.value(forKey: "_webProcessIdentifier") as? NSNumber).int32Value
        guard pid > 1 else { throw NSError(domain: "InvalidFixturePID", code: 1) }
        let identity = try processIdentity(pid)
        XCTAssertTrue(identity.contains("com.apple.WebKit.WebContent"))
        guard identity.contains("com.apple.WebKit.WebContent") else { throw NSError(domain: "WrongFixtureProcess", code: 1) }
        // Revalidate both launch time/executable and this fixture's WebKit process ID
        // immediately before signalling; no process of another app is targeted.
        XCTAssertEqual(try processIdentity(pid), identity)
        XCTAssertEqual((web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid)
        guard try processIdentity(pid) == identity,
              (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value == pid else {
            throw NSError(domain: "ReusedFixturePID", code: 1)
        }
        let generation = tab.permissionGeneration
        print("Terminating task-owned WebContent fixture: pid=\(pid), launch=\(identity)")
        XCTAssertEqual(kill(pid, SIGKILL), 0)
        try await compatibilityWait { self.tab.permissionGeneration > generation }
        XCTAssertNil(SitePermissions.effective(scope: scope, type: .camera, tabID: tab.id))
        try await compatibilityWait { web.cameraCaptureState == .none && web.microphoneCaptureState == .none }
    }

    private func processIdentity(_ pid: Int32) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "lstart=", "-o", "comm="]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if compiler(>=6.4)
    func testCancelledLocationRevocationReloadRetainsOwnerForLaterRevocation() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Requires macOS 27") }
        try await load("<script>window.oldDocument = 'original'</script>")
        let frame = try XCTUnwrap(recorder.mainFrame)
        decision = Task { await withCheckedContinuation { continuation in
            self.tab.webView(self.tab.web, requestGeolocationPermissionFor: frame.securityOrigin,
                             initiatedByFrame: frame, decisionHandler: { continuation.resume(returning: $0) })
        } }
        try await compatibilityWait { self.window.attachedSheet != nil }
        try answer(.alertFirstButtonReturn)
        let grant = await decision!.value
        XCTAssertEqual(grant, .grant)
        let blocker = PermissionReloadBlocker()
        tab.web.navigationDelegate = blocker
        defer { tab.existingWeb?.navigationDelegate = tab }
        try await evaluate("window.oldDocument = 'reload cancelled'")
        SiteControl.set(.location, to: nil, on: tab)
        try await compatibilityWait { blocker.attempts > 0 && !self.tab.web.isLoading }
        let unchanged = try await tab.web.evaluateJavaScript("window.oldDocument") as? String
        XCTAssertEqual(unchanged, "reload cancelled")
        tab.web.navigationDelegate = tab
        SiteControl.set(.location, to: false, on: tab)
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("window.oldDocument") as? String == "original" }
    }

    func testLocationRevocationStillReloadsAfterCancelledProvisionalNavigation() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Requires macOS 27") }
        try await load("<script>window.oldDocument = 'still here'</script>")
        let frame = try XCTUnwrap(recorder.mainFrame)
        decision = Task { await withCheckedContinuation { continuation in
            self.tab.webView(self.tab.web, requestGeolocationPermissionFor: frame.securityOrigin,
                             initiatedByFrame: frame, decisionHandler: { continuation.resume(returning: $0) })
        } }
        try await compatibilityWait { self.window.attachedSheet != nil }
        try answer(.alertFirstButtonReturn)
        let result = await decision!.value
        XCTAssertEqual(result, .grant)
        let previous = tab.permissionGeneration
        // A real provisional navigation is cancelled before headers replace this
        // document. Keep the owning WKNavigation identity instead of replaying nil.
        let pending = try NavigationHTTPFixture()
        defer { pending.stop() }
        pending.heldPaths.insert("/held")
        try await compatibilityWait { pending.port != nil }
        tab.go(try pending.url("/held"))
        try await compatibilityWait { self.tab.permissionGeneration > previous && self.tab.loading }
        XCTAssertGreaterThan(tab.permissionGeneration, previous)
        tab.stop()
        try await compatibilityWait { !self.tab.web.isLoading }
        let retained = try await tab.web.evaluateJavaScript("window.oldDocument") as? String
        XCTAssertEqual(retained, "still here")
        try await evaluate("window.oldDocument = 'must disappear'")
        SiteControl.set(.location, to: nil, on: tab)
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("window.oldDocument") as? String == "still here" }
        let scope = try XCTUnwrap(SitePermissions.scope(for: tab))
        XCTAssertNil(SitePermissions.effective(scope: scope, type: .location, tabID: tab.id))
    }
    #endif

}

@MainActor private final class PermissionFrameRecorder: NSObject, WKScriptMessageHandler {
    var frames: [String: WKFrameInfo] = [:]
    var mainFrame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let host = message.body as? String else { return }
        frames[host] = message.frameInfo
        if message.frameInfo.isMainFrame { mainFrame = message.frameInfo }
    }
}

@MainActor private final class PermissionReloadBlocker: NSObject, WKNavigationDelegate {
    var attempts = 0
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        attempts += 1
        decisionHandler(.cancel)
    }
}
