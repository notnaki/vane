import Foundation
import XCTest
@testable import vane

@MainActor final class PerformanceLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: directory) }

    func testSamplesAreBoundedPerMetricAndSummarised() {
        let log = PerformanceLog(directory: directory)
        log.record(.launch, ms: 900)
        for ms in 1...(PerformanceLog.maximumSamples + 10) { log.record(.hang, ms: ms) }
        XCTAssertEqual(log.summary(.launch), .init(count: 1, medianMs: 900, p95Ms: 900, maxMs: 900))
        let hangs = log.summary(.hang)!
        XCTAssertEqual(hangs.count, PerformanceLog.maximumSamples)
        XCTAssertEqual(hangs.maxMs, PerformanceLog.maximumSamples + 10)
        XCTAssertEqual(hangs.medianMs, 261)  // oldest ten dropped: 11…510, upper middle
        XCTAssertNil(log.summary(.spaceSwitch))
    }

    func testSavedSamplesComeBackAndClearRemovesThem() async throws {
        let log = PerformanceLog(directory: directory)
        log.record(.spaceSwitch, ms: 42)
        await log.saveNow()
        XCTAssertEqual(PerformanceLog(directory: directory).samples, log.samples)
        log.clear()
        PerformanceLog.disk.sync {}  // the delete is queued behind any write in flight
        XCTAssertTrue(PerformanceLog(directory: directory).samples.isEmpty)
    }

    func testExportIsAnonymousUnlessMacDetailsAreAsked() throws {
        let log = PerformanceLog(directory: directory)
        log.record(.launch, ms: 1200)
        try FileManager.default.createDirectory(at: log.metricKitDirectory, withIntermediateDirectories: true)
        let report = #"""
        {"metaData":{"regionFormat":"GB","deviceType":"Mac15,3","osVersion":"27.0","appBuildVersion":"1"},
         "timeStampBegin":"2026-11-24 13:37:00 +0000",
         "crashDiagnostics":[{"diagnosticMetaData":{"pid":4242,"exceptionType":1,
           "objectiveCexceptionReason":{"composedMessage":"bad https://secret.example","exceptionName":"NSRangeException"},
           "terminationReason":"Namespace SIGNAL /Users/someone/x","virtualMemoryRegionInfo":"/Users/someone/Library"},
           "callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":"vane","binaryUUID":"AAAA-1111","offsetIntoBinaryTextSegment":12}]}]}}]}
        """#
        try Data(report.utf8).write(to: log.metricKitDirectory.appendingPathComponent("1-0-metrics.json"))

        let plain = String(decoding: try log.export(includeMac: false), as: UTF8.self)
        for leak in ["regionFormat", "GB", "deviceType", "Mac15,3", "osVersion", "\"mac\"", "4242",
                     "secret.example", "/Users/someone", "AAAA-1111", "13:37"] {
            XCTAssertFalse(plain.contains(leak), leak)
        }
        for kept in ["appBuildVersion", "NSRangeException", "\"offsetIntoBinaryTextSegment\" : 12",
                     "\"timeStampBegin\" : \"2026-11-24\""] {
            XCTAssertTrue(plain.contains(kept), kept)
        }
        XCTAssertTrue(plain.contains("\"ms\" : 1200"))

        let detailed = String(decoding: try log.export(includeMac: true), as: UTF8.self)
        XCTAssertTrue(detailed.contains("Mac15,3"))
        XCTAssertTrue(detailed.contains("AAAA-1111"))
        XCTAssertFalse(detailed.contains("secret.example"))
        XCTAssertFalse(detailed.contains("13:37"))
        XCTAssertTrue(detailed.contains("\"mac\""))
        XCTAssertFalse(detailed.contains("regionFormat"))
    }
}
