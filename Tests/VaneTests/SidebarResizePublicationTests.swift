import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SidebarResizePublicationTests: XCTestCase {
    private final class Owner { var current = true }
    @MainActor private final class Frames {
        var callback: (@MainActor () -> Void)?
        var starts = 0
        var stops = 0
        var driver: SidebarResizePublication.FrameDriver {
            { [unowned self] callback in
                starts += 1
                self.callback = callback
                return { [unowned self] in stops += 1 }
            }
        }
        func tick() { callback?() }
    }

    func testFramePublishesOnlyLatestWidthAndDoesNotRepeatIdleValues() {
        let frames = Frames()
        var widths: [CGFloat] = []
        let publication = SidebarResizePublication(frameDriver: frames.driver, publish: { widths.append($0) })
        defer { publication.cancel() }
        publication.enqueue(240)
        publication.enqueue(242)
        publication.enqueue(246)
        XCTAssertTrue(widths.isEmpty)
        frames.tick()
        XCTAssertEqual(widths, [246])
        frames.tick()
        XCTAssertEqual(widths, [246])
        publication.enqueue(250)
        frames.tick()
        XCTAssertEqual(widths, [246, 250])
        XCTAssertEqual(frames.starts, 1)
    }

    func testReleaseFlushesSynchronouslyAndLaterExactWidthsAreImmediate() {
        let frames = Frames()
        var widths: [CGFloat] = []
        let publication = SidebarResizePublication(frameDriver: frames.driver, publish: { widths.append($0) })
        publication.enqueue(240)
        publication.enqueue(244)
        publication.finish()
        XCTAssertEqual(widths, [244], "Release must publish before the buffer reconciles its exact parent")
        XCTAssertEqual(frames.stops, 1)
        publication.enqueue(200)
        XCTAssertEqual(widths, [244, 200], "An uncovered release can become covered after the link stops")
        publication.finish()
        frames.tick()
        XCTAssertEqual(widths, [244, 200])
        publication.cancel()
        publication.enqueue(180)
        XCTAssertEqual(widths, [244, 200])
        XCTAssertEqual(frames.stops, 1)
    }

    func testCancellationDiscardsQueuedValueAndRejectsLateFrameAndRelease() {
        let frames = Frames()
        var widths: [CGFloat] = []
        let publication = SidebarResizePublication(frameDriver: frames.driver, publish: { widths.append($0) })
        publication.enqueue(300)
        publication.cancel()
        publication.cancel()
        frames.tick()
        publication.finish()
        publication.enqueue(320)
        XCTAssertTrue(widths.isEmpty)
        XCTAssertEqual(frames.stops, 1)
    }

    func testOwnerReplacementDiscardsQueuedWidthBeforeFrameOrRelease() {
        for release in [false, true] {
            let frames = Frames()
            let owner = Owner()
            var widths: [CGFloat] = []
            let publication = SidebarResizePublication(frameDriver: frames.driver,
                isCurrent: { owner.current }, publish: { widths.append($0) })
            publication.enqueue(300)
            owner.current = false
            if release { publication.finish() } else { frames.tick() }
            owner.current = true
            publication.enqueue(320)
            frames.tick()
            XCTAssertTrue(widths.isEmpty)
            XCTAssertEqual(frames.stops, 1)
        }
    }

    func testDroppingOwnerInvalidatesDriverWithoutRetainingPublication() {
        let frames = Frames()
        var publication: SidebarResizePublication? = SidebarResizePublication(frameDriver: frames.driver, publish: { _ in
            XCTFail("A retired owner must not publish")
        })
        weak let retired = publication
        publication?.enqueue(300)
        publication = nil
        XCTAssertNil(retired)
        XCTAssertEqual(frames.stops, 1)
        frames.tick()
    }

    private final class ModelWindow: NSWindow {
        var admittedVisible = true
        override var isVisible: Bool { admittedVisible }
    }

    @MainActor private final class Fixture {
        let frames = Frames()
        let host: WebHost
        let web: WKWebView
        let window: ModelWindow
        var buffer: LivePageResizeBuffer!
        var publication: SidebarResizePublication!
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadlines: [@MainActor @Sendable () -> Void] = []
        var widths: [CGFloat] = []
        var completions = 0
        var time: TimeInterval = 0
        var current = true

        init() {
            TestEnvironment.prepare()
            web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            host = WebHost(web)
            host.setFrameSize(NSSize(width: 600, height: 400))
            host.resizeLayout.sidebarWidth = 228
            window = ModelWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            buffer = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
                presenter: { [unowned self] _, callback in paints.append(callback) },
                deadline: { [unowned self] interval, callback in
                    XCTAssertEqual(interval, 0.25)
                    deadlines.append(callback)
                }, now: { [unowned self] in time }, isCurrent: { [unowned self] in current },
                apply: { [unowned self] _, width in
                    if let width { publication.enqueue(width) }
                }, completion: { [unowned self] in
                    publication.cancel()
                    completions += 1
                })!
            publication = SidebarResizePublication(buffer: buffer, frameDriver: frames.driver,
                publish: { [unowned self] in widths.append($0) })
            buffer.start()
        }

        func paint() {
            guard !paints.isEmpty else { XCTFail("Expected a paint"); return }
            paints.removeFirst()()
        }

        func request(_ width: CGFloat) {
            time += 1
            XCTAssertTrue(buffer.request(frame: window.frame, sidebarWidth: width))
        }

        func acknowledge(_ width: CGFloat) {
            host.resizeLayout.sidebarWidth = SidebarWidth.fitting(width, in: 600)
            host.didUpdateResizeLayout()
            host.setFrameSize(NSSize(width: 828 - SidebarWidth.fitting(width, in: 600), height: 400))
        }

        func close() {
            buffer.cancel()
            publication.cancel()
            window.contentView = nil
            host.removePage()
            window.close()
        }
    }

    func testLatestUncoveredRequestRetainsOnlyCoveredQueuedGeometryUntilPaint() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(200) //628pt is covered by the648pt prime.
        f.request(164) //664pt must await the refill's presentation.
        XCTAssertTrue(f.widths.isEmpty)
        f.frames.tick()
        XCTAssertEqual(f.widths, [200], "An uncovered latest input must not replace the covered queue")
        f.acknowledge(200)
        f.paint()
        XCTAssertEqual(f.widths, [200])
        f.frames.tick()
        XCTAssertEqual(f.widths, [200, 164])
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 664)
    }

    func testPendingShrinkAndReversalNeverPublishPastTheSmallerInFlightViewport() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(400)
        XCTAssertEqual(f.web.frame.width, 600, "A deferred parent is still600pt wide during this trim")
        f.request(164)
        f.frames.tick()
        XCTAssertEqual(f.widths, [400])
        f.acknowledge(400)
        f.paint()
        f.frames.tick()
        XCTAssertEqual(f.widths, [400], "The smaller paint cannot admit the664pt reversal")
        f.paint()
        f.frames.tick()
        XCTAssertEqual(f.widths, [400, 164])
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 664)
    }

    func testUnacknowledgedSubmittedFloorDoesNotRepeatTheSamePaintDuringDrag() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        XCTAssertEqual(f.widths, [164])
        f.request(500)
        XCTAssertEqual(f.web.frame.width, 664)
        f.paint()
        // Complete bounded callbacks before any frame tick, parent ack or end.
        // A retained floor must not manufacture another identical preparation.
        for _ in 0..<3 where !f.paints.isEmpty { f.paint() }
        XCTAssertTrue(f.paints.isEmpty, "An unchanged submitted-parent floor cannot repeatedly repaint")
        XCTAssertEqual(f.web.frame.width, 664)
        f.frames.tick()
        XCTAssertEqual(f.widths, [164, 500])
        f.acknowledge(500)
        XCTAssertEqual(f.web.frame.width, 476, "The real trim resumes when the latest parent acknowledges")
        XCTAssertEqual(f.paints.count, 1)
        f.paint()
        XCTAssertTrue(f.paints.isEmpty)
        f.publication.finish()
        var releases = 0
        f.buffer.finish { releases += 1 }
        f.paint()
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.web.frame.width, 428)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testSubmittedWiderParentRemainsCoveredThroughShrinkAndReleaseUntilLatestAcknowledgment() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164)
        f.paint()
        f.frames.tick()
        XCTAssertEqual(f.widths, [164])
        XCTAssertEqual(f.host.bounds.width, 600, "SwiftUI has submitted664pt but the parent has not caught up")
        f.request(500)
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 664, "A trim cannot invalidate the submitted664pt parent")
        f.publication.finish()
        XCTAssertEqual(f.widths, [164, 500])
        var releases = 0
        f.buffer.finish { releases += 1 }
        f.paint()
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(f.web.autoresizingMask, [])
        XCTAssertTrue(f.paints.isEmpty, "Release must await deferred parent layout rather than repainting its stale size")
        f.acknowledge(164) // The older wider parent can still arrive first.
        XCTAssertGreaterThanOrEqual(f.web.frame.width, f.host.bounds.width)
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(f.paints.isEmpty)
        f.acknowledge(500) // Or SwiftUI may coalesce straight to this latest geometry.
        f.paint()
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(f.web.frame.width, 428)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        f.frames.tick()
        f.deadlines.forEach { $0() }
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.frames.stops, 1)
    }

    func testCoalescedParentAcknowledgmentClearsSubmittedFloorBeforeExactPaint() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(500); f.frames.tick()
        f.acknowledge(500) // No intermediate664pt callback.
        f.publication.finish()
        var releases = 0
        f.buffer.finish { releases += 1 }
        for _ in 0..<4 where !f.paints.isEmpty { f.paint() }
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(f.paints.isEmpty)
        XCTAssertEqual(f.web.frame.width, 428)
    }

    private final class LayoutProbe: NSView {
        var action: (() -> Void)?
        override func layout() {
            super.layout()
            let action = action
            self.action = nil
            action?()
        }
    }

    func testCoalescedReturnToBaselineFinishesWithoutAnyRepresentableUpdateOrWatchdog() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(228); f.frames.tick()
        f.publication.finish()
        var releases = 0
        f.buffer.finish { releases += 1 }
        // No updateNSView, native frame-size callback, or watchdog: SwiftUI may
        // diff-elide the unchanged child after coalescing164 back to228.
        XCTAssertEqual(f.host.bounds.width, 600)
        XCTAssertEqual(f.host.resizeLayout.sidebarWidth, 228)
        XCTAssertEqual(f.paints.count, 1, "The explicit ending layout flush can acknowledge unchanged latest geometry")
        if !f.paints.isEmpty { f.paint() }
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.web.frame.width, 600)
        XCTAssertEqual(f.completions, 1)
    }

    func testOlderLargerParentInstalledDuringReleaseFlushKeepsFloorUntilLatestLayout() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(228); f.frames.tick()
        let probe = LayoutProbe(frame: .zero)
        f.host.addSubview(probe)
        probe.action = { f.acknowledge(164) }
        probe.needsLayout = true
        let oldPaintDeadline = f.deadlines.last
        f.publication.finish()
        var releases = 0
        f.buffer.finish { releases += 1 }
        XCTAssertEqual(f.host.bounds.width, 664)
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 664)
        XCTAssertTrue(f.paints.isEmpty, "A mismatching actual parent must wait rather than repeatedly paint a stale size")
        oldPaintDeadline?()
        XCTAssertEqual(releases, 0, "An obsolete paint deadline cannot expire the separate parent-layout wait")
        f.acknowledge(228)
        XCTAssertEqual(f.paints.count, 1)
        if !f.paints.isEmpty { f.paint() }
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.web.frame.width, 600)
    }

    func testEqualBoundsWithStaleMetadataDoNotAcknowledgeEarlierWiderSubmissionDuringDrag() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(228); f.frames.tick()
        f.host.needsLayout = true
        f.host.layoutSubtreeIfNeeded()
        f.request(500)
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 664,
            "An unrelated native layout with old baseline metadata cannot retire the pending wider submission")
    }

    func testSameSizeNativeLayoutAfterMetadataUpdateClearsFloorDuringDrag() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(228); f.frames.tick()
        f.acknowledge(228)
        f.host.layoutSubtreeIfNeeded()
        f.request(500)
        XCTAssertEqual(f.web.frame.width, 600,
            "A same-size native layout with newly accepted metadata permits the next bounded trim")
    }

    private final class LayoutCounts { var callbacks = 0 }

    private func countNativeLayoutCallbacks(_ host: WebHost, into counts: LayoutCounts) {
        let resized = host.pageLayoutDidResize
        let metadataLayout = host.pageResizeLayoutDidUpdate
        host.pageLayoutDidResize = { counts.callbacks += 1; resized?() }
        host.pageResizeLayoutDidUpdate = { counts.callbacks += 1; metadataLayout?() }
    }

    func testSizeChangingMetadataUsesOneNativeResizeAckWithoutAnExtraLayout() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(f.host.needsLayout, "Begin with clean native layout")
        let counts = LayoutCounts()
        countNativeLayoutCallbacks(f.host, into: counts)
        f.host.resizeLayout.sidebarWidth = 164
        f.host.didUpdateResizeLayout()
        XCTAssertFalse(f.host.needsLayout, "A size-changing metadata update already has a native frame callback pending")
        f.host.setFrameSize(NSSize(width: 664, height: 400))
        f.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(counts.callbacks, 1, "The following normal host layout must not duplicate its native resize acknowledgment")
        f.request(500); f.frames.tick()
        f.host.resizeLayout.sidebarWidth = 400 //500 fits to400 in the fixed600pt root.
        f.host.didUpdateResizeLayout()
        XCTAssertFalse(f.host.needsLayout)
        f.host.setFrameSize(NSSize(width: 428, height: 400))
        f.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(counts.callbacks, 2)
        f.paint()
        XCTAssertEqual(f.web.frame.width, 476,
            "The actual latest native frame callback must clear submitted coverage debt and permit the bounded trim")
    }

    func testSameSizeMetadataAcknowledgesOnceThenNormalLayoutsDoNotRepeatIt() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(228); f.frames.tick()
        f.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(f.host.needsLayout)
        let counts = LayoutCounts()
        countNativeLayoutCallbacks(f.host, into: counts)
        f.acknowledge(228)
        XCTAssertTrue(f.host.needsLayout, "A real same-size metadata acknowledgment needs one native layout")
        f.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(counts.callbacks, 1)
        f.host.needsLayout = true
        f.host.layoutSubtreeIfNeeded()
        XCTAssertEqual(counts.callbacks, 1, "Acknowledged debt cannot drive the buffer again on an unrelated layout")
        f.request(500)
        XCTAssertEqual(f.web.frame.width, 600)
    }

    func testCancelDuringSubmittedParentWaitDropsReleaseAndPreservesNewPageOwner() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(164); f.paint(); f.frames.tick()
        f.request(500)
        f.publication.finish()
        var releases = 0
        f.buffer.finish { releases += 1 }
        f.paint()
        let replacement = NSView(frame: NSRect(x: 12, y: 15, width: 333, height: 222))
        f.web.removeFromSuperview()
        replacement.addSubview(f.web)
        f.web.frame = replacement.bounds
        f.web.autoresizingMask = [.height]
        f.buffer.cancel()
        f.frames.tick()
        f.deadlines.forEach { $0() }
        f.paints.forEach { $0() }
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(f.web.frame, replacement.bounds)
        XCTAssertEqual(f.web.autoresizingMask, [.height])
        XCTAssertEqual(f.frames.stops, 1)
    }

    func testUncoveredReleasePublishesExactWidthWithoutAnotherFrameTick() {
        let f = Fixture(); defer { f.close() }
        f.paint()
        f.request(200)
        f.request(164)
        f.publication.finish()
        XCTAssertEqual(f.widths, [200])
        var releases = 0
        f.buffer.finish { releases += 1 }
        f.paint()
        XCTAssertEqual(f.widths, [200, 164], "A newly covered ending endpoint must publish even though its clock stopped")
        XCTAssertEqual(releases, 0)
        f.acknowledge(164)
        for _ in 0..<4 where !f.paints.isEmpty { f.paint() }
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.web.frame.width, 664)
        XCTAssertEqual(f.frames.stops, 1)
    }

    func testFrameRejectsReplacedStoreRootPageOrWindowBeforePublishing() {
        let changes: [(Fixture) -> Void] = [
            { $0.current = false },
            { $0.window.contentView = NSView(frame: $0.host.frame) },
            { $0.host.offscreen = true },
            { $0.web.removeFromSuperview() },
            { $0.host.resizeFraction.width = 0.5 },
            { $0.window.admittedVisible = false }
        ]
        for change in changes {
            let f = Fixture(); defer { f.close() }
            f.paint(); f.request(240)
            change(f)
            f.frames.tick()
            XCTAssertTrue(f.widths.isEmpty)
            XCTAssertEqual(f.completions, 1)
            XCTAssertEqual(f.frames.stops, 1)
            f.paints.forEach { $0() }
            XCTAssertTrue(f.widths.isEmpty)
        }
    }

    func testPaintWatchdogStopsClockAndKeepsNativeFallbackImmediate() {
        let f = Fixture(); defer { f.close() }
        f.request(164)
        f.deadlines.removeFirst()()
        XCTAssertEqual(f.widths, [164])
        XCTAssertEqual(f.frames.stops, 1)
        XCTAssertTrue(f.buffer.bypassForDrag)
        f.request(180)
        XCTAssertEqual(f.widths, [164, 180])
        f.paint()
        XCTAssertEqual(f.completions, 1)
        f.frames.tick()
        XCTAssertEqual(f.widths, [164, 180])
    }

    func testUnadmittedWindowKeepsImmediateFallbackWithoutStartingClock() {
        TestEnvironment.prepare()
        let frames = Frames()
        let store = TabStore(isPrivate: true, session: [])
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        defer {
            store.window = nil
            window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        window.beginSidebarResize(store, frameDriver: frames.driver)
        XCTAssertFalse(window.updateSidebarResize(260))
        XCTAssertFalse(window.endSidebarResize(260) { XCTFail("The caller owns an unadmitted release") })
        XCTAssertEqual(frames.starts, 0)
        XCTAssertEqual(frames.stops, 0)
    }
}
