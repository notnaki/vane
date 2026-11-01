import AppKit
import NativeTestHostBootstrap
import XCTest

private final class F17CandidateReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveries: [Int] = []
    func receive(_ sequence: Int) { lock.withLock { deliveries.append(sequence) } }
    var sequences: [Int] { lock.withLock { deliveries } }
}

/// Diagnostic controls only. The controller must select one case per fresh host.
/// A fresh host and no deliberate prewarm do not prove prior service coldness.
@MainActor final class F17SpellTraceTests: XCTestCase {
    private enum ControlFailure: Error { case wrongEnvironment, reusedHost, callbackTimedOut, captureMissing, receiverChanged }
    private let spelling = NSTextCheckingResult.CheckingType.spelling.rawValue

    private func requireControl(traceEnabled: Bool) throws {
        guard ProcessInfo.processInfo.environment["VANE_F17_SPELL_TRACE_CONTROLS_V1"] == "1" else {
            throw XCTSkip("Opt-in real-SDK spell-trace control; requires its own native host")
        }
        guard (ProcessInfo.processInfo.environment["VANE_F17_CANDIDATE_LATENCY_TRACE_V1"] == "1") == traceEnabled else {
            XCTFail("The controller must set the declared trace mode")
            throw ControlFailure.wrongEnvironment
        }
        guard !VaneF17SpellTraceReadStatus().requested else {
            XCTFail("Each diagnostic control requires a fresh process")
            throw ControlFailure.reusedHost
        }
        NativeFixtureRetirement.registerHostIfEnabled()
    }

    private func withLoop(_ body: () async throws -> Void) async throws {
        let app = NSApplication.shared, previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var primary: (any Error)?
        do { try loop.verifyRunning(); try await body() } catch { primary = error }
        do { try await loop.close() }
        catch {
            if primary == nil { primary = error }
            else { XCTFail("Spell control AppKit loop cleanup also failed: \(error)") }
        }
        if let primary { throw primary }
    }

    private func request(_ checker: NSSpellChecker, tag: Int, range: NSRange,
                         types: NSTextCheckingTypes, captured: Bool = false) async throws -> Int {
        let receipt = F17CandidateReceipt()
        let completion: @Sendable (Int, [NSTextCheckingResult]) -> Void = { sequence, _ in receipt.receive(sequence) }
        let sequence: Int
        if captured {
            sequence = VaneF17SpellTraceCallCapturedCandidate(checker, range, "helo world", types, nil, tag, completion)
        } else {
            sequence = checker.requestCandidates(forSelectedRange: range, in: "helo world", types: types,
                options: nil, inSpellDocumentWithTag: tag, completionHandler: completion)
        }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(5))
        while receipt.sequences.isEmpty {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ControlFailure.callbackTimedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard clock.now < deadline else { throw ControlFailure.callbackTimedOut }
        XCTAssertEqual(receipt.sequences, [sequence], "The real SDK completion must match its returned request sequence")
        return sequence
    }

    private func assertClean(_ status: VaneF17SpellTraceStatus, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(status.problems, 0, file: file, line: line)
        XCTAssertEqual(status.inFlight, 0, file: file, line: line)
        XCTAssertEqual(status.closeInFlight, 0, file: file, line: line)
        XCTAssertEqual(status.dropped, 0, file: file, line: line)
        XCTAssertEqual(status.unpublished, 0, file: file, line: line)
        XCTAssertEqual(status.sharedStarts, status.sharedReturns, file: file, line: line)
        XCTAssertEqual(status.candidateStarts, status.candidateReturns, file: file, line: line)
    }

    private func finishTrace() {
        VaneF17SpellTraceEnd()
        let status = VaneF17SpellTraceReadStatus()
        assertClean(status)
        XCTAssertTrue(status.factoryRestored && status.factoryOriginalNow)
        XCTAssertTrue(status.candidateRestored && status.candidateOriginalNow)
        VaneF17SpellTraceEmit()
    }

    func testFlagOffLeavesFactoryUntouchedUntilRealSDKAction() async throws {
        try requireControl(traceEnabled: false)
        let before = VaneF17SpellTraceFactoryCurrentIMP()
        XCTAssertNotEqual(before, 0)
        XCTAssertFalse(VaneF17SpellTraceBegin())
        XCTAssertEqual(VaneF17SpellTraceFactoryCurrentIMP(), before)
        XCTAssertFalse(VaneF17SpellTraceReadStatus().requested)
        try await withLoop {
            let checker = NSSpellChecker.shared
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            defer { checker.closeSpellDocument(withTag: tag) }
            _ = try await request(checker, tag: tag, range: NSRange(location: 0, length: 4), types: spelling)
        }
        VaneF17SpellTraceEnd()
        VaneF17SpellTraceEmit()
        XCTAssertEqual(VaneF17SpellTraceReadStatus().eventCount, 0)
        XCTAssertEqual(VaneF17SpellTraceFactoryCurrentIMP(), before)
    }

