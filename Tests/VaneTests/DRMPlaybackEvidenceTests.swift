import XCTest
@testable import vane

@MainActor final class DRMPlaybackEvidenceTests: XCTestCase {
    func testClearPlaybackCannotBeReportedAsProtected() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: false, error: nil), .withoutKeys)
    }

    func testKeysWithoutDecodedProgressDoNotProvePlayback() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 0, previousTime: 0, width: 640, hasKeys: true, error: nil), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 0, hasKeys: true, error: nil), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: true, error: 3), .unverified)
    }

    func testDecodedEncryptedProgressIsProtectedPlaybackEvidence() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: true, error: nil), .keysAttached)
    }

    func testFrozenSeekedFrameAndFirstSampleAreUnverified() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, previousTime: 30, width: 640, hasKeys: true, error: nil), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, width: 640, hasKeys: true, error: nil), .unverified)
    }
}
