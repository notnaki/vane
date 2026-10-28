import XCTest

final class NativeFixtureLaunchAdmissionTests: XCTestCase {
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
        XCTAssertEqual(admission.observe(finished: false, at: start + .seconds(1)), .waiting)
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(6)), .timedOut)
    }

    func testFinishedLaunchCannotBypassDelayedWatchdogCallback() {
        let start = ContinuousClock.now
        var admission = NativeFixtureLaunchAdmission(finishedAtEntry: true, deadline: start + .seconds(5),
                                                     watchdogDeadline: start + .seconds(12))
        XCTAssertEqual(admission.observe(finished: true, at: start + .seconds(12)), .watchdogExpired)
    }
}
