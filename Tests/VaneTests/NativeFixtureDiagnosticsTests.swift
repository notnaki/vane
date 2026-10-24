import Darwin
import XCTest

final class NativeFixtureDiagnosticsTests: XCTestCase {
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
}
