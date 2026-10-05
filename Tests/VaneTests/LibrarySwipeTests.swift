import AppKit
import XCTest
@testable import vane

@MainActor final class LibrarySwipeTests: XCTestCase {
    private func fixture() -> (TabStore, LibraryScrollWindow, LibrarySwipeMonitor) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = UUID()
        let store = TabStore(profileID: profile,
                             space: Space(name: "Library swipe", profileID: profile), session: [])
        let window = LibraryScrollWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                         styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        store.libraryOpen = true
        let monitor = LibrarySwipeMonitor()
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            store.window = nil
            window.close()
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
        }
        return (store, window, monitor)
    }

    private func send(_ window: NSWindow, point: NSPoint = NSPoint(x: 100, y: 350),
                      dx: CGFloat = 0, dy: CGFloat = 0, phase: NSEvent.Phase = .changed,
                      momentum: NSEvent.Phase = [], precise: Bool = true, inverted: Bool = true) {
        NSApplication.shared.sendEvent(LibraryScrollEvent(window: window, point: point,
            dx: dx, dy: dy, phase: phase, momentum: momentum, precise: precise, inverted: inverted))
    }

    func testLeftSwipeClosesLibraryAcrossWindowWithSidebarHidden() {
        let (store, window, _) = fixture()
        store.sidebarShown = false
        for point in [NSPoint(x: 20, y: 350), NSPoint(x: 250, y: 350),
                      NSPoint(x: 800, y: 350), NSPoint(x: 450, y: 696)] {
            store.libraryOpen = true
            send(window, point: point, phase: .began)
            send(window, point: point, dx: -120)
            XCTAssertTrue(store.libraryOpen, "Wait for fingers-up")
            send(window, point: point, phase: .ended)
            XCTAssertFalse(store.libraryOpen, "Close from anywhere in the window: \(point)")
            XCTAssertFalse(store.spaceSwiping)
            XCTAssertEqual(store.spaceDrag, 0)
        }
    }

    func testPhysicalLeftSwipeClosesWithEitherNaturalScrollingPreference() {
        let (store, window, _) = fixture()
        // AppKit's device direction is positive for left; Natural Scrolling inverts it.
        for (inverted, leftDelta) in [(true, CGFloat(-120)), (false, CGFloat(120))] {
            store.libraryOpen = true
            send(window, phase: .began, inverted: inverted)
            send(window, dx: leftDelta, inverted: inverted)
            send(window, phase: .ended, inverted: inverted)
            XCTAssertFalse(store.libraryOpen, "Physical left closes regardless of Natural Scrolling")
            store.libraryOpen = true
            send(window, phase: .began, inverted: inverted)
            send(window, dx: -leftDelta, inverted: inverted)
            send(window, phase: .ended, inverted: inverted)
            XCTAssertTrue(store.libraryOpen, "Physical right never closes Library")
        }
    }

    func testVerticalScrollLocksOutLaterHorizontalDrift() {
        let (store, window, _) = fixture()
        send(window, phase: .began)
        send(window, dx: -1, dy: 20)
        send(window, dx: -200)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 4)
    }

    func testReverseShortCancelledAndReturnedSwipesKeepLibraryOpen() {
        let (store, window, _) = fixture()
        for (out, back, end) in [(CGFloat(120), CGFloat(0), NSEvent.Phase.ended),
                                 (-15, 0, .ended), (-120, 0, .cancelled),
                                 (-120, 115, .ended)] {
            send(window, phase: .began)
            send(window, dx: out)
            send(window, dx: back)
            send(window, phase: end)
            XCTAssertTrue(store.libraryOpen)
        }
    }

    func testMomentumCannotDismissReopenedLibraryOrReachThePage() {
        let (store, window, _) = fixture()
        send(window, phase: .began)
        send(window, dx: -120)
        send(window, phase: .ended)
        XCTAssertFalse(store.libraryOpen)
        let scrolls = window.scrolls
        store.libraryOpen = true
        send(window, dx: -300, phase: [], momentum: .began)
        send(window, dx: -300, phase: [], momentum: .changed)
        send(window, phase: [], momentum: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, scrolls, "The claimed gesture's tail must not navigate the page")
    }

    func testClosedLibraryMouseWheelAndOtherWindowKeepTheirEvents() {
        let (store, window, _) = fixture()
        store.libraryOpen = false
        send(window, dx: -120, phase: .began)
        send(window, phase: .ended)
        store.libraryOpen = true
        send(window, dx: -120, phase: [], precise: false)
        send(window, dx: -120, phase: [], precise: true)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(window.scrolls, 4)
        let other = LibraryScrollWindow(contentRect: window.frame, styleMask: .borderless,
                                        backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        send(other, phase: .began)
        send(other, dx: -120)
        send(other, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        XCTAssertEqual(other.scrolls, 3)
    }

    func testInterruptedGestureAndRemovedMonitorDoNotDismissLibrary() {
        let (store, window, monitor) = fixture()
        send(window, phase: .began)
        send(window, dx: -120)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
        send(window, phase: .began)
        send(window, dx: -120)
        monitor.remove()
        send(window, phase: .ended)
        XCTAssertTrue(store.libraryOpen)
    }
}

private final class LibraryScrollWindow: NSWindow {
    var scrolls = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { scrolls += 1 }
        else { super.sendEvent(event) }
    }
}

private final class LibraryScrollEvent: NSEvent, @unchecked Sendable {
    private let target: NSWindow
    private let targetNumber: Int
    private let point: NSPoint
    private let dx: CGFloat
    private let dy: CGFloat
    private let scrollPhase: NSEvent.Phase
    private let momentum: NSEvent.Phase
    private let precise: Bool
    private let inverted: Bool

    @MainActor init(window: NSWindow, point: NSPoint, dx: CGFloat, dy: CGFloat,
                    phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, inverted: Bool) {
        target = window
        targetNumber = window.windowNumber
        self.point = point
        self.dx = dx
        self.dy = dy
        scrollPhase = phase
        self.momentum = momentum
        self.precise = precise
        self.inverted = inverted
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { 1 }
}
