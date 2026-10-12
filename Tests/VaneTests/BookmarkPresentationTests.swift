import AppKit
import XCTest
@testable import vane

@MainActor final class BookmarkPresentationTests: XCTestCase {
    func testWindowKeepsItsMinimumSizeAfterResultsArrive() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STORE_PERFORMANCE"] == "1",
                          "Requires a logged-in desktop")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        _ = store.addBookmarks((0..<6).map {
            (URL(string: "https://fixture.invalid/\($0)")!, "Saved page \($0)")
        })
        BookmarkManager.show(profileID: profile)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThanOrEqual(window.minSize.width, 620)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 400)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true)
        try await Task.sleep(for: .milliseconds(100))
        let host = try XCTUnwrap(window.contentView)
        func splitView(in view: NSView) -> NSSplitView? {
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { splitView(in: $0) }.first
        }
        let split = try XCTUnwrap(splitView(in: host))
        XCTAssertLessThanOrEqual(split.frame.height, host.bounds.height + 1,
                                 "Split panes must fit the available height without clipping their headers")
    }

    /// Native field-editor smoke remains opt-in alongside presentation measurements.
    func testFilteringKeepsTheFieldEditor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STORE_PERFORMANCE"] == "1",
                          "Requires a logged-in desktop")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        XCTAssertEqual(store.addBookmarks([(URL(string: "https://fixture.invalid/visible")!,
                                           "Visible fixture bookmark")]), 1)
        BookmarkManager.show(profileID: profile)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
        defer { window.orderOut(nil); window.contentView = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date.now.addingTimeInterval(5)
        while !(window.firstResponder is NSTextView), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        for query in ["Visible fixture", "not present", "Visible fixture"] {
            editor.insertText(query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(editor.string, query)
            XCTAssertTrue(window.firstResponder === editor,
                          "Filtering, including empty results, must retain the search field")
        }
        editor.insertText("not present", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(20))
        editor.insertText("Visible fixture", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(editor.string, "Visible fixture")
        XCTAssertTrue(window.firstResponder === editor, "Superseded queries must retain typing focus")
    }
}
