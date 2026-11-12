import Foundation
import XCTest
@testable import vane

#if DEBUG
@MainActor final class ResizePaintTraceTests: XCTestCase {
    func testArtifactPreservesCompleteBoundedTraceWithoutConsoleInterleaving() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = ResizePaintTrace(label: "sidebar=true\nfixture", limit: 2)
        let details = ["native": String(repeating: "WKChild {12, 34}\n\"quoted\" Test Case 'fixture' passed. ", count: 200)]
        trace.append("buffer.timeout", time: 1.25, fields: details, channel: "state")
        trace.append("buffer.bypass.retired", time: 2.5, channel: "state")
        trace.append("overflow", time: 3)
        let artifact = directory.appendingPathComponent("trace.json")
        try trace.writeArtifact(to: artifact)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: artifact)) as? [String: Any])
        XCTAssertEqual(document["attempt"] as? String, trace.attempt)
        XCTAssertEqual(document["label"] as? String, trace.label)
        XCTAssertEqual(document["dropped"] as? Int, 1)
        let entries = try XCTUnwrap(document["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["event"] as? String }, ["buffer.timeout", "buffer.bypass.retired"])
        XCTAssertEqual(entries.first?["fields"] as? [String: String], details)
    }

    func testTraceBoundsRetainedEventsAndEscapesMultilineNativeDetails() throws {
        let trace = ResizePaintTrace(label: "format", limit: 2)
        let details = ["native": "WKChild {12, 34}\n\"quoted\"\\path"]
        trace.append("first", time: 1.25, fields: details)
        trace.append("second", time: 2.5)
        trace.append("dropped", time: 3.75)
        let lines = try trace.encodedEntries()
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(trace.snapshot().dropped, 1)
        XCTAssertFalse(lines[0].contains("\n"), "Each trace entry must remain one machine-readable log line")
        let decoded = try lines.map { try JSONDecoder().decode(ResizePaintTrace.Entry.self, from: Data($0.utf8)) }
        XCTAssertEqual(decoded.map(\.event), ["first", "second"])
        XCTAssertEqual(decoded.map(\.channel), ["fixture", "fixture"])
        XCTAssertEqual(decoded[0].fields, details)
        XCTAssertEqual(decoded[0].time, 1.25)
    }

    func testFixtureRestoresBothPriorSinksAfterThrowingAndStoppingTwice() throws {
        let oldTiming = ResizeTimingDiagnostics.sink
        let oldState = ResizeTimingDiagnostics.stateSink
        defer { ResizeTimingDiagnostics.sink = oldTiming; ResizeTimingDiagnostics.stateSink = oldState }
        var timingCalls = 0
        var stateCalls = 0
        ResizeTimingDiagnostics.sink = { _, _, _, _ in timingCalls += 1 }
        ResizeTimingDiagnostics.stateSink = { _, _, _ in stateCalls += 1 }
        let trace = ResizePaintTrace(label: "lifecycle")
        enum FixtureFailure: Error { case expected }
        func failedFixture() throws {
            trace.install()
            trace.install()
            defer { trace.stop() }
            ResizeTimingDiagnostics.record("during", width: 12, height: 34)
            ResizeTimingDiagnostics.recordState("during.state", fields: ["generation": "one"])
            throw FixtureFailure.expected
        }
        XCTAssertThrowsError(try failedFixture())
        trace.stop()
        ResizeTimingDiagnostics.record("after")
        ResizeTimingDiagnostics.recordState("after.state", fields: [:])
        XCTAssertEqual(trace.snapshot().entries.map(\.event), ["during", "during.state"])
        XCTAssertEqual(trace.snapshot().entries.map(\.channel), ["timing", "state"])
        XCTAssertEqual(timingCalls, 1)
        XCTAssertEqual(stateCalls, 1)
    }

    func testDisabledStateTraceDoesNotEvaluatePayloadWithExistingTimingSinkInstalled() {
        let oldTiming = ResizeTimingDiagnostics.sink
        let oldState = ResizeTimingDiagnostics.stateSink
        defer { ResizeTimingDiagnostics.sink = oldTiming; ResizeTimingDiagnostics.stateSink = oldState }
        ResizeTimingDiagnostics.stateSink = nil
        var timingCalls = 0
        ResizeTimingDiagnostics.sink = { _, _, _, _ in timingCalls += 1 }
        var payloads = 0
        func payload() -> [String: String] { payloads += 1; return ["formatted": "value"] }
        ResizeTimingDiagnostics.recordState("disabled", fields: payload())
        ResizeTimingDiagnostics.record("existing")
        XCTAssertEqual(payloads, 0)
        XCTAssertEqual(timingCalls, 1)
    }
}
#endif
