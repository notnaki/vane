import AppKit
import XCTest
@testable import vane

/// Set up once, before any app singleton can resolve its paths or defaults suite.
@MainActor enum TestEnvironment {
    private static let cleanup: FixtureCleanup = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vane-search-tests-\(UUID())")
        setenv("VANE_DATA_DIR", dir.path, 1)
        let cleanup = FixtureCleanup(directory: dir)
        XCTestObservationCenter.shared.addTestObserver(cleanup)
        return cleanup
    }()

    private static let resourceBaseline: Void = {
        NativeFixtureDiagnostics.emit("resource baseline: " + NativeFixtureDiagnostics.resourceSnapshot())
    }()

    /// CI starts xctest as a launchd job, not from a visible app, so between window-presenting
    /// fixtures it is App Nap eligible: its timers coalesce. Started with `launchctl submit` on
    /// an idle Mac, 64 of its 20ms sleeps in 40s overran 100ms (worst 0.54s); with this
    /// activity, 3 (0.12s). Keeps real-time fixture deadlines independent of how the runner
    /// launched the process.
    private static let appNapOptOut = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "Native fixtures measure real-time deadlines")

    static func prepare() {
        _ = appNapOptOut
        _ = cleanup
        NativeFixtureRetirement.registerHostIfEnabled()
        // Deny by default: mounting the Passwords pane prompts, and no fixture may show a
        // real Touch ID sheet. Tests that need a grant install their own.
        #if DEBUG
        if Passwords.authenticator == nil { Passwords.authenticator = { _, done in done(false) } }
        #endif
        _ = resourceBaseline
        _ = approvedPasswordFills
    }

    /// Fixtures that fill a saved password have nobody to answer a system prompt. Cases
    /// about the prompt itself give their tab a gate of its own.
    private static let approvedPasswordFills: Void = {
        PasswordFillGate.shared.authenticate = { _, done in done(true); return nil }
    }()

    static func supportsPiPMotion(in frames: [NSRect]) -> Bool {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let screens = NSScreen.screens.map(\.frame)
        let batterySaver = BatterySaver.shared.isActive
        let available = !reduceMotion && !batterySaver && frames.allSatisfy { frame in
            screens.contains { $0.intersects(frame) }
        }
        print("PiP motion prerequisites: reduceMotion=\(reduceMotion), batterySaver=\(batterySaver), screens=\(screens), frames=\(frames), available=\(available)")
        return available
    }
}

private final class FixtureCleanup: NSObject, XCTestObservation {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func testBundleDidFinish(_ testBundle: Bundle) {
        UserDefaults.dropScratchSuite(UserDefaults.suiteName(forDataDir: directory.path))
        try? FileManager.default.removeItem(at: directory)
    }
}
