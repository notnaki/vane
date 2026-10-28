import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel05LibraryFocusTests: XCTestCase {
    func testSectionChangesReachCurrentSearchWithAndWithoutBatterySaver() async throws {
        TestEnvironment.prepare()
        let previousTrace = ProcessInfo.processInfo.environment["VANE_LIBRARY_FOCUS_TRACE"]
        setenv("VANE_LIBRARY_FOCUS_TRACE", "1", 1)
        defer {
            if let previousTrace { setenv("VANE_LIBRARY_FOCUS_TRACE", previousTrace, 1) }
            else { unsetenv("VANE_LIBRARY_FOCUS_TRACE") }
        }
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exerciseSectionChanges() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseSectionChanges() async throws {
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
        try await LibraryFocusFixture.admitForeground(window)
        Library.open(.archived, in: store)
        window.contentView = NSHostingView(rootView: LibraryPanel().environmentObject(store))
        window.contentView?.layoutSubtreeIfNeeded()
        try await LibraryFocusFixture.wait("initial Archive editor", in: window) {
            self.currentPrompt(in: window) == LibrarySection.archived.searchPrompt
        }
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
                if currentPrompt(in: window) != section.searchPrompt {
                    LibraryFocusFixture.report("section=\(section) mode=\(mode)", in: window)
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
