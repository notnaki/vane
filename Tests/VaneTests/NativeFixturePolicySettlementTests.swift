import AppKit
import XCTest

@MainActor final class NativeFixturePolicySettlementTests: XCTestCase {
    @MainActor private final class Transition {
        var introduced = false
        var restored = false
        var restoration: Task<Void, Never>?
        var loop: NativeFixtureApplicationLoop?
        var closing: Task<Void, any Error>?
        var pollObserved = false

        func introduce(restore: Bool) {
            introduced = NSApp.setActivationPolicy(.prohibited) && NSApp.activationPolicy() == .prohibited
            print("Native policy control: actualMismatch=\(introduced)")
            if restore {
                restoration = Task { @MainActor in
                    // Deliberate transition latency after the genuine mismatch;
                    // the loop must observe recovery rather than guess a delay.
                    try? await Task.sleep(for: .milliseconds(100))
                    self.restored = NSApp.setActivationPolicy(.accessory) && NSApp.activationPolicy() == .accessory
                }
            }
        }
    }

    private func beginPolicy() throws -> NSApplication.ActivationPolicy {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let previous = app.activationPolicy()
        guard app.setActivationPolicy(.accessory), app.activationPolicy() == .accessory else {
            _ = app.setActivationPolicy(previous)
            throw NSError(domain: "NativePolicyControl", code: 1)
        }
        return previous
    }

    func testTransientRunReturnPolicyIsSettledBeforeSuccessfulJoin() async throws {
        let previous = try beginPolicy()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let loop: NativeFixtureApplicationLoop
        do {
            loop = try await NativeFixtureApplicationLoop.acquire(afterRunReturn: {
                transition.introduce(restore: true)
            })
        } catch {
            // The hook can also run during failed admission. Join any owned
            // setter before the baseline-policy defer, preserving that error.
            await transition.restoration?.value
            transition.restoration = nil
            throw error
        }
        var failure: Error?
        do { try await loop.close() } catch { failure = error }
        let restoredAtJoin = transition.restored
        await transition.restoration?.value
        transition.restoration = nil
        XCTAssertTrue(transition.introduced, "The actual SDK must establish the wrong policy")
        XCTAssertTrue(transition.restored, "The owned restoration must finish and be joined")
        XCTAssertNil(failure, "A recovered shutdown policy must not become a permanent fixture failure")
        XCTAssertTrue(restoredAtJoin, "Close must await actual recovery, not merely start restoration")
        XCTAssertFalse(NSApp.isRunning)
        XCTAssertFalse(loop.policyPollPendingForTesting)
    }

    func testPolicyMatchingOnlyAfterShutdownBudgetStillFails() async throws {
        let previous = try beginPolicy()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let loop = try await NativeFixtureApplicationLoop.acquire(afterRunReturn: {
            transition.introduce(restore: false)
            // Deliberately block timer delivery past the unchanged 12s budget.
            Thread.sleep(forTimeInterval: 13)
            transition.restored = NSApp.setActivationPolicy(.accessory) && NSApp.activationPolicy() == .accessory
        })
        var failure: Error?
        do { try await loop.close() } catch { failure = error }
        XCTAssertTrue(transition.introduced && transition.restored)
        XCTAssertNotNil(failure, "Late equality must not bypass the original shutdown deadline")
        XCTAssertFalse(NSApp.isRunning)
        XCTAssertFalse(loop.policyPollPendingForTesting)
    }

    func testPermanentWrongPolicyFailsAndRetiresPollTimer() async throws {
        let previous = try beginPolicy()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let loop = try await NativeFixtureApplicationLoop.acquire(afterRunReturn: {
            transition.introduce(restore: false)
        }, policyPollScheduled: {
            transition.pollObserved = transition.loop?.policyPollPendingForTesting == true
        })
        transition.loop = loop
        var failure: Error?
        do { try await loop.close() } catch { failure = error }
        transition.loop = nil
        XCTAssertTrue(transition.introduced && transition.pollObserved)
        XCTAssertEqual(failure.map { String(describing: $0) }, "shutdownWatchdogExpired")
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited, "The fixture must never set policy to manufacture success")
        XCTAssertFalse(NSApp.isRunning)
        XCTAssertFalse(loop.policyPollPendingForTesting)
    }

    func testCancellationWhilePolicyPollIsPendingRetiresTimer() async throws {
        let previous = try beginPolicy()
        defer { NSApp.setActivationPolicy(previous) }
        let transition = Transition()
        let loop = try await NativeFixtureApplicationLoop.acquire(afterRunReturn: {
            transition.introduce(restore: false)
        }, policyPollScheduled: {
            transition.pollObserved = transition.loop?.policyPollPendingForTesting == true
            transition.closing?.cancel()
        })
        transition.loop = loop
        let closing = Task { @MainActor in try await loop.close() }
        transition.closing = closing
        var failure: Error?
        do { try await closing.value } catch { failure = error }
        transition.closing = nil
        transition.loop = nil
        XCTAssertTrue(transition.introduced && transition.pollObserved)
        XCTAssertTrue(closing.isCancelled)
        XCTAssertEqual(failure.map { String(describing: $0) }, "cancelled")
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertFalse(NSApp.isRunning)
        XCTAssertFalse(loop.policyPollPendingForTesting)
    }

}
