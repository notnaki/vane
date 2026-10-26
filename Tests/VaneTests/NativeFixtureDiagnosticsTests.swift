import Darwin
import XCTest

final class NativeFixtureDiagnosticsTests: XCTestCase {
    func testSQLiteClassificationRequiresExactOwnedDirectoryAndProfileFilename() {
        let directory = URL(fileURLWithPath: "/private/tmp/owned-vane-fixture")
        let database = directory.appendingPathComponent("vane-12345678-1234-1234-1234-123456789abc.db").path
        XCTAssertEqual(NativeFixtureDiagnostics.sqliteHandleKind(path: directory.appendingPathComponent("vane.db").path, directory: directory), .database)
        XCTAssertEqual(NativeFixtureDiagnostics.sqliteHandleKind(path: database, directory: directory), .database)
        XCTAssertEqual(NativeFixtureDiagnostics.sqliteHandleKind(path: database + "-wal", directory: directory), .wal)
        XCTAssertEqual(NativeFixtureDiagnostics.sqliteHandleKind(path: database + "-shm", directory: directory), .shm)
        for path in ["/private/tmp/owned-vane-fixture-other/vane.db", directory.appendingPathComponent("nested/vane.db").path,
                     directory.appendingPathComponent("vane-secret.db").path, database + "-journal", database + "-wal-extra"] {
            XCTAssertNil(NativeFixtureDiagnostics.sqliteHandleKind(path: path, directory: directory))
        }
    }

