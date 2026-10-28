import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LibraryHeadFocusOwnershipTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var mountsOutgoing = false
    }
    private struct Headers: View {
        @ObservedObject var state: State
        var body: some View {
            VStack {
                LibraryHead(section: .downloads, filtering: false, query: .constant(""),
                            filter: { EmptyView() }, actions: { EmptyView() })
                if state.mountsOutgoing {
                    LibraryHead(section: .archived, filtering: false, query: .constant(""),
                                filter: { EmptyView() }, actions: { EmptyView() })
                }
            }
        }
    }

    func testLateOutgoingHeaderCannotStealCurrentSearchFocus() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await exerciseLateOutgoingHeader() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func exerciseLateOutgoingHeader() async throws {
        let store = TabStore(profileID: UUID(), session: [])
        let state = State()
        let old = (Library.shared.section, Library.shared.query, Library.shared.littleArcOnly, Library.shared.completedOnly)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 180),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        defer {
            Library.open(old.0, in: store)
            Library.shared.query = old.1
            Library.shared.littleArcOnly = old.2; Library.shared.completedOnly = old.3
            store.libraryOpen = false
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil; store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        try await LibraryFocusFixture.admitForeground(window)
        Library.open(.downloads, in: store)
        let host = NSHostingView(rootView: Headers(state: state).environmentObject(store))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func prompt() -> String? {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
        }
        try await LibraryFocusFixture.wait("initial Downloads editor", in: window) {
            prompt() == LibrarySection.downloads.searchPrompt
        }
        let field = try XCTUnwrap((window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        var ink: NSColor?
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = field.textColor?.usingColorSpace(.deviceRGB)
        }
        XCTAssertEqual(try XCTUnwrap(ink).alphaComponent, 0.8, accuracy: 0.001,
                       "Native search text must retain the Library's primary ink strength")
        // A departing head can remain mounted while a replacement appears. Its
        // delayed onAppear request has no authority over the selected section.
        state.mountsOutgoing = true
        host.layoutSubtreeIfNeeded()
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(16))
            if prompt() != LibrarySection.downloads.searchPrompt {
                XCTFail("An outgoing Library header stole the current search field editor")
                break
            }
        }
    }
}

/// Admission is separate from the focus request under test. Never manually focus
/// a search field or retry the product request to manufacture fixture success.
@MainActor enum LibraryFocusFixture {
    static func admitForeground(_ window: NSWindow) async throws {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await wait("empty window foreground", in: window) {
            NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow
        }
    }

    static func wait(_ phase: String, in window: NSWindow, condition: () -> Bool) async throws {
        do { try await compatibilityWait { condition() } }
        catch {
            report(phase, in: window)
            throw error
        }
    }

    static func report(_ phase: String, in window: NSWindow) {
        func fields(_ view: NSView) -> [String] {
            let own = (view as? NSTextField).map { "\($0.placeholderString ?? "nil")@window=\($0.window === window)" }
            return (own.map { [$0] } ?? []) + view.subviews.flatMap(fields)
        }
        let editor = window.firstResponder as? NSTextView
        let field = editor?.delegate as? NSTextField
        print("LIBRARY_FOCUS_ADMISSION phase=\(phase) policy=\(NSApp.activationPolicy().rawValue) " +
              "running=\(NSApp.isRunning) active=\(NSApp.isActive) hidden=\(NSApp.isHidden) " +
              "key=\(window.isKeyWindow) exactKey=\(NSApp.keyWindow === window) visible=\(window.isVisible) " +
              "occlusion=\(window.occlusionState.rawValue) responder=\(String(describing: window.firstResponder.map { type(of: $0) })) " +
              "delegate=\(String(describing: editor?.delegate.map { type(of: $0) })) prompt=\(field?.placeholderString ?? "nil") " +
              "section=\(Library.shared.section) focusToken=\(Library.shared.focusToken)")
        print("LIBRARY_FOCUS_FIELDS phase=\(phase) mounted=\(window.contentView.map(fields) ?? [])")
    }
}
