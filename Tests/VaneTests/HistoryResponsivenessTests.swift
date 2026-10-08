import AppKit
import XCTest
@testable import vane

@MainActor final class HistoryResponsivenessTests: XCTestCase {
    func testLargeHistoryLeavesTheInputActorAvailable() async throws {
        // A hosted debug CI window cannot attribute wall-clock delay to Vane:
        // AppKit activation, the window server and timer scheduling all contribute.
        // Keep the 100 ms budget for an explicitly controlled release benchmark.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_UI_PERFORMANCE"] == "1",
                          "Run VANE_UI_PERFORMANCE=1 swift test -c release --filter HistoryResponsivenessTests on a quiet logged-in Mac")
        #if DEBUG
        try XCTSkipIf(true, "The native UI performance budget requires a release build")
        #endif
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
        let opening = ProcessInfo.processInfo.systemUptime - started
        var longest = opening
        var longestHeartbeat = 0.0
        let deadline = started + 0.8
        while ProcessInfo.processInfo.systemUptime < deadline {
            let before = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(2))
            let delay = ProcessInfo.processInfo.systemUptime - before - 0.002
            longestHeartbeat = max(longestHeartbeat, delay)
            longest = max(longest, delay)
        }
        print("HISTORY_10K_SYNCHRONOUS_OPEN_MS: \(opening * 1000)")
        print("HISTORY_10K_LONGEST_TIMER_OVERSHOOT_MS: \(longestHeartbeat * 1000)")
        print("HISTORY_10K_LONGEST_INPUT_ACTOR_DELAY_MS: \(longest * 1000)")
        XCTAssertLessThan(longest, 0.1, "Opening 500 results must not stall the input actor for 100 ms")
    }
}
