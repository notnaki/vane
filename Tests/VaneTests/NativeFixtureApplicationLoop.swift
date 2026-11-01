import AppKit
import CoreFoundation

private enum NativeApplicationLoopFailure: String, Error {
    case existingOwner, existingLoop, delegatePresent, modalPresent, launchOpenRequest
    case policyChanged, cancelled, startupWatchdogExpired, shutdownWatchdogExpired
    case timerUnavailable, wakeEventUnavailable, loopNotRunning, loopStillRunning
    case launchTimedOut, unexpectedLoopReturn, incompleteHeartbeat
}

struct NativeFixtureLaunchAdmission {
    enum Observation: Equatable { case waiting, ready, timedOut, watchdogExpired }
    let finishedAtEntry: Bool
    let deadline: ContinuousClock.Instant
    let watchdogDeadline: ContinuousClock.Instant
    private(set) var observedUnfinished = false

    mutating func observe(finished: Bool, at now: ContinuousClock.Instant) -> Observation {
        if !finished { observedUnfinished = true }
        // A delayed timer callback must never admit work past the watchdog.
        if now >= watchdogDeadline { return .watchdogExpired }
        // An executor-delayed heartbeat cannot time out an application launch
        // that was already complete before run(). The independent 12s startup
        // watchdog still bounds the entire admission, including scheduling.
        if finishedAtEntry && !observedUnfinished && finished { return .ready }
        if now >= deadline { return .timedOut }
        return finished ? .ready : .waiting
    }
}

private final class NativeApplicationLoopEntryGate: @unchecked Sendable {
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

/// Owns only a test-created AppKit loop. Its caller owns the test body and must
/// close after fixture cleanup; an independent process watchdog remains required.
@MainActor final class NativeFixtureApplicationLoop {
    private static var ownerGeneration: UUID?
    private let generation = UUID()
    private let requestedPolicy: NSApplication.ActivationPolicy?
    private let requiredPolicy: NSApplication.ActivationPolicy
    private let afterPolicyRequest: (@MainActor @Sendable () -> Void)?
    private let eventTag = Int.random(in: 1...Int.max)
    private let beforeHeartbeat: @MainActor @Sendable () async -> Void
    private let launchReadiness: @MainActor @Sendable () -> Bool
    private let afterRunReturn: (@MainActor @Sendable () -> Void)?
    private let policyPollScheduled: (@MainActor @Sendable () -> Void)?
    private var policyPollTimer: CFRunLoopTimer?
    var policyPollPendingForTesting: Bool { policyPollTimer != nil }
    private lazy var entryGate = NativeApplicationLoopEntryGate(generation: generation)
    private var admission: CheckedContinuation<Void, any Error>?
    private var pendingLaunchAdmission: NativeFixtureLaunchAdmission?
    private var joinWaiters: [CheckedContinuation<Void, any Error>] = []
    private var heartbeat: Task<Void, Never>?
    private var watchdog: CFRunLoopTimer?
    private var watchdogDeadline: ContinuousClock.Instant?
    private var firstFailure: NativeApplicationLoopFailure?
    private var enteredRun = false
    private var runReturned = false
    private var heartbeatFinished = false
    private var admissionSucceeded = false
    private var startAborted = false
    private var stopRequested = false
    private var closing = false
    private var closed = false

    private init(activationPolicy: NSApplication.ActivationPolicy?,
                 afterPolicyRequest: (@MainActor @Sendable () -> Void)?,
                 beforeHeartbeat: @escaping @MainActor @Sendable () async -> Void,
                 launchReadiness: @escaping @MainActor @Sendable () -> Bool,
                 afterRunReturn: (@MainActor @Sendable () -> Void)?,
                 policyPollScheduled: (@MainActor @Sendable () -> Void)?) {
        requestedPolicy = activationPolicy
        requiredPolicy = activationPolicy ?? NSApplication.shared.activationPolicy()
        self.afterPolicyRequest = afterPolicyRequest
        self.beforeHeartbeat = beforeHeartbeat
        self.launchReadiness = launchReadiness
        self.afterRunReturn = afterRunReturn
        self.policyPollScheduled = policyPollScheduled
    }
    private var isCurrent: Bool { Self.ownerGeneration == generation && !closed }

