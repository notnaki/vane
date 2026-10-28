import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel05LibraryFocusTests: XCTestCase {
    func testSectionChangesReachCurrentSearchWithAndWithoutBatterySaver() async throws {
        TestEnvironment.prepare()
        let previousDiagnostic = ProcessInfo.processInfo.environment["VANE_LIBRARY_FOCUS_DIAGNOSTIC"]
        setenv("VANE_LIBRARY_FOCUS_DIAGNOSTIC", "1", 1)
        defer {
            if let previousDiagnostic { setenv("VANE_LIBRARY_FOCUS_DIAGNOSTIC", previousDiagnostic, 1) }
            else { unsetenv("VANE_LIBRARY_FOCUS_DIAGNOSTIC") }
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
        let window = LibraryFocusHistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.recordEditingNotifications()
        defer { window.stopRecording() }
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
                window.record("requested section=\(section) mode=\(mode)")
                XCTAssertEqual(Library.shared.section, section)
                let deadline = Date.now.addingTimeInterval(3)
                while currentPrompt(in: window) != section.searchPrompt, Date.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                    window.record("poll section=\(section)")
                }
                if currentPrompt(in: window) != section.searchPrompt {
                    LibraryFocusFixture.report("section=\(section) mode=\(mode)", in: window)
                    window.reportHistory()
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

/// Diagnostic branch only: observe native focus without adding focus or layout retries.
@MainActor private final class LibraryFocusHistoryWindow: NSWindow {
    private var history: [String] = []
    private var editingRecorder: LibraryFocusEditingRecorder?
    private var lastSnapshot = ""

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let requested = identity(responder)
        let result = super.makeFirstResponder(responder)
        append("makeFirstResponder requested=\(requested) result=\(result) actual=\(identity(firstResponder))")
        return result
    }

    override func update() {
        super.update()
        record("window-update")
    }

    func recordEditingNotifications() {
        editingRecorder = LibraryFocusEditingRecorder(window: self)
    }

    func stopRecording() {
        editingRecorder?.stop()
        editingRecorder = nil
    }

    func recordEditing(_ note: Notification) {
        append("editing event=\(note.name.rawValue) field=\(identity(note.object as? NSResponder)) actual=\(identity(firstResponder))")
    }

    func recordHeadRequest(_ note: Notification) {
        guard note.object as? NSWindow === self else { return }
        append("head-request \(note.userInfo ?? [:])")
    }

    func record(_ phase: String) {
        func fields(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).flatMap { field -> String? in
                guard field.placeholderString?.hasPrefix("Search ") == true else { return nil }
                return "\(identity(field)) attached=\(field.window === self) hidden=\(field.isHiddenOrHasHiddenAncestor)"
            }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        let snapshot = "active=\(NSApp.isActive) key=\(NSApp.keyWindow === self) actual=\(identity(firstResponder)) fields=\(contentView.map(fields) ?? [])"
        guard snapshot != lastSnapshot || phase.hasPrefix("requested") else { return }
        lastSnapshot = snapshot
        append("\(phase) \(snapshot)")
    }

    private func identity(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        let field = (responder as? NSTextField) ?? ((responder as? NSTextView)?.delegate as? NSTextField)
        return "\(type(of: responder))@\(ObjectIdentifier(responder)) field=\(field.map { "\($0.placeholderString ?? "nil")@\(ObjectIdentifier($0))" } ?? "nil")"
    }

    private func append(_ message: String) {
        if history.count == 512 { history.removeFirst() }
        history.append("\(ProcessInfo.processInfo.systemUptime) \(message)")
    }

    func reportHistory() {
        print("LIBRARY_NATIVE_FOCUS_HISTORY_BEGIN")
        history.forEach { print($0) }
        print("LIBRARY_NATIVE_FOCUS_HISTORY_END")
    }
}

@MainActor private final class LibraryFocusEditingRecorder: NSObject {
    private weak var window: LibraryFocusHistoryWindow?

    init(window: LibraryFocusHistoryWindow) {
        self.window = window
        super.init()
        for name in [NSControl.textDidBeginEditingNotification, NSControl.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(editing(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(headRequest(_:)),
            name: .init("Vane.LibraryHeadFocusDiagnostic"), object: window)
    }

    @objc private func editing(_ note: Notification) { window?.recordEditing(note) }
    @objc private func headRequest(_ note: Notification) { window?.recordHeadRequest(note) }
    func stop() { NotificationCenter.default.removeObserver(self) }
}
