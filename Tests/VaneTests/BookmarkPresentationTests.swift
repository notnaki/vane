import AppKit
import XCTest
@testable import vane

@MainActor final class BookmarkPresentationTests: XCTestCase {
    /// Native UI smoke remains opt-in alongside the presentation measurements.
    func testResultsAreAccessibleAndFilteringKeepsTheFieldEditor() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STORE_PERFORMANCE"] == "1",
                          "Requires a logged-in desktop")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let store = Store.store(for: profile)
        defer { Store.forget(profile) }
        XCTAssertEqual(store.addBookmarks([(URL(string: "https://fixture.invalid/visible")!,
                                           "Visible fixture bookmark")]), 1)
        BookmarkManager.show(profileID: profile)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
        defer { window.orderOut(nil); window.contentView = nil }
        try await waitForBookmark(in: window)
        let bookmark = try XCTUnwrap(bookmarkElement(window))
        let customActions = NSSelectorFromString("accessibilityCustomActions")
        let actions = bookmark.responds(to: customActions)
            ? bookmark.perform(customActions)?.takeUnretainedValue() as? [NSAccessibilityCustomAction] : nil
        let select = try XCTUnwrap(actions?.first { $0.name == "Select" })
        perform(select)
        XCTAssertNotNil(bookmarkElement(window), "Selecting keeps the row accessible")
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("Visible fixture", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(150))
        try await waitForBookmark(in: window)
        XCTAssertEqual(editor.string, "Visible fixture")
        XCTAssertTrue(window.firstResponder === editor)
        editor.insertText("not present", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        // Return to the previous query before its excluded-row search can publish.
        try await Task.sleep(for: .milliseconds(20))
        editor.insertText("Visible fixture", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(150))
        try await waitForBookmark(in: window)
        let restored = try XCTUnwrap(bookmarkElement(window))
        let restoredActions = restored.perform(customActions)?.takeUnretainedValue() as? [NSAccessibilityCustomAction]
        XCTAssertTrue(restoredActions?.contains { $0.name == "Select" } == true,
                      "A superseded query must not restore a stale selection")
        editor.insertText("not present", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await waitForBookmark(in: window, present: false)
        XCTAssertTrue(window.firstResponder === editor, "Empty results must retain the search field")
        editor.insertText("Visible fixture", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await waitForBookmark(in: window)
        XCTAssertTrue(window.firstResponder === editor)
    }

    private func waitForBookmark(in window: NSWindow, present: Bool = true) async throws {
        let deadline = Date.now.addingTimeInterval(5)
        while containsBookmark(window) != present, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(containsBookmark(window), present, "Accessibility results must follow the query")
    }

    private func containsBookmark(_ root: NSObject) -> Bool {
        bookmarkElement(root) != nil
    }

    private func perform(_ action: NSAccessibilityCustomAction) {
        if let handler = action.handler { XCTAssertTrue(handler()); return }
        guard let target = action.target as? NSObject, let selector = action.selector else {
            XCTFail("Custom action must have a handler or target"); return
        }
        let implementation = target.method(for: selector)
        if NSStringFromSelector(selector).contains(":") {
            typealias Handler = @convention(c) (NSObject, Selector, NSAccessibilityCustomAction) -> Bool
            XCTAssertTrue(unsafeBitCast(implementation, to: Handler.self)(target, selector, action))
        } else {
            typealias Handler = @convention(c) (NSObject, Selector) -> Bool
            XCTAssertTrue(unsafeBitCast(implementation, to: Handler.self)(target, selector))
        }
    }

    private func bookmarkElement(_ root: NSObject) -> NSObject? {
        let label = NSSelectorFromString("accessibilityLabel")
        let children = NSSelectorFromString("accessibilityChildren")
        var pending = [root], seen = Set<ObjectIdentifier>()
        while let element = pending.popLast(), seen.count < 256 {
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            if element.responds(to: label),
               element.perform(label)?.takeUnretainedValue() as? String == "Visible fixture bookmark" { return element }
            if element.responds(to: children),
               let descendants = element.perform(children)?.takeUnretainedValue() as? [NSObject] {
                pending += descendants
            }
        }
        return nil
    }
}
