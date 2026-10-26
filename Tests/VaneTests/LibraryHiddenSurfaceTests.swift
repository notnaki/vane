import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class LibraryHiddenSurfaceTests: XCTestCase {
    private final class Activity: ObservableObject { @Published var active = false }
    private struct Fixture: View {
        @ObservedObject var activity: Activity
        let store: TabStore
        let record: @MainActor (LibrarySurfaceWork) -> Void
        var body: some View {
            LibraryPanel()
                .environmentObject(store)
                .environmentObject(ProfileManager.shared)
                .environment(\.renderSurfaceActive, activity.active)
                .environment(\.librarySurfaceWorkRecorder, record)
        }
    }

    func testRetainedLibrarySkipsHiddenWorkAndRefreshesLatestQueriesOnExposure() async throws {
        try XCTSkipUnless(RenderPerformanceExperiment.hiddenSurfaces,
                          "Run with VANE_RENDER_EXPERIMENT=1 to exercise hidden work admission")
        TestEnvironment.prepare()
        let store = TabStore(profileID: UUID(), session: [])
        let activity = Activity()
        let library = Library.shared
        let previous = (library.section, library.query, library.littleArcOnly, library.completedOnly)
        Library.open(.archived, in: store)
        var work: [LibrarySurfaceWork] = []
        var searches: Int { work.filter { $0 == .archiveSearch }.count }
        let host = NSHostingView(rootView: Fixture(activity: activity, store: store) {
            work.append($0)
        })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            Library.open(previous.0, in: store)
            library.query = previous.1; library.littleArcOnly = previous.2
            library.completedOnly = previous.3
            store.libraryOpen = false; store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }; SharedTabs.release(tabs)
            Favicons.forget(store.profileID); Store.forget(store.profileID)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        library.query = "hidden-first"
        library.query = "hidden-latest"
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(searches, 0, "A retained panel must not filter/group while fully hidden")
        activity.active = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(searches, 1, "Exposure performs one current search without replaying hidden queries")
        activity.active = false
        try await Task.sleep(for: .milliseconds(100))
        library.query = "reopen-latest"
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(searches, 1)
        activity.active = true
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(searches, 2, "A second exposure refreshes without dismantling the retained panel")
        for (section, event) in [(LibrarySection.downloads, LibrarySurfaceWork.downloadsRefresh),
                                  (.media, .mediaRefresh)] {
            activity.active = false
            try await Task.sleep(for: .milliseconds(100))
            Library.open(section, in: store)
            library.query = "hidden-\(section.rawValue)"
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(work.filter { $0 == event }.count, 0,
                           "A hidden \(section.rawValue) pane must not rebuild its list")
            activity.active = true
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(work.filter { $0 == event }.count, 1,
                           "Exposure must rebuild only the latest \(section.rawValue) presentation")
        }
    }
}
