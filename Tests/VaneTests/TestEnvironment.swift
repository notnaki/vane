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

    static func prepare() { _ = cleanup }

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
