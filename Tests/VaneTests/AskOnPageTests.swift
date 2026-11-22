import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class AskOnPageTests: XCTestCase {
    override func tearDown() async throws {
        UserDefaults.vane.removeObject(forKey: "appleAI")
        BrowserAI.save(AIConnections())
    }

    func testAIOffShowsTheEnablePathAndPrivateWindowsRefuseCloud() {
        TestEnvironment.prepare()
        UserDefaults.vane.set(false, forKey: "appleAI")
        XCTAssertEqual(AskOnPage.blocker(isPrivate: false), "Turn on Max to ask questions about pages.")

        var connection = AIConnection(provider: .openAI)
        connection.credentialUsesEndpointScope = true
        var state = AIConnections(); state.connections = [connection]; state.route(.askOnPage, to: connection.id)
        BrowserAI.save(state)
        UserDefaults.vane.set(true, forKey: "appleAI")
        // No key saved: the route's own reason, which Settings → Max also shows.
        XCTAssertEqual(AskOnPage.blocker(isPrivate: false), "Save an API key for this connection.")
        XCTAssertNil(state.connection(for: .summaries), "Ask on Page has its own route")
    }

    func testClosingTheBarEndsAskModeAndClearsTheConversation() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID())
        defer { TabStore.all.removeAll { $0 === store } }
        let session = Find.session(for: store)
        store.findOpen = true
        session.asking = true
        session.ask.turns = [.init(question: "Q", answer: "A", pending: false)]
        store.findOpen = false
        XCTAssertFalse(session.asking)
        XCTAssertTrue(session.ask.turns.isEmpty)
    }

    func testSwitchingTabsMidAnswerClearsTheConversation() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID())
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let first = store.newBlankTab(focus: true)
        let second = store.newBlankTab(focus: false)
        store.current = first.id
        let session = Find.session(for: store)
        store.findOpen = true
        session.asking = true
        session.ask.turns = [.init(question: "Q", answer: "Partial")]
        XCTAssertTrue(session.ask.busy)
        store.current = second.id
        XCTAssertTrue(session.ask.turns.isEmpty)
        XCTAssertFalse(session.ask.busy)
        XCTAssertTrue(session.asking, "the bar stays in Ask mode for the new tab")

        store.openFind()
        XCTAssertFalse(session.asking, "⌘F goes back to find")
    }

    func testAskNeedsAPageAndANewDocumentEndsTheConversation() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID())
        defer { TabStore.all.removeAll { $0 === store }; SharedTabs.release(store.tabs) }
        let tab = store.newBlankTab(focus: true)
        let ask = Find.session(for: store).ask
        if tab.existingWeb == nil {
            XCTAssertFalse(ask.ask("Q", in: tab), "no page: the question stays with the caller")
        }
        _ = tab.web
        XCTAssertTrue(ask.ask("Q", in: tab))
        XCTAssertEqual(ask.turns.count, 1)
        XCTAssertNotNil(tab.onDocumentCommit)
        tab.onDocumentCommit?()
        XCTAssertTrue(ask.turns.isEmpty, "a committed document is a different page")
        XCTAssertNil(tab.onDocumentCommit)
    }

    /// Set VANE_ASK_CAPTURE_DIR to write the panel's look for review.
    func testPanelRendersAConversation() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        UserDefaults.vane.set(true, forKey: "appleAI")
        let store = TabStore(isPrivate: true, profileID: UUID())
        defer { TabStore.all.removeAll { $0 === store } }
        let tab = store.newBlankTab(focus: false)
        let session = Find.session(for: store)
        session.ask.turns = [
            .init(question: "What year did the program end?", answer: "The page says the last crewed landing was in December 1972, on Apollo 17.", pending: false),
            .init(question: "Who flew it?", answer: "", pending: false, failed: true),
        ]
        let host = NSHostingView(rootView: AskPanel(session: session, ask: session.ask, tab: tab)
            .environmentObject(store).padding(20).background(.black).defaultAppStorage(.vane))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(host.fittingSize.height, 60, "the conversation adds height under the field")
        if let directory = ProcessInfo.processInfo.environment["VANE_ASK_CAPTURE_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("ask-panel.png"))
        }
        SharedTabs.release(store.tabs)
    }
}
