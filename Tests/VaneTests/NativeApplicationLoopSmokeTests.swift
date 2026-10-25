import AppKit
import CoreFoundation
import XCTest

@MainActor final class NativeApplicationLoopSmokeTests: XCTestCase {
    func testOwnedLoopAdmitsAsyncWorkAndStops() async throws {
        TestEnvironment.prepare()
        guard ProcessInfo.processInfo.environment["VANE_APPKIT_LOOP_SMOKE"] == "1" else {
            throw XCTSkip("Requires a fresh selected process and the owned 20-second driver bound")
        }
        for cycle in 1...2 {
            try await OwnedApplicationLoopSmoke().run()
            print("AppKit loop smoke: cycle=\(cycle), completed=true")
        }
    }
}

private enum ApplicationLoopSmokeFailure: String, Error {
    case existingOwner, existingLoop, delegatePresent, modalPresent, launchOpenRequest
    case policyChanged, cancelled, watchdogExpired, timerUnavailable, wakeEventUnavailable
    case loopNotRunning, launchTimedOut, unexpectedLoopReturn, incompleteHeartbeat
}

// Cancellation can arrive before the queued main-run-loop entry executes.
private final class ApplicationLoopEntryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let generation: UUID
    private var cancelled = false
    private var claimed = false

    init(generation: UUID) { self.generation = generation }

    func cancel(_ generation: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if self.generation == generation { cancelled = true }
    }

    func claim(_ generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation, !cancelled, !claimed else { return false }
        claimed = true
        return true
    }
}

@MainActor private final class OwnedApplicationLoopSmoke {
    private static var ownerGeneration: UUID?
    private let generation = UUID()
    private let originalPolicy = NSApplication.shared.activationPolicy()
    private let eventTag = Int.random(in: 1...Int.max)
    private lazy var entryGate = ApplicationLoopEntryGate(generation: generation)
    private var continuation: CheckedContinuation<Void, any Error>?
    private var heartbeat: Task<Void, Never>?
    private var watchdog: CFRunLoopTimer?
    private var firstFailure: ApplicationLoopSmokeFailure?
    private var enteredRun = false
    private var runReturned = false
    private var heartbeatFinished = false
    private var heartbeatSucceeded = false
    private var startAborted = false
    private var stopRequested = false
    private var completed = false

    private var isCurrent: Bool { Self.ownerGeneration == generation && !completed }

    // CF schedules this callback on the main run loop, rather than wrapping
    // NSApplication.run in an outstanding main-dispatch/MainActor job.
    nonisolated private static func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func preflightFailure() -> ApplicationLoopSmokeFailure? {
        let app = NSApplication.shared
        if app.isRunning { return .existingLoop }
        if app.delegate != nil { return .delegatePresent }
        if app.modalWindow != nil { return .modalPresent }
        let open = UserDefaults.standard.object(forKey: "NSOpen")
        if !(open == nil || (open as? String)?.isEmpty == true || (open as? [Any])?.isEmpty == true) {
            return .launchOpenRequest
        }
        if app.activationPolicy() != originalPolicy { return .policyChanged }
        return nil
    }

    func run() async throws {
        guard Self.ownerGeneration == nil else { throw ApplicationLoopSmokeFailure.existingOwner }
        if let failure = preflightFailure() { throw failure }
        Self.ownerGeneration = generation
        let gate = entryGate
        let token = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                guard let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 12, 0, 0, 0, { _ in
                    MainActor.assumeIsolated { self.cancelOrExpire(.watchdogExpired) }
                }) else {
                    abortStart(.timerUnavailable)
                    return
                }
                watchdog = timer
                CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.commonModes)
                Self.enqueue { self.enter() }
                // Return immediately so XCTest's MainActor job can suspend.
            }
        } onCancel: {
            gate.cancel(token)
            Self.enqueue { self.cancelOrExpire(.cancelled) }
        }
    }

    private func enter() {
        guard isCurrent else { return }
        guard entryGate.claim(generation) else { abortStart(.cancelled); return }
        if let failure = preflightFailure() { abortStart(failure); return }
        let deadline = ContinuousClock.now + .seconds(5)
        heartbeat = Task { @MainActor in await self.checkHeartbeat(until: deadline) }
        enteredRun = true
        NSApplication.shared.run()
        runReturned = true
        if !stopRequested { record(.unexpectedLoopReturn) }
        if NSApplication.shared.activationPolicy() != originalPolicy { record(.policyChanged) }
        heartbeat?.cancel()
        completeIfJoined()
    }

    private func checkHeartbeat(until deadline: ContinuousClock.Instant) async {
        defer {
            heartbeatFinished = true
            requestStop()
            completeIfJoined()
        }
        let app = NSApplication.shared
        guard app.isRunning else { record(.loopNotRunning); return }
        do {
            while !NSRunningApplication.current.isFinishedLaunching {
                guard app.isRunning else { record(.loopNotRunning); return }
                guard ContinuousClock.now < deadline else { record(.launchTimedOut); return }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard ContinuousClock.now < deadline else { record(.launchTimedOut); return }
            try await Task.sleep(for: .milliseconds(50))
            guard app.isRunning else { record(.loopNotRunning); return }
            guard NSRunningApplication.current.isFinishedLaunching else { record(.incompleteHeartbeat); return }
            guard app.activationPolicy() == originalPolicy else { record(.policyChanged); return }
            heartbeatSucceeded = true
        } catch {
            record(.cancelled)
        }
    }

    private func record(_ failure: ApplicationLoopSmokeFailure) {
        if firstFailure == nil { firstFailure = failure }
    }

    private func abortStart(_ failure: ApplicationLoopSmokeFailure) {
        guard isCurrent else { return }
        record(failure)
        entryGate.cancel(generation)
        startAborted = true
        completeIfJoined()
    }

    private func cancelOrExpire(_ failure: ApplicationLoopSmokeFailure) {
        guard isCurrent else { return }
        record(failure)
        entryGate.cancel(generation)
        if !enteredRun { abortStart(failure); return }
        heartbeat?.cancel()
        requestStop()
    }

    private func requestStop() {
        guard isCurrent, enteredRun, !runReturned, !stopRequested else { return }
        let app = NSApplication.shared
        guard app.isRunning else { record(.loopNotRunning); return }
        // stop() would target a modal loop instead of our run() lease.
        guard app.modalWindow == nil else { record(.modalPresent); return }
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: 0, data1: eventTag, data2: 0) else {
            record(.wakeEventUnavailable)
            return
        }
        stopRequested = true
        app.stop(nil)
        // AppKit checks stop after dispatching an actual event, not just a timer
        // or CF callback. This tagged wake event contains no user input.
        app.postEvent(event, atStart: false)
    }

    private func completeIfJoined() {
        guard isCurrent, startAborted || (runReturned && heartbeatFinished) else { return }
        if !startAborted && !heartbeatSucceeded { record(.incompleteHeartbeat) }
        if NSApplication.shared.activationPolicy() != originalPolicy { record(.policyChanged) }
        completed = true
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        watchdog = nil
        heartbeat = nil
        let completion = continuation
        continuation = nil
        Self.ownerGeneration = nil
        if let firstFailure { completion?.resume(throwing: firstFailure) }
        else {
            print("AppKit loop smoke: heartbeatFinished=true, runReturned=true, policyUnchanged=true")
            completion?.resume()
        }
    }
}
