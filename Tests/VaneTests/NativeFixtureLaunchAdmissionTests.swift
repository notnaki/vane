import AppKit
import XCTest

final class NativeFixtureLaunchAdmissionTests: XCTestCase {
    @MainActor func testReadinessWithdrawnAtFinalVerificationIsReadmitted() async throws {
        try await exerciseFinalWithdrawal(at: 3)
    }

    @MainActor func testReadinessWithdrawnAtCallerHandoffIsReadmitted() async throws {
        try await exerciseFinalWithdrawal(at: 4)
    }

    @MainActor private func exerciseFinalWithdrawal(at observation: Int) async throws {
        TestEnvironment.prepare()
        let sequence = LaunchReadinessSequence(withdrawAt: observation)
        let loop: NativeFixtureApplicationLoop
        do {
            loop = try await NativeFixtureApplicationLoop.acquire(launchReadiness: { sequence.observe() })
        } catch {
            XCTAssertTrue(sequence.withdrew, "The control must withdraw actual admission readiness")
            XCTFail("A temporary final-verification withdrawal must be readmitted within the original budget: \(error)")
            return
        }
        var failure: (any Error)?
        do {
            XCTAssertTrue(sequence.withdrew)
            XCTAssertTrue(sequence.recovered, "Acquisition must observe recovery rather than bypass the predicate")
            XCTAssertGreaterThanOrEqual(sequence.observations, observation + 1,
                "Acquisition must observe recovery after the controlled final-verification withdrawal")
            try loop.verifyRunning()
            XCTAssertTrue(NSApplication.shared.isRunning)
        } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        XCTAssertFalse(NSApplication.shared.isRunning)
        if let failure { throw failure }
    }

    @MainActor func testPermanentCallerHandoffWithdrawalExpiresOriginalBudget() async throws {
        TestEnvironment.prepare()
        let sequence = LaunchReadinessSequence(withdrawAt: 4, recovers: false)
        var acquired: NativeFixtureApplicationLoop?
        var failure: (any Error)?
        do { acquired = try await NativeFixtureApplicationLoop.acquire(launchReadiness: { sequence.observe() }) }
        catch { failure = error }
        if let acquired { try await acquired.close(); XCTFail("Permanent withdrawal must not authorize a fixture body") }
        XCTAssertTrue(sequence.withdrew)
        XCTAssertFalse(sequence.recovered)
        XCTAssertEqual(failure.map { String(describing: $0) }, "launchTimedOut")
        XCTAssertFalse(NSApplication.shared.isRunning)
    }

    @MainActor func testLateCallerHandoffWithdrawalCannotGetANewBudget() async throws {
        TestEnvironment.prepare()
        let warmup = try await NativeFixtureApplicationLoop.acquire()
        try await warmup.close()
        guard NSRunningApplication.current.isFinishedLaunching else {
            XCTFail("The delayed-ready control requires an actually completed launch")
            return
        }
        let sequence = LaunchReadinessSequence(withdrawAt: 4)
        var acquired: NativeFixtureApplicationLoop?
        var failure: (any Error)?
        do {
            acquired = try await NativeFixtureApplicationLoop.acquire(beforeHeartbeat: {
                // Deliberate executor delay after a completed launch, not a
                // readiness sleep. A subsequent false sample still owes 5s.
                try? await Task.sleep(for: .seconds(6))
            }, launchReadiness: { sequence.observe() })
        } catch { failure = error }
        if let acquired { try await acquired.close(); XCTFail("A false sample after the original budget must fail") }
        XCTAssertTrue(sequence.withdrew)
        XCTAssertEqual(failure.map { String(describing: $0) }, "launchTimedOut")
        XCTAssertFalse(NSApplication.shared.isRunning)
    }

    @MainActor func testCallerHandoffCancellationJoinsTheOwnedLoop() async throws {
        TestEnvironment.prepare()
        let sequence = LaunchReadinessSequence(withdrawAt: 4, recovers: false)
        sequence.onWithdrawal = { sequence.operation?.cancel() }
        let operation = Task { @MainActor in
            try await NativeFixtureApplicationLoop.acquire(launchReadiness: { sequence.observe() })
        }
        sequence.operation = operation
        var acquired: NativeFixtureApplicationLoop?
        var failure: (any Error)?
        do { acquired = try await operation.value } catch { failure = error }
        sequence.operation = nil
        sequence.onWithdrawal = nil
        if let acquired { try await acquired.close(); XCTFail("Cancellation must not authorize a fixture body") }
        XCTAssertTrue(sequence.withdrew)
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(failure.map { String(describing: $0) }, "cancelled")
        XCTAssertFalse(NSApplication.shared.isRunning)
    }

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
    private let withdrawAt: Int
    private let recovers: Bool
    private(set) var observations = 0
    private(set) var withdrew = false
    private(set) var recovered = false
    var operation: Task<NativeFixtureApplicationLoop, any Error>?
    var onWithdrawal: (@MainActor () -> Void)?
    init(withdrawAt: Int = 2, recovers: Bool = true) { self.withdrawAt = withdrawAt; self.recovers = recovers }
    func observe() -> Bool {
        observations += 1
        if observations == withdrawAt {
            withdrew = true
            onWithdrawal?()
            return false
        }
        if observations > withdrawAt, !recovers { return false }
        if withdrew { recovered = true }
        return true
    }
}
