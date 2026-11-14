import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LivePageResizeBufferTests: XCTestCase {
    private final class ModelWindow: NSWindow {
        var admittedVisible = true
        override var isVisible: Bool { admittedVisible }
        var fixtureBackingScale: CGFloat?
        override var backingScaleFactor: CGFloat { fixtureBackingScale ?? super.backingScaleFactor }
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
        let frameDriver: LivePageResizeBuffer.FrameDriver?
        lazy var buffer = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
            presenter: { [unowned self] _, callback in paints.append(callback) },
            deadline: { [unowned self] interval, callback in
                XCTAssertEqual(interval, 0.25)
                deadlines.append(callback)
            }, now: { [unowned self] in time }, frameDriver: frameDriver, apply: { [unowned self] frame, _ in
                commits.append(frame.size)
                window.setFrame(frame, display: false)
            }, completion: { [unowned self] in completions += 1 })!

        init(frameDriver: LivePageResizeBuffer.FrameDriver? = nil) {
            self.frameDriver = frameDriver
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

    func testExactLibraryInstalledShrinkSupersedesOlderPendingPaint() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadlines: [@MainActor @Sendable () -> Void] = []
        var installedLeading: CGFloat = 100
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) },
            deadline: { _, callback in deadlines.append(callback) },
            navigation: .init(owner: owner, leading: 100, exactRequests: true,
                              layoutLeading: { installedLeading }), apply: { _, _ in }))
        defer { buffer.cancel() }
        buffer.start()
        let oldPaint = nextPaint(&paints)
        let oldDeadline = try XCTUnwrap(deadlines.last)
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 200))
        XCTAssertEqual(f.web.frame.width, 600, "Do not trim before native layout installs the smaller clip")
        installedLeading = 200
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 200))
        XCTAssertEqual(f.web.frame.width, 600, "The marker alone cannot certify the old child geometry")
        f.host.setFrameSize(NSSize(width: 500, height: 400))
        XCTAssertEqual(f.web.frame.width, 500, "An installed covered shrink must not wait for the obsolete larger paint")
        XCTAssertTrue(buffer.isPreparing, "Native sizing is not a paint acknowledgment")
        oldPaint(); oldDeadline()
        XCTAssertEqual(f.web.frame.width, 500)
        XCTAssertTrue(buffer.isPreparing, "Old paint and deadline cannot acknowledge or retire the new viewport")
        XCTAssertEqual(f.web.autoresizingMask, [])
        nextPaint(&paints)()
        XCTAssertFalse(buffer.isPreparing)
        buffer.finish()
        XCTAssertEqual(f.web.frame.width, 500)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testExactLibraryGrowthPublishesPaintedProgressWhileNewerInputWaits() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        var paints: [@MainActor @Sendable () -> Void] = []
        var accepted: [CGFloat] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 100, exactRequests: true), apply: { _, leading in
                guard let leading else { return }
                accepted.append(leading)
                f.host.setFrameSize(NSSize(width: 700 - leading, height: 400))
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 90))
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 80))
        XCTAssertTrue(accepted.isEmpty, "Growth must wait for its own paint")
        nextPaint(&paints)()
        XCTAssertEqual(accepted, [90], "An acknowledged viewport must advance the clip even when newer growth is pending")
        XCTAssertEqual(f.host.bounds.width, 610)
        XCTAssertTrue(buffer.isPreparing)
        // Reverse past the in-flight 620pt viewport. Its late acknowledgment
        // must not pull the clip back toward the obsolete expansion request.
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 95))
        nextPaint(&paints)()
        XCTAssertEqual(accepted.last, 95)
        XCTAssertFalse(accepted.contains(80), "Obsolete painted growth must not reverse the current input")
    }

    func testExactLibrarySplitWaitsForNativeLayoutBeforeUsingRoundedWidth() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        f.host.resizeFraction.width = 0.5
        let secondWeb = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let second = WebHost(secondWeb)
        second.setFrameSize(NSSize(width: 600, height: 400))
        second.resizeFraction.width = 0.5
        second.libraryNavigationPaintOwner = owner
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
        f.host.removeFromSuperview()
        root.addSubview(f.host)
        root.addSubview(second)
        second.setFrameOrigin(NSPoint(x: 600, y: 0))
        f.window.setContentSize(root.frame.size)
        f.window.contentView = root
        defer { second.removePage(); second.removeFromSuperview() }
        var paints: [@MainActor @Sendable () -> Void] = []
        var installedLeading: CGFloat = 100
        var submitted: [CGFloat] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 100, exactRequests: true, layoutLeading: { installedLeading }), apply: { _, leading in
                if let leading { submitted.append(leading) }
                // SwiftUI has accepted the phase but has not laid out its host.
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)(); nextPaint(&paints)()
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 101))
        XCTAssertTrue(buffer.isPreparing, "The old parent being within one pixel is not a native acknowledgment")
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 103))
        XCTAssertEqual(submitted, [101, 103])
        XCTAssertTrue(paints.isEmpty, "Do not trim the document before its actual parent moves")
        // Logical598.5/598.5 is distributed as599/598 by native layout.
        installedLeading = 103
        f.host.setFrameSize(NSSize(width: 599, height: 400))
        XCTAssertTrue(buffer.isPreparing, "One resized pane cannot acknowledge the entire split")
        second.setFrameSize(NSSize(width: 598, height: 400))
        XCTAssertEqual(f.web.frame.width, 599, "Prepare the viewport actually installed by native layout")
        XCTAssertEqual(secondWeb.frame.width, 598)
        XCTAssertEqual(paints.count, 2)
        nextPaint(&paints)(); nextPaint(&paints)()
        XCTAssertFalse(buffer.isPreparing)
        buffer.finish()
        XCTAssertEqual(f.web.frame.size, f.host.bounds.size)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testExactLibraryRejectsAnOlderNativeLayoutWithinOnePixelOfTheNewRequest() throws {
        let f = Fixture(); defer { f.close() }
        f.window.fixtureBackingScale = 1
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        var paints: [@MainActor @Sendable () -> Void] = []
        var installedLeading: CGFloat = 100
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 100, exactRequests: true, layoutLeading: { installedLeading }), apply: { _, _ in }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 101))
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 102))
        installedLeading = 101
        f.host.setFrameSize(NSSize(width: 599, height: 400))
        if !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertTrue(buffer.isPreparing, "The delayed101 layout must not acknowledge request102 merely because it is one pixel away")
        XCTAssertEqual(f.web.autoresizingMask, [])
        installedLeading = 102
        XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 102))
        if !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertTrue(buffer.isPreparing, "The page marker arriving before its child must not certify the child's old width")
        f.host.setFrameSize(NSSize(width: 598, height: 400))
        nextPaint(&paints)()
        XCTAssertFalse(buffer.isPreparing)
        buffer.finish()
        XCTAssertEqual(f.web.frame.size, f.host.bounds.size)
    }

    func testShrinkingLibraryViewportDoesNotRetainAWholeResponsiveColumnOutsideTheCard() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            now: { f.time }, navigation: .init(owner: owner, leading: 0), apply: { _, leading in
                if let leading { f.host.setFrameSize(NSSize(width: 600 - leading, height: 400)) }
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        for width in stride(from: 598, through: 450, by: -2) {
            f.time += 1.0 / 60
            XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: CGFloat(600 - width)))
            if !paints.isEmpty { nextPaint(&paints)() }
            XCTAssertGreaterThanOrEqual(f.web.frame.width, f.host.bounds.width)
            XCTAssertLessThanOrEqual(f.web.frame.width - f.host.bounds.width, 48.001,
                "Library shrinking must follow the visible responsive width")
        }
    }

    func testLibraryFinishSupersedesObsoleteLookaheadWithoutAcceptingItsCallback() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        var paints: [@MainActor @Sendable () -> Void] = []
        var deadlines: [@MainActor @Sendable () -> Void] = []
        var completions = 0
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) },
            deadline: { _, callback in deadlines.append(callback) },
            navigation: .init(owner: owner, leading: 228), apply: { _, _ in },
            completion: { completions += 1 }))
        defer { buffer.cancel() }
        buffer.start()
        let obsoletePaint = nextPaint(&paints)
        let obsoleteDeadline = try XCTUnwrap(deadlines.first)
        XCTAssertGreaterThan(f.web.frame.width, f.host.bounds.width)
        buffer.finish()
        XCTAssertEqual(f.web.frame.size, f.host.bounds.size,
                       "An already covered installed clip must replace obsolete lookahead immediately")
        XCTAssertEqual(paints.count, 1, "Exact geometry needs its own presentation acknowledgement")
        XCTAssertTrue(buffer.isPreparing)
        obsoletePaint()
        obsoleteDeadline()
        XCTAssertEqual(completions, 0, "An obsolete callback or deadline cannot acknowledge the exact replacement")
        XCTAssertTrue(buffer.isPreparing)
        guard paints.count == 1 else { return }
        nextPaint(&paints)()
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(buffer.isPreparing)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        obsoletePaint(); obsoleteDeadline()
        XCTAssertEqual(completions, 1)
    }

    func testNativeWindowResizeRetiresPendingLibraryViewportBeforeCapturingSizing() throws {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        let originalMask = f.web.autoresizingMask
        var libraryPaints: [@MainActor @Sendable () -> Void] = []
        var retired = false
        let library = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in libraryPaints.append(callback) }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 228), apply: { _, _ in }, completion: { retired = true }))
        defer { library.cancel() }
        library.start()
        let stalePaint = nextPaint(&libraryPaints)
        XCTAssertEqual(f.web.autoresizingMask, [])
        let resize = f.buffer
        XCTAssertTrue(retired, "Retire the old viewport owner before capturing its temporarily frozen flags")
        resize.start()
        stalePaint()
        XCTAssertTrue(f.host.clipsToBounds)
        f.request(620)
        for _ in 0..<4 where f.commits.isEmpty { nextPaint(&f.paints)() }
        resize.finish()
        for _ in 0..<4 where f.completions == 0 { nextPaint(&f.paints)() }
        XCTAssertEqual(f.completions, 1)
        XCTAssertEqual(f.web.bounds.width, 620, accuracy: 1)
        XCTAssertEqual(f.web.autoresizingMask, originalMask, "Interruption must not permanently freeze the document")
    }

    func testLibraryPreparationDoesNotStealAnActiveNativeResizeViewport() {
        let f = Fixture(); defer { f.close() }
        let owner = UUID()
        f.host.libraryNavigationPaintOwner = owner
        f.buffer.start()
        let library = LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, _ in }, deadline: { _, _ in },
            navigation: .init(owner: owner, leading: 228), apply: { _, _ in })
        XCTAssertNil(library, "Navigation waits for the native pointer resize instead of copying its frozen flags")
        XCTAssertEqual(f.completions, 0)
        XCTAssertTrue(f.buffer.isPreparing)
    }

    func testWindowPublicationsCoalesceAtDisplayFramesAndStillRequirePaint() {
        var frame: (@MainActor () -> Void)?
        let f = Fixture(frameDriver: { frame = $0; return {} }); defer { f.close() }
        f.buffer.start()
        f.request(610)
        frame?()
        XCTAssertTrue(f.commits.isEmpty, "A display tick must not bypass the paint barrier")
        nextPaint(&f.paints)()
        XCTAssertTrue(f.commits.isEmpty, "Paint admits coverage, not a second publication clock")
        f.request(614)
        f.request(618)
        XCTAssertTrue(f.commits.isEmpty)
        frame?()
        XCTAssertEqual(f.commits, [NSSize(width: 618, height: 400)])
        f.request(620)
        f.request(622)
        XCTAssertEqual(f.commits.count, 1)
        frame?()
        XCTAssertEqual(f.commits.map(\.width), [618, 622])
        frame?()
        XCTAssertEqual(f.commits.count, 2, "An idle frame must not dirty the unchanged window")
    }

    func testWindowPublicationReleaseDrainsWithoutAnotherDisplayTick() {
        var frame: (@MainActor () -> Void)?
        var stops = 0
        let f = Fixture(frameDriver: { frame = $0; return { stops += 1 } }); defer { f.close() }
        f.buffer.start()
        nextPaint(&f.paints)()
        f.request(620)
        XCTAssertTrue(f.commits.isEmpty)
        f.buffer.finish()
        XCTAssertEqual(f.commits.map(\.width), [620])
        XCTAssertEqual(stops, 1)
        // A velocity-driven refill may already be in flight at release; its
        // callback must be followed by exact endpoint paint before retirement.
        for _ in 0..<3 where f.completions == 0 { nextPaint(&f.paints)() }
        XCTAssertEqual(f.completions, 1)
        frame?()
        XCTAssertEqual(f.commits.count, 1)
        XCTAssertEqual(stops, 1)
    }

    func testCancelledWindowPublicationCannotPublishFromALateFrame() {
        var frame: (@MainActor () -> Void)?
        var stops = 0
        let f = Fixture(frameDriver: { frame = $0; return { stops += 1 } }); defer { f.close() }
        f.buffer.start()
        nextPaint(&f.paints)()
        f.request(620)
        f.buffer.cancel()
        frame?()
        XCTAssertTrue(f.commits.isEmpty)
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(f.window.frame.width, 600)
    }

    func testWindowFrameRevalidatesOwnershipBeforePublishing() {
        var frame: (@MainActor () -> Void)?
        var stops = 0
        let f = Fixture(frameDriver: { frame = $0; return { stops += 1 } }); defer { f.close() }
        f.buffer.start()
        nextPaint(&f.paints)()
        f.request(620)
        f.window.contentView = NSView(frame: f.host.frame)
        frame?()
        XCTAssertTrue(f.commits.isEmpty)
        XCTAssertEqual(stops, 1)
    }

    func testWindowWatchdogStopsFrameClockAndRetainsImmediateNativeFallback() {
        var frame: (@MainActor () -> Void)?
        var stops = 0
        let f = Fixture(frameDriver: { frame = $0; return { stops += 1 } }); defer { f.close() }
        f.buffer.start()
        f.request(620)
        f.deadlines.removeFirst()()
        XCTAssertEqual(f.commits.map(\.width), [620])
        XCTAssertEqual(stops, 1)
        f.request(624)
        XCTAssertEqual(f.commits.map(\.width), [620, 624])
        frame?()
        XCTAssertEqual(f.commits.count, 2)
        nextPaint(&f.paints)()
        XCTAssertEqual(stops, 1)
    }

    func testUnchangedInitialProposalDoesNotRepublishTheAlreadyVisibleWindow() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        f.request(600)
        XCTAssertTrue(f.commits.isEmpty, "The baseline is already installed; do not schedule a redundant display during initial paint")
        f.request(620)
        XCTAssertTrue(f.commits.isEmpty, "Growth still requires newly painted coverage")
        nextPaint(&f.paints)()
        XCTAssertEqual(f.commits, [NSSize(width: 620, height: 400)])
    }

    func testStyleReplyProtectsPendingPaintFromTheSupersededDeadline() async throws {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        let originalDeadline = try XCTUnwrap(f.deadlines.first)
        try await compatibilityWait { f.deadlines.count == 2 }
        f.request(640)
        originalDeadline()
        XCTAssertFalse(f.buffer.bypassForDrag)
        XCTAssertEqual(f.window.frame.width, 600, "An acknowledged style operation still does not authorize unpainted growth")
        XCTAssertTrue(f.web.autoresizingMask.isEmpty)
        try XCTUnwrap(f.deadlines.last)()
        XCTAssertTrue(f.buffer.bypassForDrag, "The subsequent paint phase remains bounded")
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testOverdueStyleReplyCannotRenewAnUndeliveredInitialDeadline() async throws {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        f.request(640)
        f.time = 1
        try await compatibilityWait { f.buffer.bypassForDrag }
        XCTAssertEqual(f.deadlines.count, 1, "An overdue reply cannot grant another paint budget")
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testPreviousGenerationStyleReplyCannotRenewTheCurrentPaint() async throws {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        nextPaint(&f.paints)()
        f.request(640)
        XCTAssertEqual(f.deadlines.count, 2)
        try await compatibilityWait { f.deadlines.count == 3 }
        XCTAssertEqual(f.window.frame.width, 640)
        f.deadlines[0]()
        f.deadlines[1]()
        XCTAssertFalse(f.buffer.bypassForDrag)
        XCTAssertTrue(f.web.autoresizingMask.isEmpty)
        f.deadlines[2]()
        XCTAssertTrue(f.buffer.bypassForDrag)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

#if DEBUG
    func testDiagnosticTimelineCorrelatesTimedOutPrimeWithLateCallbackAndRetirement() throws {
        let fixture = Fixture()
        let trace = ResizePaintTrace(label: "timeout-model")
        trace.install()
        defer { fixture.close(); trace.stop() }
        fixture.buffer.start()
        let paint = nextPaint(&fixture.paints)
        let prepared = try XCTUnwrap(trace.snapshot().entries.first { $0.event == "buffer.prepare.after" })
        XCTAssertEqual(prepared.fields["hasPresentedViewport"], "false")
        XCTAssertNotEqual(prepared.fields["page.0.prepared"], prepared.fields["page.0.painted"])
        fixture.request(640)
        try XCTUnwrap(fixture.deadlines.first)()
        XCTAssertTrue(fixture.buffer.bypassForDrag)
        paint()
        XCTAssertFalse(fixture.buffer.bypassForDrag)
        XCTAssertEqual(fixture.completions, 1)
        let entries = trace.snapshot().entries.filter { $0.channel == "state" }
        let timeout = try XCTUnwrap(entries.first { $0.event == "buffer.timeout" })
        let arrival = try XCTUnwrap(entries.first { $0.event == "buffer.presentation.arrived" })
        XCTAssertEqual(timeout.fields["generation"], prepared.fields["generation"])
        XCTAssertEqual(arrival.fields["callbackGeneration"], prepared.fields["generation"])
        XCTAssertNotEqual(arrival.fields["generation"], arrival.fields["callbackGeneration"])
        XCTAssertEqual(arrival.fields["callbackPage"], prepared.fields["page.0.id"])
        XCTAssertEqual(arrival.fields["bypass"], "true")
        let retired = try XCTUnwrap(entries.first { $0.event == "buffer.bypass.retired" })
        XCTAssertEqual(retired.fields["bypass"], "false")
        XCTAssertGreaterThanOrEqual(retired.time, arrival.time)
        XCTAssertEqual(entries.last?.event, "buffer.completion.returned")
    }
#endif

    private func baselineSnapshot(_ changes: [String: Any] = [:]) throws -> ResizeMotionBaselineSnapshot {
        var values: [String: Any] = ["visibilityState": "visible", "readyState": "complete", "appReady": true, "active": true, "sheetAdopted": true, "sheetDisabled": false,
            "targetWidth": 661.5, "targetHeight": 578.5, "innerWidth": 662, "innerHeight": 579,
            "documentWidth": 662, "customProperties": 300, "nativeWidth": 661.5,
            "nativeHeight": 578.5, "pageZoom": 1,
            "safeAreaTop": 0, "safeAreaLeft": 0, "safeAreaBottom": 0, "safeAreaRight": 0]
        values.merge(changes) { _, next in next }
        return try JSONDecoder().decode(ResizeMotionBaselineSnapshot.self, from: JSONSerialization.data(withJSONObject: values))
    }

    func testBaselineAdmissionRejectsThePagesUncommittedInitialRender() throws {
        XCTAssertFalse(try baselineSnapshot(["appReady": false]).isReady,
                       "A complete document can still be waiting for its application render")
        XCTAssertTrue(try baselineSnapshot().isReady)
    }

    func testBaselineAdmissionRejectsHiddenOrLoadingDocument() throws {
        XCTAssertFalse(try baselineSnapshot(["visibilityState": "hidden"]).isReady)
        XCTAssertFalse(try baselineSnapshot(["readyState": "loading"]).isReady)
        XCTAssertFalse(try baselineSnapshot(["readyState": "interactive"]).isReady)
        XCTAssertTrue(try baselineSnapshot().isReady)
    }

    func testBaselineAdmissionMapsActualTwentyOnePointInsetAndZoom() throws {
        XCTAssertTrue(try baselineSnapshot(["nativeWidth": 661, "nativeHeight": 578,
            "safeAreaTop": 21, "targetWidth": 661, "targetHeight": 557,
            "innerWidth": 661, "innerHeight": 557]).isReady)
        XCTAssertTrue(try baselineSnapshot(["nativeWidth": 661, "nativeHeight": 578, "pageZoom": 1.5,
            "safeAreaTop": 21, "safeAreaLeft": 3, "safeAreaBottom": 4, "safeAreaRight": 5,
            "targetWidth": 435.3333333333333, "targetHeight": 368.6666666666667,
            "innerWidth": 435, "innerHeight": 369]).isReady)
        XCTAssertFalse(try baselineSnapshot(["nativeHeight": 578.5, "safeAreaTop": 21]).isReady,
                       "A native-sized hint remains stale when CSS excludes its public inset")
    }

    func testTopAnchorHandlesFlippedCoordinatesAndNonzeroParentBounds() {
        let original = NSRect(x: 15, y: 25, width: 560, height: 340)
        let parent = NSRect(x: 5, y: 7, width: 600, height: 400)
        let next = NSRect(x: 8, y: 11, width: 650, height: 450)
        let size = NSSize(width: 608, height: 388)
        for flipped in [false, true] {
            let anchor = LivePageResizeAnchor(originalFrame: original, originalParentBounds: parent, flipped: flipped)
            XCTAssertEqual(anchor.frame(for: original.size, in: parent), original)
            XCTAssertEqual(anchor.frame(for: size, in: next),
                           NSRect(x: 18, y: flipped ? 29 : 31, width: 608, height: 388))
        }
    }

    func testBufferKeepsTheOriginalTopGapDuringPreparationOwnedPublishAndCancellation() throws {
        let f = Fixture(); defer { f.close() }
        f.web.frame = NSRect(x: 13, y: 17, width: 560, height: 340)
        let topGap = f.host.bounds.maxY - f.web.frame.maxY
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 1),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }, now: { f.time },
            apply: { frame, _ in
                f.window.setFrame(frame, display: false)
                XCTAssertEqual(f.host.bounds.maxY - f.web.frame.maxY, topGap,
                               "Host callbacks must reanchor even inside the owned native publication")
            }))
        defer { buffer.cancel() }
        buffer.start()
        XCTAssertEqual(f.web.frame, NSRect(x: 13, y: -31, width: 608, height: 388))
        nextPaint(&paints)()
        f.time += 1.0 / 60
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: 620, height: 420)))
        XCTAssertEqual(f.host.bounds.maxY - f.web.frame.maxY, topGap)
        buffer.cancel()
        XCTAssertEqual(f.web.frame, NSRect(x: 13, y: 17, width: 580, height: 360))
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertTrue(f.web.autoresizesSubviews)
        paints.forEach { $0() }
        XCTAssertEqual(f.web.frame, NSRect(x: 13, y: 17, width: 580, height: 360))
    }

    func testUnshownTitledWindowPrimePreparesNativeChildrenAndBothCSSAxesBehindHostClip() async throws {
        TestEnvironment.prepare()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let host = WebHost(web)
        host.frame = NSRect(x: 233, y: 11, width: 661, height: 578)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.addSubview(host)
        let window = ModelWindow(contentRect: root.bounds, styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { web.stopLoading(); window.contentView = nil; host.removePage(); window.close() }
        let variables = (0..<160).map { "--inset-fixture-\($0):\($0)px;" }.joined()
        web.loadHTMLString("<html><title>Frozen inset ready</title><style>:root{\(variables)}body{margin:0}</style><body>Local inset fixture</body></html>", baseURL: nil)
        try await compatibilityWait { !web.isLoading && web.title == "Frozen inset ready" }
        root.layoutSubtreeIfNeeded()
        let originalFrame = web.frame
        let originalMask = web.autoresizingMask
        let originalAuto = web.autoresizesSubviews
        let originalClip = host.clipsToBounds
        let originalParent = host.bounds
        let child = try XCTUnwrap(web.subviews.first)
        let originalChild = child.frame.size
        let inset = web.safeAreaInsets
        XCTAssertGreaterThan(inset.top, 0, "The unshown titled host must exercise a real nonzero public inset")
        let baselineHeight = Double(web.bounds.height - inset.top - inset.bottom)
        let baselineWidth = Double(web.bounds.width - inset.left - inset.right)
        try await compatibilityWait {
            let height = try await web.evaluateJavaScript("innerHeight") as? NSNumber
            return abs((height?.doubleValue ?? 0) - baselineHeight) <= 1
        }
        XCTAssertFalse(window.occlusionState.contains(.visible), "This local HTML regression must never order its window in")
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 1),
            deadline: { _, _ in }, apply: { _, _ in }))
        defer { buffer.cancel() }
        buffer.start()
        XCTAssertEqual(web.frame.maxY, originalFrame.maxY)
        XCTAssertEqual(web.frame.minY, originalFrame.minY - 48)
        XCTAssertEqual(child.frame.width, originalChild.width + 48,
                       "Native WebKit child geometry must be prepared before the presentation callback")
        XCTAssertEqual(child.frame.height, originalChild.height + 48)
        XCTAssertEqual(host.bounds, originalParent)
        XCTAssertTrue(host.clipsToBounds)
        XCTAssertEqual(web.autoresizesSubviews, originalAuto)
        XCTAssertLessThanOrEqual(web.visibleRect.width, host.bounds.width)
        XCTAssertLessThanOrEqual(web.visibleRect.height, host.bounds.height)
        try await compatibilityWait { !buffer.isPreparing }
        let primedValue = try await web.evaluateJavaScript("innerHeight")
        let primedHeight = try XCTUnwrap(primedValue as? NSNumber).doubleValue
        XCTAssertEqual(primedHeight, baselineHeight + 48, accuracy: 1,
                       "Frozen vertical lookahead must enlarge CSS height rather than enter the titlebar")
        let primedWidthValue = try await web.evaluateJavaScript("innerWidth")
        let primedWidth = try XCTUnwrap(primedWidthValue as? NSNumber).doubleValue
        XCTAssertEqual(primedWidth, baselineWidth + 48, accuracy: 1)
        let hintJSON: String = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("JSON.stringify({height:globalThis.__vaneResizeStyle?.height??null})", in: nil, in: PageResizeStyle.world) { result in
                continuation.resume(with: result.map { $0 as? String ?? "{}" })
            }
        }
        let hints = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(hintJSON.utf8)) as? [String: Any])
        XCTAssertEqual((hints["height"] as? NSNumber)?.doubleValue ?? -1, primedHeight, accuracy: 1)
        XCTAssertEqual(web.safeAreaInsets.top, inset.top)
        buffer.finish()
        try await compatibilityWait { !buffer.isPreparing }
        XCTAssertEqual(web.frame, originalFrame)
        XCTAssertEqual(web.autoresizingMask, originalMask)
        XCTAssertEqual(web.autoresizesSubviews, originalAuto)
        XCTAssertEqual(host.clipsToBounds, originalClip)
        XCTAssertEqual(child.frame.size, originalChild)
        let finalValue = try await web.evaluateJavaScript("innerHeight")
        let finalHeight = try XCTUnwrap(finalValue as? NSNumber).doubleValue
        XCTAssertEqual(finalHeight, baselineHeight, accuracy: 1)
        let finalWidthValue = try await web.evaluateJavaScript("innerWidth")
        XCTAssertEqual(try XCTUnwrap(finalWidthValue as? NSNumber).doubleValue, baselineWidth, accuracy: 1)
        XCTAssertEqual(web.pageZoom, 1)
    }

    func testUnshownNativeChildLayoutPreparesBothCSSAxesBehindFixedHostClip() async throws {
        TestEnvironment.prepare()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let host = WebHost(web)
        host.frame = NSRect(x: 233, y: 11, width: 661, height: 578)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.addSubview(host)
        let window = ModelWindow(contentRect: root.bounds, styleMask: [.titled, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { web.stopLoading(); window.contentView = nil; host.removePage(); window.close() }
        let variables = (0..<160).map { "--native-clip-fixture-\($0):\($0)px;" }.joined()
        web.loadHTMLString("<html><title>Native clip ready</title><style>:root{\(variables)}body{margin:0}</style><body>Native child layout</body></html>", baseURL: nil)
        try await compatibilityWait { !web.isLoading && web.title == "Native clip ready" }
        root.layoutSubtreeIfNeeded()
        let original = web.frame
        let mask = web.autoresizingMask
        let auto = web.autoresizesSubviews
        let clip = host.clipsToBounds
        let parent = host.bounds
        let inset = web.safeAreaInsets
        let child = try XCTUnwrap(web.subviews.first)
        let childSize = child.frame.size
        let cssWidth = web.bounds.width - inset.left - inset.right
        let cssHeight = web.bounds.height - inset.top - inset.bottom
        XCTAssertTrue(auto, "This probe must exercise ordinary native WebKit child sizing")
        XCTAssertGreaterThan(inset.top, 0)
        XCTAssertFalse(window.occlusionState.contains(.visible))
        let anchor = LivePageResizeAnchor(originalFrame: original, originalParentBounds: parent, flipped: host.isFlipped)
        web.autoresizingMask = []
        host.clipsToBounds = true
        let next = NSSize(width: original.width + 48, height: original.height + 48)
        web.frame = anchor.frame(for: next, in: parent)
        PageResizeStyle.prepare(web, nextSize: next)
        web.prepareContent(in: web.bounds)
        XCTAssertEqual(child.frame.width, childSize.width + 48)
        XCTAssertEqual(child.frame.height, childSize.height + 48)
        XCTAssertEqual(host.bounds, parent, "Native child preparation must leave the visible parent clip fixed")
        XCTAssertTrue(host.clipsToBounds)
        XCTAssertEqual(web.autoresizesSubviews, auto)
        XCTAssertEqual(web.safeAreaInsets.top, inset.top, "Lead must enlarge CSS height rather than cancel its public inset")
        try await compatibilityWait {
            let size = try await web.evaluateJavaScript("[innerWidth,innerHeight]") as? [NSNumber]
            return size?.count == 2 && abs(size![0].doubleValue - Double(cssWidth + 48)) <= 1
                && abs(size![1].doubleValue - Double(cssHeight + 48)) <= 1
        }
        web.frame = original
        web.autoresizingMask = mask
        host.clipsToBounds = clip
        PageResizeStyle.finish(web)
        XCTAssertEqual(child.frame.size, childSize)
        XCTAssertEqual(web.autoresizesSubviews, auto)
        XCTAssertEqual(web.pageZoom, 1)
    }

    func testBaselineAdmissionAllowsIntegerCSSViewportRounding() throws {
        XCTAssertTrue(try baselineSnapshot().isReady)
        XCTAssertTrue(try baselineSnapshot(["nativeWidth": 992.25, "nativeHeight": 867.75, "pageZoom": 1.5]).isReady)
    }

    func testBaselineAdmissionRejectsPendingNativeViewportAcknowledgement() throws {
        XCTAssertFalse(try baselineSnapshot(["innerHeight": 600]).isReady)
        XCTAssertFalse(try baselineSnapshot(["targetHeight": 600]).isReady)
        XCTAssertFalse(try baselineSnapshot(["targetWidth": NSNull()]).isReady)
    }

    func testBaselineAdmissionRequiresTheActiveAdoptedEnabledSheet() throws {
        for changes: [String: Any] in [["active": false], ["sheetAdopted": false], ["sheetDisabled": true]] {
            XCTAssertFalse(try baselineSnapshot(changes).isReady)
        }
    }

    func testBaselineAdmissionRequiresAnActualLaidOutDocument() throws {
        XCTAssertFalse(try baselineSnapshot(["documentWidth": 0]).isReady)
    }

    func testSynchronousPrimeRefillAndExactPresentationCompleteWithoutWatchdog() throws {
        let f = Fixture(); defer { f.close() }
        var paints = 0
        var completed = 0
        var released = 0
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints += 1; callback() }, deadline: { _, _ in },
            now: { f.time }, apply: { frame, _ in f.window.setFrame(frame, display: false) },
            completion: { completed += 1 }))
        defer { buffer.cancel() }
        buffer.start()
        XCTAssertFalse(buffer.isPreparing)
        f.time = 1.0 / 60
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: 720, height: 400)))
        XCTAssertEqual(f.window.frame.width, 720)
        buffer.finish { released += 1 }
        XCTAssertGreaterThanOrEqual(paints, 3)
        XCTAssertEqual(released, 1, "Synchronous exact presentation must drain the reentrant drive")
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(buffer.isPreparing)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertEqual(f.web.frame.width, 720)
    }

    func testInspectorSiblingRejectsAdmissionBeforeMutatingEitherWebView() {
        let f = Fixture(); defer { f.close() }
        let inspector = WKWebView(frame: NSRect(x: 300, y: 0, width: 300, height: 400), configuration: WKWebViewConfiguration())
        f.host.addSubview(inspector)
        defer { inspector.removeFromSuperview() }
        let pageFrame = f.web.frame
        let inspectorFrame = inspector.frame
        let inspectorMask = inspector.autoresizingMask
        let buffer = LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0), apply: { _, _ in })
        XCTAssertNil(buffer, "The unsupported docked inspector arrangement must fall back atomically")
        XCTAssertEqual(f.web.frame, pageFrame)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertTrue(f.web.autoresizesSubviews)
        XCTAssertEqual(inspector.frame, inspectorFrame)
        XCTAssertEqual(inspector.autoresizingMask, inspectorMask)
        XCTAssertTrue(inspector.autoresizesSubviews)
        buffer?.cancel()
    }

    func testFixedNativeAxisDoesNotRefillForeverOrWaitForAnUnrelatedParentDelta() throws {
        let f = Fixture(); defer { f.close() }
        f.web.autoresizingMask = [.height]
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in },
            apply: { frame, _ in f.window.setFrame(frame, display: false) }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        XCTAssertTrue(paints.isEmpty, "A fixed native axis has no lookahead to refill")
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: 700, height: 400)))
        var released = false
        buffer.finish { released = true }
        for _ in 0..<3 where !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertTrue(released)
        XCTAssertEqual(f.web.frame.width, 600)
        XCTAssertEqual(f.host.bounds.width, 700)
        XCTAssertEqual(f.web.autoresizingMask, [.height])
    }

    func testOriginalPageToParentDifferenceSurvivesExactRelease() throws {
        let f = Fixture(); defer { f.close() }
        f.web.setFrameSize(NSSize(width: 400, height: 300))
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }, apply: { _, _ in }))
        defer { buffer.cancel() }
        buffer.start()
        XCTAssertEqual(f.web.frame.size, NSSize(width: 448, height: 300))
        nextPaint(&paints)()
        var released = false
        buffer.finish { released = true }
        for _ in 0..<3 where !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertTrue(released)
        XCTAssertTrue(paints.isEmpty, "An unchanged endpoint cannot repeatedly prepare the raw larger parent")
        XCTAssertEqual(f.web.frame.size, NSSize(width: 400, height: 300))
        XCTAssertEqual(f.host.bounds.size, NSSize(width: 600, height: 400))
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testDestinationShowCancelsOldBufferBeforeAssigningItsGeometry() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        let destination = WebHost(nil)
        destination.setFrameSize(NSSize(width: 320, height: 250))
        defer { destination.removePage() }
        destination.show(f.web)
        XCTAssertTrue(f.web.superview === destination)
        XCTAssertEqual(f.web.frame, destination.bounds)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertTrue(f.web.autoresizesSubviews)
        XCTAssertFalse(f.buffer.isPreparing)
        XCTAssertEqual(f.completions, 1)
        nextPaint(&f.paints)()
        XCTAssertEqual(f.web.frame, destination.bounds, "The old paint cannot replace destination geometry")
    }

    func testIdleRootOrPageRemovalRestoresNativeSizingWithoutAnotherPaint() {
        for change in 0..<3 {
            let f = Fixture(); defer { f.close() }
            f.buffer.start(); nextPaint(&f.paints)()
            XCTAssertTrue(f.paints.isEmpty)
            XCTAssertEqual(f.web.autoresizingMask, [])
            if change == 0 { f.host.removePage() }
            else if change == 1 { f.window.contentView = NSView(frame: f.host.frame) }
            else { f.host.isHidden = true }
            XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
            XCTAssertTrue(f.web.autoresizesSubviews)
            XCTAssertEqual(f.completions, 1)
        }
    }

    func testIdleWindowHideOrProgrammaticFrameChangeRestoresNativeSizing() {
        for hide in [false, true] {
            let f = Fixture(); defer { f.close() }
            f.buffer.start(); nextPaint(&f.paints)()
            XCTAssertTrue(f.paints.isEmpty)
            if hide {
                f.window.admittedVisible = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: f.window)
            } else {
                f.window.setFrame(NSRect(x: 0, y: 0, width: 700, height: 400), display: false)
                NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: f.window)
            }
            XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
            XCTAssertTrue(f.web.autoresizesSubviews)
            XCTAssertEqual(f.completions, 1)
        }
    }

    @MainActor private final class LayoutProbe: NSView {
        var calls = 0
        var onLayout: (() -> Void)?
        override func layout() {
            calls += 1
            onLayout?()
            super.layout()
        }
    }

    func testCoveredSidebarRequestsCoalesceDescendantLayoutUntilExactRelease() throws {
        try coalescedSidebarRelease(widths: [226, 224, 222], synchronous: false)
    }

    func testCoveredShrinkingSidebarReleaseReconcilesDeferredHostBeforeExactPaint() throws {
        try coalescedSidebarRelease(widths: [230, 232, 234], synchronous: false)
    }

    func testCoveredShrinkingSidebarReleaseBoundsSynchronousPresentations() throws {
        try coalescedSidebarRelease(widths: [230, 232, 234], synchronous: true)
    }

    func testCoveredShrinkingReleaseWaitsForNativeParentOrWatchdogWithoutRepainting() throws {
        for deliverParent in [false, true] {
            let f = Fixture(); defer { f.close() }
            f.host.resizeLayout.sidebarWidth = 228
            var presentations = 0
            var deadlines: [@MainActor @Sendable () -> Void] = []
            let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
                presenter: { _, callback in
                    presentations += 1
                    guard presentations <= 8 else { XCTFail("A deferred native parent cannot trigger a synchronous paint loop"); return }
                    callback()
                }, deadline: { interval, callback in
                    XCTAssertEqual(interval, 0.25)
                    deadlines.append(callback)
                }, now: { f.time }, apply: { _, width in
                    if let width { f.host.resizeLayout.sidebarWidth = width }
                }))
            defer { buffer.cancel() }
            buffer.start()
            f.time += 1.0 / 60
            XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: 234))
            var releases = 0
            buffer.finish { releases += 1 }
            XCTAssertTrue(buffer.isPreparing)
            XCTAssertEqual(presentations, 1, "Wait for the deferred host instead of repeatedly painting its stale600pt extent")
            XCTAssertEqual(releases, 0)
            // A completed prime's old paint deadline cannot expire the separate
            // release-layout wait. That phase owns its own bounded deadline.
            deadlines.first?()
            XCTAssertEqual(releases, 0)
            if deliverParent {
                f.host.setFrameSize(NSSize(width: 594, height: 400))
                XCTAssertEqual(f.web.frame.width, 594)
                XCTAssertEqual(presentations, 2)
            } else { deadlines.last?() }
            XCTAssertEqual(releases, 1)
            XCTAssertFalse(buffer.isPreparing)
            XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
            XCTAssertTrue(f.web.autoresizesSubviews)
            deadlines.forEach { $0() }
            XCTAssertEqual(releases, 1)
        }
    }

    private func coalescedSidebarRelease(widths: [CGFloat], synchronous: Bool) throws {
        let f = Fixture(); defer { f.close() }
        let root = NSView(frame: f.host.frame)
        let probe = LayoutProbe(frame: root.bounds)
        f.window.contentView = nil
        root.addSubview(f.host); root.addSubview(probe)
        f.window.contentView = root
        f.host.resizeLayout.sidebarWidth = 228
        var pendingWidth: CGFloat = 228
        probe.onLayout = { f.host.setFrameSize(NSSize(width: 600 + 228 - pendingWidth, height: 400)) }
        root.layoutSubtreeIfNeeded()
        var paints: [@MainActor @Sendable () -> Void] = []
        var presentationCount = 0
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in
                presentationCount += 1
                guard presentationCount <= 8 else {
                    XCTFail("Release must not spin preparing against a stale larger parent")
                    return
                }
                if synchronous { callback() } else { paints.append(callback) }
            }, deadline: { _, _ in }, now: { f.time },
            apply: { _, width in
                if let width {
                    pendingWidth = width
                    f.host.resizeLayout.sidebarWidth = width
                    probe.needsLayout = true
                }
            }))
        defer { buffer.cancel() }
        buffer.start()
        if !synchronous { nextPaint(&paints)() }
        let initialLayouts = probe.calls
        for width in widths {
            f.time += 1.0 / 60
            XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: width))
        }
        XCTAssertEqual(probe.calls, initialLayouts, "Pointer-rate publication must not recursively force retained sidebar descendants")
        var released = false
        buffer.finish { released = true }
        for _ in 0..<8 where !paints.isEmpty { nextPaint(&paints)() }
        XCTAssertTrue(released)
        XCTAssertLessThanOrEqual(presentationCount, 6, "A covered release needs an exact paint, not repeated stale-parent paints")
        XCTAssertTrue(paints.isEmpty)
        XCTAssertGreaterThan(probe.calls, initialLayouts, "The exact endpoint still needs its final native host flush")
        let expected = 600 + 228 - (try XCTUnwrap(widths.last))
        XCTAssertEqual(f.host.bounds.width, expected)
        XCTAssertEqual(f.web.bounds.width, expected)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
    }

    func testPrimingPreparesNativeChildrenBehindHostClipAndOnlyCoveredRequestsCommit() throws {
        let f = Fixture(); defer { f.close() }
        let child = try XCTUnwrap(f.web.subviews.first)
        let oldChild = child.frame.size
        let originalParent = f.host.bounds
        let originalAuto = f.web.autoresizesSubviews
        f.buffer.start()
        XCTAssertEqual(f.web.frame.width, 648)
        XCTAssertEqual(child.frame.width, oldChild.width + 48)
        XCTAssertEqual(child.frame.height, oldChild.height)
        XCTAssertEqual(f.host.bounds, originalParent)
        XCTAssertTrue(f.host.clipsToBounds)
        XCTAssertEqual(f.web.autoresizingMask, [])
        f.request(620)
        XCTAssertTrue(f.commits.isEmpty)
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 620)
        f.request(640)
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(f.paints.count, 1, "Refilling must run independently of covered pointer movement")
        XCTAssertEqual(f.web.autoresizesSubviews, originalAuto)
    }

    func testWindowDragDoesNotScheduleSidebarMetadataAcknowledgmentLayout() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start()
        f.host.layoutSubtreeIfNeeded()
        XCTAssertFalse(f.host.needsLayout, "Native layout must be clean before measuring added work")
        f.host.didUpdateResizeLayout()
        XCTAssertFalse(f.host.needsLayout,
            "Sidebar publication acknowledgment must not add native host layout work to a window drag")
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

    func testSlowSidebarShrinkReusesCoverageWithinTheAbsoluteLeadCeiling() throws {
        let f = Fixture(); defer { f.close() }
        f.host.resizeLayout.sidebarWidth = 228
        var paints: [@MainActor @Sendable () -> Void] = []
        var presentations = 0
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 0),
            presenter: { _, callback in presentations += 1; paints.append(callback) }, deadline: { _, _ in },
            now: { f.time }, apply: { _, sidebar in
                guard let sidebar else { return }
                f.host.resizeLayout.sidebarWidth = sidebar
                f.host.setFrameSize(NSSize(width: 828 - sidebar, height: 400))
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        for sidebar in stride(from: 230, through: 400, by: 2) {
            f.time += 1.0 / 60
            XCTAssertTrue(buffer.request(frame: f.window.frame, sidebarWidth: CGFloat(sidebar)))
            XCTAssertEqual(f.host.bounds.width, CGFloat(828 - sidebar), "Covered shrinking geometry must publish immediately")
            XCTAssertGreaterThanOrEqual(f.web.frame.width, f.host.bounds.width)
            XCTAssertLessThanOrEqual(f.web.frame.width - f.host.bounds.width, 192.001)
            if !paints.isEmpty { nextPaint(&paints)() }
            XCTAssertTrue(paints.isEmpty, "One completed shrink trim must not immediately schedule another")
        }
        XCTAssertEqual(presentations, 2, "The prime plus one bounded trim covers this172pt shrink; repainting each2pt step defeats buffering")
        buffer.finish()
        nextPaint(&paints)()
        XCTAssertEqual(f.web.frame.width, 428)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertFalse(buffer.isPreparing)
    }

    func testShrinkHysteresisStillRefillsGrowthAndBlocksReversalPastPendingTrim() {
        let f = Fixture(); defer { f.close() }
        f.buffer.start(); nextPaint(&f.paints)()
        f.time += 1
        f.request(456)
        XCTAssertEqual(f.window.frame.width, 456)
        XCTAssertEqual(f.web.frame.width, 648, "Retain the existing paint at exactly192pt excess")
        XCTAssertTrue(f.paints.isEmpty)
        f.time += 1
        f.request(454)
        XCTAssertEqual(f.window.frame.width, 454)
        XCTAssertEqual(f.web.frame.width, 502, "Crossing192pt must trim back to the48pt target")
        XCTAssertEqual(f.paints.count, 1)
        f.time += 1
        f.request(520)
        XCTAssertEqual(f.window.frame.width, 454, "The old648pt paint cannot cover a reversal beyond the pending502pt viewport")
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 454)
        XCTAssertEqual(f.web.frame.width, 568)
        nextPaint(&f.paints)()
        XCTAssertEqual(f.window.frame.width, 520)
        f.time += 1
        f.request(546)
        XCTAssertEqual(f.window.frame.width, 546)
        XCTAssertEqual(f.web.frame.width, 594, "Growth still refills once less than half the48pt target remains")
        XCTAssertEqual(f.paints.count, 1)
    }

    func testShrinkHysteresisCeilingScalesWithEachSplitAxis() throws {
        for horizontal in [true, false] { try splitShrinkHysteresis(horizontal: horizontal) }
    }

    private func splitShrinkHysteresis(horizontal: Bool) throws {
        let f = Fixture(); defer { f.close() }
        f.host.resizeFraction = NSSize(width: 0.5, height: 0.5)
        var paints: [@MainActor @Sendable () -> Void] = []
        let buffer = try XCTUnwrap(LivePageResizeBuffer(window: f.window, axes: NSSize(width: 1, height: 1),
            presenter: { _, callback in paints.append(callback) }, deadline: { _, _ in }, now: { f.time },
            apply: { frame, _ in
                f.window.setFrame(frame, display: false)
                f.host.setFrameSize(NSSize(width: 600 + (frame.width - 600) / 2,
                                          height: 400 + (frame.height - 400) / 2))
            }))
        defer { buffer.cancel() }
        buffer.start(); nextPaint(&paints)()
        f.time = 1
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0,
            width: horizontal ? 456 : 600, height: horizontal ? 400 : 256)))
        XCTAssertEqual(f.web.frame.size, NSSize(width: 624, height: 424))
        XCTAssertTrue(paints.isEmpty, "Each half-size pane may retain96pt, not just its24pt refill target")
        f.time = 2
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0,
            width: horizontal ? 454 : 600, height: horizontal ? 400 : 254)))
        XCTAssertEqual(f.web.frame.size, horizontal ? NSSize(width: 551, height: 424) : NSSize(width: 624, height: 351))
        XCTAssertEqual(paints.count, 1, "Trim when either pane-local axis exceeds its96pt ceiling")
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

    func testSplitHostClipsKeepVisibleGeometryCoveredUntilEveryIndependentPaintPresents() throws {
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
        XCTAssertEqual(leftChild.frame.width, 324)
        XCTAssertEqual(rightChild.frame.width, 324)
        XCTAssertTrue(f.host.clipsToBounds)
        XCTAssertTrue(right.clipsToBounds)
        XCTAssertTrue(buffer.request(frame: NSRect(x: 0, y: 0, width: 640, height: 400)))
        let first = try XCTUnwrap(paints.first)
        paints.removeFirst()
        first(); first()
        XCTAssertEqual(f.window.frame.width, 600)
        XCTAssertEqual(f.host.bounds.width, 300)
        XCTAssertEqual(right.bounds.width, 300)
        XCTAssertEqual(leftChild.frame.width, 324)
        XCTAssertEqual(rightChild.frame.width, 324)
        nextPaint(&paints)()
        XCTAssertEqual(f.window.frame.width, 640)
        XCTAssertEqual(f.host.bounds.width, 320)
        XCTAssertEqual(right.bounds.width, 320)
        XCTAssertEqual(leftChild.frame.width, f.web.frame.width)
        XCTAssertEqual(rightChild.frame.width, rightWeb.frame.width)
        XCTAssertGreaterThanOrEqual(leftChild.frame.width, f.host.bounds.width)
        XCTAssertGreaterThanOrEqual(rightChild.frame.width, right.bounds.width)
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

    func testOwnedHostClipAndOriginalChildSizingFlagsRestoreOnReleaseAndCancel() {
        for originalClip in [false, true] {
            for originalAuto in [false, true] {
                for release in [false, true] {
                    let f = Fixture(); defer { f.close() }
                    f.host.clipsToBounds = originalClip
                    f.web.autoresizesSubviews = originalAuto
                    let originalFrame = f.web.frame
                    f.buffer.start()
                    XCTAssertTrue(f.host.clipsToBounds)
                    XCTAssertEqual(f.web.autoresizesSubviews, originalAuto)
                    let preparedChildren = f.web.subviews.map(\.frame)
                    nextPaint(&f.paints)()
                    XCTAssertEqual(f.web.subviews.map(\.frame), preparedChildren,
                        "Acknowledging a presentation must not change native WebKit child drawing geometry")
                    if release {
                        f.buffer.finish()
                        XCTAssertEqual(f.web.frame, originalFrame, "Exact native geometry is prepared before its final paint")
                        XCTAssertTrue(f.host.clipsToBounds)
                        for _ in 0..<4 where !f.paints.isEmpty { nextPaint(&f.paints)() }
                    } else { f.buffer.cancel() }
                    XCTAssertEqual(f.completions, 1)
                    XCTAssertEqual(f.host.clipsToBounds, originalClip)
                    XCTAssertEqual(f.web.autoresizesSubviews, originalAuto)
                    XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
                    XCTAssertEqual(f.web.frame, originalFrame)
                }
            }
        }
    }

    func testMovedPageKeepsNewOwnerFlagsWhileOriginalHostClipRestores() {
        let f = Fixture(); defer { f.close() }
        f.host.clipsToBounds = false
        f.buffer.start()
        XCTAssertTrue(f.host.clipsToBounds)
        let newOwner = NSView(frame: NSRect(x: 0, y: 0, width: 333, height: 222))
        newOwner.clipsToBounds = true
        f.web.removeFromSuperview()
        newOwner.addSubview(f.web)
        f.web.frame = newOwner.bounds
        f.web.autoresizingMask = [.height]
        f.web.autoresizesSubviews = false
        nextPaint(&f.paints)()
        f.deadlines.forEach { $0() }
        XCTAssertFalse(f.host.clipsToBounds)
        XCTAssertTrue(newOwner.clipsToBounds)
        XCTAssertEqual(f.web.frame, newOwner.bounds)
        XCTAssertEqual(f.web.autoresizingMask, [.height])
        XCTAssertFalse(f.web.autoresizesSubviews)
        XCTAssertEqual(f.completions, 1)
    }

    func testSameHostReplacementSizingKeepsNewFrameMaskChildFlagAndClip() {
        let f = Fixture(); defer { f.close() }
        f.host.clipsToBounds = false
        f.buffer.start()
        let replacementFrame = NSRect(x: 11, y: 17, width: 333, height: 222)
        f.web.frame = replacementFrame
        f.web.autoresizingMask = [.height]
        f.web.autoresizesSubviews = false
        f.host.clipsToBounds = true
        nextPaint(&f.paints)()
        XCTAssertEqual(f.web.frame, replacementFrame)
        XCTAssertEqual(f.web.autoresizingMask, [.height])
        XCTAssertFalse(f.web.autoresizesSubviews)
        XCTAssertTrue(f.host.clipsToBounds)
        XCTAssertEqual(f.completions, 1)
    }

    func testExternallyChangedHostClipCancelsWithoutRestoringOverItsOwner() {
        let f = Fixture(); defer { f.close() }
        f.host.clipsToBounds = true
        f.buffer.start()
        f.host.clipsToBounds = false
        nextPaint(&f.paints)()
        XCTAssertEqual(f.completions, 1)
        XCTAssertFalse(f.host.clipsToBounds)
        XCTAssertEqual(f.web.autoresizingMask, [.width, .height])
        XCTAssertTrue(f.web.autoresizesSubviews)
    }

    func testTimedOutOwnersLatePaintCannotDisableTransferredPagesNewPreparation() async throws {
        let f = Fixture(); defer { f.close() }
        let variables = (0..<160).map { "--transfer-fixture-\($0):\($0)px;" }.joined()
        f.web.loadHTMLString("<html><title>Transfer ready</title><style>:root{\(variables)}</style></html>", baseURL: nil)
        defer { f.web.stopLoading() }
        try await compatibilityWait { !f.web.isLoading && f.web.title == "Transfer ready" }
        f.buffer.start()
        let oldPaint = nextPaint(&f.paints)
        f.request(640)
        try XCTUnwrap(f.deadlines.first)()
        XCTAssertTrue(f.buffer.bypassForDrag)

        f.host.removePage()
        let newOwner = WebHost(f.web)
        newOwner.setFrameSize(NSSize(width: 333, height: 222))
        let root = NSView(frame: f.window.contentView!.frame)
        root.addSubview(newOwner)
        f.window.contentView = root
        defer { newOwner.removePage() }
        PageResizeStyle.prepare(f.web)
        let state = "JSON.stringify([globalThis.__vaneResizeStyle.active,globalThis.__vaneResizeStyle.sheet.disabled,globalThis.__vaneResizeStyle.width])"
        func readState() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                f.web.evaluateJavaScript(state, in: nil, in: PageResizeStyle.world) { result in
                    continuation.resume(with: result.flatMap { value in
                        guard let value = value as? String else {
                            return .failure(NSError(domain: "TransferStyleState", code: 1))
                        }
                        return .success(value)
                    })
                }
            }
        }
        let prepared = try await readState()
        XCTAssertEqual(prepared, "[true,false,333]")
        oldPaint()
        let after = try await readState()
        XCTAssertEqual(after, "[true,false,333]", "Retiring the timed-out owner must leave the new owner's active hints intact")
        XCTAssertFalse(f.buffer.bypassForDrag)
        XCTAssertEqual(f.completions, 1)
        XCTAssertTrue(f.web.superview === newOwner)
        XCTAssertEqual(f.web.frame.size, NSSize(width: 333, height: 222))
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
