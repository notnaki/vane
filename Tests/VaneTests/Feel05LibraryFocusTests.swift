import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel05LibraryFocusTests: XCTestCase {
    func testSectionChangesReachCurrentSearchWithAndWithoutBatterySaver() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let previous = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        defer { BatterySaver.shared.setMode(previous) }
        let store = TabStore(profileID: UUID(), session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let old = (Library.shared.section, Library.shared.query, Library.shared.littleArcOnly, Library.shared.completedOnly)
        defer {
            Library.open(old.0, in: store)
            Library.shared.query = old.1
            Library.shared.littleArcOnly = old.2
            Library.shared.completedOnly = old.3
            store.libraryOpen = false
            store.window = nil
            store.dropStashes()
            window.contentView = nil
            window.close()
        }
        Library.open(.archived, in: store)
        window.contentView = NSHostingView(rootView: LibraryPanel().environmentObject(store))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        for mode in [BatterySaver.Mode.off, .alwaysOn] {
            BatterySaver.shared.setMode(mode)
            for section in [LibrarySection.downloads, .media, .archived] {
                try await Task.sleep(for: .milliseconds(50))
                Library.open(section, in: store)
                XCTAssertEqual(Library.shared.section, section)
                let deadline = Date.now.addingTimeInterval(3)
                while currentPrompt(in: window) != section.searchPrompt, Date.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(window.firstResponder is NSTextView, "Section activation must reach its search field")
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                let field = try XCTUnwrap(editor.delegate as? NSTextField)
                XCTAssertEqual(field.placeholderString, section.searchPrompt)
            }
        }
    }

    private func currentPrompt(in window: NSWindow) -> String? {
        ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
    }
}
