import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class HTTPAuthenticationSecurityTests: XCTestCase {
    private var appLoop: NativeFixtureApplicationLoop?
    private var previousPolicy: NSApplication.ActivationPolicy?
    private var ownedTab: Tab?
    private var ownedWindow: NSWindow?
    private var ownedSheets: [NSWindow] = []

    /// XCTest's invocation cannot finish while an async setup-owned NSApp.run
    /// remains active. Keep acquisition, assertions and joined retirement inside
    /// the test body, including every failure path.
    private func withPresentationLoop(_ body: @MainActor () async throws -> Void) async throws {
        TestEnvironment.prepare()
        let application = NSApplication.shared
        let policy = application.activationPolicy()
        previousPolicy = policy
        var failure: (any Error)?
        do {
            appLoop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: policy == .prohibited ? .accessory : policy)
            try await body()
        } catch { failure = error }
        do { try await retirePresentations() }
        catch { if failure == nil { failure = error } else { XCTFail("Native presentation cleanup also failed: \(error)") } }
        if let failure { throw failure }
    }

    private func retirePresentations() async throws {
        var failure: (any Error)?
        if let window = ownedWindow {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort) }
            do {
                try await waitForPresentation("HTTP auth sheets dismissed before retirement") {
                    window.attachedSheet == nil && self.ownedSheets.allSatisfy { !$0.isVisible }
                }
            } catch { failure = error }
            ownedTab?.tearDown()
            window.contentView = nil
            NSApp.removeWindowsItem(window)
            window.close()
            XCTAssertFalse(window.isVisible)
        }
        ownedSheets.removeAll()
        ownedTab = nil
        ownedWindow = nil
        if let appLoop {
            do { try await appLoop.close() }
            catch { if failure == nil { failure = error } }
        }
        appLoop = nil
        if let previousPolicy {
            if NSApp.activationPolicy() != previousPolicy { NSApp.setActivationPolicy(previousPolicy) }
            do { try await waitForPresentation("HTTP auth original policy restored") { NSApp.activationPolicy() == previousPolicy } }
            catch { if failure == nil { failure = error } }
        }
        previousPolicy = nil
        if let failure { throw failure }
    }

    private func waitForPresentation(_ reason: String, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + reason) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(method: String, scheme: String = "https", host: String,
                           port: Int = 443, navigation: String, startsProvisional: Bool = true,
                           committed: Bool = false, expectsPrompt: Bool) async throws {
        try XCTUnwrap(appLoop).verifyRunning()
        let tab = Tab(isPrivate: true, profileID: UUID())
        ownedTab = tab
        tab.web.navigationDelegate = nil
        let destination = try XCTUnwrap(URL(string: navigation))
        let requestsDocument = startsProvisional || committed
        var navigationID: WKNavigation?
        if requestsDocument {
            navigationID = try XCTUnwrap(tab.web.loadHTMLString("auth fixture", baseURL: destination))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView = tab.web
        ownedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitForPresentation("HTTP auth foreground, document and exact sheet owner") {
            NSApp.isRunning && NSRunningApplication.current.isFinishedLaunching
                && NSApp.isActive && window.isKeyWindow && window.isVisible
                && window.contentView === tab.web && tab.web.window === window
                && !tab.web.isHiddenOrHasHiddenAncestor && !tab.web.isLoading
                && (!requestsDocument || tab.web.url == destination)
        }
        if requestsDocument {
            let text = try await tab.web.evaluateJavaScript("document.body.textContent") as? String
            guard text == "auth fixture" else { throw ExtensionHost.Failure("The HTTP authentication sheet's exact fixture document is not ready") }
        }
        tab.allowCertificateNavigation(to: destination)
        if startsProvisional { tab.webView(tab.web, didStartProvisionalNavigation: try XCTUnwrap(navigationID)) }
        if committed { tab.webView(tab.web, didCommit: try XCTUnwrap(navigationID)) }
        if !requestsDocument {
            XCTAssertNil(tab.certificateDocumentURL, "Policy approval alone must not create a committed authentication origin")
            XCTAssertNil(tab.certificateNavigationURL, "Policy approval alone must not create an actual provisional load")
        }
        NativeFixtureDiagnostics.emit("HTTP auth presentation admitted: running=\(NSApp.isRunning), finished=\(NSRunningApplication.current.isFinishedLaunching), policy=\(NSApp.activationPolicy().rawValue), exactOwner=\(tab.web.window === window), excludedFromWindowsMenu=\(window.isExcludedFromWindowsMenu)")
        let space = URLProtectionSpace(host: host, port: port, protocol: scheme,
                                       realm: "fixture", authenticationMethod: method)
        let request = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender())
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        let task = Task { result = await tab.webView(tab.web, respondTo: request) }
        let deadline = Date.now.addingTimeInterval(10)
        while result == nil && window.attachedSheet == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prompted = window.attachedSheet != nil
        if let sheet = window.attachedSheet {
            sheet.isExcludedFromWindowsMenu = true
            ownedSheets.append(sheet)
            XCTAssertTrue(sheet.sheetParent === window)
            window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        if result == nil && !prompted { task.cancel(); CertificateTrust.navigationStarted(in: tab) }
        await task.value
        try await waitForPresentation("HTTP auth challenge sheet fully dismissed") { window.attachedSheet == nil }
        XCTAssertEqual(prompted, expectsPrompt)
        XCTAssertEqual(result?.0, .cancelAuthenticationChallenge)
        XCTAssertNil(result?.1)
    }

    func testCrossOriginBasicSubresourceCannotRaiseNativeLogin() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPBasic, host: "tracker.example",
                                navigation: "https://article.example/page", expectsPrompt: false)
        }
    }

    func testCrossOriginDigestSubresourceCannotRaiseNativeLogin() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPDigest, host: "tracker.example",
                                navigation: "https://article.example/page", expectsPrompt: false)
        }
    }

    func testSchemeMismatchCannotRaiseNativeLogin() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPBasic, scheme: "http",
                                host: "article.example", port: 443,
                                navigation: "https://article.example/page", expectsPrompt: false)
        }
    }

    func testPortMismatchCannotRaiseNativeLogin() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPDigest, host: "article.example", port: 8443,
                                navigation: "https://article.example/page", expectsPrompt: false)
        }
    }

    func testActualMainFrameBasicAuthenticationStillPrompts() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPBasic, host: "article.example",
                                navigation: "https://article.example/page", expectsPrompt: true)
        }
    }

    func testActualHTTPMainFrameAuthenticationStillPrompts() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPDigest, scheme: "http", host: "article.example", port: 80,
                                navigation: "http://article.example/page", expectsPrompt: true)
        }
    }
    func testPolicyApprovalWithoutActualMainFrameLoadCannotAuthorizeLogin() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPBasic, host: "article.example",
                                navigation: "https://article.example/page", startsProvisional: false,
                                expectsPrompt: false)
        }
    }

    func testMatchingCommittedDocumentCanStillAuthenticate() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPDigest, host: "article.example",
                                navigation: "https://article.example/page", committed: true, expectsPrompt: true)
        }
    }

    func testCrossOriginChallengeAfterCommitCannotPrompt() async throws {
        try await withPresentationLoop {
            try await challenge(method: NSURLAuthenticationMethodHTTPBasic, host: "tracker.example",
                                navigation: "https://article.example/page", committed: true, expectsPrompt: false)
        }
    }

}
