import AppKit
import WebKit
import Network
import XCTest
@testable import vane

@MainActor final class PasswordAutofillTests: XCTestCase {
    private var nativeFixtureProfiles: Set<UUID> = []

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

    private func fixture(_ html: String, url: URL = URL(string: "https://login.example.test/signin")!) async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
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
        window.setFrameOrigin(CGPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "vanepw", contentWorld: Autofill.world)
            window.close()
        }
        web.loadSimulatedRequest(URLRequest(url: url),
                                 responseHTML: "<!doctype html><body>" + html + "</body>")
        try await wait { !web.isLoading }
        return (web, capture)
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

    private func wait(for stage: String = "fixture condition", file: StaticString = #filePath, line: UInt = #line,
                      diagnostics: () async -> String = { "" },
                      _ condition: () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        do {
            while try await !condition() {
                if Date.now > deadline { throw FixtureTimeout(stage: stage) }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            NativeFixtureDiagnostics.emit("\(file):\(line): Failed waiting for \(stage): \(error); collecting native diagnostics")
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
        let (web, capture) = try await fixture("<form id=login hidden><input id=password type=text disabled></form>")
        try await Task.sleep(for: .milliseconds(150))
        let before = capture.messages.filter { $0["ready"] as? Bool == true }.count
        _ = try await js(web, "password.type='password'; password.disabled=false; login.hidden=false")
        // Offscreen WebKit can defer its MutationObserver/message delivery under
        // load. Wait for the tested notification, with the fixture's bounded timeout.
        try await wait { capture.messages.filter { $0["ready"] as? Bool == true }.count > before }
        XCTAssertGreaterThan(capture.messages.filter { $0["ready"] as? Bool == true }.count, before)
        expectTrue(try await fill(web))
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

    private func withNativeContinuationFixture(_ body: (Tab, PasswordOrigin) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let profile = UUID(), origin = PasswordOrigin(host: "continuation.example.test")
        defer { Passwords.deleteAll(profileID: profile) }
        guard Passwords.save(origin: origin, account: "bob", password: "bob-secret", profileID: profile),
              Passwords.save(origin: origin, account: "ada", password: "ada-secret", profileID: profile)
        else { throw XCTSkip("Disposable Keychain fixtures unavailable") }
        nativeFixtureProfiles.insert(profile)
        let tab = Tab(profileID: profile)
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { tab.tearDown(); window.close() }
        try await body(tab, origin)
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

    private func loadContinuationPage(_ tab: Tab, origin: PasswordOrigin, path: String, html: String) async throws {
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

    private func submitUsernameAndLoadPassword(_ tab: Tab, origin: PasswordOrigin, identity: String = "") async throws {
        _ = try await js(tab.web, "document.forms[0].dispatchEvent(new Event('submit',{bubbles:true,cancelable:true}))")
        // Let the native bridge receive the submitted username before starting navigation.
        try await Task.sleep(for: .milliseconds(100))
        try await loadContinuationPage(tab, origin: origin, path: "password",
            html: "<form>" + identity + "<input id=password type=password autocomplete=current-password></form>")
    }

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
        let (web, capture) = try await fixture("<form><input id=field autocomplete=username></form>")
        try await Task.sleep(for: .milliseconds(150))
        expectTrue(try await fill(web))
        let before = capture.messages.filter { $0["ready"] as? Bool == true }.count
        _ = try await js(web, "field.value=''; field.type='password'; field.autocomplete='current-password'")
        try await wait { capture.messages.filter { $0["ready"] as? Bool == true }.count > before }
        XCTAssertGreaterThan(capture.messages.filter { $0["ready"] as? Bool == true }.count, before)
        expectEqual(capture.messages.last { $0["ready"] as? Bool == true }?["accountHint"] as? String, "ada")
        expectFalse(try await fill(web, account: "bob", automatic: true))
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
