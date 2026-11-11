import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LivePageResizeBufferTests: XCTestCase {
    private final class ModelWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    @MainActor private final class Fixture {
        let host: WebHost
        let web: WKWebView
        let window: ModelWindow
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadlines: [@MainActor @Sendable () -> Void] = []
        var commits: [NSSize] = []
        var completions = 0
        var time: TimeInterval = 0
        lazy var buffer = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
            presenter: { [unowned self] _, callback in paints.append(callback) },
            deadline: { [unowned self] interval, callback in
                XCTAssertEqual(interval, 0.25)
                deadlines.append(callback)
            }, now: { [unowned self] in time }, apply: { [unowned self] frame, _ in
                commits.append(frame.size)
                window.setFrame(frame, display: false)
            }, completion: { [unowned self] in completions += 1 })!

        init() {
            TestEnvironment.prepare()
            web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            host = WebHost(web)
            host.setFrameSize(NSSize(width: 600, height: 400))
            window = ModelWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
        }
        func request(_ width: CGFloat) {
            time += 1.0 / 60
            XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: width, height: 400)))
        }
        func close() {
            buffer.cancel()
            window.contentView = nil
            host.removePage()
            window.close()
        }
    }

    private func nextPaint(_ paints: inout [@MainActor @Sendable () -> Void]) -> @MainActor @Sendable () -> Void {
        guard !paints.isEmpty else { XCTFail("Expected a pending presentation"); return {} }
        return paints.removeFirst()
    }

    func testPrimingFreezesNativeSizingAndCoveredRequestsCommitWithoutAnotherPaint() throws {
        let f = Fixture(); defer { f.close() }
        let child = try XCTUnwrap(f.web.subviews.first)
        let oldChild = child.frame.size
        f.buffer.start()
        XCTAssertEqual(f.web.frame.width, 648)
        XCTAssertEqual(child.frame.size, oldChild)
        XCTAssertEqual(f.web.autoresizingMask, [])
        f.request(620)
        XCTAssertTrue(f.commits.isEmpty)
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 620)
        f.request(640)
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(f.paints.count, 1, "Refilling must run independently of covered pointer movement")
        XCTAssertFalse(f.web.autoresizesSubviews)
    }

    func testFirstNearImmediatePointerSampleDoesNotInflateTheMinimumPrime() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        f.time = 0.0001
        XCTAssertTrue(f.buffer.request(frame: NSRect(x: 0, y: 0, width: 604, height: 400)))
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 604)
        XCTAssertEqual(f.web.frame.width, 648)
        XCTAssertTrue(f.paints.isEmpty, "A tiny first movement cannot manufacture constructor-time velocity")
    }

    func testRefillUsesFixedBaselineAndReversalFitsBothPaintedAndInFlightCoverage() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start(); nextPaint(&f.paints)()
        f.request(720)
        XCTAssertEqual(f.web.frame.width, 912, "Do not add lookahead to the already enlarged web frame")
        nextPaint(&f.paints)()
        f.request(500)
        XCTAssertEqual(f.web.frame.width, 692)
        f.request(800)
        XCTAssertEqual(f.window.frame.width, 500, "A reversal cannot expose the smaller in-flight paint")
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 500)
        XCTAssertEqual(f.web.frame.width, 992)
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 800)
    }

    func testFinishRetainsLatestEndpointThenRestoresExactNativeSizingOnce() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        f.request(740)
        f.request(760)
        f.buffer.finish()
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 600, "Uncovered final growth still needs its paint")
        XCTAssertEqual(f.web.frame.width, 760)
        XCTAssertEqual(f.completions, 0)
        nextPaint(&f.paints)()
        XCTAssertFalse(f.buffer.isPreparing)
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(f.web.frame.size, f.host.bounds.size)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertTrue(f.web.autoresizesSubviews)
        f.deadlines.forEach { $0() }
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(f.web.frame.width, 760)
    }

    func testOwnerReplacementRejectsLatePaintWithoutOverwritingNewFrameAndMask() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start(); f.request(760)
        let replacement = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        f.web.removeFromSuperview(); replacement.addSubview(f.web)
        f.web.frame = replacement.bounds
        f.web.autoresizingMask = [.height]
        nextPaint(&f.paints)()
        XCTAssertTrue(f.commits.isEmpty)
        XCTAssertEqual(f.web.frame, replacement.bounds)
        XCTAssertEqual(f.web.autoresizingMask, [.height])
        XCTAssertTrue(f.web.autoresizesSubviews)
        XCTAssertFalse(f.buffer.isPreparing)
    }

    func testSplitPagesKeepTheirClipsUntilEveryIndependentPaintPresents() throws {
        let f = Fixture(); defer { f.close() }
        let rightWeb = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let right = WebHost(rightWeb)
        let root = NSView(frame: f.host.frame)
        f.window.contentView = nil
        f.host.setFrameSize(NSSize(width: 300, height: 400))
        right.frame = NSRect(x: 300, y: 0, width: 300, height: 400)
        f.host.resizeFraction.width = 0.5
        right.resizeFraction.width = 0.5
        root.addSubview(f.host); root.addSubview(right)
        f.window.contentView = root
        defer { right.removePage() }
        let leftChild = try XCTUnwrap(f.web.subviews.first)
        let rightChild = try XCTUnwrap(rightWeb.subviews.first)
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }, apply: { frame, _ in
                f.window.setFrame(frame, display: false)
                f.host.setFrameSize(NSSize(width: frame.width / 2, height: 400))
                right.setFrameSize(NSSize(width: frame.width / 2, height: 400))
            }))
        defer { buffer.cancel() }
        buffer.start()
        XCTAssertEqual(f.web.frame.width, 324)
        XCTAssertEqual(rightWeb.frame.width, 324)
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: 640, height: 400)))
        let first = try XCTUnwrap(paints.first)
        paints.removeFirst()
        first(); first()
        XCTAssertEqual(f.window.frame.width, 600)
        XCTAssertEqual(leftChild.frame.width, 300)
        XCTAssertEqual(rightChild.frame.width, 300)
        nextPaint(&paints)()
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(leftChild.frame.width, 324)
        XCTAssertEqual(rightChild.frame.width, 324)
    }

    func testSidebarPredictionUsesOriginalNavigationAndWaitsForFinalHostLayout() throws {
        let f = Fixture(); defer { f.close() }
        f.host.resizeLayout.sidebarWidth = 228
        var paints: [@MainActor @Sendable () -> Void] = []
        var widths: [CGFloat] = []
        var finished = false
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            now: { f.time }, apply: { _, width in
                if let width {
                    widths.append(width)
                    f.host.resizeLayout.sidebarWidth = width
                }
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        f.time += 1.0 / 60
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 500))
        XCTAssertEqual(widths, [500])
        // At600pt root width, the same fitting formula caps the sidebar at400.
        XCTAssertEqual(f.web.frame.width, 620, accuracy: 0.001)
        f.host.setFrameSize(NSSize(width: 428, height: 400))
        buffer.finish { finished = true }
        nextPaint(&paints)()
        XCTAssertEqual(f.web.frame.width, 428)
        XCTAssertFalse(finished)
        nextPaint(&paints)()
        XCTAssertTrue(finished)
        XCTAssertEqual(f.web.frame.width, 428)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testFinalPaintWaitsForAsynchronousSidebarParentBeforeRestoringMask() throws {
        let f = Fixture(); defer { f.close() }
        f.host.resizeLayout.sidebarWidth = 228
        var paints: [@MainActor @Sendable () -> Void] = []
        var finished = false
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            apply: { _, _ in }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 200))
        buffer.finish { finished = true }
        while !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertFalse(finished)
        XCTAssertEqual(f.web.autoresizingMask, [])
        f.host.setFrameSize(NSSize(width: 628, height: 400))
        XCTAssertTrue(finished)
        XCTAssertEqual(f.web.frame.width, 628, "Restoration cannot apply the sidebar delta twice")
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testMixedAxisPreparationNeverShrinksBelowStillVisibleGeometry() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start(); nextPaint(&f.paints)()
        XCTAssertTrue(f.buffer.request(frame: NSRect(x: 0, y: 0, width: 300, height: 500)))
        XCTAssertEqual(f.window.frame.size, NSSize(width: 600, height: 400))
        XCTAssertGreaterThanOrEqual(f.web.frame.width, 600)
        f.buffer.finish()
        while !f.paints.isEmpty { nextPaint(&f.paints)() }
        XCTAssertEqual(f.window.frame.size, NSSize(width: 300, height: 500))
        XCTAssertEqual(f.web.frame.size, NSSize(width: 300, height: 500))
        XCTAssertFalse(f.buffer.isPreparing)
    }

    func testProgrammaticWindowOrRootReplacementCancelsTheOldDrag() {
        for replaceRoot in [false, true] {
            let f = Fixture(); defer { f.close() }
            f.buffer.start(); f.request(800)
            if replaceRoot { f.window.contentView = NSView(frame: f.host.frame) }
            else { f.window.setFrame(NSRect(x: 10, y: 20, width: 700, height: 450), display: false) }
            nextPaint(&f.paints)()
            XCTAssertTrue(f.commits.isEmpty)
            XCTAssertFalse(f.buffer.isPreparing)
            XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
            XCTAssertTrue(f.web.autoresizesSubviews)
        }
    }

    func testReleaseWatchdogRunsDeferredSidebarEffectsExactlyOnce() {
        let f = Fixture(); defer { f.close() }
        var releases = 0
        f.buffer.start(); f.request(800)
        f.buffer.finish { releases += 1 }
        f.buffer.finish() // Duplicate native end must preserve sidebar release work.
        f.deadlines.removeFirst()()
        XCTAssertEqual(f.window.frame.width, 800)
        XCTAssertEqual(releases, 1)
        XCTAssertEqual(f.completions, 1)
        nextPaint(&f.paints)()
        f.deadlines.forEach { $0() }
        XCTAssertEqual(releases, 1)
    }

    func testChangedNavigationOrSplitMetadataCancelsTheFixedBaseline() {
        let changes: [(WebHost) -> Void] = [
            { $0.resizeLayout.sidebarWidth = 164 },
            { $0.resizeLayout.librarySection = .archived },
            { $0.resizeLayout.spaces += 1 },
            { $0.resizeLayout.isPrivate.toggle() },
            { $0.resizeFraction.width = 0.5 },
            { $0.resizeLayout.enabled = false }
        ]
        for change in changes {
            let f = Fixture(); defer { f.close() }
            f.buffer.start(); f.request(800)
            change(f.host)
            nextPaint(&f.paints)()
            XCTAssertTrue(f.commits.isEmpty)
            XCTAssertFalse(f.buffer.isPreparing)
            XCTAssertEqual(f.web.frame.width, 600)
            XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
            XCTAssertTrue(f.web.autoresizesSubviews)
        }
    }

    func testNewCommandCancelsPendingReleaseAndItsSideEffects() {
        let f = Fixture(); defer { f.close() }
        var releases = 0
        f.buffer.start(); f.request(800)
        f.buffer.finish { releases += 1 }
        f.buffer.cancel()
        f.window.setFrame(NSRect(x: 0, y: 0, width: 700, height: 400), display: false)
        nextPaint(&f.paints)()
        f.deadlines.forEach { $0() }
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(f.window.frame.width, 700)
        XCTAssertEqual(f.web.frame.width, 700)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testCancellationPreservesOriginallyDisabledNativeFlags() {
        let f = Fixture(); defer { f.close() }
        f.web.autoresizingMask = [.height]
        f.web.autoresizesSubviews = false
        f.buffer.start()
        f.buffer.cancel()
        XCTAssertEqual(f.web.autoresizingMask, [.height])
        XCTAssertFalse(f.web.autoresizesSubviews)
        nextPaint(&f.paints)()
        XCTAssertFalse(f.web.autoresizesSubviews)
    }

    func testWatchdogUsesLatestRequestAndLateCallbacksCannotCommitAgain() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start(); f.request(800); f.request(850)
        f.deadlines.removeFirst()()
        XCTAssertEqual(f.window.frame.width, 850)
        XCTAssertEqual(f.web.frame.width, 850)
        XCTAssertTrue(f.web.autoresizesSubviews)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertFalse(f.buffer.isPreparing)
        XCTAssertTrue(f.buffer.bypassForDrag)
        f.request(900)
        XCTAssertEqual(f.window.frame.width, 900, "An unresponsive page must not add another paint wait on every event")
        nextPaint(&f.paints)()
        XCTAssertFalse(f.buffer.bypassForDrag)
        XCTAssertEqual(f.commits, [NSSize(width: 850, height: 400), NSSize(width: 900, height: 400)])
    }
}
