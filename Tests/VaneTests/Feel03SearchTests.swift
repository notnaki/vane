import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel03SearchTests: XCTestCase {
    func testRecentTabsMatchStableFullSortAcrossLargeCountsAndCaps() {
        let tabs = (0..<10_000).map { i in
            (id: UUID(), lastActive: Date(timeIntervalSince1970: Double(i % 37)))
        }
        let current = tabs[777].id
        let sorted = tabs.enumerated().filter { $0.element.id != current }.sorted {
            $0.element.lastActive == $1.element.lastActive ? $0.offset < $1.offset
                : $0.element.lastActive > $1.element.lastActive
        }.map { $0.element.id }
        for cap in [0, 1, 5, 24, Int.max] {
            XCTAssertEqual(TabSwitcher.recent(tabs, current: current, limit: cap),
                           Array(([current] + sorted).prefix(cap)))
        }
    }

    func testLateSuggestionsReuseLayoutAndPreserveArrangement() {
        for tabs in [[], ["strong"], ["strong", "weak", "weaker"]] {
            let lead = min(tabs.count, 1)
            let layout = Feel03PaletteLayout(leading: Array(tabs.prefix(lead)) + ["typed"],
                trailing: Array(tabs.dropFirst(lead)) + ["archive", "command"],
                assistant: "assistant", acceptsSuggestions: true)
            for suggestions in [[], ["local"], ["local", "remote"]] {
                XCTAssertEqual(layout.rows(suggestions: suggestions), Palette.arrange(tabs: tabs,
                    typed: "typed", suggestions: suggestions, ai: "assistant",
                    rest: ["archive"], commands: ["command"], leadingTabs: lead))
            }
        }
    }

    func testAsyncInsertionsKeepSelectedResultPastTheDisplayCap() {
        let local = (0..<24).map { "tab:\($0)" }
        let updated = ["typed", "history", "completion"] + local
        let visible = Feel03PaletteLayout.visible(updated, limit: 24, retaining: "tab:23", id: { $0 })
        let index = Palette.selectedIndex(previous: 23, selectedID: "tab:23", rowIDs: visible, reset: false)
        XCTAssertEqual(visible[index], "tab:23")
        XCTAssertEqual(Feel03PaletteLayout.visible(updated, limit: 24, retaining: nil, id: { $0 }).count, 24)
    }

    func testSelectedCompletionSurvivesHistoryCappingAndDeduplication() throws {
        TestEnvironment.prepare()
        let completion = try XCTUnwrap(SearchSuggestions.merge("swift", local: [],
            remote: ["swift concurrency"]).first)
        for count in [1, 8] {
            let local = (0..<count).map {
                Suggestion(url: "https://saved.example/\($0)",
                           title: count == 1 ? "swift concurrency" : "Saved page \($0)", bookmarked: true)
            }
            let merged = SearchSuggestions.merge("swift", local: local, remote: ["swift concurrency"])
            XCTAssertFalse(merged.contains { $0.id == completion.id })
            let visible = Feel03PaletteLayout.visible(merged, limit: 24,
                retaining: completion.id, fallback: completion, id: \.id)
            let index = Palette.selectedIndex(previous: 0, selectedID: completion.id,
                rowIDs: visible.map(\.id), reset: false)
            XCTAssertEqual(visible[index].url, completion.url,
                           "Return must still open the completion selected before history arrived")
            let refreshed = Feel03PaletteLayout.visible(merged, limit: 24,
                retaining: visible[index].id, fallback: visible[index], id: \.id)
            let refreshedIndex = Palette.selectedIndex(previous: index, selectedID: completion.id,
                rowIDs: refreshed.map(\.id), reset: false)
            XCTAssertEqual(refreshed[refreshedIndex].url, completion.url,
                           "Later tab-title or favicon refreshes must preserve the same destination")
            XCTAssertFalse(Feel03PaletteLayout.visible(merged, limit: 24,
                retaining: nil, fallback: completion, id: \.id).contains { $0.id == completion.id },
                "A new query must discard the retained completion")
        }
    }

    func testSharedTabRowsRetainTheirIntendedWindow() {
        let tab = UUID()
        let firstWindow = NSObject(), secondWindow = NSObject()
        let first = Feel03TabContent.rowID(tab, owner: firstWindow)
        let second = Feel03TabContent.rowID(tab, owner: secondWindow)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, Feel03TabContent.rowID(tab, owner: firstWindow))
        let rows = ["typed", "local", first, second]
        let kept = Palette.selectedIndex(previous: 1, selectedID: second, rowIDs: rows, reset: false)
        XCTAssertEqual(rows[kept], second)
    }

    func testTabSnapshotIgnoresProgressAndTracksResultContent() {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID(), session: [])
        defer { TabStore.all.removeAll { $0 === store } }
        let tab = Tab(isPrivate: true)
        let before = Feel03TabContent(tab, owner: store, windowNumber: 0)
        tab.progress = 0.5
        XCTAssertEqual(before, Feel03TabContent(tab, owner: store, windowNumber: 0))
        tab.canGoBack = true
        XCTAssertNotEqual(before, Feel03TabContent(tab, owner: store, windowNumber: 0),
                          "Action availability must still refresh without a query edit")
        tab.title = "Arrived title"
        XCTAssertNotEqual(before, Feel03TabContent(tab, owner: store, windowNumber: 0))
        let titled = Feel03TabContent(tab, owner: store, windowNumber: 0)
        tab.address = "https://fixture.invalid"
        XCTAssertNotEqual(titled, Feel03TabContent(tab, owner: store, windowNumber: 0))
    }

    func testHostedAddressPaletteSelectsSeedAndKeepsTypingFocus() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let store = TabStore(profileID: profile, session: [])
        let tab = Tab(profileID: profile)
        tab.address = "https://fixture.invalid/prefilled"
        store.tabs = [tab]
        store.current = tab.id
        store.palette = .address
        SearchSuggestions.enabled = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            store.clearSuggestions()
            window.contentView = nil
            window.close()
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile)
        }
        window.contentView = NSHostingView(rootView: PaletteView(mode: .address) {
            store.palette = nil
        }.environmentObject(store))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date.now.addingTimeInterval(5)
        while !(window.firstResponder is NSTextView), Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.string, tab.address)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: tab.address.utf16.count))
        editor.insertText("local query", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "local query")
        XCTAssertTrue(window.firstResponder === editor)
        // These writes intentionally happen in one turn: SwiftUI can retain the
        // mounted field while presentation itself closes and reopens.
        store.palette = nil
        store.palette = .address
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, tab.address)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: tab.address.utf16.count))
        editor.insertText("reopened query", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(editor.string, "reopened query")
    }

    func testRetiringFieldCannotTakeFocusDuringDismissal() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        var active = true
        var text = "old"
        let field = CommandField(text: Binding(get: { text }, set: { text = $0 }),
                                 prompt: "Search", selectAll: true, label: "Search", hint: "",
                                 canFocus: { active }, onKey: { _ in true })
        let coordinator = CommandField.Coordinator(field)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let native = CommandField.BarField(string: text)
        let replacement = NSTextField(string: "new")
        coordinator.take(native, selectAll: true)
        active = false
        window.contentView?.addSubview(native)
        window.contentView?.addSubview(replacement)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(replacement)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(window.firstResponder === replacement.currentEditor())
    }

    func testFieldTakesFocusOnMountAndDoesNotStealItAfterRemoval() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        var text = "https://example.test/address"
        let field = CommandField(text: Binding(get: { text }, set: { text = $0 }),
                                 prompt: "Search", selectAll: true, label: "Search",
                                 hint: "", onKey: { _ in true })
        let coordinator = CommandField.Coordinator(field)
        let native = CommandField.BarField(string: text)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let replacement = NSTextField(string: "other")
        window.contentView?.addSubview(replacement)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(replacement)
        coordinator.take(native, selectAll: true)
        // Drain more queue turns than the old retry limit before attaching.
        for _ in 0..<25 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        window.contentView?.addSubview(native)
        XCTAssertEqual(native.currentEditor()?.selectedRange,
                       NSRange(location: 0, length: (text as NSString).length))
        native.removeFromSuperview()
        window.makeFirstResponder(replacement)
        coordinator.take(native, selectAll: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(window.firstResponder === replacement.currentEditor())
    }
}
