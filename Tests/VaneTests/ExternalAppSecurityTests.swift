import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

@MainActor final class ExternalAppSecurityTests: XCTestCase {
    private var store: TabStore!
    private var server: NavigationHTTPFixture!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        store = TabStore(isPrivate: true)
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
    }

    override func tearDown() async throws {
        store.tabs.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        server.stop()
        store = nil; server = nil
    }

    private final class FrameProbe: NSObject, WKScriptMessageHandler {
        var frame: WKFrameInfo?
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            frame = message.frameInfo
        }
    }

    func testEmbeddedAppRequestNamesItsOwnOrigin() async throws {
        try await embeddedRequest(popup: false)
    }

    func testEmbeddedPopupCannotBorrowItsParentsSavedGrant() async throws {
        try await embeddedRequest(popup: true)
    }

    private func embeddedRequest(popup: Bool) async throws {
        let launch = popup ? "window.open('vane-security-fixture://open', '_blank')" : "location.href = 'vane-security-fixture://open'"
        server.pages["/child"] = "<script>window.webkit.messageHandlers.fixtureFrame.postMessage('ready');</script>"
        let child = try server.url("/child", host: "localhost")
        server.pages["/parent"] = "<iframe src='\(child.absoluteString)'></iframe>"
        let parent = try server.url("/parent")
        store.newTab(parent)
        let tab = try XCTUnwrap(store.active)
        let frameProbe = FrameProbe()
        tab.web.configuration.userContentController.add(frameProbe, name: "fixtureFrame")
        defer { tab.web.configuration.userContentController.removeScriptMessageHandler(forName: "fixtureFrame") }
        tab.web.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        try await compatibilityWait { tab.web.url == parent && !tab.web.isLoading && frameProbe.frame != nil }
        let parentScope = ExternalApps.Scope(url: parent, profileID: tab.profileID, privateTabID: tab.id)
        ExternalApps.allow(scope: parentScope, scheme: "vane-security-fixture")
        _ = try await tab.web.callAsyncJavaScript(launch, arguments: [:], in: frameProbe.frame, contentWorld: .page)
        try await compatibilityWait { self.store.externalApp != nil }
        XCTAssertEqual(store.externalApp?.host, "localhost", "An embedded site must not be credited to the parent")
        XCTAssertEqual(store.externalApp?.originLabel, "http://localhost:\(server.port!)")
        XCTAssertEqual(store.externalApp?.embeddedOn, ExternalApps.Scope(url: parent, profileID: tab.profileID)?.origin,
                       "The prompt must also name the top-level page hosting the embedded frame")
    }

    func testNavigationDismissesAnOldAppRequest() async throws {
        let parent = try server.url("/parent")
        store.newTab(parent)
        let tab = try XCTUnwrap(store.active)
        try await compatibilityWait { tab.web.url == parent && !tab.web.isLoading }
        _ = try await tab.web.evaluateJavaScript("location.href = 'vane-security-fixture://open'")
        try await compatibilityWait { self.store.externalApp != nil }
        let stale = try XCTUnwrap(store.externalApp)
        let next = try server.url("/next")
        tab.go(next)
        try await compatibilityWait { tab.web.url == next && !tab.web.isLoading }
        XCTAssertNil(store.externalApp, "A new document cannot approve the previous document's app request")
        ExternalApps.answer(stale, .always, in: store)
        XCTAssertFalse(ExternalApps.remembered(scope: stale.scope, scheme: stale.scheme))
    }

    func testReturnCancelsAnExternalAppCard() async throws {
        let scope = ExternalApps.Scope(url: URL(string: "https://meeting.invalid"), profileID: UUID())
        let prompt = ExternalApps.Prompt(url: URL(string: "mailto:fixture@example.invalid")!, scope: scope,
                                        tabID: UUID(), documentID: UUID(), scheme: "mailto",
                                        app: URL(fileURLWithPath: "/System/Applications/Mail.app"), name: "Mail")
        var answer: ExternalApps.Answer?
        let host = NSHostingController(rootView: ExternalAppCard(prompt: prompt) { answer = $0 })
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        host.view.layoutSubtreeIfNeeded()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(answer, .cancel)
    }

    func testScriptedExternalNavigationWithoutActivationCannotPromptButAUserClickStillDoes() async throws {
        // The scripted attempt runs during load, so its policy decision precedes the
        // later click. `offer` ignores requests while a prompt is showing: a prompt for
        // the scripted URL would block the click instead of being replaced by it.
        server.pages["/scripted"] = """
        <a id='go' href='vane-security-fixture://clicked'>Open</a>
        <script>location.href = 'vane-security-fixture://scripted';</script>
        """
        let url = try server.url("/scripted")
        #if DEBUG
        ExternalApps.offersForTesting.removeAll()
        #endif
        store.newTab(url)
        let tab = try XCTUnwrap(store.active)
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading }
        // Not vacuous: the scripted request must have reached the decision without activation.
        #if DEBUG
        try await compatibilityWait {
            ExternalApps.offersForTesting.contains { $0.url == "vane-security-fixture://scripted" && !$0.userInitiated }
        }
        #endif
        XCTAssertNil(store.externalApp, "A script without user activation must not prompt")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('go').click()")
        try await compatibilityWait { self.store.externalApp != nil }
        XCTAssertEqual(store.externalApp?.url.absoluteString, "vane-security-fixture://clicked",
                       "Only the user-activated link may prompt; the scripted request must have been refused")
    }

    func testGrantsAreScopedToExactOriginProfileAndPrivateTab() throws {
        let profile = UUID()
        let origin = URL(string: "https://meeting.invalid")!
        let scope = try XCTUnwrap(ExternalApps.Scope(url: origin, profileID: profile))
        defer { ExternalApps.forgetAll(profileID: profile) }
        ExternalApps.allow(scope: scope, scheme: "vane-security-fixture")
        XCTAssertTrue(ExternalApps.remembered(scope: scope, scheme: "VANE-SECURITY-FIXTURE"))
        for url in ["http://meeting.invalid", "https://meeting.invalid:8443", "https://sub.meeting.invalid"] {
            let other = ExternalApps.Scope(url: URL(string: url), profileID: profile)
            XCTAssertFalse(ExternalApps.remembered(scope: other, scheme: "vane-security-fixture"), url)
        }
        XCTAssertFalse(ExternalApps.remembered(scope: ExternalApps.Scope(url: origin, profileID: UUID()),
                                              scheme: "vane-security-fixture"))
        let privateID = UUID(), otherPrivateID = UUID()
        let privateScope = ExternalApps.Scope(url: origin, profileID: profile, privateTabID: privateID)
        XCTAssertFalse(ExternalApps.remembered(scope: privateScope, scheme: "vane-security-fixture"))
        let before = UserDefaults.vane.dictionaryRepresentation() as NSDictionary
        ExternalApps.allow(scope: privateScope, scheme: "private-fixture")
        XCTAssertEqual(UserDefaults.vane.dictionaryRepresentation() as NSDictionary, before)
        XCTAssertTrue(ExternalApps.remembered(scope: privateScope, scheme: "private-fixture"))
        XCTAssertFalse(ExternalApps.remembered(scope: scope, scheme: "private-fixture"))
        XCTAssertFalse(ExternalApps.remembered(
            scope: ExternalApps.Scope(url: origin, profileID: profile, privateTabID: otherPrivateID), scheme: "private-fixture"))
        ExternalApps.forgetPrivate(tabID: privateID)
        XCTAssertFalse(ExternalApps.remembered(scope: privateScope, scheme: "private-fixture"))
        ExternalApps.forget(scope: scope, scheme: "vane-security-fixture")
        XCTAssertFalse(ExternalApps.remembered(scope: scope, scheme: "vane-security-fixture"))
    }

    func testHostOnlyLegacyGrantsCannotAuthorizeLaunches() throws {
        let key = "externalApp.legacy-meeting.invalid"
        UserDefaults.vane.set(["vane-security-fixture"], forKey: key)
        defer { UserDefaults.vane.removeObject(forKey: key) }
        let scope = ExternalApps.Scope(url: URL(string: "https://legacy-meeting.invalid"), profileID: UUID())
        XCTAssertFalse(ExternalApps.remembered(scope: scope, scheme: "vane-security-fixture"))
        ExternalApps.allow(scope: nil, scheme: "vane-security-fixture")
        XCTAssertFalse(ExternalApps.remembered(scope: nil, scheme: "vane-security-fixture"))
    }

    func testClosingPrivateTabForgetsItsGrants() throws {
        let tab = store.newBlankTab(focus: false)
        let scope = ExternalApps.Scope(url: URL(string: "https://meeting.invalid"), profileID: tab.profileID, privateTabID: tab.id)
        ExternalApps.allow(scope: scope, scheme: "vane-security-fixture")
        XCTAssertTrue(ExternalApps.remembered(scope: scope, scheme: "vane-security-fixture"))
        tab.tearDown()
        XCTAssertFalse(ExternalApps.remembered(scope: scope, scheme: "vane-security-fixture"))
    }
}
