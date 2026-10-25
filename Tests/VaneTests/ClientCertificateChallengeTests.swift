import AppKit
import Security
import WebKit
import XCTest
@testable import vane

/// Native challenge → production branch → native sheet → credential/cancellation.
/// Identity discovery is injected so these tests cannot enumerate a user keychain.
@MainActor final class ClientCertificateChallengeTests: XCTestCase {
    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private final class ClientSpace: URLProtectionSpace, @unchecked Sendable {
        override var distinguishedNames: [Data]? { [Data([0x30, 0x00])] }
        override func copy(with zone: NSZone? = nil) -> Any { self }
        init(host: String = "cert.fixture.test") {
            super.init(host: host, port: 443, protocol: "https", realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        }
        required init?(coder: NSCoder) { fatalError("Unused") }
    }

    private enum Action { case choose, cancel, navigate, close, cancelTask }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { views(type, in: $0) }
    }

    private func exercise(_ action: Action) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let first = try XCTUnwrap(ClientCertificates.Candidate(identity: ClientCertificateFixture.identity("first")))
        let second = try XCTUnwrap(ClientCertificates.Candidate(identity: ClientCertificateFixture.identity("second")))
        let tab = Tab(isPrivate: true, profileID: UUID())
        let web = tab.web
        web.navigationDelegate = nil
        let navigation = try XCTUnwrap(web.loadHTMLString("certificate fixture", baseURL: nil))
        tab.allowCertificateNavigation(to: URL(string: "https://cert.fixture.test/"))
        tab.webView(web, didStartProvisionalNavigation: navigation)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { tab.tearDown(); window.close() }
        let challenge = URLAuthenticationChallenge(protectionSpace: ClientSpace(), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender())
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        let task = Task { result = await CertificateTrust.handle(challenge: challenge, tab: tab, web: web,
            clientIdentities: { issuers in
                XCTAssertEqual(issuers, [Data([0x30, 0x00])])
                return [first, second]
            }) }
        let deadline = Date.now.addingTimeInterval(10)
        while window.attachedSheet == nil && result == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            task.cancel(); await task.value
            XCTFail("Expected the native certificate chooser"); return
        }
        let picker = try XCTUnwrap(views(NSPopUpButton.self, in: content).first)
        XCTAssertEqual(picker.numberOfItems, 2)
        XCTAssertTrue(picker.itemTitle(at: 1).contains(second.id.prefix(12)))
        switch action {
        case .choose:
            picker.selectItem(at: 1)
            try XCTUnwrap(views(NSButton.self, in: content).first { $0.title == "Continue" }).performClick(nil)
        case .cancel:
            try XCTUnwrap(views(NSButton.self, in: content).first { $0.title == "Cancel" }).performClick(nil)
        case .navigate:
            tab.allowCertificateNavigation(to: URL(string: "https://other.fixture.test/"))
        case .close:
            tab.tearDown()
        case .cancelTask:
            task.cancel()
        }
        while result == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if result == nil { task.cancel(); CertificateTrust.navigationStarted(in: tab) }
        await task.value
        if case .choose = action {
            XCTAssertEqual(result?.0, .useCredential)
            XCTAssertTrue(result?.1?.identity.map { CFEqual($0, second.identity) } ?? false)
        } else {
            XCTAssertEqual(result?.0, .cancelAuthenticationChallenge)
            XCTAssertNil(result?.1)
        }
        XCTAssertNil(window.attachedSheet)
    }

    func testChoosingSecondIdentityAnswersTheNativeChallenge() async throws { try await exercise(.choose) }
    func testCancelDoesNotSendAnIdentity() async throws { try await exercise(.cancel) }
    func testNavigationDismissesAndRejectsThePendingChooser() async throws { try await exercise(.navigate) }
    func testClosingTabDismissesAndRejectsThePendingChooser() async throws { try await exercise(.close) }
    func testCancelledChallengeTaskDismissesThePendingChooser() async throws { try await exercise(.cancelTask) }
}