    func testDescriptorSnapshotContainsOwnedPipeWithoutAssumingStableProcessCounts() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { return XCTFail("Could not create disposable descriptor fixture") }
        defer { _ = close(descriptors[0]); _ = close(descriptors[1]) }
        let withPipe = NativeFixtureDiagnostics.currentProcessDescriptors()
        XCTAssertNotNil(withPipe.count)
        XCTAssertNil(withPipe.error)
        XCTAssertTrue(withPipe.identifiers.contains(descriptors[0]))
        XCTAssertTrue(withPipe.identifiers.contains(descriptors[1]))
    }

    func testDescriptorEnumerationReportsCapacityInsteadOfPretendingItIsComplete() throws {
        let snapshot = NativeFixtureDiagnostics.currentProcessDescriptors(limit: 1)
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.capacity, 1)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertNil(snapshot.error)
    }

    func testFailureRecordIsWrittenWithoutWaitingForStdoutFlushOrErrorFormatting() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { _ = close(descriptors[0]); _ = close(descriptors[1]) }
        XCTAssertNotEqual(fcntl(descriptors[0], F_SETFL, O_NONBLOCK), -1)
        NativeFixtureDiagnostics.emit("cached image width=0; Café", descriptor: descriptors[1])
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = bytes.withUnsafeMutableBytes { read(descriptors[0], $0.baseAddress, $0.count) }
        XCTAssertGreaterThan(count, 0, "The record must be observable immediately, before a failure is thrown")
        guard count > 0 else { return }
        XCTAssertEqual(String(decoding: bytes.prefix(count), as: UTF8.self),
                       "Vane fixture diagnostic: cached image width=0; Café\n")
    }

    private func fixture(pid: Int32 = 123, start: UInt64 = 10, path: String? = nil) -> NativeFixtureDiagnostics.Identity {
        .init(pid: pid, start: start,
              path: path ?? "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
              state: 2)
    }

    func testSamplerRequiresCurrentFixturePIDStartAndSystemWebContentExecutable() {
        let process = fixture()
        XCTAssertTrue(NativeFixtureDiagnostics.maySample(process, observed: process, ownedPID: 123))
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(process, observed: process, ownedPID: 124))
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(process, observed: nil, ownedPID: 123))
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(process, observed: fixture(start: 11), ownedPID: 123))
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(process, observed: fixture(path: "/usr/bin/sample"), ownedPID: 123))
        let ownTestProcess = fixture(pid: getpid())
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(ownTestProcess, observed: ownTestProcess, ownedPID: getpid()))
        let userApp = fixture(path: "/Applications/Vane.app/Contents/MacOS/Vane")
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(userApp, observed: userApp, ownedPID: 123))
        let userWebContent = fixture(path: "/Users/fixture/com.apple.WebKit.WebContent")
        XCTAssertFalse(NativeFixtureDiagnostics.maySample(userWebContent, observed: userWebContent, ownedPID: 123))
    }

    func testSymbolOutputOmitsArgumentsAndBinaryPathsAndCapsStacks() {
        let raw = "Arguments: PRIVATE-ARGUMENT\nCall graph:\nWebCore::FrameLoader\n" +
            String(repeating: "éstack\n", count: 4_000) + "Binary Images:\nPRIVATE-PATH"
        let result = NativeFixtureDiagnostics.symbolsOnly(raw)
        XCTAssertTrue(result.contains("WebCore::FrameLoader"))
        XCTAssertFalse(result.contains("PRIVATE-ARGUMENT"))
        XCTAssertFalse(result.contains("PRIVATE-PATH"))
        XCTAssertLessThanOrEqual(result.utf8.count, 16_384)
        XCTAssertEqual(NativeFixtureDiagnostics.symbolsOnly("Arguments: PRIVATE-ARGUMENT"), "symbolic call graph unavailable")
    }

    func testSampleReadCapsLargeReportBeforeDecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-sample-read-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("sample.txt")
        try Data(repeating: 65, count: 128 * 1_024).write(to: output)
        let data = try XCTUnwrap(NativeFixtureDiagnostics.readSampleData(output))
        XCTAssertEqual(data.count, 64 * 1_024)
        let link = directory.appendingPathComponent("sample-link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertNil(NativeFixtureDiagnostics.readSampleData(link), "A replaced report must not follow a symbolic link")
    }

    func testSamplerPhaseTokensSurviveEveryStreamBoundaryWithoutRetainingRawOutput() {
        let text = "Sampling process 123 for 1 second with 10 milliseconds of run time between samples\r\n" +
            "Sampling completed, processing symbols...\n" +
            "task_read_for_pid(123) failed\n" +
            "task_threads() for 123 failed\n" +
            "Unable to create VMUSampler for 123\n"
        let bytes = Data(text.utf8)
        for split in 0...bytes.count {
            var phases = NativeFixtureDiagnostics.SamplePhases(ownedPID: 123)
            phases.ingest(Data(bytes.prefix(split)))
            phases.ingest(Data(bytes.dropFirst(split)))
            XCTAssertEqual(phases.observed, [.collectionStarted, .symbolProcessingStarted, .taskReadFailed,
                                             .threadReadFailed, .samplerCreationFailed], "split=\(split)")
            XCTAssertEqual(phases.pendingByteCount, 0)
            XCTAssertFalse(phases.truncated)
            XCTAssertNil(phases.readError)
            XCTAssertFalse(phases.summary.contains("Sampling process"))
        }
    }

    func testSamplerPhaseRejectsForeignMalformedAndPrivateLines() {
        var phases = NativeFixtureDiagnostics.SamplePhases(ownedPID: 123)
        let rejected = [
            "Sampling process 124 for 1 second with 10 milliseconds of run time between samples",
            "Sampling process 123 for 2 seconds with 10 milliseconds of run time between samples",
            "Sampling process 123 for 1 second with 1 millisecond of run time between samples",
            "task_read_for_pid(1234) failed", "task_threads() for 124 failed",
            "Unable to create VMUSampler for 123 /Users/PRIVATE-PATH",
            "PRIVATE-ARG Sampling completed, processing symbols...",
            "Sampling completed, processing symbols... PRIVATE-ARG",
            "/Users/PRIVATE-PATH", "Café PRIVATE-ARG"
        ]
        phases.ingest(Data((rejected.joined(separator: "\n") + "\n").utf8))
        phases.ingest(Data([0xff, 0xfe, 10]))
        XCTAssertTrue(phases.observed.isEmpty)
        XCTAssertFalse(phases.summary.contains("PRIVATE"))
        XCTAssertFalse(phases.summary.contains("Café"))
        XCTAssertFalse(phases.summary.contains("1234"))
        XCTAssertLessThan(phases.summary.utf8.count, 512)
    }

    func testSamplerPhaseDropsWholeOversizedLineThenAcceptsNextRecord() {
        var phases = NativeFixtureDiagnostics.SamplePhases(ownedPID: 123)
        phases.ingest(Data(repeating: 65, count: 40_000))
        XCTAssertLessThanOrEqual(phases.pendingByteCount, 512)
        phases.ingest(Data("Sampling completed, processing symbols...\n".utf8))
        XCTAssertTrue(phases.observed.isEmpty, "A suffix of a discarded line is not a record")
        phases.ingest(Data("Sampling completed, processing symbols...\n".utf8))
        XCTAssertEqual(phases.observed, [.symbolProcessingStarted])
        XCTAssertTrue(phases.truncated)
        XCTAssertEqual(phases.pendingByteCount, 0)
    }

    func testSamplerPhaseDrainNeverWaitsForPipeEOFAndReportsReadError() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer { _ = close(descriptors[0]); _ = close(descriptors[1]) }
        XCTAssertNotEqual(fcntl(descriptors[0], F_SETFL, O_NONBLOCK), -1)
        let line = Data("Sampling completed, processing symbols...\n".utf8)
        XCTAssertEqual(line.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }, line.count)
        var phases = NativeFixtureDiagnostics.SamplePhases(ownedPID: 123)
        XCTAssertEqual(phases.drain(descriptor: descriptors[0]), line.count)
        XCTAssertEqual(phases.observed, [.symbolProcessingStarted])
        XCTAssertEqual(phases.drain(descriptor: descriptors[0]), 0, "The writer remains open; drain must stop at EAGAIN")
        XCTAssertNil(phases.readError)
        phases.drain(descriptor: -1)
        XCTAssertEqual(phases.readError, EBADF)
        XCTAssertFalse(phases.summary.contains("Sampling completed"))
    }

    func testSamplerPhaseDrainCapsOnePollWithoutDiscardingUnreadRecords() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vane-phase-poll-\(UUID())")
        defer { try? FileManager.default.removeItem(at: output) }
        let padding = Data((String(repeating: "x\n", count: 8_192)).utf8)
        let token = Data("Sampling completed, processing symbols...\n".utf8)
        try (padding + token).write(to: output)
        let descriptor = open(output.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { _ = close(descriptor) }
        var phases = NativeFixtureDiagnostics.SamplePhases(ownedPID: 123)
        XCTAssertEqual(phases.drain(descriptor: descriptor), 16_384)
        XCTAssertTrue(phases.observed.isEmpty)
        XCTAssertTrue(phases.truncated, "An exhausted per-poll budget must be visible")
        XCTAssertEqual(phases.drain(descriptor: descriptor), token.count)
        XCTAssertEqual(phases.observed, [.symbolProcessingStarted])
    }

    func testCachedNativeStateNeverCallsUnsafeGettersWithoutExistingOwnedProcess() {
        var calls: [String] = []
        let unowned = NativeFixtureDiagnostics.cachedNativeState(owned: false) { calls.append($0); return false }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(unowned, "nativeCachedState=unavailable (fixture ownership unverified)")
        let closed = NativeFixtureDiagnostics.cachedNativeState(owned: true) { calls.append($0); return true }
        XCTAssertEqual(calls, ["_isClosed"])
        XCTAssertEqual(closed, "nativeClosed=true, nativeSuspended=unavailable, nativeResponsiveCached=unavailable")
        calls.removeAll()
        let missing = NativeFixtureDiagnostics.cachedNativeState(owned: true) { calls.append($0); return nil }
        XCTAssertEqual(calls, ["_isClosed"])
        XCTAssertEqual(missing, "nativeClosed=unavailable, nativeSuspended=unavailable, nativeResponsiveCached=unavailable")
    }

    func testCachedNativeStateReportsExistingNativeValuesWithoutResponsivenessProbe() {
        var calls: [String] = []
        let state = NativeFixtureDiagnostics.cachedNativeState(owned: true) {
            calls.append($0)
            return ["_isClosed": false, "_isSuspended": true, "_webProcessIsResponsive": false][$0]
        }
        XCTAssertEqual(calls, ["_isClosed", "_isSuspended", "_webProcessIsResponsive"])
        XCTAssertEqual(state, "nativeClosed=false, nativeSuspended=true, nativeResponsiveCached=false")
    }

    @MainActor func testScriptProbeRecognizesResponsiveOldCommittedDocumentWithoutExposingURL() async {
        let committed = URL(string: "https://fixture.invalid/PRIVATE-PATH?PRIVATE-QUERY")!
        let report = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: committed,
            stillOwned: { true }, isClosed: { false }) { reply in
                Task { @MainActor in
                    await Task.yield()
                    reply(["complete", committed.absoluteString], nil)
                }
            }
        XCTAssertEqual(report, "jsProbe=reply, readyState=complete, oldCommittedDocument=true, inconclusive=false")
        XCTAssertFalse(report.contains("PRIVATE"))
        let changed = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: committed,
            stillOwned: { true }, isClosed: { false }) { $0(["interactive", "https://fixture.invalid/password"], nil) }
        XCTAssertEqual(changed, "jsProbe=reply, readyState=interactive, oldCommittedDocument=false, inconclusive=false")
    }

    @MainActor func testScriptProbeTreatsErrorsMalformedRepliesAndMissingCommitAsInconclusive() async {
        let committed = URL(string: "https://fixture.invalid/username")!
        let error = NSError(domain: "PRIVATE-ERROR", code: 9, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-DESCRIPTION"])
        let failed = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: committed,
            stillOwned: { true }, isClosed: { false }) { $0(nil, error) }
        XCTAssertEqual(failed, "jsProbe=error, inconclusive=true")
        let malformedReplies: [Any] = [NSNull(), ["complete"], ["PRIVATE-STATE", committed.absoluteString], ["complete", 7]]
        for malformed in malformedReplies {
            let report = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: committed,
                stillOwned: { true }, isClosed: { false }) { $0(malformed, nil) }
            XCTAssertEqual(report, "jsProbe=malformed-reply, inconclusive=true")
        }
        let missingCommit = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: nil,
            stillOwned: { true }, isClosed: { false }) { $0(["loading", committed.absoluteString], nil) }
        XCTAssertEqual(missingCommit, "jsProbe=reply, readyState=loading, oldCommittedDocument=unavailable, inconclusive=true")
    }

    @MainActor func testScriptProbeNeverEvaluatesWithoutVerifiedOwnershipAndOpenPage() async {
        for (owned, closed) in [(false, false as Bool?), (true, true), (true, nil)] {
            var evaluated = false
            let report = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: nil,
                stillOwned: { owned }, isClosed: { closed }) { _ in evaluated = true }
            XCTAssertFalse(evaluated)
            XCTAssertEqual(report, owned ? "jsProbe=page-unavailable, inconclusive=true" : "jsProbe=ownership-unverified, inconclusive=true")
        }
    }

    @MainActor func testScriptProbeDiscardsReplyAfterOwnedProcessChanges() async {
        var owned = true
        let report = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: nil,
            stillOwned: { owned }, isClosed: { false }) { reply in
                owned = false
                reply(["complete", "https://fixture.invalid/PRIVATE-PATH"], nil)
            }
        XCTAssertEqual(report, "jsProbe=process-changed, inconclusive=true")
    }

    @MainActor func testScriptProbeMissingCallbackReturnsAtItsBoundAndLateReplyIsHarmless() async {
        var lateReply: (@MainActor @Sendable (Any?, Error?) -> Void)?
        let report = await NativeFixtureDiagnostics.scriptResponsiveness(committedURL: nil,
            stillOwned: { true }, isClosed: { false }, timeout: .milliseconds(20)) { lateReply = $0 }
        XCTAssertEqual(report, "jsProbe=no-response, inconclusive=true")
        lateReply?(["complete", "https://fixture.invalid/PRIVATE-PATH"], nil)
        XCTAssertEqual(report, "jsProbe=no-response, inconclusive=true")
    }
}
