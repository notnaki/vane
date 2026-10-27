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
        let app = NSApplication.shared
        let store = TabStore(profileID: UUID(), session: [])
        let state = State()
        let old = (Library.shared.section, Library.shared.query, Library.shared.littleArcOnly, Library.shared.completedOnly)
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 400, height: 180),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: Headers(state: state).environmentObject(store))
        window.contentView = host
        defer {
            Library.open(old.0, in: store)
            Library.shared.query = old.1
            Library.shared.littleArcOnly = old.2; Library.shared.completedOnly = old.3
            store.libraryOpen = false
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil; store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        Library.open(.downloads, in: store)
        app.activate(); window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        func prompt() -> String? {
            ((window.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString
        }
        try await compatibilityWait { window.isKeyWindow && app.isActive && prompt() == LibrarySection.downloads.searchPrompt }
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
