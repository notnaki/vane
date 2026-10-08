import AppKit
import XCTest
@testable import vane

@MainActor final class DownloadFeedbackTests: XCTestCase {
    func testFeedbackStaysInOriginWindowAndPrivateDownloadsStayPrivate() {
        let window = NSWindow()
        let other = NSWindow()
        let feedback = DownloadFeedback()
        let start = DownloadFeedback.Start(name: "report.pdf", profileID: UUID(), window: window)
        feedback.receive(start, in: other, isPrivate: false, reduced: false)
        XCTAssertNil(feedback.start)
        feedback.receive(start, in: window, isPrivate: true, reduced: false)
        XCTAssertNil(feedback.start)
        feedback.receive(start, in: window, isPrivate: false, reduced: false)
        XCTAssertEqual(feedback.start?.id, start.id)
        XCTAssertFalse(feedback.landed)

        let privateStart = DownloadFeedback.Start(name: "private.zip", profileID: Profile.incognito.id, window: window)
        feedback.receive(privateStart, in: window, isPrivate: false, reduced: false)
        XCTAssertEqual(feedback.start?.id, start.id)
        feedback.receive(privateStart, in: window, isPrivate: true, reduced: false)
        XCTAssertEqual(feedback.start?.id, privateStart.id)
    }

    func testFastConsecutiveStartsCannotBeLandedOrDismissedByOlderAnimation() {
        let window = NSWindow()
        let feedback = DownloadFeedback()
        let first = DownloadFeedback.Start(name: "first.pdf", profileID: UUID(), window: window)
        let second = DownloadFeedback.Start(name: "second.zip", profileID: UUID(), window: window)
        feedback.receive(first, in: window, isPrivate: false, reduced: false)
        feedback.receive(second, in: window, isPrivate: false, reduced: false)
        feedback.land(first.id)
        feedback.dismiss(first.id)
        XCTAssertEqual(feedback.start?.name, "second.zip")
        XCTAssertFalse(feedback.landed)
        feedback.land(second.id)
        XCTAssertTrue(feedback.landed)
        feedback.dismiss(second.id)
        XCTAssertNil(feedback.start)
    }

    func testReducedMotionShowsFileIconImmediatelyAndDetachedOriginCannotMatch() {
        let window = NSWindow()
        let feedback = DownloadFeedback()
        let start = DownloadFeedback.Start(name: "image.png", profileID: UUID(), window: window)
        feedback.receive(start, in: window, isPrivate: false, reduced: true)
        XCTAssertTrue(feedback.landed)
        XCTAssertEqual(feedback.start?.name, "image.png")
        feedback.cancel()
        XCTAssertNil(feedback.start)
        let detached = DownloadFeedback.Start(name: "hidden.pdf", profileID: UUID(), window: nil)
        feedback.receive(detached, in: nil, isPrivate: false, reduced: false)
        XCTAssertNil(feedback.start)
    }
}
