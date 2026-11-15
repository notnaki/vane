import CoreServices
import XCTest
@testable import vane

final class DownloadQuarantineTests: XCTestCase {
    private func quarantined(source: URL?, page: URL?, isPrivate: Bool) throws -> [String: Any] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("vane-q-\(UUID().uuidString).zip")
        try Data("x".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(Downloads.quarantine(file, source: source, page: page, isPrivate: isPrivate))
        // The xattr itself, not just the resource value cache.
        XCTAssertGreaterThan(getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0), 0)
        let fresh = URL(fileURLWithPath: file.path)
        return try XCTUnwrap(fresh.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
    }

    func testFinishedDownloadRecordsAgentAndEvent() throws {
        let q = try quarantined(source: URL(string: "https://cdn.example/file.zip"),
                                page: URL(string: "https://example.com/get"), isPrivate: false)
        XCTAssertEqual(q[kLSQuarantineAgentNameKey as String] as? String, "Vane")
        XCTAssertEqual(q[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
        // The data/origin URLs go to LaunchServices' QuarantineEvents database, keyed by
        // this event id; they are not readable back through the xattr.
        XCTAssertNotNil(q["LSQuarantineEventIdentifier"])
    }

    func testPrivateAndNonWebDownloadsAreStillQuarantined() throws {
        for (source, isPrivate) in [("https://cdn.example/file.zip", true), ("blob:https://example.com/1", false)] {
            let q = try quarantined(source: URL(string: source), page: nil, isPrivate: isPrivate)
            XCTAssertEqual(q[kLSQuarantineAgentNameKey as String] as? String, "Vane")
            XCTAssertEqual(q[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
        }
    }
}
