import AppKit
import WebKit
import XCTest
@testable import vane

/// Unshown native objects only: no focus, input, or capture is needed.
@MainActor final class WindowResizePreparationTests: XCTestCase {
    func testLeftBottomResizeKeepsTheOppositeCornerFixed() {
        let frame = NSRect(x: 100, y: 200, width: 900, height: 600)
        let anchor = WindowResizeAnchor(frame: frame, pointer: NSPoint(x: 100, y: 200))
        XCTAssertEqual(anchor.frame(for: NSSize(width: 1100, height: 700)),
                       NSRect(x: -100, y: 100, width: 1100, height: 700))
    }

    func testRightTopResizeKeepsTheOppositeCornerFixed() {
        let frame = NSRect(x: 100, y: 200, width: 900, height: 600)
        let anchor = WindowResizeAnchor(frame: frame, pointer: NSPoint(x: 1000, y: 800))
        XCTAssertEqual(anchor.frame(for: NSSize(width: 1100, height: 700)),
                       NSRect(x: 100, y: 200, width: 1100, height: 700))
    }

    private func fixture() -> (WebHost, WKWebView) {
        TestEnvironment.prepare()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let host = WebHost(web)
        host.setFrameSize(NSSize(width: 600, height: 400))
        return (host, web)
    }

    func testPreparationPreservesNativeChildGeometryUntilCommit() throws {
        let (host, web) = fixture()
        defer { host.removePage() }
        let child = try XCTUnwrap(web.subviews.first)
        let original = child.frame
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        XCTAssertEqual(web.frame.size, NSSize(width: 800, height: 500))
        XCTAssertEqual(child.frame, original, "Do not clip old pixels ahead of the new paint")
        XCTAssertFalse(web.autoresizesSubviews)
        prepared.restore(committed: true)
        XCTAssertEqual(child.frame.size, NSSize(width: 800, height: 500))
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        prepared.restore(committed: true)
        XCTAssertEqual(child.frame.size, NSSize(width: 800, height: 500), "Cleanup must not apply the delta twice")
    }

    func testCancellationRestoresCurrentParentGeometry() {
        let (host, web) = fixture()
        defer { host.removePage() }
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        host.setFrameSize(NSSize(width: 700, height: 450))
        XCTAssertFalse(prepared.stillOwned, "A changed layout invalidates the prepared viewport")
        prepared.restore(committed: false)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
    }

