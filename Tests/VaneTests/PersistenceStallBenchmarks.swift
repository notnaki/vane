import AppKit
import XCTest
@testable import vane

/// Opt-in release measurements of main-thread persistence and menu work.
/// VANE_UI_PERFORMANCE=1, release build with -enable-testing.
@MainActor final class PersistenceStallBenchmarks: XCTestCase {
    private func enabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1",
                          "Opt-in release persistence measurements")
        TestEnvironment.prepare()
        _ = NSApplication.shared
    }

    private func time(_ label: String, runs: Int = 5, _ work: () -> Void) {
        var samples: [Double] = []
        for _ in 0..<runs {
            let start = ProcessInfo.processInfo.systemUptime
            work()
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let sorted = samples.sorted()
        print(String(format: "PERSIST_PERF %@: median %.2f ms, max %.2f ms", label, sorted[sorted.count / 2], sorted.last!))
    }

    func testPersistenceStalls() async throws {
        try enabled()
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Persistence stall fixture").id
        let store = Store.store(for: profile)
        XCTAssertEqual(store.addBookmarks((0..<500).map {
            (URL(string: "https://bookmark.test/\($0)")!, "Bookmark \($0)")
        }), 500)
        XCTAssertNotNil(store.record((0..<50_000).map {
            (URL(string: "https://history.test/\($0 % 5000)")!, "Visit \($0)", Date(timeIntervalSince1970: Double($0)))
        }))
        // A heavy but plausible profile: a dozen Spaces, each with pinned and Today rows.
        let spaces = (0..<12).map { n in
            Space(name: "Space \(n)", profileID: profile,
                  tabURLs: (0..<40).map { URL(string: "https://today.test/\(n)/\($0)?q=some-longer-query-string")! },
                  pinnedTabURLs: (0..<60).map { URL(string: "https://pinned.test/\(n)/\($0)/path/to/document")! })
        }
        XCTAssertTrue(manager.saveSpaces(spaces, for: profile))
        let tabStore = TabStore(profileID: profile, space: spaces[0], session: [])
        defer {
            let owned = tabStore.everyTab
            tabStore.dropStashes()
            owned.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === tabStore }
            SharedTabs.release(owned)
            Store.forget(profile)
            manager.delete(profile)
        }
        let state = Data(repeating: 65, count: 1500)
        func parked(_ urls: [URL]) -> [String: Parked] {
            Dictionary(uniqueKeysWithValues: urls.map { ($0.absoluteString, Parked(title: "Parked", state: state)) })
        }
        _ = tabStore.restore(spaces[0].pinnedTabURLs!, as: .pinned, parked: parked(spaces[0].pinnedTabURLs!))
        _ = tabStore.restore(spaces[0].tabURLs, as: .today, parked: parked(spaces[0].tabURLs))
        print("PERSIST_PERF fixture tabs=\(tabStore.tabs.count)")

        time("snapshot all tabs") { for tab in tabStore.tabs { _ = tab.snapshot } }
        time("saveCurrentSpace") { _ = tabStore.saveCurrentSpace() }
        time("Session.enqueueSave", runs: 15) { _ = Session.enqueueSave() }
        _ = await Session.flushPersistence()
        time("SharedTabs.flush") { SharedTabs.flush() }
        time("saveShape") { tabStore.saveShape() }
        time("savePins (unchanged)") { tabStore.savePins() }
        var space = spaces[0]
        time("updateSpace (changed)", runs: 15) { space.name += "!"; _ = manager.updateSpace(space) }
        time("updateSpace (unchanged)") { _ = manager.updateSpace(space) }
        time("spaces(for:)") { _ = manager.spaces(for: profile) }

        time("buildMenu") { _ = buildMenu() }
        time("rebuild (assigns mainMenu)", runs: 15) { rebuild() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tabStore.window = window
        window.makeKeyAndOrderFront(nil)
        time("windowDidBecomeKey work", runs: 15) { rebuild(); SharedTabs.refreshPresentation(); tabStore.extensions.sync() }
        tabStore.window = nil
        window.orderOut(nil)
        time("bookmarks(limit: 15)") { _ = store.bookmarks(limit: 15) }
        time("SharedTabs.refreshPresentation") { SharedTabs.refreshPresentation() }

        let archive = Archive.shared(for: profile)
        archive.add((0..<Archive.limit).map {
            Archive.Entry(url: "https://archive.test/\($0)/some/longer/path", title: "Archived page \($0) with a title", at: .now)
        })
        time("Archive.add at limit", runs: 30) { archive.add(url: URL(string: "https://archive.test/new/\(UUID())")!, title: "New") }

        let downloads = Downloads(profileID: profile, directory: Store.directory)
        for n in 0..<Downloads.historyLimit {
            var record = Downloads.Record(name: "file-\(n).zip", destination: Store.directory.appendingPathComponent("dl/file-\(n).zip"),
                                          source: URL(string: "https://download.test/\(n)/file.zip"), state: "done")
            record.destinationBookmark = Data(repeating: 7, count: 700)
            downloads.add(record)
        }
        time("Downloads.save 200") { downloads.save() }

        time("history recordNavigation") { _ = store.recordNavigation(URL(string: "https://nav.test/\(UUID())")!, title: "Nav") }
        time("Store.directory x100") { for _ in 0..<100 { _ = Store.directory } }
    }
}
