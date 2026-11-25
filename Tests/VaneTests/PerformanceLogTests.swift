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
        XCTAssertTrue(PerformanceLog(directory: directory).samples.isEmpty)
    }

    func testExportIsAnonymousUnlessMacDetailsAreAsked() throws {
        let log = PerformanceLog(directory: directory)
        log.record(.launch, ms: 1200)
        try FileManager.default.createDirectory(at: log.metricKitDirectory, withIntermediateDirectories: true)
        let report = #"{"metaData":{"regionFormat":"GB","deviceType":"Mac15,3","osVersion":"27.0","appBuildVersion":"1"},"cpu":5}"#
        try Data(report.utf8).write(to: log.metricKitDirectory.appendingPathComponent("1-0-metrics.json"))

        let plain = String(decoding: try log.export(includeMac: false), as: UTF8.self)
        for leak in ["regionFormat", "GB", "deviceType", "Mac15,3", "osVersion", "\"mac\""] {
            XCTAssertFalse(plain.contains(leak), leak)
        }
        XCTAssertTrue(plain.contains("appBuildVersion"))
        XCTAssertTrue(plain.contains("\"ms\" : 1200"))

        let detailed = String(decoding: try log.export(includeMac: true), as: UTF8.self)
        XCTAssertTrue(detailed.contains("Mac15,3"))
        XCTAssertTrue(detailed.contains("\"mac\""))
        XCTAssertFalse(detailed.contains("regionFormat"))
    }
}
