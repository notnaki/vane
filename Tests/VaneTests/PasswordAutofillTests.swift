import AppKit
import CoreGraphics
import WebKit
import Network
import XCTest
@testable import vane

@MainActor final class PasswordAutofillTests: XCTestCase {
    private var nativeFixtureProfiles: Set<UUID> = []
    private var fixtureWallNow: () -> Date = { .now }
    override func tearDown() async throws {
        try await releaseNativeFixtureProfiles()
    }

    private func releaseNativeFixtureProfiles() async throws {
        let profiles = nativeFixtureProfiles
        nativeFixtureProfiles.removeAll()
        try await NativeFixtureProfileCleanup.release(profiles)
    }

    func testNativeContinuationCleanupReleasesExtensionControllerAndStore() async throws {
        weak var host: ExtensionHost?
        weak var controller: WKWebExtensionController?
        weak var store: WKWebsiteDataStore?
        try await withNativeContinuationFixture { tab, _ in
            host = tab.extensions
            controller = tab.web.configuration.webExtensionController
            store = controller?.configuration.defaultWebsiteDataStore
            XCTAssertTrue(store === ProfileManager.dataStore(for: tab.profileID))
        }
        XCTAssertNotNil(host, "The fixture must exercise the normal profile's cached extension host")
        try await releaseNativeFixtureProfiles()
        try await wait(for: "disposed native fixture's extension host, controller and store to be released", diagnostics: {
            "hostRetained=\(host != nil), controllerRetained=\(controller != nil), storeRetained=\(store != nil)"
        }) {
            host == nil && controller == nil && store == nil
        }
    }

