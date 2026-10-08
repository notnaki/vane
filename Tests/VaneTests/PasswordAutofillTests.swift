import AppKit
import WebKit
import Network
import XCTest
@testable import vane

@MainActor final class PasswordAutofillTests: XCTestCase {
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

    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while try await !condition() {
            if Date.now > deadline { throw NSError(domain: "PasswordFixtureTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
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
        try await Task.sleep(for: .milliseconds(200))
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
            try await Task.sleep(for: .milliseconds(200))
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

}
