import AppKit
import XCTest
@testable import vane

@MainActor final class PinnedTabReturnTests: XCTestCase {
    private let home = URL(string: "about:blank#pinned-home")!
    private let away = URL(string: "about:blank#separated-page")!

    func testSeparateRestoresPinAndOpensAwayURLAtHeadOfToday() throws {
        for selected in [false, true] {
            try withStore { store in
                let pin = store.newBlankTab(focus: false, as: .pinned)
                pin.park(url: home, Parked(title: "Pinned home"))
                pin.park(url: away, Parked(title: "Away page"))
                let folder = try XCTUnwrap(store.pins.newFolder(named: "Keep this folder"))
                store.pins.move(pin.id.uuidString, into: folder.id)
                let pinsBefore = store.pins
                let existing = store.newBlankTab()
                if selected { store.current = pin.id }

                store.goHome(pin.id, separating: true)

                let today = store.tabs.filter { $0.kind == .today }
                let opened = try XCTUnwrap(today.first)
                XCTAssertNotEqual(opened.id, existing.id)
                XCTAssertEqual(opened.currentURL, away)
                XCTAssertEqual(store.current, opened.id)
                XCTAssertEqual(today.map(\.id), [opened.id, existing.id])
                XCTAssertTrue(store.tabs.first { $0.id == pin.id } === pin)
                XCTAssertEqual(pin.kind, .pinned)
                XCTAssertEqual(pin.homeURL, home)
                XCTAssertEqual(pin.currentURL, home)
                XCTAssertTrue(pin.suspended, "The background pin should not reload merely to reset it")
                XCTAssertEqual(store.pins, pinsBefore)
            }
        }
    }

    func testOrdinaryReturnDoesNotCreateTodayTab() {
        withStore { store in
            let pin = store.newBlankTab(focus: false, as: .pinned)
            pin.park(url: home, Parked())
            pin.park(url: away, Parked())
            store.current = pin.id

            store.goHome(pin.id)

            XCTAssertEqual(pin.currentURL, home)
            XCTAssertEqual(store.current, pin.id)
            XCTAssertTrue(store.tabs.allSatisfy { $0.kind != .today })
            XCTAssertFalse(pin.suspended, "Returning the visible pin must restore its page")
        }
    }

    func testSeparateAtHomeOrOnTodayDoesNotCreateDuplicate() {
        withStore { store in
            let pin = store.newBlankTab(focus: false, as: .pinned)
            pin.park(url: home, Parked())
            let today = store.newBlankTab()
            today.park(url: away, Parked())
            let before = store.tabs.map(\.id)

            store.goHome(pin.id, separating: true)
            store.goHome(today.id, separating: true)
            store.goHome(UUID(), separating: true)

            XCTAssertEqual(store.tabs.map(\.id), before)
            XCTAssertEqual(store.current, today.id)
            XCTAssertEqual(pin.currentURL, home)
            XCTAssertEqual(today.currentURL, away)
        }
    }

    private func withStore(_ body: (TabStore) throws -> Void) rethrows {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.sharingReady = false
        defer {
            store.dropStashes()
            let tabs = store.tabs
            tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        try body(store)
    }
}
