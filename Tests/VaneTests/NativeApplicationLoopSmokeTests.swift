import AppKit
import XCTest

@MainActor final class NativeApplicationLoopSmokeTests: XCTestCase {
    func testOwnedLoopAdmitsAsyncWorkAndStops() async throws {
        TestEnvironment.prepare()
        guard ProcessInfo.processInfo.environment["VANE_APPKIT_LOOP_SMOKE"] == "1" else {
            throw XCTSkip("Requires a fresh selected process and the owned 20-second driver bound")
        }
        for cycle in 1...2 {
            let loop = try await NativeFixtureApplicationLoop.acquire()
            var bodyError: (any Error)?
            do {
                try loop.verifyRunning()
                try await Task.sleep(for: .milliseconds(50))
                try loop.verifyRunning()
            } catch { bodyError = error }
            do { try await loop.close() }
            catch {
                if bodyError == nil { bodyError = error }
                else { XCTFail("Native fixture AppKit loop also failed while joining smoke") }
            }
            if let bodyError { throw bodyError }
            XCTAssertFalse(NSApplication.shared.isRunning)
            print("AppKit loop smoke: cycle=\(cycle), completed=true")
        }
    }
}
