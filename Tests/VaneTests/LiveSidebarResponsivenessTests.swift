import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

/// A loaded document stays mounted while the real browser's sidebar and palette change.
/// Optional timing runs can use a public website instead of the local HTTP document.
@MainActor final class LiveSidebarResponsivenessTests: XCTestCase {
    func testLoadedPageSurvivesDisclosureSearchAndTabSelection() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let server = try NavigationHTTPFixture()
        defer { server.stop() }
        try await compatibilityWait { server.port != nil }
        server.pages["/page"] = """
        <!doctype html><title>Live sidebar document</title>
        <style>body{font:20px system-ui}article{display:grid;grid-template-columns:repeat(4,1fr)}section{padding:24px;background:#ddd;margin:4px}</style>
        <input id="draft" value="keep this draft"><article>
        \((0..<150).map { "<section>Document card \($0)</section>" }.joined())
        </article><script>window.beats=0;setInterval(()=>window.beats++,16)</script>
        """
        let timing = ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1"
        let remote = ProcessInfo.processInfo.environment["VANE_LIVE_SITE_URL"].flatMap(URL.init(string:))
        let url = try remote ?? server.url("/page")
        let suggestionsEnabled = SearchSuggestions.enabled
        SearchSuggestions.enabled = false
        defer { SearchSuggestions.enabled = suggestionsEnabled }
        for count in timing ? [28, 300] : [28] {
            let profile = ProfileManager.shared.create(name: "Loaded document fixture").id
            let spaces = ["Work", "Neighbour"].map { Space(name: $0, profileID: profile) }
            XCTAssertTrue(ProfileManager.shared.saveSpaces(spaces, for: profile))
            let store = TabStore(profileID: profile, space: spaces[0], session: [])
            store.sharingReady = false
            let tabs = (0..<count).map { index in
                let tab = store.makeBlankTab(as: index < 4 ? .favourite : (index < 15 ? .pinned : .today))
                tab.park(url: URL(string: url.absoluteString + "#tab-\(index)")!, Parked(title: "Live document \(index)"))
                return tab
            }
            store.tabs = tabs
            let folder = Folder(name: "Documents")
            store.pins = Pins(entries: tabs[4..<8].map { .init(row: .tab($0.id.uuidString)) }
                + [.init(row: .folder(folder))]
                + tabs[8..<15].map { .init(row: .tab($0.id.uuidString), parent: folder.id) })
            store.todayShape = Pins(entries: tabs[15...].map { .init(row: .tab($0.id.uuidString)) })
            store.palette = nil
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 750),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            store.window = window
            let host = BrowserWindowHost(shown: ShownStore(store))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            SharedTabs.refreshPresentation()
            defer {
                store.clearSuggestions()
                store.spaceGesture.monitor.remove()
                store.librarySwipeMonitor.remove()
                window.contentView = nil
                window.close()
                store.window = nil
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
                SharedTabs.release(tabs)
                Store.forget(profile)
                ProfileManager.shared.delete(profile)
            }
            // Keep three actual WebKit documents alive, including the visible page.
            for tab in tabs[15..<18] {
                store.current = tab.id
                host.layoutSubtreeIfNeeded()
                try await compatibilityWait {
                    tab.existingWeb?.url != nil && tab.existingWeb?.isLoading == false && !tab.loading
                }
            }
            let active = tabs[17]
            let web = try XCTUnwrap(active.existingWeb)
            XCTAssertTrue(web.window === window)
            XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
            let title = try await web.evaluateJavaScript("document.title") as? String
            XCTAssertFalse(try XCTUnwrap(title).isEmpty)
            if remote == nil {
                let cards = try await web.evaluateJavaScript("document.querySelectorAll('section').length") as? Int
                XCTAssertEqual(cards, 150, "The content must be a rendered document, not a blank parked page")
                _ = try await web.evaluateJavaScript("document.getElementById('draft').value = 'edited draft retained'")
            }
            for iteration in 0..<3 {
                var lastBeat = ProcessInfo.processInfo.systemUptime
                var largestGap = 0.0
                let timer = Timer(timeInterval: 0.002, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        let now = ProcessInfo.processInfo.systemUptime
                        largestGap = max(largestGap, now - lastBeat)
                        lastBeat = now
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                defer { timer.invalidate() }
                let start = ContinuousClock.now
                store.toggleFolder(folder.id)
                host.layoutSubtreeIfNeeded()
                let disclosure = start.duration(to: .now)
                try await Task.sleep(for: .milliseconds(600))
                let open = ContinuousClock.now
                store.palette = .newTab
                host.layoutSubtreeIfNeeded()
                let opening = open.duration(to: .now)
                try await compatibilityWait { window.firstResponder is NSTextView }
                let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
                var typing = Duration.zero
                for text in ["l", "li", "live", "live document"] {
                    let edit = ContinuousClock.now
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                    host.layoutSubtreeIfNeeded()
                    typing = max(typing, edit.duration(to: .now))
                    try await Task.sleep(for: .milliseconds(20))
                }
                store.palette = nil
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(active.existingWeb === web)
                XCTAssertTrue(web.window === window)
                XCTAssertFalse(web.isHiddenOrHasHiddenAncestor)
                if remote == nil {
                    let draft = try await web.evaluateJavaScript("document.getElementById('draft').value") as? String
                    XCTAssertEqual(draft, "edited draft retained", "Disclosure/search must not reload the live document")
                }
                print("LIVE_SIDEBAR tabs=\(count) remote=\(remote != nil) iteration=\(iteration) disclosure=\(disclosure) open=\(opening) typing_max=\(typing) max_gap_ms=\(largestGap * 1000)")
            }
            store.current = tabs[15].id
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(tabs[15].existingWeb?.window === window)
            XCTAssertFalse(try XCTUnwrap(tabs[15].existingWeb).isHiddenOrHasHiddenAncestor)
        }
    }
}
