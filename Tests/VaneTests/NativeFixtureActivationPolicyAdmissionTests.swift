import AppKit
import XCTest

@MainActor final class NativeFixtureActivationPolicyAdmissionTests: XCTestCase {
    @MainActor private final class Transition {
        var introduced = false
        var restored = false
        var restoration: Task<Void, Never>?

        func introduce() {
            let accepted = NSApp.setActivationPolicy(.accessory)
            let observed = NSApp.activationPolicy()
            print("Native policy control fault: requested=1 accepted=\(accepted) observed=\(observed.rawValue)")
            // AppKit can return false for a no-op request. The controlled
            // wrong state is established by the actual policy observation.
            introduced = observed == .accessory
            restoration = Task { @MainActor in
                // Deliberate transition latency. Admission must observe the
                // actual target, not infer completion from an accepted setter.
                try? await Task.sleep(for: .milliseconds(100))
                let accepted = NSApp.setActivationPolicy(.regular)
                let observed = NSApp.activationPolicy()
                print("Native policy control restoration: requested=0 accepted=\(accepted) observed=\(observed.rawValue)")
                self.restored = observed == .regular
            }
        }
    }

    private func prepareAccessory() async throws -> NSApplication.ActivationPolicy {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        var prepared = false
        defer { if !prepared { app.setActivationPolicy(previous) } }
        let accepted = app.setActivationPolicy(.accessory)
        var observed = app.activationPolicy()
        let setupDeadline = ContinuousClock.now + .seconds(5)
        var changes = [observed.rawValue]
        while observed != .accessory && ContinuousClock.now < setupDeadline {
            try await Task.sleep(for: .milliseconds(10))
            observed = app.activationPolicy()
            if changes.last != observed.rawValue { changes.append(observed.rawValue) }
        }
        print("Native policy control preparation: requested=1 accepted=\(accepted) observations=\(changes)")
        guard observed == .accessory, ContinuousClock.now < setupDeadline else {
            XCTFail("The real SDK must establish accessory before the controlled request; accepted=\(accepted), observed=\(observed.rawValue)")
            throw NSError(domain: "NativePolicyControlPreparation", code: 1)
        }
        prepared = true
        return previous
    }

    func testRequestedPolicyIsObservedBeforeFixtureBodyIsAdmitted() async throws {
        let previous = try await prepareAccessory()
        let app = NSApplication.shared
        defer { app.setActivationPolicy(previous) }
        let transition = Transition()
        var acquired: NativeFixtureApplicationLoop?
        var failure: (any Error)?
        do {
            acquired = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular,
                beforeHeartbeat: { transition.introduce() }, launchReadiness: { transition.restored })
        } catch { failure = error }
        let restoredAtAdmission = transition.restored
        if let acquired {
            do { try acquired.verifyRunning(); try await acquired.close() }
            catch { failure = error; try? await acquired.close() }
        }
        await transition.restoration?.value
        transition.restoration = nil
        XCTAssertTrue(transition.introduced && transition.restored)
        XCTAssertTrue(restoredAtAdmission)
        XCTAssertNil(failure, "A requested, actually observed target must authorize acquisition: \(String(describing: failure))")
        XCTAssertEqual(app.activationPolicy(), .regular)
        XCTAssertFalse(app.isRunning)
    }

    func testPermanentPolicyMismatchCannotAdmitFixtureBody() async throws {
        let previous = try await prepareAccessory()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let start = ContinuousClock.now
        var failure: (any Error)?
        var bodyAdmitted = false
        do {
            let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular,
                beforeHeartbeat: {
                    _ = NSApp.setActivationPolicy(.accessory)
                    transition.introduced = NSApp.activationPolicy() == .accessory
                })
            bodyAdmitted = true
            try await loop.close()
        } catch { failure = error }
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(transition.introduced, "The real wrong policy must be established")
        XCTAssertFalse(bodyAdmitted)
        XCTAssertEqual(failure.map { String(describing: $0) }, "launchTimedOut")
        XCTAssertGreaterThanOrEqual(elapsed, .seconds(5))
        XCTAssertLessThan(elapsed, .seconds(8))
        XCTAssertFalse(NSApp.isRunning)
    }

    func testPolicyRequestPendingBeforeEntryCannotReceiveANewFiveSecondBudget() async throws {
        let previous = try await prepareAccessory()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        var failure: (any Error)?
        do {
            let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular,
                beforeHeartbeat: { transition.introduced = true },
                afterPolicyRequest: {
                    transition.restored = NSApp.activationPolicy() == .regular
                    // Deliberate fault: delay entry beyond the original 5s.
                    // A fresh entry budget or warm-launch shortcut must fail.
                    Thread.sleep(forTimeInterval: 6)
                })
            try await loop.close()
        } catch { failure = error }
        XCTAssertTrue(transition.restored, "The real requested policy must be present before the delay")
        XCTAssertFalse(transition.introduced, "Expired policy admission must not enter run()")
        XCTAssertEqual(failure.map { String(describing: $0) }, "launchTimedOut")
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        XCTAssertFalse(NSApp.isRunning)
    }

    func testPolicyDriftAfterAdmissionStillFailsImmediately() async throws {
        let previous = try await prepareAccessory()
        defer { NSApp.setActivationPolicy(previous) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        _ = NSApp.setActivationPolicy(.accessory)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory, "The real drift must be present")
        XCTAssertThrowsError(try loop.verifyRunning()) { error in
            XCTAssertEqual(String(describing: error), "policyChanged")
        }
        do {
            try await loop.close()
            XCTFail("Closing retains the original invariant failure")
        } catch { XCTAssertEqual(String(describing: error), "policyChanged") }
        XCTAssertFalse(NSApp.isRunning)
    }

    func testDefaultPolicyDriftDuringStartupStillFailsImmediately() async throws {
        let previous = try await prepareAccessory()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let start = ContinuousClock.now
        var failure: (any Error)?
        do {
            let loop = try await NativeFixtureApplicationLoop.acquire(beforeHeartbeat: {
                _ = NSApp.setActivationPolicy(.regular)
                transition.introduced = NSApp.activationPolicy() == .regular
            })
            try await loop.close()
        } catch { failure = error }
        XCTAssertTrue(transition.introduced)
        XCTAssertEqual(failure.map { String(describing: $0) }, "policyChanged")
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        XCTAssertFalse(NSApp.isRunning)
    }

    func testForeignOwnerIsRejectedBeforeAnyPolicyRequest() async throws {
        let previous = try await prepareAccessory()
        defer { NSApp.setActivationPolicy(previous) }
        // This may be a false-returning SDK no-op; actual target state governs.
        let owner = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let other = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
            try await other.close()
        } catch { failure = error }
        XCTAssertEqual(failure.map { String(describing: $0) }, "existingOwner")
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        var ownerFailure: (any Error)?
        do { try owner.verifyRunning() } catch { ownerFailure = error }
        // Preserve verification failure, but always join the owner even when
        // the nested-acquisition bug under test has changed its policy.
        do { try await owner.close() } catch { if ownerFailure == nil { ownerFailure = error } }
        XCTAssertNil(ownerFailure)
        XCTAssertFalse(NSApp.isRunning)
    }

}