    nonisolated private static func enqueue(_ action: @escaping @MainActor @Sendable () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private func preflightFailure(allowPendingPolicy: Bool = false) -> NativeApplicationLoopFailure? {
        let app = NSApplication.shared
        if app.isRunning { return .existingLoop }
        if app.delegate != nil { return .delegatePresent }
        if app.modalWindow != nil { return .modalPresent }
        let open = UserDefaults.standard.object(forKey: "NSOpen")
        if !(open == nil || (open as? String)?.isEmpty == true || (open as? [Any])?.isEmpty == true) {
            return .launchOpenRequest
        }
        if !allowPendingPolicy, app.activationPolicy() != requiredPolicy { return .policyChanged }
        return nil
    }

    static func acquire(activationPolicy: NSApplication.ActivationPolicy? = nil,
                        beforeHeartbeat: @escaping @MainActor @Sendable () async -> Void = {},
                        launchReadiness: @escaping @MainActor @Sendable () -> Bool = { true },
                        afterPolicyRequest: (@MainActor @Sendable () -> Void)? = nil,
                        afterRunReturn: (@MainActor @Sendable () -> Void)? = nil,
                        policyPollScheduled: (@MainActor @Sendable () -> Void)? = nil) async throws -> NativeFixtureApplicationLoop {
        let lease = NativeFixtureApplicationLoop(activationPolicy: activationPolicy, afterPolicyRequest: afterPolicyRequest,
            beforeHeartbeat: beforeHeartbeat, launchReadiness: launchReadiness,
            afterRunReturn: afterRunReturn, policyPollScheduled: policyPollScheduled)
        try await lease.start()
        if Task.isCancelled { lease.record(.cancelled) }
        do {
            try await withTaskCancellationHandler {
                try await lease.adoptAdmission()
            } onCancel: {
                Self.enqueue { lease.cancelOrExpire(.cancelled) }
            }
        } catch {
            // A cancelled or lost admission cannot throw while leaving its loop
            // behind. close retains the first lifecycle failure and joins first.
            try await lease.close()
            throw error
        }
        print("Native fixture AppKit loop: acquired=true")
        return lease
    }

    private func start() async throws {
        guard Self.ownerGeneration == nil else { throw NativeApplicationLoopFailure.existingOwner }
        if let failure = preflightFailure(allowPendingPolicy: requestedPolicy != nil) { throw failure }
        Self.ownerGeneration = generation
        let gate = entryGate
        let token = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                admission = continuation
                guard armWatchdog(.startupWatchdogExpired) else { abortStart(.timerUnavailable); return }
                guard !Task.isCancelled else { abortStart(.cancelled); return }
                if let failure = requestPolicyForAdmission() { abortStart(failure); return }
                Self.enqueue { self.enter() }
                // Suspend the caller without synchronously pumping its run loop.
            }
        } onCancel: {
            gate.cancel(token)
            Self.enqueue { self.cancelOrExpire(.cancelled) }
        }
    }

    /// Policy setters can report false while the target is already present.
    /// Only actual compound readiness authorizes admission; the SDK Boolean is
    /// metadata. A request is never repeated to manufacture a passing state.
    private func requestPolicyForAdmission() -> NativeApplicationLoopFailure? {
        guard let requestedPolicy else { return nil }
        guard let watchdogDeadline else { return .timerUnavailable }
        let start = ContinuousClock.now
        let before = NSApplication.shared.activationPolicy()
        let finishedBefore = before == requestedPolicy
            && NSRunningApplication.current.isFinishedLaunching && launchReadiness()
        var state = NativeFixtureLaunchAdmission(finishedAtEntry: finishedBefore,
            deadline: start + .seconds(5), watchdogDeadline: watchdogDeadline)
        // Pending policy before the request belongs to this same history, even
        // if AppKit is warm/finished by the time enter() eventually executes.
        _ = observeAdmission(&state, finished: finishedBefore)
        if let firstFailure { return firstFailure }
        let accepted = NSApplication.shared.setActivationPolicy(requestedPolicy)
        let after = NSApplication.shared.activationPolicy()
        let finishedAfter = after == requestedPolicy
            && NSRunningApplication.current.isFinishedLaunching && launchReadiness()
        _ = observeAdmission(&state, finished: finishedAfter)
        pendingLaunchAdmission = state
        print("Native fixture AppKit policy request: requested=\(requestedPolicy.rawValue) accepted=\(accepted) before=\(before.rawValue) after=\(after.rawValue)")
        if let firstFailure { return firstFailure }
        // A synchronous fault seam cannot restart either existing deadline.
        afterPolicyRequest?()
        return nil
    }

