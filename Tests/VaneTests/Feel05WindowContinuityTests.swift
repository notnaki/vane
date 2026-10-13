import AppKit
import XCTest
@testable import vane

@MainActor final class Feel05WindowContinuityTests: XCTestCase {
    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
    }

    func testHistoryReopeningRetainsHostButProfileChangeReplacesIt() throws {
        let first = UUID(), second = UUID()
        defer { Store.forget(first); Store.forget(second) }
        HistoryWindow.show(profileID: first)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "History" })
        defer { window.orderOut(nil); window.contentView = nil }
        let host = try XCTUnwrap(window.contentView)
        window.orderOut(nil)
        HistoryWindow.show(profileID: first)
        XCTAssertTrue(window.contentView === host, "Reopening must preserve query, scroll and field identity")
        HistoryWindow.show(profileID: second)
        XCTAssertFalse(window.contentView === host, "A different profile must get fresh view state")
    }

    func testBookmarkRefreshAndReopenRetainHostButProfileChangeReplacesIt() throws {
        let first = UUID(), second = UUID()
        defer { Store.forget(first); Store.forget(second) }
        BookmarkManager.show(profileID: first)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
        defer { window.orderOut(nil); window.contentView = nil }
        let host = try XCTUnwrap(window.contentView)
        BookmarkManager.refresh(profileID: first)
        XCTAssertTrue(window.contentView === host, "Mutation refresh must keep search and selection state")
        window.orderOut(nil)
        BookmarkManager.show(profileID: first)
        XCTAssertTrue(window.contentView === host)
        BookmarkManager.show(profileID: second)
        XCTAssertFalse(window.contentView === host)
    }

    func testRapidBookmarkQueriesAndRefreshKeepTheNativeFieldEditor() async throws {
        let profile = UUID()
        defer { Store.forget(profile) }
        let store = Store.store(for: profile)
        let rows = (0..<1_000).map { (URL(string: "https://feel05.invalid/\($0)")!, "Common page \($0)") }
        XCTAssertEqual(store.addBookmarks(rows), 1_000)
        BookmarkManager.show(profileID: profile)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
        defer { window.orderOut(nil); window.contentView = nil }
        let editor = try await fieldEditor(in: window)
        for query in ["Common", "absent", "Common page 999"] {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await Task.yield()
        }
        let id = try XCTUnwrap(store.managedBookmarks(matching: "Common page 999").first?.id)
        XCTAssertTrue(store.deleteBookmarks([id]))
        BookmarkManager.refresh(profileID: profile)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(editor.string, "Common page 999")
        XCTAssertTrue(window.firstResponder === editor)
        let remaining = await store.managedBookmarksAsync(matching: "Common page 999")
        XCTAssertTrue(remaining.isEmpty)
        editor.insertText("Common", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "Common")
    }

    func testHistoryQueriesAndLiveMutationKeepTheNativeFieldEditor() async throws {
        let profile = UUID()
        defer { Store.forget(profile) }
        let store = Store.store(for: profile)
        XCTAssertEqual(store.record((0..<10_000).map {
            (URL(string: "https://feel05.invalid/\($0)")!, "History page \($0)", Date(timeIntervalSince1970: Double($0)))
        }), 10_000)
        HistoryWindow.show(profileID: profile)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "History" })
        defer { window.orderOut(nil); window.contentView = nil }
        let editor = try await fieldEditor(in: window)
        for query in ["History", "absent", "History page 9999"] {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            await Task.yield()
        }
        let id = try XCTUnwrap(store.history(matching: "History page 9999").first?.id)
        XCTAssertTrue(store.deleteVisit(id))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "History page 9999")
        window.orderOut(nil)
        HistoryWindow.show(profileID: profile)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "History page 9999")
    }

    func testRefreshingPopulatedWindowsPreservesScrollHostsAndOffsets() async throws {
        let profile = UUID()
        defer { Store.forget(profile) }
        let store = Store.store(for: profile)
        let pages = (0..<250).map { (URL(string: "https://feel05-scroll.invalid/\($0)")!, "Page \($0)") }
        XCTAssertEqual(store.addBookmarks(pages), pages.count)
        XCTAssertEqual(store.record(pages.enumerated().map { ($0.element.0, $0.element.1, Date(timeIntervalSince1970: Double($0.offset))) }), pages.count)
        for history in [false, true] {
            if history { HistoryWindow.show(profileID: profile) } else { BookmarkManager.show(profileID: profile) }
            let window = try XCTUnwrap(NSApp.windows.first { $0.title == (history ? "History" : "Bookmarks") })
            defer { window.orderOut(nil); window.contentView = nil }
            let deadline = Date.now.addingTimeInterval(5)
            while scrollView(in: window.contentView) == nil, Date.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let scroll = try XCTUnwrap(scrollView(in: window.contentView))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 400))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            let offset = scroll.documentVisibleRect.origin.y
            XCTAssertGreaterThan(offset, 100)
            if history { HistoryWindow.show(profileID: profile) } else { BookmarkManager.refresh(profileID: profile) }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(scrollView(in: window.contentView) === scroll)
            XCTAssertEqual(scroll.documentVisibleRect.origin.y, offset, accuracy: 1)
        }
    }

    private func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 1_000 { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func fieldEditor(in window: NSWindow) async throws -> NSTextView {
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date.now.addingTimeInterval(5)
        while !(window.firstResponder is NSTextView), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(window.firstResponder as? NSTextView)
    }

}
