import AppKit
import XCTest
@testable import vane

@MainActor final class HistoryResponsivenessTests: XCTestCase {
    func testLargeHistoryLeavesTheInputActorAvailable() async throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "History performance fixture").id
        // Warm the native window/SwiftUI runtime independently of result layout.
        // The target is recurring input work, not one-time framework initialization.
        let cold = ProcessInfo.processInfo.systemUptime
        HistoryWindow.show(profileID: profile)
        try await Task.sleep(for: .milliseconds(200))
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "History" })
        window.orderOut(nil)
        window.contentView = nil
        print("HISTORY_COLD_WINDOW_WARMUP_MS: \((ProcessInfo.processInfo.systemUptime - cold) * 1000)")
        let history = Store.store(for: profile)
        let entries = (0..<10_000).map { n in
            (URL(string: "https://fixture.invalid/\(n)")!, "Synthetic history entry \(n)",
             Date(timeIntervalSince1970: 1_791_400_000 - Double(n)))
        }
        XCTAssertEqual(history.record(entries), entries.count)
        defer { ProfileManager.shared.delete(profile) }
        let started = ProcessInfo.processInfo.systemUptime
        HistoryWindow.show(profileID: profile)
        defer { window.orderOut(nil); window.contentView = nil }
        var longest = ProcessInfo.processInfo.systemUptime - started
        let deadline = started + 0.8
        while ProcessInfo.processInfo.systemUptime < deadline {
            let before = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(2))
            longest = max(longest, ProcessInfo.processInfo.systemUptime - before - 0.002)
        }
        print("HISTORY_10K_LONGEST_INPUT_ACTOR_DELAY_MS: \(longest * 1000)")
        XCTAssertLessThan(longest, 0.1, "Opening 500 results must not stall the input actor for 100 ms")
    }
}
