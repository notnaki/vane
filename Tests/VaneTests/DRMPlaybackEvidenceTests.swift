import XCTest
@testable import vane

@MainActor final class DRMPlaybackEvidenceTests: XCTestCase {
    func testClearPlaybackCannotBeReportedAsProtected() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: false, error: nil,
                                              frames: 100, previousFrames: 90), .withoutKeys)
    }

    func testKeysWithoutDecodedProgressDoNotProvePlayback() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 0, previousTime: 0, width: 640, hasKeys: true, error: nil), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 0, hasKeys: true, error: nil,
                                              frames: 100, previousFrames: 90), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: true, error: 3,
                                              frames: 100, previousFrames: 90), .unverified)
    }

    func testDecodedEncryptedProgressIsProtectedPlaybackEvidence() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 12, previousTime: 11, width: 640, hasKeys: true, error: nil,
                                              frames: 100, previousFrames: 90), .keysAttached)
    }

    func testFrozenSeekedFrameAndFirstSampleAreUnverified() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, previousTime: 30, width: 640, hasKeys: true, error: nil), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, width: 640, hasKeys: true, error: nil), .unverified)
    }

    func testSeekingPausedAndUndecodedTimeJumpsAreUnverified() {
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, previousTime: 12, width: 640, hasKeys: true, error: nil,
                                              paused: true, frames: 100, previousFrames: 90), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, previousTime: 12, width: 640, hasKeys: true, error: nil,
                                              seeking: true, frames: 100, previousFrames: 90), .unverified)
        XCTAssertEqual(DRMCheck.playbackResult(time: 30, previousTime: 12, width: 640, hasKeys: true, error: nil,
                                              frames: 100, previousFrames: 100), .unverified)
    }
}