    func testMixedAxisResizeClipsTheShrinkingAxisBeforePreparingGrowth() {
        for target in [NSSize(width: 500, height: 500), NSSize(width: 700, height: 300)] {
            let (host, web) = fixture()
            let window = modelWindow(host)
            defer { window.contentView = nil; host.removePage(); window.close() }
            var paints: [@MainActor @Sendable () -> Void] = []
            var commits: [NSSize] = []
            let resize = WindowResizePreparation(window: window,
                presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }) { frame, display in
                    commits.append(frame.size)
                    window.setFrame(frame, display: display)
                }
            let clipped = target.width == 500 ? NSSize(width: 500, height: 400) : NSSize(width: 600, height: 300)
            XCTAssertTrue(resize.request(frame: NSRect(origin: .zero, size: target), display: true))
            XCTAssertEqual(window.frame.size, clipped,
                           "Clip the old larger pixels before preparing a smaller document dimension")
            XCTAssertEqual(commits, [clipped])
            XCTAssertEqual(paints.count, 1)
            paints.removeFirst()()
            XCTAssertEqual(commits, [clipped, target])
            XCTAssertEqual(window.frame.size, target)
            XCTAssertEqual(web.frame.size, target)
            resize.cancel()
        }
    }

    func testReparentingDoesNotRestoreThePreviousHostsFrameOrMask() {
        let (oldHost, web) = fixture()
        let nextHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
        defer { oldHost.removePage(); web.removeFromSuperview() }
        let prepared = PreparedPageResize(web: web, size: NSSize(width: 800, height: 500))
        prepared.prepare()
        web.removeFromSuperview()
        nextHost.addSubview(web)
        web.frame = nextHost.bounds
        web.autoresizingMask = [.height]
        prepared.restore(committed: false)
        XCTAssertEqual(web.frame, nextHost.bounds)
        XCTAssertEqual(web.autoresizingMask, [.height])
        XCTAssertTrue(web.autoresizesSubviews)
    }

    func testQueuedFramesCoalesceAndInstallTheClipBeforeWindowDisplay() async throws {
        let (host, web) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        let child = try XCTUnwrap(web.subviews.first)
        var paints: [@MainActor @Sendable () -> Void] = []
        var commits: [NSSize] = []
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }) { frame, display in
                XCTAssertEqual(child.frame.size, frame.size,
                               "setFrame(display:true) can flush before returning")
                XCTAssertEqual(web.autoresizingMask, [], "Do not apply the native delta twice")
                commits.append(frame.size)
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), display: true))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 900, height: 600), display: true))
        XCTAssertEqual(paints.count, 1)
        paints.removeFirst()()
        try await compatibilityWait { paints.count == 1 }
        XCTAssertEqual(paints.count, 1)
        paints.removeFirst()()
        XCTAssertEqual(commits, [NSSize(width: 800, height: 500), NSSize(width: 900, height: 600)])
        XCTAssertFalse(resize.isPreparing)
        XCTAssertEqual(web.frame.size, window.contentView?.bounds.size)
        XCTAssertTrue(web.autoresizesSubviews)
    }

    func testTimeoutRestoresNativeSizingAndLatePaintReenablesCoordination() {
        let (host, web) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadlines: [@MainActor @Sendable () -> Void] = []
        var commits = 0
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) },
            deadline: { _, callback in deadlines.append(callback) }) { frame, display in
                commits += 1
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), display: true))
        deadlines.removeFirst()()
        XCTAssertEqual(window.frame.size, NSSize(width: 1000, height: 700))
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertEqual(web.autoresizingMask, [.width, .height])
        XCTAssertTrue(resize.bypassForDrag)
        XCTAssertFalse(resize.request(frame: NSRect(x: 0, y: 0, width: 1050, height: 700), display: true))
        paints.removeFirst()()
        XCTAssertEqual(commits, 1, "A late paint cannot restore the stale frame")
        XCTAssertFalse(resize.bypassForDrag, "One slow paint cannot bypass coordination for the entire drag")
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1100, height: 700), display: true))
        resize.cancel()
        resize.endLiveResize()
        XCTAssertFalse(resize.bypassForDrag)
    }

    @MainActor private final class PaintClock {
        private var now: TimeInterval = 0
        private var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []

        func schedule(after interval: TimeInterval, _ action: @escaping @MainActor @Sendable () -> Void) {
            pending.append((now + interval, action))
        }

        func advance(by interval: TimeInterval) {
            now += interval
            let due = pending.filter { $0.0 <= now }
            pending.removeAll { $0.0 <= now }
            due.forEach { $0.1() }
        }
    }

    func testNormallyLatePaintDoesNotExposeAnUnpaintedQueuedFrame() throws {
        let (host, _) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        let clock = PaintClock()
        var paints: [@MainActor @Sendable () -> Void] = []
        var commits: [NSSize] = []
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) },
            deadline: { interval, action in clock.schedule(after: interval, action) }) { frame, display in
                commits.append(frame.size)
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), display: true))
        // Advance the same elapsed interval without relying on an executor to
        // resume before the independently running real watchdog expires.
        clock.advance(by: 0.15)
        XCTAssertTrue(commits.isEmpty, "A responsive but late page must not expose unpainted width")
        XCTAssertFalse(resize.bypassForDrag)
        paints.removeFirst()()
        XCTAssertEqual(commits, [NSSize(width: 800, height: 500)])
        resize.cancel()
    }

    func testRecoveryWaitsForEverySplitPageWithoutCommittingItsStaleFrame() {
        let (left, _) = fixture()
        let (right, _) = fixture()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        left.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        right.frame = NSRect(x: 300, y: 0, width: 300, height: 400)
        left.resizeFraction.width = 0.5
        right.resizeFraction.width = 0.5
        root.addSubview(left)
        root.addSubview(right)
        let window = modelWindow(root)
        defer { window.contentView = nil; left.removePage(); right.removePage(); window.close() }
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadline: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) }, deadline: { _, callback in deadline = callback }) { frame, display in
                commits += 1
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertEqual(paints.count, 2)
        deadline?()
        paints.removeFirst()()
        XCTAssertTrue(resize.bypassForDrag, "The other split page is still unresponsive")
        paints.removeFirst()()
        XCTAssertFalse(resize.bypassForDrag)
        XCTAssertEqual(commits, 1, "Recovery callbacks cannot commit the old prepared frame")
        XCTAssertEqual(window.frame.size, NSSize(width: 800, height: 500))
    }

    func testProgrammaticFrameSupersedesPendingNativeResize() {
        let (host, web) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paint: (@MainActor @Sendable () -> Void)?
        var commits = 0
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paint = callback }, deadline: { _, _ in }) { _, _ in commits += 1 }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        let requested = NSRect(x: 20, y: 30, width: 700, height: 450)
        window.setFrame(requested, display: false)
        paint?()
        XCTAssertEqual(commits, 0)
        XCTAssertEqual(window.frame, requested)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertFalse(resize.isPreparing)
    }

    func testProgrammaticFrameSupersedesScheduledContinuation() async throws {
        let (host, _) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paints: [@MainActor @Sendable () -> Void] = []
        var commits = 0
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }) { frame, display in
                commits += 1
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), display: true))
        paints.removeFirst()()
        let newer = NSRect(x: 20, y: 30, width: 700, height: 450)
        window.setFrame(newer, display: false)
        let drained = XCTestExpectation(description: "Scheduled handoff inspected")
        RunLoop.main.perform(inModes: [.common]) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(paints.isEmpty, "Do not prepare the stale queued drag")
        paints.forEach { $0() }
        XCTAssertEqual(commits, 1)
        XCTAssertEqual(window.frame, newer)
        XCTAssertFalse(resize.isPreparing)
    }

    func testShrinkUsesNativeClippingInsteadOfPreparingSmallerPixelsInALargerWindow() async throws {
        let (host, web) = fixture()
        let window = modelWindow(host)
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paints: [@MainActor @Sendable () -> Void] = []
        var commits: [NSSize] = []
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }) { frame, display in
                commits.append(frame.size)
                window.setFrame(frame, display: display)
            }
        let smaller = NSRect(x: 0, y: 0, width: 500, height: 300)
        XCTAssertFalse(resize.request(frame: smaller, display: true))
        XCTAssertTrue(paints.isEmpty, "Let AppKit clip the old page before asking WebKit to shrink")
        resize.cancel()

        // A reversal queued behind a growth must use the same native shrink path.
        paints.removeAll()
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
        XCTAssertTrue(resize.request(frame: smaller, display: true))
        paints.removeFirst()()
        let drained = XCTestExpectation(description: "Queued reversal handled")
        RunLoop.main.perform(inModes: [.common]) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(paints.isEmpty, "Do not expose smaller content in the still-larger window")
        XCTAssertEqual(commits, [NSSize(width: 800, height: 500), smaller.size])
        XCTAssertEqual(window.frame.size, smaller.size)
        XCTAssertEqual(web.frame.size, host.bounds.size)
        XCTAssertTrue(web.autoresizesSubviews)
        XCTAssertFalse(resize.isPreparing)
        resize.cancel()
    }

    func testReplacedRootRejectsPaintAndTimeoutCommits() {
        for useTimeout in [false, true] {
            let (host, web) = fixture()
            let window = modelWindow(host)
            defer { window.contentView = nil; host.removePage(); window.close() }
            var paint: (@MainActor @Sendable () -> Void)?
            var timeout: (@MainActor @Sendable () -> Void)?
            var commits = 0
            let resize = WindowResizePreparation(window: window,
                presenter: { _, callback in paint = callback }, deadline: { _, callback in timeout = callback }) { _, _ in commits += 1 }
            let original = window.frame
            XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 800, height: 500), display: true))
            window.contentView = NSView(frame: host.frame)
            if useTimeout { timeout?() } else { paint?() }
            XCTAssertEqual(commits, 0, "A retired presentation cannot resize its replacement")
            XCTAssertEqual(window.frame, original)
            XCTAssertFalse(resize.isPreparing)
            XCTAssertTrue(web.autoresizesSubviews)
            XCTAssertEqual(web.autoresizingMask, [.width, .height])
        }
    }

    private func modelWindow(_ host: NSView) -> ResizeModelWindow {
        let window = ResizeModelWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                       styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }
}

/// Simulates only admission values for deterministic queue tests. Never ordered in.
private final class ResizeModelWindow: NSWindow {
    override var isVisible: Bool { true }
    override var inLiveResize: Bool { true }
}
