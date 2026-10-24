import Foundation
import XCTest

final class ReaderNativeLogTests: XCTestCase {
    private let reader = "vane-saved-reader-12345678-1234-1234-1234-123456789ABC"

    private func query(_ path: String? = nil, environment: [String: String] = ["GITHUB_ACTIONS": "true"]) -> ReaderNativeLog.Query? {
        ReaderNativeLog.query(image: URL(fileURLWithPath: path ?? "/tmp/\(reader)/images/fixture.png"),
                              ownerPID: 321, startedAt: Date(timeIntervalSince1970: 1_000),
                              failedAt: Date(timeIntervalSince1970: 1_010), environment: environment)
    }

    private func record(_ message: String, pid: Int = 321, process: String = "VanePackageTests",
                        subsystem: String = "com.apple.WebKit", category: String = "Sandbox") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["eventMessage": message, "processID": pid,
            "process": process, "subsystem": subsystem, "category": category])
    }

    @objc func testQueryRequiresExplicitCIAndOwnedImageShape() {
        XCTAssertNotNil(query())
        for environment in [[:], ["GITHUB_ACTIONS": "false"], ["GITHUB_ACTIONS": "TRUE"]] {
            XCTAssertNil(query(environment: environment))
        }
        for path in ["/tmp/article/images/fixture.png", "/tmp/\(reader)-sibling/images/fixture.png",
                     "/tmp/\(reader)/images/nested/fixture.png", "/tmp/\(reader)/private/fixture.png",
                     "/tmp/\(reader)/images/\" OR TRUEPREDICATE.png"] {
            XCTAssertNil(query(path))
        }
    }

    @objc func testQueryLimitsTimeWindowAndDoesNotFetchUnscopedProcesses() throws {
        let value = try XCTUnwrap(ReaderNativeLog.query(
            image: URL(fileURLWithPath: "/tmp/\(reader)/images/fixture.png"), ownerPID: 321,
            startedAt: Date(timeIntervalSince1970: 100), failedAt: Date(timeIntervalSince1970: 1_000),
            environment: ["GITHUB_ACTIONS": "true"]))
        func argument(_ key: String) throws -> String {
            let index = try XCTUnwrap(value.arguments.firstIndex(of: key))
            return value.arguments[index + 1]
        }
        XCTAssertEqual(try argument("--start"), "1970-01-01 00:16:10+0000")
        XCTAssertEqual(try argument("--end"), "1970-01-01 00:16:40+0000")
        let predicate = try argument("--predicate")
        XCTAssertTrue(predicate.contains(reader))
        XCTAssertTrue(predicate.contains("processIdentifier == 321"))
        XCTAssertFalse(predicate.contains("process == \"com.apple.WebKit.Networking\""))
        XCTAssertFalse(value.arguments.contains("--last"))
        XCTAssertFalse(value.arguments.contains("--archive"))
        XCTAssertNil(ReaderNativeLog.query(image: URL(fileURLWithPath: "/tmp/\(reader)/images/fixture.png"),
            ownerPID: 0, startedAt: .distantPast, failedAt: .now, environment: ["GITHUB_ACTIONS": "true"]))
    }

    @objc func testOwnedFileDenialIdentifiesProcessWithoutPrintingPathOrUUID() throws {
        let value = try XCTUnwrap(query())
        let data = try record("Sandbox: com.apple.WebKit.Networking(987) deny(1) file-read-data /private/tmp/\(reader)/article.html",
                              pid: 0, process: "kernel", subsystem: "com.apple.sandbox", category: "default")
        let result = try XCTUnwrap(ReaderNativeLog.classify(data, query: value))
        XCTAssertTrue(result.contains("read-denial"))
        XCTAssertTrue(result.contains("process=kernel"))
        XCTAssertTrue(result.contains("reportedTarget=webkit-networking,reportedPID=987"))
        XCTAssertFalse(result.contains(reader))
        XCTAssertFalse(result.contains("/private"))
        XCTAssertFalse(result.contains("article.html"))
    }

    @objc func testConsumeFailureOnlyEmitsClassificationAndErrnoNeverSandboxToken() throws {
        let value = try XCTUnwrap(query())
        let data = try record("Could not create a sandbox extension for 'SECRET;TOKEN;\(reader)', errno = 1")
        let result = try XCTUnwrap(ReaderNativeLog.classify(data, query: value))
        XCTAssertTrue(result.contains("consume-failure"))
        XCTAssertTrue(result.contains("errno=1"))
        XCTAssertFalse(result.contains("SECRET"))
        XCTAssertFalse(result.contains(reader))
    }

    @objc func testIssueFailureOmitsRawMessageAndUntrustedMetadata() throws {
        let value = try XCTUnwrap(query())
        let data = try record("Could not create a sandbox extension for '/Users/PRIVATE/\(reader)'",
                              process: "SECRET-PROCESS", subsystem: "SECRET-SUBSYSTEM", category: "SECRET-Sandbox")
        let result = try XCTUnwrap(ReaderNativeLog.classify(data, query: value))
        XCTAssertTrue(result.contains("issue-failure"))
        XCTAssertFalse(result.contains("SECRET"))
        XCTAssertFalse(result.contains("PRIVATE"))
    }

    @objc func testUnrelatedOrMalformedRecordsNeverEscapeParser() throws {
        let value = try XCTUnwrap(query())
        XCTAssertNil(ReaderNativeLog.classify(try record("deny(1) file-read-data /Users/PRIVATE/a", pid: 999), query: value))
        XCTAssertNil(ReaderNativeLog.classify(try record("unrelated private payload"), query: value))
        XCTAssertNil(ReaderNativeLog.classify(Data("not JSON SECRET".utf8), query: value))
        XCTAssertNil(ReaderNativeLog.classify(Data(repeating: 65, count: 16_385), query: value))
    }

    @objc func testKernelDenialForOwnerPIDIsScopedEvenWithRedactedPath() throws {
        let value = try XCTUnwrap(query())
        let own = try record("Sandbox: VanePackageTests(321) deny(1) file-read-data <private>", pid: 0, process: "kernel")
        XCTAssertTrue(try XCTUnwrap(ReaderNativeLog.classify(own, query: value)).contains("read-denial"))
        let other = try record("Sandbox: Other(4321) deny(1) file-read-data <private>", pid: 0, process: "kernel")
        XCTAssertNil(ReaderNativeLog.classify(other, query: value))
    }

    @objc func testNumericMetadataRejectsBooleansAndOversizedErrno() throws {
        let value = try XCTUnwrap(query())
        let malformed = try JSONSerialization.data(withJSONObject: ["eventMessage": "deny(1) file-read-data \(reader)",
                                                                   "processID": true, "process": "kernel"])
        XCTAssertNil(ReaderNativeLog.classify(malformed, query: value))
        let huge = try record("Could not create a sandbox extension for 'SECRET', errno = 123456789")
        let result = try XCTUnwrap(ReaderNativeLog.classify(huge, query: value))
        XCTAssertFalse(result.contains("errno="))
    }

    @objc func testRealNDJSONImagePathProvidesOnlyAllowlistedProcessName() throws {
        let value = try XCTUnwrap(query())
        for (path, name) in [("/kernel", "kernel"), ("/usr/libexec/sandboxd", "sandboxd")] {
            let data = try JSONSerialization.data(withJSONObject: ["eventMessage": "Sandbox: VanePackageTests(321) deny(1) file-read-data <private>",
                "processID": 0, "processImagePath": path, "category": "default"])
            let result = try XCTUnwrap(ReaderNativeLog.classify(data, query: value))
            XCTAssertTrue(result.contains("read-denial,process=\(name),pid=0"))
            XCTAssertFalse(result.contains(path))
        }
    }

    @objc func testOversizedNDJSONLineReportsTruncationWithoutRetainingPayload() throws {
        let value = try XCTUnwrap(query())
        var capture = ReaderNativeLog.Capture()
        capture.append(Array(repeating: UInt8(65), count: 16_385)[...], query: value)
        XCTAssertTrue(capture.truncated)
        XCTAssertEqual(capture.oversized, 1)
        XCTAssertTrue(capture.events.isEmpty)
        capture.append(Array(try record("Sandbox: Owner(321) deny(1) file-read-data <private>"))[...], query: value)
        XCTAssertTrue(capture.events.isEmpty)
    }

    @objc func testConsumeErrnoUsesActualUnquotedLiteralAndIgnoresTokenText() throws {
        let value = try XCTUnwrap(query())
        let forged = try record("Could not create a sandbox extension for 'TOKEN errno = 99', errno = '1'")
        let result = try XCTUnwrap(ReaderNativeLog.classify(forged, query: value))
        XCTAssertTrue(result.contains("extension-failure"))
        XCTAssertFalse(result.contains("errno="))
        XCTAssertFalse(result.contains("TOKEN"))
    }
}
