import AppKit
import XCTest
import NativeTestHostBootstrap

@MainActor final class NativeApplicationLoopSmokeTests: XCTestCase {
    func testNativeHostBootstrapPrecedesAppKit() throws {
        try assertNativeHostBootstrap()
    }

    private func assertNativeHostBootstrap() throws {
        XCTAssertTrue(VaneNativeTestHostBootstrapRan(), "The test-only bootstrap object must be linked")
        XCTAssertTrue(VaneNativeTestHostBootstrapWasEarly(), "The workaround must run before NSApplication is created")
        XCTAssertTrue(VaneNativeTestHostBootstrapConfigured(), "Late or ineffective AppKit setup must fail clearly")
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let enabled = try XCTUnwrap(arguments["NSEventConcurrentProcessingEnabled"] as? Bool)
        XCTAssertFalse(enabled, "Only this process's volatile argument domain configures the test host")
    }

    func testOwnedLoopAdmitsAsyncWorkAndStops() async throws {
        try assertNativeHostBootstrap()
        TestEnvironment.prepare()
        guard ProcessInfo.processInfo.environment["VANE_APPKIT_LOOP_SMOKE"] == "1" else {
            throw XCTSkip("Requires a fresh selected process and the bounded owned driver")
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
