import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Native layout/input diagnostics; timings are deliberately opt-in and have no CI budget.
@MainActor final class SearchPresentationPerformanceTests: XCTestCase {
    func testOpeningAndTyping() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1")
        TestEnvironment.prepare()
        _ = NSApplication.shared
        SearchSuggestions.enabled = false
        for count in [20, 300] {
            let profile = ProfileManager.shared.create(name: "Search performance fixture").id
            let spaces = ["Search", "Neighbour"].map { Space(name: $0, profileID: profile) }
            XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
            let store = TabStore(profileID: profile, space: spaces[0], session: [])
            store.sharingReady = false
            store.palette = nil
            store.tabs = (0..<count).map { i in
                let tab = Tab(profileID: profile)
                tab.park(url: URL(string: "about:blank#fixture-\(i)")!,
                         Parked(title: "Search fixture \(i)", needsRecovery: true))
                return tab
            }
            store.syncShapes()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            store.window = window
            let host = BrowserWindowHost(shown: ShownStore(store))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer {
                store.clearSuggestions()
                store.spaceGesture.monitor.remove()
                store.librarySwipeMonitor.remove()
                store.window = nil
                window.contentView = nil
                window.close()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(store.tabs)
                Store.forget(profile)
                ProfileManager.shared.delete(profile)
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            for iteration in 0..<3 {
                let open = ContinuousClock.now
                store.palette = .newTab
                host.layoutSubtreeIfNeeded()
                let opening = open.duration(to: .now)
                var largestGap: Duration = .zero
                let settle = ContinuousClock.now
                while settle.duration(to: .now) < .milliseconds(250) {
                    let beat = ContinuousClock.now
                    try await Task.sleep(for: .milliseconds(2))
                    largestGap = max(largestGap, beat.duration(to: .now))
                }
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                var typing: [Duration] = []
                for text in ["s", "se", "sea", "sear", "search", "search fixture 2"] {
                    let start = ContinuousClock.now
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    host.layoutSubtreeIfNeeded()
                    typing.append(start.duration(to: .now))
                    try await Task.sleep(for: .milliseconds(20))
                }
                print("SEARCH_PRESENTATION tabs=\(count) iteration=\(iteration) open=\(opening) opening_max_gap=\(largestGap) typing_max=\(typing.max()!)")
                store.palette = nil
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertTrue(store.tabs.allSatisfy { $0.existingWeb == nil })
        }
    }
}