    func testNativeContinuationFixturePresentsAnActiveUserDocumentAcrossIdle() async throws {
        try await withNativeContinuationFixture { tab, _ in
            let web = tab.web
            let window = try XCTUnwrap(web.window)
            @MainActor func assertReady(file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertTrue(NSRunningApplication.current.isFinishedLaunching, "The native fixture host must complete AppKit launch", file: file, line: line)
                XCTAssertTrue(NSApplication.shared.isRunning, "The native fixture must retain its real AppKit loop", file: file, line: line)
                XCTAssertTrue(NSApplication.shared.isActive, "The native account-selection fixture needs an active test host", file: file, line: line)
                XCTAssertTrue(window.isKeyWindow, "The owned document window must receive user interaction", file: file, line: line)
                XCTAssertTrue(window.isVisible, file: file, line: line)
                XCTAssertFalse(NSApplication.shared.isHidden, file: file, line: line)
                XCTAssertFalse(NSRunningApplication.current.isHidden, file: file, line: line)
                XCTAssertTrue(NSApplication.shared.keyWindow === window, file: file, line: line)
                XCTAssertFalse(window.isMiniaturized, file: file, line: line)
                XCTAssertTrue(window.isOnActiveSpace, file: file, line: line)
                XCTAssertGreaterThan(window.alphaValue, 0, file: file, line: line)
                XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) },
                              "The owned document window must fit on a real screen", file: file, line: line)
                XCTAssertTrue(window.contentView === web && web.window === window, file: file, line: line)
                XCTAssertFalse(web.isHiddenOrHasHiddenAncestor, file: file, line: line)
                XCTAssertGreaterThan(web.bounds.width, 0, file: file, line: line)
                XCTAssertGreaterThan(web.bounds.height, 0, file: file, line: line)
                XCTAssertTrue(nativeContinuationReady(window, document: web), file: file, line: line)
            }
            assertReady()
            emitNativeContinuationReadiness(window, document: web, stage: "idle-before")
            try await Task.sleep(for: .milliseconds(100))
            assertReady()
            emitNativeContinuationReadiness(window, document: web, stage: "idle-after")
        }
        XCTAssertFalse(NSApplication.shared.isRunning, "The native fixture must join its AppKit loop before returning")
    }

    func testNativeContinuationReadinessRejectsHiddenAndDetachedOwnedDocument() async throws {
        try await withNativeContinuationFixture { tab, origin in
            let web = tab.web
            let window = try XCTUnwrap(web.window)
            // Detach only a loaded root: removing a never-loaded WKWebView can
            // trigger a separate framework removedFromContainer failure.
            try await loadContinuationPage(tab, origin: origin, path: "readiness",
                html: "<p id=fixture>Readiness</p>")
            expectEqual(try await js(web, "document.getElementById('fixture').textContent") as? String, "Readiness")
            let originalHidden = web.isHidden
            defer {
                web.isHidden = originalHidden
                window.contentView = web
            }
            XCTAssertTrue(nativeContinuationReady(window, document: web))
            web.isHidden = true
            XCTAssertFalse(nativeContinuationReady(window, document: web),
                           "A hidden document cannot receive an account-selection interaction")
            web.isHidden = originalHidden
            XCTAssertTrue(nativeContinuationReady(window, document: web))
            window.contentView = NSView(frame: web.frame)
            XCTAssertNil(web.window, "The negative case must detach the original document")
            XCTAssertFalse(nativeContinuationReady(window, document: web),
                           "A replacement content view cannot admit the detached original document")
            window.contentView = web
            XCTAssertTrue(nativeContinuationReady(window, document: web))
        }
    }

    func testNativeContinuationReadinessRejectsUnownedAndOffscreenDocument() async throws {
        try await withNativeContinuationFixture { tab, _ in
            let web = tab.web
            let window = try XCTUnwrap(web.window)
            let originalFrame = window.frame
            defer { window.setFrame(originalFrame, display: false) }
            XCTAssertTrue(nativeContinuationReady(window, document: web))
            XCTAssertFalse(nativeContinuationReady(window, document: NSView(frame: web.frame)),
                           "An unrelated view cannot borrow the owned window's interaction state")
            let leftmostDisplay = try XCTUnwrap(NSScreen.screens.map { $0.frame.minX }.min())
            window.setFrameOrigin(CGPoint(x: leftmostDisplay - window.frame.width - 100, y: originalFrame.minY))
            XCTAssertFalse(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) },
                           "The negative case must place the complete window outside every display")
            XCTAssertFalse(nativeContinuationReady(window, document: web),
                           "An offscreen document cannot receive an account-selection interaction")
            window.setFrame(originalFrame, display: false)
            XCTAssertTrue(nativeContinuationReady(window, document: web))
        }
    }

    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }

    private func expectTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    private func expectFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }
    private func expectEqual<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, file: file, line: line)
    }

    private func fixture(_ html: String, url: URL = URL(string: "https://login.example.test/signin")!,
                         foreground: Bool = false) async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        WebKitStartup.prepare()
        let capture = Capture()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, contentWorld: Autofill.world, name: "vanepw")
        config.userContentController.addUserScript(WKUserScript(source: Autofill.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Autofill.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        let cleanup: @MainActor @Sendable () -> Void = {
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "vanepw", contentWorld: Autofill.world)
            window.contentView = nil
            window.close()
        }
        var returned = false
        defer { if !returned { cleanup() } }
        if foreground {
            let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
            let available = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let size = CGSize(width: min(window.frame.width, available.width),
                              height: min(window.frame.height, available.height))
            window.setFrame(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            try await wait(for: "document fixture to receive user interaction", diagnostics: {
                self.nativeWindowVisibilityState(window)
            }) { self.nativeContinuationReady(window, document: web) }
        } else {
            window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
            window.orderFront(nil)
        }
        web.loadSimulatedRequest(URLRequest(url: url),
                                 responseHTML: "<!doctype html><body>" + html + "</body>")
        try await wait { !web.isLoading }
        try await wait(for: "autofill bridge installation") {
            try await self.js(web, "typeof window.__vaneFill === 'function'", world: Autofill.world) as? Bool == true
        }
        if !foreground { addTeardownBlock { @MainActor in cleanup() } }
        returned = true
        return (web, capture)
    }

    /// Close the native loop inside the test body: XCTest cannot start teardown
    /// while NSApplication.run is still nested inside its test invocation.
    private func withDocumentFixture(_ html: String, _ body: (WKWebView, Capture) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { app.setActivationPolicy(.accessory) }
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            let (web, capture) = try await fixture(html, foreground: true)
            let window = try XCTUnwrap(web.window)
            defer {
                web.stopLoading()
                web.configuration.userContentController.removeScriptMessageHandler(forName: "vanepw", contentWorld: Autofill.world)
                window.contentView = nil
                window.close()
            }
            try await body(web, capture)
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Document fixture AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private struct FixtureTimeout: Error, CustomStringConvertible {
        let stage: String
        var description: String { "Password fixture timed out waiting for \(stage)" }
    }

    private struct FixtureFailure: Error, CustomStringConvertible {
        let stage: String
        let cause: Error
        let diagnostics: String
        let file: StaticString
        let line: UInt
        var description: String {
            "\(file):\(line): Failed waiting for \(stage): \(cause). \(diagnostics)"
        }
    }

    func testFixtureConditionFailureKeepsOriginalContextWithoutRecordingTwice() async throws {
        enum ConditionFailure: Error { case rejected }
        do {
            try await wait(for: "injected fixture condition", file: "fixture.swift", line: 17,
                           diagnostics: { "native diagnostic" }) {
                throw ConditionFailure.rejected
            }
            XCTFail("The failing condition must abort the fixture")
        } catch {
            let failure = try XCTUnwrap(error as? FixtureFailure)
            XCTAssertEqual(failure.stage, "injected fixture condition")
            XCTAssertTrue(failure.cause is ConditionFailure)
            XCTAssertEqual(failure.diagnostics, "native diagnostic")
            XCTAssertEqual(String(describing: failure.file), "fixture.swift")
            XCTAssertEqual(failure.line, 17)
        }
    }

    @MainActor private final class SupervisedFixtureWait {
        var result: Result<Void, Error>?
        var overran = false
    }

    /// The controlled predicates yield or finish within six seconds. This seven-
    /// second supervisor cancels and joins a cooperative overrun; it does not
    /// claim to interrupt a predicate that blocks the executor indefinitely.
    private func supervisedFixtureWait(for stage: String,
                                       _ condition: @escaping @MainActor () async throws -> Bool) async -> SupervisedFixtureWait {
        let attempt = SupervisedFixtureWait(), clock = ContinuousClock()
        let supervisorDeadline = clock.now.advanced(by: .seconds(7))
        let worker = Task { @MainActor in
            do {
                try await self.wait(for: stage, condition)
                attempt.result = .success(())
            } catch { attempt.result = .failure(error) }
        }
        let supervisor = Task { @MainActor in
            do { try await clock.sleep(until: supervisorDeadline) }
            catch { return }
            guard attempt.result == nil else { return }
            attempt.overran = true
            worker.cancel()
        }
        await worker.value
        supervisor.cancel()
        await supervisor.value
        return attempt
    }

    func testFixtureWaitBackwardWallStepStillExpires() async throws {
        var offset: TimeInterval = 0
        let previous = fixtureWallNow
        fixtureWallNow = { Date.now.addingTimeInterval(offset) }
        defer { fixtureWallNow = previous }
        let attempt = await supervisedFixtureWait(for: "backward wall step") {
            offset = -60
            return false
        }
        XCTAssertFalse(attempt.overran, "A wall-clock rollback must not extend the five-second wait")
        guard !attempt.overran else { return }
        guard case .failure(let error) = attempt.result else {
            return XCTFail("A false predicate must time out")
        }
        let failure = try XCTUnwrap(error as? FixtureFailure)
        XCTAssertTrue(failure.cause is FixtureTimeout)
    }

    func testFixtureWaitRejectsLateTrue() async throws {
        let attempt = await supervisedFixtureWait(for: "late true predicate") {
            try await Task.sleep(for: .seconds(6))
            return true
        }
        XCTAssertFalse(attempt.overran, "The finite predicate must return before the independent supervisor")
        guard !attempt.overran else { return }
        guard case .failure(let error) = attempt.result else {
            return XCTFail("A predicate returning true after six seconds must not pass a five-second wait")
        }
        let failure = try XCTUnwrap(error as? FixtureFailure)
        XCTAssertTrue(failure.cause is FixtureTimeout)
    }

    #if DEBUG
    func testFixtureWaitForwardWallStepAwaitsActualUsernameProcessing() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "username",
                html: "<form><input autocomplete=username value=bob></form>")
            let web = tab.web, window = try XCTUnwrap(web.window)
            XCTAssertTrue(nativeContinuationReady(window, document: web))
            XCTAssertFalse(web.isLoading)
            let held = HeldUsernameStep(tab: tab)
            let receipt = UsernameSubmissionReceipt(scope: held.scope)
            let previousBoundary = tab.usernameStepBoundary, previousWall = fixtureWallNow
            var offset: TimeInterval = 0
            var steppedWhilePending = false
            fixtureWallNow = { Date.now.addingTimeInterval(offset) }
            tab.usernameStepBoundary = { [weak held, weak receipt] event, delivery in
                receipt?.observe(event)
                held?.receive(event, delivery: delivery)
            }
            web.evaluateJavaScript("document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))",
                                   in: nil, in: .page) { [weak receipt] result in
                receipt?.evaluation = result.map { _ in () }
            }
            let attempt = await supervisedFixtureWait(for: "forward wall step with real held username message") {
                if !steppedWhilePending, receipt.request != nil, receipt.processed == nil,
                   !receipt.discarded, !receipt.duplicate {
                    steppedWhilePending = true
                    offset = 60
                }
                if let evaluation = receipt.evaluation { try evaluation.get() }
                return receipt.evaluation != nil && receipt.processed != nil
            }
            await held.join()
            tab.usernameStepBoundary = previousBoundary
            fixtureWallNow = previousWall
            XCTAssertEqual(held.events.filter { $0.phase == .received }.count, 1)
            XCTAssertEqual(held.events.last?.phase, .processed(continuationAllowed: false))
            XCTAssertTrue(steppedWhilePending, "The wall step must occur while the matching real native receipt is pending")
            print("Fixture wall-step control: steppedWhilePending=\(steppedWhilePending), " + receipt.diagnostics)
            XCTAssertFalse(attempt.overran)
            guard !attempt.overran else { return }
            if case .failure(let error) = attempt.result {
                XCTFail("A forward wall-clock step must not expire the pending native ACK: \(error)")
            }
        }
    }
    #endif

    private func wait(for stage: String = "fixture condition", file: StaticString = #filePath, line: UInt = #line,
                      diagnostics: () async -> String = { "" },
                      _ condition: () async throws -> Bool) async throws {
        let clock = ContinuousClock(), started = clock.now
        let deadline = started.advanced(by: .seconds(5))
        let wallStarted = fixtureWallNow()
        do {
            while true {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw FixtureTimeout(stage: stage) }
                let ready = try await condition()
                try Task.checkCancellation()
                guard clock.now < deadline else { throw FixtureTimeout(stage: stage) }
                if ready { return }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            NativeFixtureDiagnostics.emit("\(file):\(line): Failed waiting for \(stage): \(error); " +
                "elapsedMonotonic=\(started.duration(to: clock.now)), " +
                "elapsedWallMetadata=\(fixtureWallNow().timeIntervalSince(wallStarted)); collecting native diagnostics")
            // XCTest records the thrown failure once. Recording XCTFail here too
            // obscures the original failure with a second, unexpected thrown error.
            let report = await diagnostics()
            NativeFixtureDiagnostics.emit("\(file):\(line): Failed waiting for \(stage): \(error). \(report)")
            throw FixtureFailure(stage: stage, cause: error, diagnostics: report, file: file, line: line)
        }
    }

    private func js(_ web: WKWebView, _ source: String, world: WKContentWorld = .page) async throws -> Any? {
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: world) { result in
                do {
                    let value: Any? = try result.get()
                    guard let value else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }

    private func fill(_ web: WKWebView, account: String = "ada", automatic: Bool = false) async throws -> Bool {
        try await js(web, Autofill.fillJS(account: account, password: "fixture-secret", automatic: automatic),
                     world: Autofill.world) as? Bool == true
    }

    func testDocumentNotificationFixtureOwnsAnActiveAppKitContext() async throws {
        try await withDocumentFixture("<form><input autocomplete=username></form>") { web, _ in
            let window = try XCTUnwrap(web.window)
            XCTAssertTrue(NSApplication.shared.isRunning, "Live WebKit notifications require an owned AppKit loop")
            XCTAssertTrue(nativeContinuationReady(window, document: web),
                          "The document must be attached to its active, on-screen window before mutations")
        }
        XCTAssertFalse(NSApplication.shared.isRunning, "The document fixture must join its loop before returning")
    }

    func testPasswordStepRejectsDifferentAccountAfterUsernameRemoval() async throws {
        let (web, _) = try await fixture("<form id=login><input id=user autocomplete=username></form>")
        let initial = try await fill(web)
        expectTrue(initial)
        _ = try await js(web, "login.innerHTML = '<input id=password type=password autocomplete=current-password>'")
        let wrong = try await fill(web, account: "bob", automatic: true)
        expectFalse(wrong, "The password step must preserve its own selected username")
        let correct = try await fill(web, automatic: true)
        expectTrue(correct)
        expectEqual(try await js(web, "password.value") as? String, "fixture-secret")
    }

    func testExistingFieldBecomesLoginThroughAttributeAndVisibilityChanges() async throws {
        try await withDocumentFixture("<form id=login hidden><input id=password type=text disabled></form>") { web, capture in
            let before = capture.messages.filter { $0["ready"] as? Bool == true }.count
            _ = try await js(web, "password.type='password'; password.disabled=false; login.hidden=false")
            // Observe the actual bridge notification in the admitted document context.
            try await wait { capture.messages.filter { $0["ready"] as? Bool == true }.count > before }
            XCTAssertGreaterThan(capture.messages.filter { $0["ready"] as? Bool == true }.count, before)
            expectTrue(try await fill(web))
        }
    }

    func testHiddenAndUnrelatedFieldsStayUntouched() async throws {
        let (web, _) = try await fixture("""
            <form><input id=search type=search><input id=otp autocomplete=one-time-code>
            <input id=invisible style='visibility:hidden' type=password>
            <input id=user autocomplete=username><input id=password type=password></form>
            """)
        _ = try await js(web, "password.focus()")
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "[search.value,otp.value,invisible.value,user.value,password.value].join('|')") as? String,
                       "|||ada|fixture-secret")
    }

    func testFocusedSecondLoginDoesNotFillFirstLogin() async throws {
        let (web, _) = try await fixture("""
            <form><input id=firstUser autocomplete=username><input id=firstPassword type=password></form>
            <form><input id=secondUser autocomplete=username><input id=secondPassword type=password></form>
            """)
        _ = try await js(web, "secondPassword.focus()")
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "[firstUser.value,firstPassword.value,secondUser.value,secondPassword.value].join('|')") as? String,
                       "||ada|fixture-secret")
    }

    func testEmbeddedSameOriginLoginFillsAndCapturesItsOwnFields() async throws {
        let (web, capture) = try await fixture("""
            <input id=decoy autocomplete=username>
            <iframe id=embedded srcdoc='<form><input id=user autocomplete=username><input id=password type=password></form>'></iframe>
            """)
        try await wait { try await self.js(web, "!!embedded.contentDocument.getElementById('password')") as? Bool == true }
        _ = try await js(web, "embedded.contentDocument.getElementById('password').focus()")
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "embedded.contentDocument.getElementById('password').value") as? String, "fixture-secret")
        expectEqual(try await js(web, "decoy.value") as? String, "")
        _ = try await js(web, "embedded.contentDocument.forms[0].dispatchEvent(new Event('submit',{bubbles:true}))")
        try await Task.sleep(for: .milliseconds(100))
        expectEqual(capture.messages.last { $0["password"] != nil }?["account"] as? String, "ada")
    }

    func testSandboxedEmbeddedLoginCannotFillOrOffer() async throws {
        let (web, capture) = try await fixture("<iframe sandbox='allow-scripts' srcdoc='<form><input autocomplete=username><input type=password value=foreign></form>'></iframe>")
        try await Task.sleep(for: .milliseconds(200))
        expectFalse(try await fill(web))
        expectFalse(capture.messages.contains { $0["password"] != nil || $0["ready"] as? Bool == true })
    }

    func testReadOnlyIdentityAndNewPasswordsArePreserved() async throws {
        let (web, _) = try await fixture("<form><input autocomplete=username readonly value=ada><input id=otp autocomplete=one-time-code><input id=password type=password></form>")
        expectFalse(try await fill(web, account: "bob"))
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "otp.value") as? String, "")
        _ = try await js(web, "document.body.innerHTML='<form><input autocomplete=username><input id=newPassword type=password autocomplete=new-password></form>'")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "newPassword.value") as? String, "")
    }
    func testStaleChooserTargetDoesNotFillReplacementLogin() async throws {
        let (web, _) = try await fixture("<form><input autocomplete=username><input type=password></form>")
        let raw = try await js(web, "window.__vaneAnchor()", world: Autofill.world) as? String
        let data = try XCTUnwrap(raw?.data(using: .utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let target = try XCTUnwrap(body["target"] as? String)
        _ = try await js(web, "document.body.innerHTML='<form><input autocomplete=username><input id=replacement type=password></form>'")
        expectFalse(try await js(web, Autofill.fillJS(account: "ada", password: "fixture-secret", target: target), world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "replacement.value") as? String, "")
    }

    func testSelectedAccountContinuesAcrossUsernameNavigation() async throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "login.example.test")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "ada", password: "ada-secret", profileID: profile),
              Passwords.save(origin: origin, account: "bob", password: "bob-secret", profileID: profile)
        else { throw XCTSkip("Disposable Keychain fixtures unavailable") }
        nativeFixtureProfiles.insert(profile)
        let tab = Tab(profileID: profile)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { tab.tearDown(); window.close() }
        tab.web.loadSimulatedRequest(URLRequest(url: origin.url.appendingPathComponent("username")),
            responseHTML: "<form><input id=user autocomplete=username></form>")
        try await wait { !tab.web.isLoading }
        tab.fillChosen(host: origin.host, account: "bob")
        try await wait { try await self.js(tab.web, "user.value") as? String == "bob" }
        _ = try await js(tab.web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        try await Task.sleep(for: .milliseconds(100))
        tab.web.loadSimulatedRequest(URLRequest(url: origin.url.appendingPathComponent("password")),
            responseHTML: "<form><input id=password type=password autocomplete=current-password></form>")
        try await wait { !tab.web.isLoading }
        try await Task.sleep(for: .milliseconds(250))
        expectEqual(try await js(tab.web, "password.value") as? String, "bob-secret")
        _ = try await js(tab.web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        try await Task.sleep(for: .milliseconds(100))
        expectTrue(tab.pendingSave == nil, "An unchanged saved password must not create a save prompt")
    }

    /// These tests exercise an owned user-interaction context, not pixel coverage.
    /// AppKit's occlusion getter can remain stale after activation; retain it in
    /// diagnostics rather than making it an extra credential-authorization gate.
    /// https://github.com/flutter/flutter/commit/272fe23e0e32d63fa6c34dbf9659411dcfabb970
    private func nativeContinuationReady(_ window: NSWindow, document: NSView) -> Bool {
        let app = NSApplication.shared, running = NSRunningApplication.current
        return app.isRunning && running.isFinishedLaunching && app.isActive &&
            !app.isHidden && !running.isHidden && app.keyWindow === window &&
            window.isKeyWindow && window.isVisible && !window.isMiniaturized &&
            window.isOnActiveSpace && window.alphaValue > 0 &&
            NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) } &&
            window.contentView === document && document.window === window &&
            !document.isHiddenOrHasHiddenAncestor && document.bounds.width > 0 && document.bounds.height > 0
    }

    /// One bounded scalar record per admission/idle sample; no WindowServer probes.
    private func emitNativeContinuationReadiness(_ window: NSWindow, document: NSView, stage: StaticString) {
        let app = NSApplication.shared, running = NSRunningApplication.current
        print("Native continuation readiness: stage=\(stage), ready=\(nativeContinuationReady(window, document: document)), " +
              "appRunning=\(app.isRunning), finishedLaunching=\(running.isFinishedLaunching), active=\(app.isActive), " +
              "appHidden=\(app.isHidden), runningHidden=\(running.isHidden), exactKey=\(app.keyWindow === window), " +
              "windowKey=\(window.isKeyWindow), windowVisible=\(window.isVisible), miniaturized=\(window.isMiniaturized), " +
              "activeSpace=\(window.isOnActiveSpace), alphaPositive=\(window.alphaValue > 0), " +
              "onScreen=\(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }), " +
              "ownsContent=\(window.contentView === document), attached=\(document.window === window), " +
              "viewHidden=\(document.isHiddenOrHasHiddenAncestor), " +
              "positiveBounds=\(document.bounds.width > 0 && document.bounds.height > 0), " +
              "appOcclusion=\(app.occlusionState.rawValue), windowOcclusion=\(window.occlusionState.rawValue)")
    }

    private func withNativeContinuationFixture(_ body: (Tab, PasswordOrigin) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "continuation.example.test")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "bob", password: "bob-secret", profileID: profile),
              Passwords.save(origin: origin, account: "ada", password: "ada-secret", profileID: profile)
        else { throw XCTSkip("Disposable Keychain fixtures unavailable") }
        nativeFixtureProfiles.insert(profile)
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let policyRequestAccepted: Bool?
        if previousPolicy == .prohibited { policyRequestAccepted = app.setActivationPolicy(.accessory) }
        else { policyRequestAccepted = nil }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var fixtureError: (any Error)?
        do {
            let tab = Tab(profileID: profile)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { tab.tearDown(); window.close() }
            window.contentView = tab.web
            let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first, "A native account-selection fixture needs a display")
            let available = screen.visibleFrame.insetBy(dx: 20, dy: 20)
            let size = CGSize(width: min(window.frame.width, available.width),
                              height: min(window.frame.height, available.height))
            // Fit the complete decorated window, not just its content rectangle.
            window.setFrame(CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                   width: size.width, height: size.height), display: false)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            // These fixtures choose native account rows. Establish that user-facing
            // context once, before loading; individual navigations must stand alone.
            let web = tab.web
            try await wait(for: "native continuation fixture to receive user interaction", diagnostics: {
                let running = NSRunningApplication.current
                let openValue = UserDefaults.standard.object(forKey: "NSOpen")
                let openAbsentOrEmpty = openValue == nil || (openValue as? String)?.isEmpty == true ||
                    (openValue as? [Any])?.isEmpty == true
                return "appActive=\(app.isActive), windowKey=\(window.isKeyWindow), windowVisible=\(window.isVisible), " +
                    "windowOcclusion=\(window.occlusionState.rawValue), onScreen=\(NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }), " +
                    "priorPolicy=\(previousPolicy.rawValue), policyRequestAccepted=\(policyRequestAccepted.map(String.init) ?? "not-requested"), " +
                    "appPolicy=\(app.activationPolicy().rawValue), runningPolicy=\(running.activationPolicy.rawValue), " +
                    "runningActive=\(running.isActive), finishedLaunching=\(running.isFinishedLaunching), appRunning=\(app.isRunning), " +
                    "appDelegateNil=\(app.delegate == nil), NSOpenAbsentOrEmpty=\(openAbsentOrEmpty), " +
                    "isOnActiveSpace=\(window.isOnActiveSpace), isMiniaturized=\(window.isMiniaturized), " +
                    "viewsNeedDisplay=\(window.viewsNeedDisplay), contentNeedsLayout=\(web.needsLayout), " +
                    "contentNeedsDisplay=\(web.needsDisplay), alphaPositive=\(window.alphaValue > 0), " +
                    self.nativeWindowVisibilityState(window)
            }) {
                // The owned AppKit loop supplies event dispatch and deferred drawing.
                return nativeContinuationReady(window, document: web)
            }
            emitNativeContinuationReadiness(window, document: web, stage: "admission")
            try await body(tab, origin)
        } catch { fixtureError = error }
        do { try await loop.close() }
        catch {
            if fixtureError == nil { fixtureError = error }
            else { XCTFail("Native continuation AppKit loop join also failed: \(error)") }
        }
        if let fixtureError { throw fixtureError }
    }

    /// Failure-only scalar metadata: no window names, titles, images, or display mutations.
    private func nativeWindowVisibilityState(_ window: NSWindow) -> String {
        let app = NSApplication.shared, running = NSRunningApplication.current
        let owned = app.orderedWindows
        let ownedRows = owned.prefix(16).map { candidate in
            "appKitNumber=\(candidate.windowNumber), level=\(candidate.level.rawValue), " +
                "visible=\(candidate.isVisible), key=\(candidate.isKeyWindow), " +
                "occlusion=\(candidate.occlusionState.rawValue), alpha=\(candidate.alphaValue)"
        }.joined(separator: "; ")
        let application = "appHidden=\(app.isHidden), runningHidden=\(running.isHidden), " +
            "appOcclusion=\(app.occlusionState.rawValue), " +
            "frontmostPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier.description ?? "unavailable"), " +
            "ownAppKitWindowNumber=\(window.windowNumber), ownWindowLevel=\(window.level.rawValue), " +
            "ownWindowOrderedIndex=\(window.orderedIndex), parentAppKitWindowNumber=\(window.parent?.windowNumber.description ?? "none"), " +
            "tabbedWindowCount=\(window.tabbedWindows?.count ?? 0), " +
            "orderedAppWindowCount=\(owned.count), orderedAppWindows=[\(ownedRows)]"
        guard let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else {
            return application + ", processOwnedWindowServerRows=unavailable, particularWindowCorrelation=UNKNOWN"
        }
        func number(_ row: [String: Any], _ key: CFString) -> NSNumber? { row[key as String] as? NSNumber }
        func bounds(_ row: [String: Any]) -> CGRect? {
            guard let dictionary = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
        }
        func state(_ row: [String: Any]) -> String {
            let rectangle = bounds(row).map { "\($0.origin.x),\($0.origin.y),\($0.width),\($0.height)" } ?? "unavailable"
            return "id=\(number(row, kCGWindowNumber)?.description ?? "unavailable"), " +
                "pid=\(number(row, kCGWindowOwnerPID)?.description ?? "unavailable"), " +
                "layer=\(number(row, kCGWindowLayer)?.description ?? "unavailable"), bounds=\(rectangle), " +
                "alpha=\(number(row, kCGWindowAlpha)?.description ?? "unavailable"), " +
                "onscreen=\(number(row, kCGWindowIsOnscreen)?.description ?? "unavailable")"
        }
        let processID = ProcessInfo.processInfo.processIdentifier
        let processRows = rows.filter { number($0, kCGWindowOwnerPID)?.int32Value == processID }
        let serverRows = processRows.prefix(16).map(state).joined(separator: "; ")
        return application + ", processOwnedWindowServerRowCount=\(processRows.count), " +
            "particularWindowCorrelation=UNKNOWN, processOwnedWindowServerRows=[\(serverRows)]"
    }

    private func continuationLoadState(_ tab: Tab, web: WKWebView, requestedURL: URL) -> String {
        let selector = NSSelectorFromString("_webProcessIdentifier")
        var process: NativeFixtureDiagnostics.Identity?
        if web.responds(to: selector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            let pid = unsafeBitCast(web.method(for: selector), to: Getter.self)(web, selector)
            process = NativeFixtureDiagnostics.identity(pid)
        }
        let native = process.map {
            "contentPID=\($0.pid), contentStart=\($0.start), contentPath=\($0.path), contentState=\($0.state)"
        } ?? "contentIdentity=unavailable"
        return "requested=\(requestedURL.absoluteString), webURL=\(web.url?.absoluteString ?? "nil"), " +
            "tabCurrentURL=\(tab.currentURL?.absoluteString ?? "nil"), " +
            "historyURL=\(web.backForwardList.currentItem?.url.absoluteString ?? "nil"), " +
            "loading=\(web.isLoading), progress=\(web.estimatedProgress), tabLoading=\(tab.loading), " +
            "suspended=\(tab.suspended), recovery=\(tab.needsRecovery), " + native
    }

    #if DEBUG
    @MainActor private final class NavigationStages {
        private var events: [Tab.NavigationStageEvent] = []
        private var dropped = 0

        func append(_ event: Tab.NavigationStageEvent) {
            guard events.count < 48 else { dropped += 1; return }
            events.append(event)
        }

        func snapshot(expected: ObjectIdentifier) -> String {
            var tokens: [Tab.NavigationStageIdentity: Int] = [.navigation(expected): 1]
            let records = events.map { event in
                let token: String
                if let identity = event.identity {
                    if tokens[identity] == nil { tokens[identity] = tokens.count + 1 }
                    token = "object#\(tokens[identity]!)"
                } else { token = "no-object" }
                return "\(event.stage)(\(token), \(event.detail))"
            }
            return "expected=object#1, events=[\(records.joined(separator: "; "))], dropped=\(dropped)"
        }
    }
    #endif

    private func loadContinuationPage(_ tab: Tab, origin: PasswordOrigin, path: String, html: String,
                                      beforeRequest: (@MainActor () throws -> Void)? = nil) async throws {
        let web = tab.web, url = origin.url.appendingPathComponent(path)
        let started = Date.now
        #if DEBUG
        let stages = NavigationStages()
        let previousObserver = tab.navigationStageObserver
        tab.navigationStageObserver = { [weak stages] event in
            previousObserver?(event)
            stages?.append(event)
        }
        defer { tab.navigationStageObserver = previousObserver }
        #endif
        let before = continuationLoadState(tab, web: web, requestedURL: url)
        try beforeRequest?()
        let navigationID = ObjectIdentifier(web.loadSimulatedRequest(URLRequest(url: url), responseHTML: html))
        let after = continuationLoadState(tab, web: web, requestedURL: url)
        try await wait(for: "continuation document \(path) to finish loading", diagnostics: {
            #if DEBUG
            NativeFixtureDiagnostics.emit("continuation callback stages: " + stages.snapshot(expected: navigationID))
            NativeFixtureDiagnostics.emit("continuation observer ownership: delegateIsTab=\(web.navigationDelegate === tab), currentView=\(tab.existingWeb === web), observerInstalled=\(tab.navigationStageObserver != nil)")
            #endif
            let state = "before={\(before)}; returnedNavigation=\(navigationID); after={\(after)}; " +
                "timeout={\(continuationLoadState(tab, web: web, requestedURL: url))}"
            NativeFixtureDiagnostics.emit("continuation document \(path) cached state before sampling: " + state)
            return state + "; " + (await NativeFixtureDiagnostics.failureReport(for: web))
        }) {
            return !web.isLoading
        }
        if Date.now.timeIntervalSince(started) >= 0.5 {
            print("Continuation fixture \(path) loaded in \(Date.now.timeIntervalSince(started))s")
        }
    }

    private func submitUsernameAndLoadPassword(_ tab: Tab, origin: PasswordOrigin, identity: String = "",
                                               beforeNavigation: (() -> Void)? = nil) async throws {
        #if DEBUG
        let admitRequest = try await awaitSubmittedUsernameProcessing(tab, origin: origin)
        #else
        // Release product builds expose no fixture boundary. Preserve this existing,
        // unqualified release-test setup; the processed-ACK repair is for DEBUG CI.
        _ = try await js(tab.web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        try await Task.sleep(for: .milliseconds(100))
        #endif
        try await loadContinuationPage(tab, origin: origin, path: "password",
            html: "<form>" + identity + "<input id=password type=password autocomplete=current-password></form>",
            beforeRequest: {
                #if DEBUG
                try admitRequest()
                #endif
                beforeNavigation?()
            })
    }

    #if DEBUG
    @MainActor private final class UsernameSubmissionReceipt {
        let scope: Tab.UsernameStepScope
        var request: UUID?
        var processed: Bool?
        var discarded = false
        var duplicate = false
        var evaluation: Result<Void, Error>?

        init(scope: Tab.UsernameStepScope) { self.scope = scope }

        func observe(_ event: Tab.UsernameStepEvent) {
            guard event.scope == scope else { return }
            switch event.phase {
            case .received:
                if request == nil { request = event.request }
                else if request != event.request { duplicate = true }
            case .processed(let allowed):
                if event.request == request { processed = allowed }
            case .discarded:
                if event.request == request { discarded = true }
            }
        }

        var diagnostics: String {
            "received=\(request != nil), processed=\(processed.map(String.init) ?? "absent"), " +
                "discarded=\(discarded), duplicate=\(duplicate), evaluationReturned=\(evaluation != nil)"
        }
    }

    private func awaitSubmittedUsernameProcessing(_ tab: Tab, origin: PasswordOrigin) async throws -> @MainActor () throws -> Void {
        // One prerequisite budget includes foreground admission, DOM submission,
        // JavaScript completion and actual native processing. A late true is rejected.
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        let web = tab.web, window = try XCTUnwrap(web.window)
        let outgoingURL = try XCTUnwrap(web.url)
        let scope = Tab.UsernameStepScope(tab: tab, web: web)
        let receipt = UsernameSubmissionReceipt(scope: scope)
        func currentDocument() -> Bool {
            tab.existingWeb === web && Tab.UsernameStepScope(tab: tab, web: web) == scope &&
                web.url == outgoingURL && tab.currentURL == outgoingURL &&
                PasswordOrigin(url: outgoingURL) == origin && !web.isLoading
        }
        func checkDeadline() throws {
            try Task.checkCancellation()
            guard clock.now < deadline else {
                throw FixtureTimeout(stage: "submitted username native processing: " + receipt.diagnostics)
            }
            guard currentDocument() else {
                throw FixtureTimeout(stage: "submitted username outgoing document changed: " + receipt.diagnostics)
            }
        }
        while true {
            try checkDeadline()
            if nativeContinuationReady(window, document: web) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let previous = tab.usernameStepBoundary
        tab.usernameStepBoundary = { [weak receipt] event, delivery in
            receipt?.observe(event)
            if let previous { previous(event, delivery) }
            else { delivery?() }
        }
        defer { tab.usernameStepBoundary = previous }
        try checkDeadline()
        emitNativeContinuationReadiness(window, document: web, stage: "username-submit")
        // A callback result acknowledges evaluation, not native message processing.
        // Keep it independently bounded and require both before requesting navigation.
        web.evaluateJavaScript("""
            (function () {
                if (document.readyState !== 'complete') throw new Error('Username document is not ready');
                return document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
            })()
            """, in: nil, in: .page) { [weak receipt] result in
                receipt?.evaluation = result.map { _ in () }
            }
        while true {
            try checkDeadline()
            if let evaluation = receipt.evaluation { try evaluation.get() }
            if receipt.discarded || receipt.duplicate {
                throw FixtureTimeout(stage: "submitted username receipt rejected: " + receipt.diagnostics)
            }
            // `false` is a genuine processed denial, never the initial absent ACK.
            if receipt.evaluation != nil, receipt.processed != nil,
               nativeContinuationReady(window, document: web) {
                // Recheck at the actual SDK request, across the async return and
                // failure-state getters, without starting another prerequisite budget.
                return {
                    try checkDeadline()
                    guard self.nativeContinuationReady(window, document: web) else {
                        throw FixtureTimeout(stage: "submitted username presentation owner changed")
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Hold a real, already validated SDK message rather than fabricating a native
    /// username step. The delay is an adversarial delivery condition, not readiness.
    @MainActor private final class HeldUsernameStep {
        let scope: Tab.UsernameStepScope
        var events: [Tab.UsernameStepEvent] = []
        var navigationBeforeProcessed = false
        private var releaseTask: Task<Void, Never>?

        init(tab: Tab) { scope = Tab.UsernameStepScope(tab: tab, web: tab.web) }

        func receive(_ event: Tab.UsernameStepEvent, delivery: (@MainActor () -> Void)?) {
            guard event.scope == scope else { delivery?(); return }
            events.append(event)
            guard let delivery else { return }
            guard releaseTask == nil else { delivery(); return }
            releaseTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(400)) }
                catch { return }
                delivery()
            }
        }

        func willNavigate() {
            navigationBeforeProcessed = !events.contains { event in
                if case .processed = event.phase { return true }
                return false
            }
        }

        func join(cancel: Bool = false) async {
            if cancel { releaseTask?.cancel() }
            await releaseTask?.value
            releaseTask = nil
        }
    }

    private func assertHeldUsernameStep(_ tab: Tab, origin: PasswordOrigin,
                                        continuationAllowed: Bool) async throws {
        let web = tab.web, window = try XCTUnwrap(web.window)
        XCTAssertTrue(nativeContinuationReady(window, document: web))
        XCTAssertFalse(web.isLoading)
        let held = HeldUsernameStep(tab: tab)
        let previous = tab.usernameStepBoundary
        tab.usernameStepBoundary = { [weak held] event, delivery in
            held?.receive(event, delivery: delivery)
        }
        var operationError: Error?
        do {
            try await submitUsernameAndLoadPassword(tab, origin: origin,
                beforeNavigation: { held.willNavigate() })
        } catch { operationError = error }
        await held.join(cancel: operationError != nil)
        tab.usernameStepBoundary = previous
        if let operationError { throw operationError }
        let received = held.events.filter { $0.phase == .received }
        XCTAssertEqual(received.count, 1, "The control must hold one genuine main-document username message")
        print("Held username step: requestedBeforeProcessed=\(held.navigationBeforeProcessed), " +
              "phases=\(held.events.map { String(describing: $0.phase) })")
        XCTAssertFalse(held.navigationBeforeProcessed,
                       "A password navigation must follow actual native processing, including denied authorization")
        if held.navigationBeforeProcessed {
            // The RED control navigated first: the old document's held delivery
            // must be discarded, rather than acknowledged against its replacement.
            XCTAssertEqual(held.events.last?.phase, .discarded)
            return
        }
        XCTAssertEqual(held.events.last?.phase, .processed(continuationAllowed: continuationAllowed))
        XCTAssertTrue(held.events.allSatisfy { $0.scope == held.scope && $0.request == received.first?.request })
        if continuationAllowed {
            try await wait { try await js(web, "password.value") as? String == "bob-secret" }
            expectEqual(try await js(web, "password.value") as? String, "bob-secret")
        } else {
            try await Task.sleep(for: .milliseconds(250))
            expectEqual(try await js(web, "password.value") as? String, "")
        }
    }

    func testSubmittedMainUsernameAwaitsProcessedAuthorizationBeforeNavigation() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "username",
                html: "<form><input id=user autocomplete=username></form>")
            tab.fillChosen(host: origin.host, account: "bob")
            try await wait { try await js(tab.web, "user.value") as? String == "bob" }
            try await assertHeldUsernameStep(tab, origin: origin, continuationAllowed: true)
        }
    }

    func testSubmittedMainUsernameAwaitsProcessedDenialBeforeNavigation() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "login", html:
                "<iframe id=embedded srcdoc='<form><input id=user autocomplete=username></form>'></iframe>")
            try await wait(for: "embedded username DOM") {
                try await js(tab.web, "!!embedded.contentDocument.getElementById('user')") as? Bool == true
            }
            _ = try await js(tab.web, "embedded.contentDocument.getElementById('user').focus()")
            var embeddedTarget = ""
            try await wait(for: "isolated-world embedded username target") {
                embeddedTarget = try await js(tab.web, """
                    (function () {
                        var raw = window.__vaneAnchor && window.__vaneAnchor();
                        var anchor = raw && JSON.parse(raw);
                        return anchor && anchor.target || '';
                    })()
                    """, world: Autofill.world) as? String ?? ""
                return !embeddedTarget.isEmpty
            }
            tab.closeChooser(.escape)
            _ = try await js(tab.web, "embedded.contentDocument.getElementById('user').click()")
            try await wait(for: "native embedded-account chooser") {
                tab.passwordChoice?.target == embeddedTarget && tab.passwordChoice?.accounts.contains("bob") == true
            }
            let choice = try XCTUnwrap(tab.passwordChoice)
            let target = try XCTUnwrap(choice.target)
            tab.fillChosen(host: choice.host, account: "bob", port: choice.port, target: target)
            try await wait(for: "explicitly chosen account to fill the embedded username") {
                try await js(tab.web, "embedded.contentDocument.getElementById('user').value") as? String == "bob"
            }
            _ = try await js(tab.web, "document.body.innerHTML='<form><input autocomplete=username value=bob></form>'")
            try await assertHeldUsernameStep(tab, origin: origin, continuationAllowed: false)
        }
    }
    #endif

    func testSelectedAccountContinuesWithHiddenOrReadOnlyIdentity() async throws {
        for identity in ["<input type=hidden autocomplete=username value=bob>",
                         "<input readonly autocomplete=username value=bob>"] {
            try await withNativeContinuationFixture { tab, origin in
                try await loadContinuationPage(tab, origin: origin, path: "username",
                    html: "<form><input id=user autocomplete=username></form>")
                tab.fillChosen(host: origin.host, account: "bob")
                try await wait { try await js(tab.web, "user.value") as? String == "bob" }
                try await submitUsernameAndLoadPassword(tab, origin: origin, identity: identity)
                // Wait for the actual fill rather than judging an async Keychain read by time.
                try await wait { try await js(tab.web, "password.value") as? String == "bob-secret" }
                expectEqual(try await js(tab.web, "password.value") as? String, "bob-secret")
            }
        }
    }

    func testSelectedAccountCannotContinueIntoDifferentHiddenOrReadOnlyIdentity() async throws {
        for identity in ["<input type=hidden autocomplete=username value=ada>",
                         "<input readonly autocomplete=username value=ada>"] {
            try await withNativeContinuationFixture { tab, origin in
                try await loadContinuationPage(tab, origin: origin, path: "username",
                    html: "<form><input id=user autocomplete=username></form>")
                tab.fillChosen(host: origin.host, account: "bob")
                try await wait { try await js(tab.web, "user.value") as? String == "bob" }
                try await submitUsernameAndLoadPassword(tab, origin: origin, identity: identity)
                try await Task.sleep(for: .milliseconds(250))
                expectEqual(try await js(tab.web, "password.value") as? String, "")
            }
        }
    }

    func testFullFormSelectionCannotAuthorizeUnrelatedUsernameStep() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "login",
                html: "<form><input id=user autocomplete=username><input id=password type=password></form>")
            tab.fillChosen(host: origin.host, account: "bob")
            try await wait { try await js(tab.web, "password.value") as? String == "bob-secret" }
            _ = try await js(tab.web, "document.body.innerHTML='<form><input autocomplete=username value=bob></form>'")
            try await submitUsernameAndLoadPassword(tab, origin: origin)
            try await Task.sleep(for: .milliseconds(250))
            expectEqual(try await js(tab.web, "password.value") as? String, "")
        }
    }

    func testEmbeddedSelectionCannotAuthorizeMainDocumentUsernameStep() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "login", html:
                "<iframe id=embedded srcdoc='<form><input id=user autocomplete=username></form>'></iframe>")
            try await wait(for: "embedded username DOM") {
                try await js(tab.web, "!!embedded.contentDocument.getElementById('user')") as? Bool == true
            }
            _ = try await js(tab.web, "embedded.contentDocument.getElementById('user').focus()")
            // The child DOM can exist before discovery installs its isolated-world context.
            // A native row cannot be picked until the bridge and its account list are ready.
            var embeddedTarget = ""
            try await wait(for: "isolated-world embedded username target") {
                embeddedTarget = try await js(tab.web, """
                    (function () {
                        var raw = window.__vaneAnchor && window.__vaneAnchor();
                        var anchor = raw && JSON.parse(raw);
                        return anchor && anchor.target || '';
                    })()
                    """, world: Autofill.world) as? String ?? ""
                return !embeddedTarget.isEmpty
            }
            // Request a fresh chooser after discovery, including when the original focus
            // happened before its listener existed. Await metadata before choosing the row.
            tab.closeChooser(.escape)
            _ = try await js(tab.web, "embedded.contentDocument.getElementById('user').click()")
            try await wait(for: "native embedded-account chooser") {
                tab.passwordChoice?.target == embeddedTarget && tab.passwordChoice?.accounts.contains("bob") == true
            }
            let choice = try XCTUnwrap(tab.passwordChoice)
            let target = try XCTUnwrap(choice.target)
            tab.fillChosen(host: choice.host, account: "bob", port: choice.port, target: target)
            try await wait(for: "explicitly chosen account to fill the embedded username") {
                try await js(tab.web, "embedded.contentDocument.getElementById('user').value") as? String == "bob"
            }
            _ = try await js(tab.web, "document.body.innerHTML='<form><input autocomplete=username value=bob></form>'")
            try await submitUsernameAndLoadPassword(tab, origin: origin)
            try await Task.sleep(for: .milliseconds(250))
            expectEqual(try await js(tab.web, "password.value") as? String, "")
        }
    }

    func testReplacementUsernameFormCannotReuseExplicitSelection() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "username",
                html: "<form><input id=user autocomplete=username></form>")
            tab.fillChosen(host: origin.host, account: "bob")
            try await wait { try await js(tab.web, "user.value") as? String == "bob" }
            _ = try await js(tab.web, "document.body.innerHTML='<form><input autocomplete=username value=bob></form>'")
            try await submitUsernameAndLoadPassword(tab, origin: origin)
            try await Task.sleep(for: .milliseconds(250))
            expectEqual(try await js(tab.web, "password.value") as? String, "")
        }
    }

    func testSuccessfulContinuationIsConsumedEvenWhenSiteFocusStartsAnotherRead() async throws {
        try await withNativeContinuationFixture { tab, origin in
            try await loadContinuationPage(tab, origin: origin, path: "username",
                html: "<form><input id=user autocomplete=username></form>")
            tab.fillChosen(host: origin.host, account: "bob")
            try await wait { try await js(tab.web, "user.value") as? String == "bob" }
            _ = try await js(tab.web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
            try await Task.sleep(for: .milliseconds(100))
            try await loadContinuationPage(tab, origin: origin, path: "password", html: """
                <form id=login><input id=password type=password autocomplete=current-password></form>
                <script>
                password.addEventListener('input', function () {
                    window.firstFilled = password.value;
                    login.innerHTML = '<input id=replacement type=password autocomplete=current-password>';
                    replacement.focus();
                });
                </script>
                """)
            try await wait { try await js(tab.web, "window.firstFilled || ''") as? String == "bob-secret" }
            try await Task.sleep(for: .milliseconds(250))
            expectEqual(try await js(tab.web, "replacement.value") as? String, "")
        }
    }

    func testRevokedContinuationCannotReadOrFillAfterDelayedPasswordService() async throws {
        for delaySecret in [false, true] {
            try await withNativeContinuationFixture { tab, origin in
                try await loadContinuationPage(tab, origin: origin, path: "username",
                    html: "<form><input id=user autocomplete=username></form>")
                tab.fillChosen(host: origin.host, account: "bob")
                try await wait { try await js(tab.web, "user.value") as? String == "bob" }
                let entered = expectation(description: delaySecret ? "secret read started" : "metadata read started")
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                var reader = tab.passwordReader
                let matches = reader.matches, password = reader.password
                if delaySecret {
                    reader.password = { origin, account, profile in
                        entered.fulfill()
                        _ = release.wait(timeout: .now() + 3)
                        return try password(origin, account, profile)
                    }
                } else {
                    reader.matches = { origin, profile in
                        entered.fulfill()
                        _ = release.wait(timeout: .now() + 3)
                        return try matches(origin, profile)
                    }
                    reader.password = { origin, account, profile in
                        XCTFail("A replaced continuation must not read a secret after metadata returns")
                        return try password(origin, account, profile)
                    }
                }
                tab.passwordReader = reader
                try await submitUsernameAndLoadPassword(tab, origin: origin)
                await fulfillment(of: [entered], timeout: 2)
                // The password target remains live, but another form submits a username
                // without a choice while its earlier continuation read is pending.
                _ = try await js(tab.web, """
                    document.body.insertAdjacentHTML('beforeend','<form id=other><input autocomplete=username value=bob></form>');
                    other.dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}));
                    """)
                try await Task.sleep(for: .milliseconds(100))
                release.signal()
                try await Passwords.flushPendingOperations()
                try await Task.sleep(for: .milliseconds(250))
                expectEqual(try await js(tab.web, "password.value") as? String, "")
            }
        }
    }

    func testUsernameInputHandlerCannotRedirectSecretIntoHiddenPassword() async throws {
        let (web, _) = try await fixture("""
            <form><input id=user autocomplete=username><input id=password type=password></form>
            <script>user.addEventListener('input',()=>{ password.style.visibility='hidden'; });</script>
            """)
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testOpacityHiddenLoginAndOTPDoNotReceiveCredentials() async throws {
        let (web, _) = try await fixture("""
            <form style='opacity:0'><input autocomplete=username><input id=hiddenPassword type=password></form>
            <form><input id=code autocomplete=one-time-code><input id=password type=password></form>
            """)
        _ = try await js(web, "password.focus()")
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "[hiddenPassword.value,code.value,password.value].join('|')") as? String,
                    "||fixture-secret")
    }

    func testNavigationCannotReuseOldDocumentTarget() async throws {
        let (web, _) = try await fixture("<form><input type=password></form>")
        let raw = try await js(web, "window.__vaneAnchor()", world: Autofill.world) as? String
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Any])
        let target = try XCTUnwrap(body["target"] as? String)
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://login.example.test/next")!),
                                 responseHTML: "<form><input id=password type=password></form>")
        try await wait { !web.isLoading }
        expectFalse(try await js(web, Autofill.fillJS(account: "ada", password: "fixture-secret", target: target), world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testNativeBridgeKeepsProfilesPrivateBrowsingAndOriginsIsolated() async throws {
        TestEnvironment.prepare()
        let httpsOnly = HTTPSOnly.enabled
        HTTPSOnly.enabled = false
        defer { HTTPSOnly.enabled = httpsOnly }
        let profile = UUID(), otherProfile = UUID()
        let origin = PasswordOrigin(host: "isolation.example.test")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "ada", password: "owned-secret", profileID: profile)
        else { throw XCTSkip("Disposable Keychain fixtures unavailable") }
        let cases: [(UUID, Bool, String, String)] = [
            (profile, false, "https://isolation.example.test/", "owned-secret"),
            (otherProfile, false, "https://isolation.example.test/", ""),
            (profile, true, "https://isolation.example.test/", ""),
            (profile, false, "http://isolation.example.test/", ""),
            (profile, false, "https://isolation.example.test:8443/", "")
        ]
        for (scope, privateMode, address, expected) in cases {
            if !privateMode { nativeFixtureProfiles.insert(scope) }
            let tab = Tab(isPrivate: privateMode, profileID: scope)
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = tab.web
            window.orderFront(nil)
            defer { tab.tearDown(); window.close() }
            tab.web.loadSimulatedRequest(URLRequest(url: URL(string: address)!),
                responseHTML: "<form><input id=user autocomplete=username><input id=password type=password></form>")
            try await wait { !tab.web.isLoading }
            tab.fillPassword()
            // A requested fill reads the Keychain first; only a refusal can be judged by time.
            if expected.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
            else { try await wait { try await js(tab.web, "password.value") as? String == expected } }
            expectEqual(try await js(tab.web, "password.value") as? String, expected)
            _ = try await js(tab.web, "user.value='typed'; password.value='typed-secret'; document.forms[0].dispatchEvent(new Event('submit',{bubbles:true}))")
            try await Task.sleep(for: .milliseconds(100))
            if privateMode || address.hasPrefix("http:") { expectTrue(tab.pendingSave == nil) }
            else {
                expectEqual(tab.pendingSave?.account, "typed")
                expectEqual(tab.pendingSave?.origin, PasswordOrigin(url: URL(string: address)!))
                expectEqual(tab.pendingSave?.update, false)
            }
            expectEqual(Passwords.password(origin: origin, account: "ada", profileID: profile), "owned-secret")
        }
    }

    func testUsernameReplacementCannotChangeIdentityBeforeSecretWrite() async throws {
        let (web, _) = try await fixture("""
            <form><input id=user autocomplete=username><input id=password type=password></form>
            <script>user.addEventListener('input',()=>{
              user.outerHTML='<input id=user autocomplete=username readonly value=bob>';
            });</script>
            """)
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "[user.value,password.value].join('|')") as? String, "bob|")
    }

    func testDetachedUsernameCannotChangeIdentityBeforeSecretWrite() async throws {
        let (web, _) = try await fixture("""
            <form><input id=user autocomplete=username><input id=password type=password></form>
            <script>user.addEventListener('input',()=>{
              user.value='bob'; user.remove();
            });</script>
            """)
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testDomainRelaxationCannotShareCredentialsAcrossPorts() async throws {
        // document.domain makes these ports DOM-accessible, but not the same origin.
        let listener = try NWListener(using: .tcp, on: .any)
        let html = "<script>document.domain='localhost'</script><form><input id=password type=password></form>"
        let response = Data(("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: " +
                             String(html.utf8.count) + "\r\nConnection: close\r\n\r\n" + html).utf8)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .main)
        defer { listener.cancel() }
        try await wait { (listener.port?.rawValue ?? 0) != 0 }
        let childPort = try XCTUnwrap(listener.port).rawValue
        let parentPort = childPort == 65535 ? childPort - 1 : childPort + 1
        let (web, capture) = try await fixture("""
            <script>document.domain='localhost'</script>
            <iframe id=embedded src='http://localhost:\(childPort)/'></iframe>
            """, url: URL(string: "http://localhost:\(parentPort)/")!)
        try await wait { try await self.js(web, "!!embedded.contentDocument?.getElementById('password')") as? Bool == true }
        _ = try await js(web, "embedded.contentDocument.getElementById('password').focus()")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "embedded.contentDocument.getElementById('password').value") as? String, "")
        expectFalse(capture.messages.contains { $0["focus"] as? Bool == true || $0["ready"] as? Bool == true })
    }

    func testPasswordTypedOneTimeCodeIsNotALoginPassword() async throws {
        let (web, capture) = try await fixture("<form><input id=code type=password autocomplete=one-time-code></form>")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "code.value") as? String, "")
        expectFalse(capture.messages.contains { $0["ready"] as? Bool == true })
    }

    func testReusedUsernameNodeBecomesANewPasswordStep() async throws {
        try await withDocumentFixture("<form><input id=field autocomplete=username></form>") { web, capture in
            try await wait(for: "initial username ready notification") {
                capture.messages.contains { $0["ready"] as? Bool == true }
            }
            expectTrue(try await fill(web))
            let before = capture.messages.filter { $0["ready"] as? Bool == true }.count
            _ = try await js(web, "field.value=''; field.type='password'; field.autocomplete='current-password'")
            try await wait(for: "reused username node to report its password step", diagnostics: {
                let ready = capture.messages.filter { $0["ready"] as? Bool == true }.count
                let onScreen = web.window.map { window in
                    NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
                } ?? false
                return "readyBefore=\(before) readyNow=\(ready) appRunning=\(NSApp.isRunning) " +
                    "windowVisible=\(web.window?.isVisible ?? false) occlusion=\(web.window?.occlusionState.rawValue ?? 0) " +
                    "onScreen=\(onScreen) webHidden=\(web.isHiddenOrHasHiddenAncestor) loading=\(web.isLoading)"
            }) { capture.messages.filter { $0["ready"] as? Bool == true }.count > before }
            XCTAssertGreaterThan(capture.messages.filter { $0["ready"] as? Bool == true }.count, before)
            expectEqual(capture.messages.last { $0["ready"] as? Bool == true }?["accountHint"] as? String, "ada")
            expectFalse(try await fill(web, account: "bob", automatic: true))
        }
    }

    func testEditedAccountReplacesEarlierChoiceBeforeUsernameRemoval() async throws {
        let (web, _) = try await fixture("<form><input id=user autocomplete=username><input id=password type=password></form>")
        expectTrue(try await fill(web))
        _ = try await js(web, """
            user.value='bob'; user.dispatchEvent(new Event('input',{bubbles:true}));
            password.value=''; user.remove();
            """)
        expectFalse(try await fill(web, automatic: true))
        expectTrue(try await fill(web, account: "bob", automatic: true))
    }

    func testClearingUsernameCancelsItsAccountContinuity() async throws {
        let (web, _) = try await fixture("<form><input id=user autocomplete=username><input id=password type=password></form>")
        expectTrue(try await fill(web))
        _ = try await js(web, "user.value=''; user.dispatchEvent(new Event('input',{bubbles:true})); password.value=''; user.remove()")
        let raw = try await js(web, "window.__vaneAnchor()", world: Autofill.world) as? String
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Any])
        expectEqual(body["accountHint"] as? String, "")
    }

    func testReadOnlyIdentitySupersedesAnEarlierPasswordOnlyChoice() async throws {
        let (web, _) = try await fixture("<form id=login><input id=password type=password></form>")
        expectTrue(try await fill(web))
        _ = try await js(web, "password.value=''; login.insertAdjacentHTML('afterbegin','<input autocomplete=username readonly value=bob>')")
        expectFalse(try await fill(web, automatic: true))
        expectTrue(try await fill(web, account: "bob", automatic: true))
    }

    func testAmbiguousUnmarkedPasswordFieldsDoNotAutofill() async throws {
        let (web, _) = try await fixture("<form><input autocomplete=username><input id=first type=password><input id=second type=password></form>")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "first.value + second.value") as? String, "")
    }

    func testSemanticNonUsernameFieldIsNeverUsedAsAccount() async throws {
        let (web, _) = try await fixture("<form><input id=name autocomplete=given-name><input id=password type=password></form>")
        expectTrue(try await fill(web))
        expectEqual(try await js(web, "document.getElementById('name').value") as? String, "")
    }

    func testCurrentPasswordAutocompleteOnTextFieldDoesNotReceiveSecret() async throws {
        let (web, _) = try await fixture("<form><input id=field autocomplete=current-password></form>")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "field.value") as? String, "")
    }

    func testAbandoningFilledFormDoesNotOfferToSave() async throws {
        let (web, capture) = try await fixture("<form><input autocomplete=username value=ada><input type=password value=typed-secret></form>")
        _ = try await js(web, "window.dispatchEvent(new Event('pagehide'))")
        try await Task.sleep(for: .milliseconds(150))
        expectFalse(capture.messages.contains { $0["password"] != nil })
    }

    func testMismatchedNewPasswordConfirmationDoesNotOffer() async throws {
        let (web, capture) = try await fixture("<form><input autocomplete=username value=ada><input type=password autocomplete=new-password value=first><input type=password autocomplete=new-password value=second></form>")
        _ = try await js(web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true}))")
        try await Task.sleep(for: .milliseconds(100))
        expectFalse(capture.messages.contains { $0["password"] != nil })
    }

    func testChooserTargetIncludesItsUsernameNode() async throws {
        let (web, _) = try await fixture("<form><input id=user autocomplete=username><input id=password type=password></form>")
        let raw = try await js(web, "window.__vaneAnchor()", world: Autofill.world) as? String
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw?.data(using: .utf8))) as? [String: Any])
        let target = try XCTUnwrap(body["target"] as? String)
        _ = try await js(web, "user.outerHTML='<input id=user autocomplete=username>'")
        expectFalse(try await js(web, Autofill.fillJS(account: "ada", password: "fixture-secret", target: target), world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testGeneratorFillsOnlyNewPasswordsAndTheirConfirmation() async throws {
        let (web, capture) = try await fixture("<form><input id=old type=password autocomplete=current-password value=keep><input id=newPassword type=password autocomplete=new-password><input id=confirmation type=password autocomplete=new-password></form>")
        _ = try await js(web, "newPassword.focus()")
        try await Task.sleep(for: .milliseconds(100))
        let target = capture.messages.last { $0["generate"] as? Bool == true }?["target"] as? String ?? "missing"
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["generated-fixture", target]), as: UTF8.self)
        expectTrue(try await js(web, "!!window.__vaneGenerate && window.__vaneGenerate.apply(null," + args + ")", world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "[old.value,newPassword.value,confirmation.value].join('|')") as? String, "keep|generated-fixture|generated-fixture")
    }

    func testGeneratedPasswordRevalidatesConfirmationAfterSiteEvents() async throws {
        let (web, capture) = try await fixture("<form><input id=newPassword type=password autocomplete=new-password><input id=confirmation type=password autocomplete=new-password></form><script>newPassword.addEventListener('input',()=>{confirmation.autocomplete='current-password'});</script>")
        _ = try await js(web, "newPassword.focus()")
        try await Task.sleep(for: .milliseconds(100))
        let target = capture.messages.last { $0["generate"] as? Bool == true }?["target"] as? String ?? "missing"
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["generated-fixture", target]), as: UTF8.self)
        expectFalse(try await js(web, "!!window.__vaneGenerate && window.__vaneGenerate.apply(null," + args + ")", world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "confirmation.value") as? String, "")
    }

    func testOffscreenPasswordIsNotAVisibleLogin() async throws {
        let (web, _) = try await fixture("<form style='position:absolute;left:-9999px'><input autocomplete=username><input id=password type=password></form>")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testCrossOriginAndDowngradedFormActionsDoNotReceiveCredentials() async throws {
        for action in ["https://other.example.test/login", "http://login.example.test/login"] {
            let (web, _) = try await fixture("<form action='\(action)'><input autocomplete=username><input id=password type=password></form>")
            expectFalse(try await fill(web))
            expectEqual(try await js(web, "password.value") as? String, "")
        }
    }

    func testUnmarkedOldAndNewPasswordsDoNotOfferAmbiguousGeneration() async throws {
        let (web, capture) = try await fixture("<form><input id=first type=password><input id=second type=password></form>")
        _ = try await js(web, "second.focus()")
        try await Task.sleep(for: .milliseconds(100))
        expectFalse(capture.messages.contains { $0["generate"] as? Bool == true })
    }

    func testRepeatedSubmissionOffersOnlyOneAttempt() async throws {
        let (web, capture) = try await fixture("<form><input autocomplete=username value=ada><input type=password value=fixture></form>")
        _ = try await js(web, "for(let i=0;i<3;i++) document.forms[0].dispatchEvent(new Event('submit',{bubbles:true}))")
        try await Task.sleep(for: .milliseconds(150))
        expectEqual(capture.messages.filter { $0["password"] != nil }.count, 1)
    }

    func testVisibleLoginErrorRetractsItsUnverifiedAttempt() async throws {
        let (web, capture) = try await fixture("<form><input autocomplete=username value=ada><input id=password type=password value=fixture></form>")
        _ = try await js(web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["attempt"] != nil } }
        let attempt = capture.messages.last { $0["attempt"] != nil }?["attempt"] as? String
        _ = try await js(web, "password.setAttribute('aria-invalid','true')")
        try await wait { capture.messages.contains { $0["rejectedAttempt"] != nil } }
        expectEqual(capture.messages.last { $0["rejectedAttempt"] != nil }?["rejectedAttempt"] as? String, attempt)
    }

    func testAutomaticFillRespectsAutocompleteOffButExplicitChoiceIsAllowed() async throws {
        let (web, _) = try await fixture("<form autocomplete=off><input id=user autocomplete=username><input id=password type=password autocomplete=current-password></form>")
        expectFalse(try await fill(web, automatic: true))
        expectEqual(try await js(web, "password.value") as? String, "")
        expectTrue(try await fill(web))
    }

    func testEmbeddedUsernameHandlerCannotMoveFocusBeforePasswordWrite() async throws {
        let (web, _) = try await fixture("<button id=outside>Outside</button><iframe id=embedded srcdoc='<form><input id=user autocomplete=username><input id=password type=password autocomplete=current-password></form>'></iframe>")
        try await wait { try await self.js(web, "!!embedded.contentDocument.getElementById('password')") as? Bool == true }
        _ = try await js(web, "embedded.contentDocument.getElementById('user').addEventListener('input',()=>outside.focus()); embedded.contentDocument.getElementById('password').focus()")
        expectFalse(try await fill(web))
        expectEqual(try await js(web, "embedded.contentDocument.getElementById('password').value") as? String, "")
    }

    func testEmbeddedGeneratorRechecksFrameFocusBetweenFields() async throws {
        let (web, capture) = try await fixture("<button id=outside>Outside</button><iframe id=embedded srcdoc='<form><input id=newPassword type=password autocomplete=new-password><input id=confirmation type=password autocomplete=new-password></form>'></iframe>")
        try await wait { try await self.js(web, "!!embedded.contentDocument.getElementById('newPassword')") as? Bool == true }
        _ = try await js(web, "embedded.contentDocument.getElementById('newPassword').addEventListener('input',()=>outside.focus()); embedded.contentDocument.getElementById('newPassword').focus()")
        try await wait { capture.messages.contains { $0["generate"] as? Bool == true } }
        let target = try XCTUnwrap(capture.messages.last { $0["generate"] as? Bool == true }?["target"] as? String)
        expectFalse(try await js(web, Autofill.generateJS(password: "generated-fixture", target: target), world: Autofill.world) as? Bool == true)
        expectEqual(try await js(web, "embedded.contentDocument.getElementById('confirmation').value") as? String, "")
    }

}
