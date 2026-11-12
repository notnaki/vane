import AppKit
import WebKit
import XCTest
@testable import vane

/// Real WebKit, with an attached but never ordered window. These fixtures do not
/// activate an app, synthesize native input, take screenshots, or use Keychain.
@MainActor final class PasswordShadowAutofillTests: XCTestCase {
    private final class Capture: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
    }
    private func js(_ web: WKWebView, _ source: String, isolated: Bool = false) async throws -> Any? {
        let data: Data? = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(source, in: nil, in: isolated ? Autofill.world : .page) { result in
                do {
                    let value: Any? = try result.get()
                    guard let value else { continuation.resume(returning: nil); return }
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
                } catch { continuation.resume(throwing: error) }
            }
        }
        return try data.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
    }
    private func wait(_ stage: String = "fixture outcome", file: StaticString = #filePath,
                      line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Focus-free WebKit fixture timed out: \(stage); appRunning=\(NSApp.isRunning)", file: file, line: line)
        throw NSError(domain: "PasswordShadowFixtureTimeout", code: 1)
    }
    private func fixture(_ html: String,
                         url: URL = URL(string: "https://login.example.test/signin")!, tracking: String = "",
                         retireWith: ((@escaping @MainActor @Sendable () -> Void) -> Void)? = nil) async throws -> (WKWebView, Capture) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let config = WKWebViewConfiguration(), capture = Capture()
        // This fixture never orders its window. JavaScript evaluation can wake
        // WebContent just for the API reply, while discovery's delayed callbacks
        // still need a runnable process after that reply. Admit that prerequisite
        // explicitly instead of depending on background suspension timing.
        config.preferences.inactiveSchedulingPolicy = .none
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(capture, contentWorld: Autofill.world, name: "vanepw")
        if !tracking.isEmpty {
            config.userContentController.addUserScript(WKUserScript(source: tracking,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Autofill.world))
        }
        config.userContentController.addUserScript(WKUserScript(source: Autofill.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Autofill.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        let retire: @MainActor @Sendable () -> Void = {
            web.stopLoading()
            config.userContentController.removeScriptMessageHandler(forName: "vanepw", contentWorld: Autofill.world)
            window.contentView = nil
            window.close()
        }
        if let retireWith { retireWith(retire) }
        else { addTeardownBlock { @MainActor in retire() } }
        web.loadSimulatedRequest(URLRequest(url: url),
            responseHTML: "<!doctype html><body>" + html + "</body>")
        try await wait("document load and isolated API") {
            guard !web.isLoading else { return false }
            return try await self.js(web, "typeof __vaneFill", isolated: true) as? String == "function"
        }
        return (web, capture)
    }
    private func expectEqual<T: Equatable>(_ value: T, _ expected: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(value, expected, message, file: file, line: line)
    }
    private func fill(_ web: WKWebView, account: String = "ada", target: String? = nil) async throws -> Bool {
        try await js(web, Autofill.fillJS(account: account, password: "fixture-secret", target: target), isolated: true) as? Bool == true
    }
    private func anchor(_ web: WKWebView) async throws -> [String: Any]? {
        guard let raw = try await js(web, "__vaneAnchor()", isolated: true) as? String,
              let data = raw.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
    }
    private let login = "<form id=login><input id=user autocomplete=username><input id=password type=password autocomplete=current-password><button>Sign in</button></form>"
    // Wrap real WebKit getters without changing their results or suppressing their
    // diagnostics. A caught exception does not conceal a forbidden native probe.
    private static let frameAccessTracking = #"""
    globalThis.__blockedFrameReads = 0;
    globalThis.__frameSecurityErrors = [];
    for (const type of [HTMLIFrameElement, HTMLFrameElement]) {
      const doc = Object.getOwnPropertyDescriptor(type.prototype, 'contentDocument');
      const win = Object.getOwnPropertyDescriptor(type.prototype, 'contentWindow');
      Object.defineProperty(type.prototype, 'contentDocument', {...doc, get() {
        const child = win.get.call(this);
        if (child && Object.getPrototypeOf(child) === null) __blockedFrameReads++;
        return doc.get.call(this);
      }});
    }
    addEventListener('error', event => {
      if (event.error?.name === 'SecurityError' || /blocked a frame|cross.origin/i.test(event.message))
        __frameSecurityErrors.push(event.message);
    });
    """#
    private func shadow(_ content: String, nested: Bool = true) -> String {
        let literal = String(decoding: try! JSONSerialization.data(withJSONObject: [content]), as: UTF8.self)
        return """
        <div id=host></div><script>
        var outer=host.attachShadow({mode:'open'}); var root=outer;
        \(nested ? "outer.innerHTML='<div id=inner></div>'; root=outer.getElementById('inner').attachShadow({mode:'open'});" : "")
        root.innerHTML=\(literal)[0]; var login=root.getElementById('login');
        var user=root.getElementById('user'), password=root.getElementById('password');
        </script>
        """
    }

    func testFocusFreeOrdinaryLoginBaselineFillsAndCapturesWithoutSubmitting() async throws {
        let (web, capture) = try await fixture(login)
        let filled = try await fill(web)
        XCTAssertTrue(filled)
        expectEqual(try await js(web, "password.value") as? String, "fixture-secret")
        XCTAssertFalse(capture.messages.contains { $0["password"] != nil })
        _ = try await js(web, "login.dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["password"] as? String == "fixture-secret" } }
    }

    func testNestedOpenShadowLoginFillsComposedEventsAndCapturesLocalSubmit() async throws {
        let (web, capture) = try await fixture(shadow(login))
        _ = try await js(web, "var inputs=0, changes=0; host.addEventListener('input',()=>inputs++); host.addEventListener('change',()=>changes++); password.focus()")
        let filled = try await fill(web)
        XCTAssertTrue(filled)
        try await wait { capture.messages.contains { $0["focus"] as? Bool == true } }
        expectEqual(try await js(web, "[user.value,password.value,inputs,changes].join('|')") as? String, "ada|fixture-secret|2|2")
        XCTAssertFalse(capture.messages.contains { $0["password"] != nil })
        _ = try await js(web, "login.dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["password"] as? String == "fixture-secret" } }
        XCTAssertEqual(capture.messages.last { $0["password"] != nil }?["account"] as? String, "ada")
    }

    func testLateAttachedNestedRootsAndFieldsNotifyDiscoveryWithoutLightDOMMutation() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do {
            try await compatibilityWait { try loop.isReadyForInteraction() }
            try await checkLateAttachedNestedRoots()
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Shadow discovery AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkLateAttachedNestedRoots() async throws {
        XCTAssertTrue(NSApp.isRunning,
                      "Shadow discovery requires an admitted AppKit loop before WebKit starts")
        var retire: (@MainActor @Sendable () -> Void)?
        defer { retire?() }
        // Retire inside the owned loop, including when fixture admission throws.
        let (web, capture) = try await fixture("<div id=host></div>", retireWith: { retire = $0 })
        _ = try await js(web, "var root=host.attachShadow({mode:'open'}); root.innerHTML='<div id=inner></div>'; var inner=root.getElementById('inner'); var nested=inner.attachShadow({mode:'open'}); nested.innerHTML='<form><input autocomplete=username><input id=password type=password></form>'")
        try await wait("late shadow root discovery") { capture.messages.contains { $0["ready"] as? Bool == true } }
        let originalAnchor = try await anchor(web)
        let old = try XCTUnwrap(originalAnchor?["target"] as? String)
        let count = capture.messages.filter { $0["ready"] as? Bool == true }.count
        _ = try await js(web, "nested.getElementById('password').outerHTML='<input id=password type=password autocomplete=current-password>'")
        try await wait("replacement shadow field discovery") { capture.messages.filter { $0["ready"] as? Bool == true }.count > count }
        let stale = try await fill(web, target: old)
        XCTAssertFalse(stale)
        let current = try await fill(web)
        XCTAssertTrue(current)
    }

    func testShadowHostVisibilityAndInertBoundariesRefuseWriting() async throws {
        for attribute in ["hidden", "inert", "aria-hidden='true'", "style='opacity:0'", "style='visibility:hidden'", "style='clip-path:inset(0)'", "style='height:1px;overflow:hidden;padding-top:0'"] {
            let (web, _) = try await fixture(shadow(login))
            _ = try await js(web, "host.outerHTML")
            let literal = String(decoding: try JSONSerialization.data(withJSONObject: [attribute]), as: UTF8.self)
            _ = try await js(web, "var temp=document.createElement('div'); temp.innerHTML='<div '+\(literal)[0]+'></div>'; for(var a of temp.firstChild.attributes) host.setAttribute(a.name,a.value); \(attribute.contains("height") ? "root.getElementById('login').style.transform='translateY(100px)'" : "")")
            let filled = try await fill(web)
            XCTAssertFalse(filled, attribute)
            expectEqual(try await js(web, "password.value") as? String, "", attribute)
        }
    }

    func testShadowClosedRootsAmbiguousPasswordsAndUnsafeActionsRefuse() async throws {
        for content in ["<form><input type=password><input type=password></form>", "<form action='https://other.example.test'><input type=password></form>", "<form><input type=password><button formaction='http://login.example.test'>Go</button></form>"] {
            let (web, _) = try await fixture(shadow(content))
            let filled = try await fill(web)
            XCTAssertFalse(filled, content)
        }
        let (web, capture) = try await fixture("<div id=host></div><script>var root=host.attachShadow({mode:'closed'}); root.innerHTML='<form><input type=password value=closed-secret></form>';</script>")
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        _ = try await js(web, "root.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true}))")
        XCTAssertFalse(capture.messages.contains { $0["password"] != nil })
    }

    func testRetainedSeparateUsernameFormExplicitlyLabelsNewPasswordStep() async throws {
        let (web, capture) = try await fixture("<section><form id=identity><input id=user autocomplete=username></form><form id=login></form></section>")
        let first = try await fill(web)
        XCTAssertTrue(first)
        _ = try await js(web, "identity.hidden=true; login.innerHTML='<input id=password type=password autocomplete=current-password aria-labelledby=user>'; password.focus()")
        expectEqual(try await anchor(web)?["accountHint"] as? String, "ada")
        let wrong = try await fill(web, account: "bob")
        XCTAssertFalse(wrong, "The explicit previous-step identity must constrain this password")
        let right = try await fill(web)
        XCTAssertTrue(right)
        _ = try await js(web, "login.dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["password"] as? String == "fixture-secret" } }
        XCTAssertEqual(capture.messages.last { $0["password"] != nil }?["account"] as? String, "ada")
    }
    func testExplicitStepAssociationRequiresUniqueSameTreeRememberedIdentity() async throws {
        for modification in ["password.removeAttribute('aria-labelledby')", "password.setAttribute('aria-labelledby','other')", "user.value='mallory'", "identity.hidden=false", "user.id='changed'", "identity.insertAdjacentHTML('beforeend','<input id=user autocomplete=username value=mallory>')", "identity.action='https://other.example.test'"] {
            let (web, _) = try await fixture("<form id=identity><input id=user autocomplete=username></form><form id=login></form><span id=other>ada</span>")
            let first = try await fill(web)
            XCTAssertTrue(first)
            _ = try await js(web, "identity.hidden=true; login.innerHTML='<input id=password type=password aria-labelledby=user>'; " + modification)
            // Without a valid explicit association this is an independent password-only
            // form. It must never claim the old account as a continuation hint.
            expectEqual(try await anchor(web)?["accountHint"] as? String, "", modification)
        }
    }

    func testShadowGenerationRevalidatesFieldAndHostAfterComposedInput() async throws {
        let content = "<form id=login><input id=password type=password autocomplete=new-password><input id=confirmation type=password autocomplete=new-password></form>"
        let (web, capture) = try await fixture(shadow(content))
        _ = try await js(web, "password.focus()")
        try await wait { capture.messages.contains { $0["generate"] as? Bool == true } }
        let target = try XCTUnwrap(capture.messages.last { $0["generate"] as? Bool == true }?["target"] as? String)
        _ = try await js(web, "host.addEventListener('input',()=>host.inert=true,{once:true})")
        let generated = try await js(web, Autofill.generateJS(password: "generated-fixture", target: target), isolated: true) as? Bool
        XCTAssertEqual(generated, false)
        expectEqual(try await js(web, "root.getElementById('confirmation').value") as? String, "")
    }

    func testShadowUsernameEventCannotReplacePasswordOrMoveIntoHiddenHost() async throws {
        for mutation in ["password.outerHTML='<input id=password type=password>'", "host.setAttribute('aria-hidden','true')"] {
            let (web, _) = try await fixture(shadow(login))
            _ = try await js(web, "user.addEventListener('input',()=>{" + mutation + "},{once:true})")
            let filled = try await fill(web)
            XCTAssertFalse(filled)
            expectEqual(try await js(web, "root.getElementById('password').value") as? String, "")
        }
    }

    func testShadowFormHostHonorsOuterActionAndSlottedVisibility() async throws {
        let (web, _) = try await fixture("<form action='https://other.example.test'><div id=host></div></form><script>var root=host.attachShadow({mode:'open'}); root.innerHTML='<input type=password>';</script>")
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        let (slotted, _) = try await fixture("<form><div id=host><input id=password type=password slot=secret></div></form><script>host.attachShadow({mode:'open'}).innerHTML='<section inert><slot name=secret></slot></section>';</script>")
        let slotFill = try await fill(slotted)
        XCTAssertFalse(slotFill)
    }

    func testShadowSubmitRetractionAndPageLifecycleTeardown() async throws {
        let (web, capture) = try await fixture(shadow(login))
        let filled = try await fill(web)
        XCTAssertTrue(filled)
        _ = try await js(web, "login.dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["attempt"] != nil } }
        let attempt = capture.messages.last { $0["attempt"] != nil }?["attempt"] as? String
        _ = try await js(web, "password.setAttribute('aria-invalid','true')")
        try await wait { capture.messages.contains { $0["rejectedAttempt"] as? String == attempt } }
        _ = try await js(web, "window.dispatchEvent(new Event('pagehide'))")
        let count = capture.messages.count
        _ = try await js(web, "root.innerHTML='<input type=password>'; host.remove()")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(capture.messages.count, count, "Paused discovery must not retain callbacks into a removed root")
        _ = try await js(web, "document.body.append(outer.host); window.dispatchEvent(new Event('pageshow'))")
        try await wait { capture.messages.count > count }
    }

    func testDeepFocusedUnrelatedInputRefusesCachedShadowLogin() async throws {
        let (web, _) = try await fixture(shadow(login + "<input id=search autocomplete=one-time-code>"))
        _ = try await js(web, "password.focus()")
        let original = try await anchor(web)
        let target = try XCTUnwrap(original?["target"] as? String)
        _ = try await js(web, "root.getElementById('search').focus()")
        let filled = try await fill(web, target: target)
        XCTAssertFalse(filled)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testShadowRootReplacementAndNavigationRefuseOldTarget() async throws {
        let (web, _) = try await fixture(shadow(login))
        let original = try await anchor(web)
        let target = try XCTUnwrap(original?["target"] as? String)
        _ = try await js(web, "host.replaceWith(host.cloneNode(false)); var replacement=document.getElementById('host').attachShadow({mode:'open'}); replacement.innerHTML='<input type=password>'")
        let replaced = try await fill(web, target: target)
        XCTAssertFalse(replaced)
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://login.example.test/next")!), responseHTML: login)
        try await wait { !web.isLoading }
        try await wait { try await self.js(web, "typeof __vaneFill", isolated: true) as? String == "function" }
        let navigated = try await fill(web, target: target)
        XCTAssertFalse(navigated)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testShadowHostedSameOriginFrameRequiresDeepFrameFocus() async throws {
        let content = "<iframe id=embedded srcdoc='<form id=login><input id=user autocomplete=username><input id=password type=password></form>'></iframe>"
        let (web, capture) = try await fixture(shadow(content))
        try await wait { try await self.js(web, "!!root.getElementById('embedded').contentDocument?.getElementById('password')") as? Bool == true }
        let unfocused = try await fill(web)
        XCTAssertFalse(unfocused)
        _ = try await js(web, "var frame=root.getElementById('embedded'); frame.contentDocument.getElementById('password').focus()")
        try await wait { capture.messages.contains { $0["focus"] as? Bool == true } }
        let focused = try await fill(web)
        XCTAssertTrue(focused)
        expectEqual(try await js(web, "frame.contentDocument.getElementById('password').value") as? String, "fixture-secret")
        _ = try await js(web, "frame.contentDocument.getElementById('login').dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["password"] as? String == "fixture-secret" } }
    }

    func testShadowHostedOpaqueFrameCannotEnterBridge() async throws {
        let (web, capture) = try await fixture(shadow("<iframe sandbox='allow-scripts' srcdoc='<form><input type=password value=opaque-secret></form>'></iframe>"))
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        XCTAssertFalse(capture.messages.contains { $0["password"] != nil || $0["focus"] as? Bool == true })
    }

    func testCrossOriginRedirectedAndCSPFramesNeverProbeForbiddenDocuments() async throws {
        let server = try NavigationHTTPFixture()
        defer { server.stop() }
        try await wait("loopback listener") { server.port != nil }
        let foreign = try server.url("/foreign", host: "localhost")
        server.redirects["/redirect"] = foreign
        server.pages["/foreign"] = "<script>parent.postMessage('foreign-ready','*')</script><input type=password value=foreign-secret>"
        server.pages["/csp"] = "<script>parent.postMessage('csp-ready','*')</script><input type=password value=opaque-secret>"
        server.responseHeaders["/csp"] = ["Content-Security-Policy": "sandbox allow-scripts"]
        let (web, capture) = try await fixture("""
            <script>window.frameLoads=[];addEventListener('message',e=>frameLoads.push(e.data));</script>
            <iframe id=foreign src="\(foreign)"></iframe>
            <iframe id=redirected src="\(try server.url("/redirect"))"></iframe>
            <iframe id=csp src="\(try server.url("/csp"))"></iframe>
            """, url: try server.url("/top"), tracking: Self.frameAccessTracking)
        try await wait("real foreign, redirected, and CSP sandbox documents") {
            try await self.js(web, "frameLoads.filter(x=>x==='foreign-ready').length===2 && frameLoads.includes('csp-ready')") as? Bool == true
        }
        let inaccessible = try await js(web, "['foreign','redirected','csp'].every(id=>Object.getPrototypeOf(document.getElementById(id).contentWindow)===null)") as? Bool
        XCTAssertEqual(inaccessible, true)
        _ = try await js(web, """
            for (const id of ['foreign','redirected','csp']) {
              const frame=document.getElementById(id);
              frame.dispatchEvent(new Event('load'));
              frame.focus();
            }
            """)
        expectEqual(try await fill(web), false)
        expectEqual(try await js(web, "__blockedFrameReads", isolated: true) as? Int, 0)
        expectEqual(try await js(web, "__frameSecurityErrors.length", isolated: true) as? Int, 0)
        XCTAssertFalse(capture.messages.contains { $0["password"] != nil || $0["focus"] as? Bool == true })
    }

    func testShadowFrameBecomingOpaqueRetiresQuietlyAndCanReturnToSameOrigin() async throws {
        let content = "<iframe id=embedded sandbox='allow-scripts allow-same-origin' srcdoc='\(login)'></iframe>"
        let (web, capture) = try await fixture(shadow(content) + "<iframe id=discoveryTrigger srcdoc='<p>Ready</p>'></iframe>",
                                               tracking: Self.frameAccessTracking)
        try await wait("same-origin shadow frame") {
            try await self.js(web, "!!root.getElementById('embedded').contentDocument?.getElementById('password')") as? Bool == true
        }
        _ = try await js(web, "var frame=root.getElementById('embedded');frame.contentDocument.getElementById('password').focus()")
        try await wait("admitted frame focus") { capture.messages.contains { $0["focus"] as? Bool == true } }
        let proposed = try await anchor(web)
        let target = try XCTUnwrap(proposed?["target"] as? String)
        expectEqual(try await fill(web), true)
        _ = try await js(web, """
            window.opaqueReady=false;addEventListener('message',e=>{if(e.data==='opaque-ready')opaqueReady=true;});
            frame.removeAttribute('srcdoc');
            frame.src='data:text/html,<script>parent.postMessage("opaque-ready","*")</script><input type=password>';
            """)
        try await wait("opaque replacement document") { try await self.js(web, "opaqueReady && Object.getPrototypeOf(frame.contentWindow)===null") as? Bool == true }
        // A light-DOM frame load exercises discovery across all open shadow roots.
        _ = try await js(web, "discoveryTrigger.dispatchEvent(new Event('load'));frame.focus()")
        expectEqual(try await fill(web, target: target), false)
        expectEqual(try await js(web, "__blockedFrameReads", isolated: true) as? Int, 0)
        expectEqual(try await js(web, "__frameSecurityErrors.length", isolated: true) as? Int, 0)

        let literal = String(decoding: try JSONSerialization.data(withJSONObject: [login]), as: UTF8.self)
        _ = try await js(web, "frame.srcdoc=\(literal)[0]")
        try await wait("same-origin replacement document") { try await self.js(web, "!!frame.contentDocument?.getElementById('password')") as? Bool == true }
        _ = try await js(web, "discoveryTrigger.dispatchEvent(new Event('load'));frame.contentDocument.getElementById('password').focus()")
        expectEqual(try await fill(web, target: target), false)
        expectEqual(try await fill(web), true)
        expectEqual(try await js(web, "frame.contentDocument.getElementById('password').value") as? String, "fixture-secret")
    }

    func testFocusedShadowControlsCannotBypassOuterFormAction() async throws {
        for content in ["<section role=form><input id=password type=password></section>", "<form><input id=password type=password></form>"] {
            let markup = shadow(content).replacingOccurrences(of: "<div id=host></div>", with: "<form action='https://other.example.test'><div id=host></div></form>")
            let (web, _) = try await fixture(markup)
            _ = try await js(web, "password.focus()")
            let filled = try await fill(web)
            XCTAssertFalse(filled, content)
            expectEqual(try await js(web, "password.value") as? String, "")
        }
    }

    func testExhaustedShadowTraversalRefusesFocusedFormWithoutUsingPartialControls() async throws {
        let (web, _) = try await fixture("<form id=login><input id=password type=password><div id=host></div></form><script>var root=host.attachShadow({mode:'open'}); root.innerHTML='<span></span>'.repeat(20001)+'<button formaction=https://other.example.test>Go</button>';</script>")
        _ = try await js(web, "password.focus()")
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testShadowLocalScrollDismissesFocusedChooser() async throws {
        let (web, capture) = try await fixture(shadow(login))
        _ = try await js(web, "password.focus()")
        try await wait { capture.messages.contains { $0["focus"] as? Bool == true } }
        _ = try await js(web, "login.dispatchEvent(new Event('scroll'))")
        try await wait { capture.messages.contains { $0["dismiss"] as? String == "scroll" } }
    }

    func testExplicitStepIdentityReplacementInvalidatesChooserTarget() async throws {
        for change in ["user.outerHTML='<input id=user autocomplete=username value=mallory>'", "user.value='mallory'", "password.removeAttribute('aria-labelledby')"] {
            let (web, _) = try await fixture("<form id=identity><input id=user autocomplete=username></form><form id=login></form>")
            let first = try await fill(web)
            XCTAssertTrue(first)
            _ = try await js(web, "identity.hidden=true; login.innerHTML='<input id=password type=password aria-labelledby=user>'; password.focus()")
            let original = try await anchor(web)
            let target = try XCTUnwrap(original?["target"] as? String)
            _ = try await js(web, change)
            let filled = try await fill(web, target: target)
            XCTAssertFalse(filled, change)
            expectEqual(try await js(web, "password.value") as? String, "")
        }
    }

    func testLateRootFocusAdmitsImmediateNonComposedSubmission() async throws {
        let (web, capture) = try await fixture("<div id=host></div>")
        _ = try await js(web, "var root=host.attachShadow({mode:'open'}); root.innerHTML='<form id=login><input autocomplete=username value=ada><input id=password type=password value=late-secret></form>'; root.getElementById('password').focus(); root.getElementById('login').dispatchEvent(new Event('submit',{bubbles:true}))")
        try await wait { capture.messages.contains { $0["password"] as? String == "late-secret" } }
        XCTAssertEqual(capture.messages.filter { $0["password"] != nil }.count, 1)
    }

    func testSlottedControlCannotBypassItsShadowFormAction() async throws {
        let (web, _) = try await fixture("<form id=login><div id=host><input id=password type=password></div></form>")
        _ = try await js(web, "var root=host.attachShadow({mode:'open'}); var inner=document.createElement('form'); inner.action='https://other.example.test'; inner.append(document.createElement('slot')); root.append(inner); password.focus()")
        expectEqual(try await js(web, "root.querySelectorAll('form').length") as? Int, 1)
        expectEqual(try await js(web, "password.assignedSlot === inner.firstChild") as? Bool, true)
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testExternalNativeFormAssociationCannotBypassComposedFormActions() async throws {
        for changesAfterUsername in [false, true] {
            let (web, capture) = try await fixture("<form id=login></form><div id=host><input id=user autocomplete=username form=login><input id=password type=password autocomplete=current-password form=login></div>")
            _ = try await js(web, "var root=host.attachShadow({mode:'open'}); root.innerHTML='<form><slot></slot></form>'; var inner=root.querySelector('form'); password.focus();" + (changesAfterUsername
                ? "user.addEventListener('input',()=>inner.action='https://other.example.test',{once:true});"
                : "inner.action='https://other.example.test';"))
            let filled = try await fill(web)
            XCTAssertFalse(filled, "External native form associations must retain composed action checks")
            expectEqual(try await js(web, "password.value") as? String, "")
            _ = try await js(web, "inner.action='https://other.example.test'; user.value='ada'; password.value='blocked-fixture'; login.dispatchEvent(new Event('submit',{bubbles:true}));")
            // Observe the bridge's normal delivery window without native input.
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(capture.messages.contains { $0["password"] as? String == "blocked-fixture" })
        }
    }

    func testExternalNativeGenerationRechecksComposedFormBeforeEachWrite() async throws {
        let (web, capture) = try await fixture("<form id=login></form><div id=host><input id=password type=password autocomplete=new-password form=login><input id=confirmation type=password autocomplete=new-password form=login></div>")
        _ = try await js(web, "var root=host.attachShadow({mode:'open'}); root.innerHTML='<form><slot></slot></form>'; var inner=root.querySelector('form'); password.focus();")
        try await wait { capture.messages.contains { $0["generate"] as? Bool == true } }
        let target = try XCTUnwrap(capture.messages.last { $0["generate"] as? Bool == true }?["target"] as? String)
        _ = try await js(web, "host.addEventListener('input',()=>inner.action='https://other.example.test',{once:true})")
        let generated = try await js(web, Autofill.generateJS(password: "generated-fixture", target: target), isolated: true) as? Bool
        XCTAssertEqual(generated, false)
        expectEqual(try await js(web, "confirmation.value") as? String, "")
    }

    func testWindowScrollStillDismissesShadowChooser() async throws {
        let (web, capture) = try await fixture(shadow(login))
        _ = try await js(web, "password.focus()")
        try await wait { capture.messages.contains { $0["focus"] as? Bool == true } }
        _ = try await js(web, "window.dispatchEvent(new Event('scroll'))")
        try await wait { capture.messages.contains { $0["dismiss"] as? String == "scroll" } }
    }

    func testExternalNativeFormAssociationsCannotExceedTraversalBudget() async throws {
        let (web, _) = try await fixture("<form id=login><input id=password type=password></form><script>document.body.insertAdjacentHTML('beforeend','<input form=login>'.repeat(20001)); password.focus();</script>")
        let filled = try await fill(web)
        XCTAssertFalse(filled)
        expectEqual(try await js(web, "password.value") as? String, "")
    }

    func testNativeExternalUsernameRetainsItsPrecedingOrderWithShadowDiscovery() async throws {
        let (web, _) = try await fixture("<input id=user name=login form=login><form id=login><input id=password type=password></form>")
        let filled = try await fill(web)
        XCTAssertTrue(filled)
        expectEqual(try await js(web, "[user.value,password.value].join('|')") as? String, "ada|fixture-secret")
    }

    func testSlottedUsernamePairsByComposedOrderBeforeShadowPassword() async throws {
        let (web, _) = try await fixture("<form><div id=host><input id=user name=login></div></form><script>var root=host.attachShadow({mode:'open'}); root.innerHTML='<slot></slot><input id=password type=password>'; var password=root.getElementById('password');</script>")
        let filled = try await fill(web)
        XCTAssertTrue(filled)
        expectEqual(try await js(web, "[user.value,password.value].join('|')") as? String, "ada|fixture-secret")
    }

}