    private func launchReadyForAdmission() -> Bool {
        NSRunningApplication.current.isFinishedLaunching && launchReadiness()
            && (requestedPolicy == nil || NSApplication.shared.activationPolicy() == requiredPolicy)
    }

    private func enter() {
        guard isCurrent else { return }
        guard entryGate.claim(generation) else { abortStart(.cancelled); return }
        if let failure = preflightFailure(allowPendingPolicy: requestedPolicy != nil) { abortStart(failure); return }
        guard let watchdogDeadline else { abortStart(.timerUnavailable); return }
        guard ContinuousClock.now < watchdogDeadline else { abortStart(.startupWatchdogExpired); return }
        var state: NativeFixtureLaunchAdmission
        if let pendingLaunchAdmission {
            state = pendingLaunchAdmission
        } else {
            let entryDeadline = ContinuousClock.now + .seconds(5)
            let finishedAtEntry = NSRunningApplication.current.isFinishedLaunching
            state = NativeFixtureLaunchAdmission(finishedAtEntry: finishedAtEntry,
                deadline: entryDeadline, watchdogDeadline: watchdogDeadline)
        }
        if requestedPolicy != nil {
            _ = observeAdmission(&state, finished: launchReadyForAdmission())
            if let firstFailure { abortStart(firstFailure); return }
        }
        print("Native fixture AppKit admission: finishedAtEntry=\(state.finishedAtEntry)")
        let initialAdmission = state
        heartbeat = Task { @MainActor in
            await self.beforeHeartbeat()
            await self.checkHeartbeat(admission: initialAdmission)
        }
        enteredRun = true
        NSApplication.shared.run()
        afterRunReturn?()
        runReturned = true
        if !stopRequested { record(.unexpectedLoopReturn) }
        heartbeat?.cancel()
        completeIfJoined()
    }

