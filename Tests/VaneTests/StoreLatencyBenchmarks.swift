import AppKit
import XCTest
@testable import vane

/// Diagnostic measurements only; the existing History benchmark owns the UI budget.
@MainActor final class StoreLatencyBenchmarks: XCTestCase {
    private func enabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_STORE_PERFORMANCE"] == "1",
                          "Opt-in release Store/Library measurements")
        #if DEBUG
        try XCTSkipIf(true, "Use a release build")
        #endif
        TestEnvironment.prepare()
        _ = NSApplication.shared
    }

    private func measure<T>(_ label: String, _ work: () -> T) -> T {
        let start = ProcessInfo.processInfo.systemUptime
        let result = work()
        print("STORE_PERF \(label): \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
        return result
    }

    func testQueriesAndRepeatedWrites() async throws {
        try enabled()
        for count in [10_000, 240_000] {
            let profile = UUID()
            let store = Store.store(for: profile)
            defer { Store.forget(profile) }
            let entries = (0..<count).map { n in
                (URL(string: "https://fixture.invalid/\(n % (count / 10))")!,
                 "Common synthetic entry \(n)", Date(timeIntervalSince1970: Double(n)))
            }
            XCTAssertEqual(store.record(entries), count)
            XCTAssertEqual(store.addBookmarks(Array(entries.prefix(count / 10)).map { ($0.0, $0.1) }), count / 10)
            for _ in 0..<3 {
                _ = measure("\(count) history browse") { store.history() }
                _ = measure("\(count) history common") { store.history(matching: "common") }
                _ = measure("\(count) suggest common") { store.suggest("common") }
                _ = measure("\(count) bookmark browse") { store.managedBookmarks() }
                _ = measure("\(count) bookmark common") { store.managedBookmarks(matching: "common") }
            }
            let cancelled = Task { await store.historyAsync(matching: "common") }
            try await Task.sleep(for: .milliseconds(10))
            let cancellation = ProcessInfo.processInfo.systemUptime
            cancelled.cancel()
            let discarded = await cancelled.value
            // A sufficiently fast machine may finish before cancellation is requested.
            print("STORE_PERF \(count) cancellation drain: \((ProcessInfo.processInfo.systemUptime - cancellation) * 1000) ms; returned rows: \(discarded.count)")
            measure("\(count) 100 identical retitles") {
                for _ in 0..<100 { XCTAssertTrue(store.retitle(entries[0].0, title: "Unchanged")) }
            }
        }
    }

    func testBookmarkPresentation() async throws {
        try enabled()
        for count in [1_000, 10_000] {
            let profile = UUID()
            let store = Store.store(for: profile)
            defer { Store.forget(profile) }
            XCTAssertEqual(store.addBookmarks((0..<count).map {
                (URL(string: "https://fixture.invalid/\($0)")!, "Common bookmark \($0)")
            }), count)
            let start = ProcessInfo.processInfo.systemUptime
            BookmarkManager.show(profileID: profile)
            let opening = ProcessInfo.processInfo.systemUptime - start
            var longest = opening
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while ProcessInfo.processInfo.systemUptime < deadline {
                let before = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(2))
                longest = max(longest, ProcessInfo.processInfo.systemUptime - before - 0.002)
            }
            print("STORE_PERF \(count) bookmarks open: \(opening * 1000) ms; actor delay: \(longest * 1000) ms")
            let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Bookmarks" })
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            let typed = ProcessInfo.processInfo.systemUptime
            editor.insertText("common", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            var typingDelay = ProcessInfo.processInfo.systemUptime - typed
            let typingDeadline = ProcessInfo.processInfo.systemUptime + 1
            while ProcessInfo.processInfo.systemUptime < typingDeadline {
                let before = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(for: .milliseconds(2))
                typingDelay = max(typingDelay, ProcessInfo.processInfo.systemUptime - before - 0.002)
            }
            XCTAssertEqual(editor.string, "common")
            XCTAssertTrue(window.firstResponder === editor, "Filtering must retain keyboard focus")
            print("STORE_PERF \(count) bookmark filter actor delay: \(typingDelay * 1000) ms")
            window.orderOut(nil)
            window.contentView = nil
        }
    }

    func testRepeatedSnapshots() throws {
        try enabled()
        let root = Store.directory.appendingPathComponent("snapshot-benchmark")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.json")
        var entries = (0..<1000).map { n in
            Session.Entry(id: UUID().uuidString, url: "https://fixture.invalid/\(n)",
                          title: "Session fixture \(n)", state: Data(repeating: 65, count: 800).base64EncodedString())
        }
        let data = try XCTUnwrap(Session.encode([entries]))
        print("STORE_PERF snapshot bytes: \(data.count)")
        XCTAssertTrue(RecoverySnapshots.write(data, to: file, valid: Session.readable))
        measure("100 identical 1000-tab recovery snapshots") {
            for _ in 0..<100 {
                XCTAssertTrue(RecoverySnapshots.write(data, to: file, valid: Session.readable))
            }
        }
        measure("100 changing 1000-tab recovery snapshots including encoding") {
            for n in 0..<100 {
                entries[0].title = "Changed \(n)"
                let next = Session.encode([entries])!
                XCTAssertTrue(RecoverySnapshots.write(next, to: file, valid: Session.readable))
            }
        }
    }

    func testLibraryFiltering() throws {
        try enabled()
        let entries = (0..<Archive.limit).map { n in
            Archive.Entry(url: "https://fixture.invalid/\(n)", title: "Synthetic archive entry \(n)",
                          at: Date(timeIntervalSince1970: Double(n)))
        }
        for _ in 0..<3 {
            measure("2000 Library archive four keystrokes") {
                for query in ["sy", "syn", "synt", "synthetic"] {
                    let filtered = Library.filtered(entries, query: query, littleArcOnly: false)
                    let groups = Library.grouped(filtered, by: { $0.at })
                    XCTAssertEqual(groups.flatMap(\.items).count, entries.count)
                }
            }
        }
    }
}