    func testFirstObservedFactoryAndCandidateForwardRealSDKResults() async throws {
        try requireControl(traceEnabled: true)
        XCTAssertTrue(VaneF17SpellTraceBegin())
        defer { finishTrace() }
        VaneF17SpellTracePhase(100)
        try await withLoop {
            let checker = NSSpellChecker.shared // First deliberate accessor, after installation.
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            defer { checker.closeSpellDocument(withTag: tag) }
            let range = NSRange(location: 0, length: 4)
            let sequence = try await request(checker, tag: tag, range: range, types: spelling)
            let status = VaneF17SpellTraceReadStatus()
            assertClean(status)
            XCTAssertTrue(status.factoryInstalled && status.candidateInstalled)
            XCTAssertGreaterThan(status.sharedStarts, 0)
            XCTAssertEqual(status.receiver, UInt(bitPattern: Unmanaged.passUnretained(checker).toOpaque()))
            XCTAssertTrue(VaneF17SpellTraceHasCandidateResult(range, spelling, tag, sequence))
        }
    }

    func testWarmReceiverPreservesNullableCompletionTypesAndRanges() async throws {
        try requireControl(traceEnabled: true)
        // Deliberate warm control, never evidence of class/service coldness.
        let warm = NSSpellChecker.shared
        XCTAssertTrue(VaneF17SpellTraceBegin())
        defer { finishTrace() }
        VaneF17SpellTracePhase(101)
        try await withLoop {
            // A cached receiver alone bypasses binding. Make this natural call.
            let checker = NSSpellChecker.shared
            XCTAssertTrue(checker === warm)
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            defer { checker.closeSpellDocument(withTag: tag) }
            let firstRange = NSRange(location: 0, length: 4)
            let sequence = try await request(checker, tag: tag, range: firstRange, types: spelling)
            XCTAssertTrue(VaneF17SpellTraceHasCandidateResult(firstRange, spelling, tag, sequence))
            let secondRange = NSRange(location: 5, length: 5)
            let types = spelling | NSTextCheckingResult.CheckingType.correction.rawValue
            let withoutCompletion = checker.requestCandidates(forSelectedRange: secondRange, in: "helo world",
                types: types, options: [:], inSpellDocumentWithTag: tag, completionHandler: nil)
            XCTAssertTrue(VaneF17SpellTraceHasCandidateResult(secondRange, types, tag, withoutCompletion))
            assertClean(VaneF17SpellTraceReadStatus())
        }
    }

    func testRestoredMethodsAndLateFetchedStaticIMPsStillForward() async throws {
        try requireControl(traceEnabled: true)
        let originalFactory = VaneF17SpellTraceFactoryCurrentIMP()
        XCTAssertTrue(VaneF17SpellTraceBegin())
        defer { finishTrace() }
        var firstReceiver: NSSpellChecker?
        try await withLoop {
            let checker = NSSpellChecker.shared
            firstReceiver = checker
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            defer { checker.closeSpellDocument(withTag: tag) }
            _ = try await request(checker, tag: tag, range: NSRange(location: 0, length: 4), types: spelling)
            guard VaneF17SpellTraceCaptureOwnedIMPs() else { throw ControlFailure.captureMissing }
        }
        // First loop and its real spell document have been cleaned up and joined.
        VaneF17SpellTraceEnd()
        let ended = VaneF17SpellTraceReadStatus()
        assertClean(ended)
        XCTAssertTrue(ended.factoryRestored && ended.factoryOriginalNow)
        XCTAssertTrue(ended.candidateRestored && ended.candidateOriginalNow)
        XCTAssertEqual(VaneF17SpellTraceFactoryCurrentIMP(), originalFactory)
        try await withLoop {
            let checker = try XCTUnwrap(VaneF17SpellTraceCallCapturedFactory())
            guard checker === firstReceiver, VaneF17SpellTraceIsBoundReceiver(checker) else {
                XCTFail("The late fetched IMP must only receive its exact original receiver and dynamic class")
                throw ControlFailure.receiverChanged
            }
            let tag = NSSpellChecker.uniqueSpellDocumentTag()
            defer { checker.closeSpellDocument(withTag: tag) }
            _ = try await request(checker, tag: tag, range: NSRange(location: 0, length: 4), types: spelling, captured: true)
        }
        assertClean(VaneF17SpellTraceReadStatus())
        XCTAssertEqual(VaneF17SpellTraceReadStatus().eventCount, ended.eventCount)
    }
}