    private func checkHeartbeat(admission initialAdmission: NativeFixtureLaunchAdmission) async {
        var admission = initialAdmission
        defer {
            pendingLaunchAdmission = admission
            finishHeartbeat(deadline: initialAdmission.watchdogDeadline)
        }
        let app = NSApplication.shared
        guard app.isRunning else { record(.loopNotRunning); return }
        var readyOnPreviousTurn = false
        do {
            while true {
                try Task.checkCancellation()
                guard app.isRunning else { record(.loopNotRunning); return }
                let finished = launchReadyForAdmission()
                switch admission.observe(finished: finished, at: .now) {
                case .ready:
                    if readyOnPreviousTurn {
                        if let failure = runningFailure() {
                            if failure == .incompleteHeartbeat {
                                guard observeAdmission(&admission, finished: false) == .waiting else { return }
                                readyOnPreviousTurn = false
                                try await Task.sleep(for: .milliseconds(20))
                                continue
                            }
                            record(failure)
                            return
                        }
                        // The final native getters may consume the remaining
                        // budget even when they return a positive result.
                        _ = observeAdmission(&admission, finished: true)
                        return
                    }
                    // Confirm readiness after yielding the executor. A prior
                    // ready sample cannot authorize a later unfinished launch.
                    readyOnPreviousTurn = true
                    await Task.yield()
                    continue
                case .timedOut:
                    print("Native fixture AppKit admission timed out: finishedAtEntry=\(admission.finishedAtEntry), finishedNow=\(finished), observedUnfinished=\(admission.observedUnfinished)")
                    record(.launchTimedOut)
                    return
                case .watchdogExpired:
                    record(.startupWatchdogExpired)
                    return
                case .waiting:
                    if readyOnPreviousTurn {
                        print("Native fixture AppKit admission: readiness withdrew before final verification")
                    }
                    readyOnPreviousTurn = false
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
            }
        } catch {
            if firstFailure == nil { record(.cancelled) }
        }
    }

    private func finishHeartbeat(deadline: ContinuousClock.Instant) {
        heartbeatFinished = true
        heartbeat = nil
        if firstFailure == nil, !closing, ContinuousClock.now >= deadline { record(.startupWatchdogExpired) }
        if firstFailure == nil && !closing {
            // Heartbeat readiness is provisional. Keep its original watchdog
            // and admission history until the caller accepts the final sample.
            let completion = admission
            admission = nil
            completion?.resume()
        } else {
            closing = true
            requestStop()
            completeIfJoined()
        }
    }

    private func runningFailure() -> NativeApplicationLoopFailure? {
        if let firstFailure { return firstFailure }
        guard isCurrent, enteredRun, !runReturned, NSApplication.shared.isRunning else { return .loopNotRunning }
        guard NSRunningApplication.current.isFinishedLaunching && launchReadiness() else { return .incompleteHeartbeat }
        guard NSApplication.shared.activationPolicy() == requiredPolicy else {
            return requestedPolicy != nil && !admissionSucceeded ? .incompleteHeartbeat : .policyChanged
        }
        return nil
    }

    func verifyRunning() throws {
        if let failure = runningFailure() {
            record(failure)
            throw firstFailure!
        }
    }

    /// Poll only inside a bounded pre-action prerequisite. A launch/owner
    /// readiness withdrawal is pending; cancellation and lifecycle loss are fatal.
    func isReadyForInteraction() throws -> Bool {
        if Task.isCancelled { record(.cancelled) }
        if let firstFailure { throw firstFailure }
        guard admissionSucceeded, isCurrent, enteredRun, !runReturned, NSApplication.shared.isRunning else {
            record(.loopNotRunning)
            throw firstFailure!
        }
        guard NSApplication.shared.activationPolicy() == requiredPolicy else {
            record(.policyChanged)
            throw firstFailure!
        }
        return NSRunningApplication.current.isFinishedLaunching && launchReadiness()
    }

    private func observeAdmission(_ admission: inout NativeFixtureLaunchAdmission,
                                  finished: Bool) -> NativeFixtureLaunchAdmission.Observation {
        let observation = admission.observe(finished: finished, at: .now)
        switch observation {
        case .timedOut: record(.launchTimedOut)
        case .watchdogExpired: record(.startupWatchdogExpired)
        case .ready, .waiting: break
        }
        return observation
    }

    private func adoptAdmission() async throws {
        guard var state = pendingLaunchAdmission else {
            record(.incompleteHeartbeat)
            throw firstFailure!
        }
        var readyOnPreviousTurn = true
        while true {
            try Task.checkCancellation()
            let failure = runningFailure()
            try Task.checkCancellation()
            if let failure, failure != .incompleteHeartbeat {
                record(failure)
                throw firstFailure!
            }
            switch observeAdmission(&state, finished: failure == nil) {
            case .timedOut, .watchdogExpired:
                throw firstFailure!
            case .waiting:
                readyOnPreviousTurn = false
                try await Task.sleep(for: .milliseconds(20))
            case .ready:
                if !readyOnPreviousTurn {
                    readyOnPreviousTurn = true
                    await Task.yield()
                    continue
                }
                if let firstFailure { throw firstFailure }
                guard isCurrent, !runReturned else {
                    record(.loopNotRunning)
                    throw firstFailure!
                }
                // No readiness getter or suspension follows the accepted sample.
                admissionSucceeded = true
                pendingLaunchAdmission = nil
                invalidateWatchdog()
                return
            }
        }
    }

    func close() async throws {
        if closed {
            if let firstFailure { throw firstFailure }
            return
        }
        if Task.isCancelled { record(.cancelled) }
        let gate = entryGate
        let token = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                joinWaiters.append(continuation)
                let wasClosing = closing
                closing = true
                if !wasClosing && !runReturned && !startAborted && !armWatchdog(.shutdownWatchdogExpired) {
                    record(.timerUnavailable)
                }
                requestStop()
                completeIfJoined()
            }
        } onCancel: {
            gate.cancel(token)
            Self.enqueue { self.cancelOrExpire(.cancelled) }
        }
    }

    private func record(_ failure: NativeApplicationLoopFailure) {
        if firstFailure == nil {
            firstFailure = failure
            print("Native fixture AppKit loop: failure=\(failure.rawValue)")
        }
    }

    private func armWatchdog(_ failure: NativeApplicationLoopFailure) -> Bool {
        invalidateWatchdog()
        let deadline = ContinuousClock.now + .seconds(12)
        guard let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 12, 0, 0, 0, { _ in
            MainActor.assumeIsolated { self.cancelOrExpire(failure) }
        }) else { return false }
        watchdog = timer
        watchdogDeadline = deadline
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.commonModes)
        return true
    }

    private func invalidateWatchdog() {
        if let watchdog { CFRunLoopTimerInvalidate(watchdog) }
        watchdog = nil
        watchdogDeadline = nil
    }

    private func abortStart(_ failure: NativeApplicationLoopFailure) {
        guard isCurrent else { return }
        record(failure)
        entryGate.cancel(generation)
        startAborted = true
        closing = true
        completeIfJoined()
    }

    private func cancelOrExpire(_ failure: NativeApplicationLoopFailure) {
        guard isCurrent else { return }
        record(failure)
        entryGate.cancel(generation)
        if !enteredRun { abortStart(failure); return }
        closing = true
        heartbeat?.cancel()
        requestStop()
        completeIfJoined()
    }

    private func requestStop() {
        guard isCurrent, enteredRun, !runReturned, !stopRequested else { return }
        let app = NSApplication.shared
        guard app.isRunning else { record(.loopNotRunning); return }
        guard app.modalWindow == nil else { record(.modalPresent); return }
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: 0, data1: eventTag, data2: 0) else {
            record(.wakeEventUnavailable)
            return
        }
        stopRequested = true
        app.stop(nil)
        app.postEvent(event, atStart: false)
    }

    private func armPolicyPoll() -> Bool {
        if policyPollTimer != nil { return true }
        guard let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, { _ in
            MainActor.assumeIsolated {
                guard self.isCurrent else { return }
                self.completeIfJoined()
            }
        }) else { return false }
        policyPollTimer = timer
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, CFRunLoopMode.commonModes)
        print("Native fixture AppKit loop: waitingForOriginalPolicy=true")
        policyPollScheduled?()
        return true
    }

    private func invalidatePolicyPoll() {
        if let policyPollTimer { CFRunLoopTimerInvalidate(policyPollTimer) }
        policyPollTimer = nil
    }

    private func completeIfJoined() {
        guard isCurrent, closing || !admissionSucceeded,
              startAborted || (runReturned && heartbeatFinished) else { return }
        if NSApplication.shared.isRunning { record(.loopStillRunning) }
        let policy = NSApplication.shared.activationPolicy()
        // AppKit can transiently report another policy while run() unwinds.
        // Keep the exact required-policy invariant at the completed join, using
        // only the already-armed shutdown budget. Check time after the getter:
        // a queued watchdog cannot authorize equality observed too late.
        if firstFailure == nil, !startAborted, let deadline = watchdogDeadline {
            if ContinuousClock.now >= deadline {
                record(.shutdownWatchdogExpired)
            } else if policy != requiredPolicy {
                if armPolicyPoll() { return }
                record(.timerUnavailable)
            }
        }
        if policy != requiredPolicy { record(.policyChanged) }
        closed = true
        pendingLaunchAdmission = nil
        invalidatePolicyPoll()
        invalidateWatchdog()
        heartbeat = nil
        let startup = admission
        admission = nil
        let waiters = joinWaiters
        joinWaiters.removeAll()
        Self.ownerGeneration = nil
        if enteredRun && runReturned && heartbeatFinished {
            print("Native fixture AppKit loop: joined=true")
        }
        if let firstFailure {
            startup?.resume(throwing: firstFailure)
            for waiter in waiters { waiter.resume(throwing: firstFailure) }
        } else {
            startup?.resume()
            for waiter in waiters { waiter.resume() }
        }
    }
}
