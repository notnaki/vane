import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class DownloadFeedbackTests: XCTestCase {
    func testHiddenSidebarRendersFeedbackAndDismissesWithBatterySaver() async throws {
        try await assertHiddenSidebarFeedback(savingBattery: true)
    }

    func testHiddenSidebarRendersFeedbackAndDismissesWithAnimation() async throws {
        try await assertHiddenSidebarFeedback(savingBattery: false)
    }

    private func assertHiddenSidebarFeedback(savingBattery: Bool) async throws {
        TestEnvironment.prepare()
        let previousMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(savingBattery ? .alwaysOn : .off)
        defer { BatterySaver.shared.setMode(previousMode) }
        let store = TabStore(isPrivate: true)
        store.sidebarShown = false
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: Color.gray
            .anchorPreference(key: DownloadFeedbackBounds.self, value: .bounds) { [.page: $0] }
            .modifier(DownloadFeedbackPresentation(store: store, chrome: false)))
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let before = try SidebarSnapshot.pixels(in: host)
        let start = DownloadFeedback.Start(name: "report.pdf", profileID: Profile.incognito.id, window: window)
        NotificationCenter.default.post(name: DownloadFeedback.started, object: start)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(try SidebarSnapshot.pixels(in: host), before,
                          "A download must visibly appear even without a sidebar bucket anchor")
        XCTAssertFalse(store.sidebarShown)
        try await Task.sleep(for: .milliseconds(2100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(try SidebarSnapshot.pixels(in: host), before,
                       "The temporary download control must disappear after feedback ends")
    }

    func testHiddenSidebarGetsVisibleDownloadTargetInsidePage() throws {
        let page = CGRect(x: 8, y: 8, width: 900, height: 600)
        let hiddenBucket = CGRect(x: -200, y: 550, width: 32, height: 32)
        let target = try XCTUnwrap(DownloadFeedbackBounds.destination(
            page: page, bucket: hiddenBucket, chrome: false))
        XCTAssertTrue(page.contains(target))
        XCTAssertEqual(target.minX, page.minX + 16)
        XCTAssertEqual(target.maxY, page.maxY - 16)
        XCTAssertEqual(DownloadFeedbackBounds.destination(page: page, bucket: nil, chrome: false), target)
    }

    func testVisibleSidebarUsesActualLibraryTarget() {
        let page = CGRect(x: 240, y: 8, width: 900, height: 600)
        let bucket = CGRect(x: 16, y: 550, width: 32, height: 32)
        XCTAssertEqual(DownloadFeedbackBounds.destination(page: page, bucket: bucket, chrome: true), bucket)
        XCTAssertNil(DownloadFeedbackBounds.destination(page: page, bucket: nil, chrome: true))
    }

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
