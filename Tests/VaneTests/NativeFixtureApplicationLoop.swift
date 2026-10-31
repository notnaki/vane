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
    private let originalPolicy = NSApplication.shared.activationPolicy()
    private let eventTag = Int.random(in: 1...Int.max)
    private let beforeHeartbeat: @MainActor @Sendable () async -> Void
    private let launchReadiness: @MainActor @Sendable () -> Bool
    private let afterRunReturn: (@MainActor @Sendable () -> Void)?
    private let policyPollScheduled: (@MainActor @Sendable () -> Void)?
    private var policyPollTimer: CFRunLoopTimer?
    var policyPollPendingForTesting: Bool { policyPollTimer != nil }
    private lazy var entryGate = NativeApplicationLoopEntryGate(generation: generation)
    private var admission: CheckedContinuation<Void, any Error>?
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

    private init(beforeHeartbeat: @escaping @MainActor @Sendable () async -> Void,
                 launchReadiness: @escaping @MainActor @Sendable () -> Bool,
                 afterRunReturn: (@MainActor @Sendable () -> Void)?,
                 policyPollScheduled: (@MainActor @Sendable () -> Void)?) {
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

    private func preflightFailure() -> NativeApplicationLoopFailure? {
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

    static func acquire(beforeHeartbeat: @escaping @MainActor @Sendable () async -> Void = {},
                        launchReadiness: @escaping @MainActor @Sendable () -> Bool = { true },
                        afterRunReturn: (@MainActor @Sendable () -> Void)? = nil,
                        policyPollScheduled: (@MainActor @Sendable () -> Void)? = nil) async throws -> NativeFixtureApplicationLoop {
        let lease = NativeFixtureApplicationLoop(beforeHeartbeat: beforeHeartbeat, launchReadiness: launchReadiness,
            afterRunReturn: afterRunReturn, policyPollScheduled: policyPollScheduled)
        try await lease.start()
        if Task.isCancelled { lease.record(.cancelled) }
        do { try lease.verifyRunning() }
        catch {
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
        if let failure = preflightFailure() { throw failure }
        Self.ownerGeneration = generation
        let gate = entryGate
        let token = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                admission = continuation
                guard armWatchdog(.startupWatchdogExpired) else { abortStart(.timerUnavailable); return }
                Self.enqueue { self.enter() }
                // Suspend the caller without synchronously pumping its run loop.
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
        guard let watchdogDeadline else { abortStart(.timerUnavailable); return }
        guard ContinuousClock.now < watchdogDeadline else { abortStart(.startupWatchdogExpired); return }
        let deadline = ContinuousClock.now + .seconds(5)
        let finishedAtEntry = NSRunningApplication.current.isFinishedLaunching
        print("Native fixture AppKit admission: finishedAtEntry=\(finishedAtEntry)")
        heartbeat = Task { @MainActor in
            await self.beforeHeartbeat()
            await self.checkHeartbeat(admission: NativeFixtureLaunchAdmission(finishedAtEntry: finishedAtEntry,
                deadline: deadline, watchdogDeadline: watchdogDeadline))
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
        defer { finishHeartbeat(deadline: initialAdmission.watchdogDeadline) }
        let app = NSApplication.shared
        guard app.isRunning else { record(.loopNotRunning); return }
        var admission = initialAdmission
        var readyOnPreviousTurn = false
        do {
            while true {
                try Task.checkCancellation()
                guard app.isRunning else { record(.loopNotRunning); return }
                let finished = NSRunningApplication.current.isFinishedLaunching && launchReadiness()
                switch admission.observe(finished: finished, at: .now) {
                case .ready:
                    if readyOnPreviousTurn {
                        try verifyRunning()
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
            invalidateWatchdog()
            admissionSucceeded = true
            let completion = admission
            admission = nil
            completion?.resume()
        } else {
            closing = true
            requestStop()
            completeIfJoined()
        }
    }

    func verifyRunning() throws {
        if let firstFailure { throw firstFailure }
        guard isCurrent, enteredRun, !runReturned, NSApplication.shared.isRunning else {
            record(.loopNotRunning)
            throw firstFailure!
        }
        guard NSRunningApplication.current.isFinishedLaunching && launchReadiness() else {
            record(.incompleteHeartbeat)
            throw firstFailure!
        }
        guard NSApplication.shared.activationPolicy() == originalPolicy else {
            record(.policyChanged)
            throw firstFailure!
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
        // Keep the exact original-policy invariant at the completed join, using
        // only the already-armed shutdown budget. Check time after the getter:
        // a queued watchdog cannot authorize equality observed too late.
        if firstFailure == nil, !startAborted, let deadline = watchdogDeadline {
            if ContinuousClock.now >= deadline {
                record(.shutdownWatchdogExpired)
            } else if policy != originalPolicy {
                if armPolicyPoll() { return }
                record(.timerUnavailable)
            }
        }
        if policy != originalPolicy { record(.policyChanged) }
        closed = true
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
