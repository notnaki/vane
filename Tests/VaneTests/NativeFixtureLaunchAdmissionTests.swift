import AppKit
import XCTest

final class NativeFixtureLaunchAdmissionTests: XCTestCase {
    @MainActor func testLostReadinessAfterInitialHeartbeatIsReadmittedBeforeReturning() async throws {
        TestEnvironment.prepare()
        let sequence = LaunchReadinessSequence()
        let loop = try await NativeFixtureApplicationLoop.acquire(launchReadiness: { sequence.observe() })
        var failure: (any Error)?
        do {
            try loop.verifyRunning()
            XCTAssertGreaterThanOrEqual(sequence.observations, 3,
                "The second observation deliberately loses readiness; acquisition must observe recovery")
            XCTAssertTrue(NSApplication.shared.isRunning)
            XCTAssertTrue(NSRunningApplication.current.isFinishedLaunching)
        } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        XCTAssertFalse(NSApplication.shared.isRunning)
        if let failure { throw failure }
    }

    func testDelayedHeartbeatAcceptsLaunchAlreadyFinishedAtEntry() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: true, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(6)), .ready,
                       "Executor delay is not an unfinished application launch")
    }

    func testUnfinishedLaunchKeepsItsOriginalDeadline() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: false, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: false, at: start + .seconds(1)), .waiting)
        XCTAssertEqual(admission.observe(finished: false, at: start + .seconds(5)), .timedOut)
    }

    func testFirstFinishedObservationAfterNewLaunchDeadlineStillFails() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: false, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(6)), .timedOut)
    }

    func testPreviouslyFinishedLaunchLosingReadinessKeepsItsDeadline() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: true, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .milliseconds(500)), .ready)
        XCTAssertEqual(admission.observe(finished: false, at: start + .seconds(1)), .waiting)
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(6)), .timedOut)
    }

    func testFinishedLaunchCannotBypassDelayedWatchdogCallback() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: true, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(12)), .watchdogExpired)
    }

    func testReadinessLostAfterDelayedReadySampleKeepsTheOriginalDeadline() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: true, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(6)), .ready)
        XCTAssertEqual(admission.observe(finished: false, at: start + .seconds(6)), .timedOut,
                       "A completed initial sample cannot extend a later genuinely unfinished launch")
    }
}

@MainActor private final class LaunchReadinessSequence {
    private(set) var observations = 0
    func observe() -> Bool {
        observations += 1
        return observations != 2
    }
}
