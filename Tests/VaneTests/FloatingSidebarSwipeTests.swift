import AppKit
import XCTest
@testable import vane

@MainActor final class FloatingSidebarSwipeTests: XCTestCase {
    private func fixture() -> (TabStore, VaneWindow, SwipeMonitor) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let profile = ProfileManager.shared.active.id
        let space = Space(name: "Swipe", profileID: profile)
        let oldSpaces = ProfileManager.shared.spaces(for: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: space.profileID))
        let store = TabStore(profileID: space.profileID, space: space, session: [])
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        store.sidebarShown = false
        window.peekingSidebar = true
        let monitor = SwipeMonitor()
        monitor.install(store)
        addTeardownBlock { @MainActor in
            monitor.remove()
            store.window = nil
            window.close()
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(store.profileID)
            XCTAssertTrue(ProfileManager.shared.saveSpaces(oldSpaces, for: profile))
        }
        return (store, window, monitor)
    }

    private func send(_ window: NSWindow, at point: NSPoint = NSPoint(x: 100, y: 350),
                      dx: CGFloat = -40, dy: CGFloat = 0, phase: NSEvent.Phase = .changed) {
        NSApplication.shared.sendEvent(SidebarScrollEvent(window: window, point: point,
                                                          dx: dx, dy: dy, phase: phase))
    }

    func testHorizontalSwipeMovesFloatingSidebarWhileDockedSidebarIsHidden() {
        let (store, window, _) = fixture()
        send(window)
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertLessThan(store.spaceDrag, 0)
    }

    func testFloatingSwipeIncludesInsetTrailingEdgeButLeavesPageAndGapsAlone() {
        let (store, window, monitor) = fixture()
        let width = SidebarWidth.shared.width
        send(window, at: NSPoint(x: width + 4, y: 350))
        XCTAssertTrue(store.spaceSwiping, "The floating panel extends past the docked sidebar's edge")
        monitor.abort()
        for point in [NSPoint(x: 4, y: 350), NSPoint(x: width + 20, y: 350),
                      NSPoint(x: 100, y: 4), NSPoint(x: 100, y: 696)] {
            send(window, at: point, phase: .began)
            XCTAssertFalse(store.spaceSwiping, "Page and outer gaps must retain their scroll events: \(point)")
        }
    }

    func testVerticalScrollingDoesNotBecomeASpaceSwipe() {
        let (store, window, _) = fixture()
        send(window, dx: 1, dy: 20, phase: .began)
        send(window, dx: -60, dy: 1)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testHiddenSidebarAndLibraryDoNotClaimSwipesButPaletteAllowsThem() {
        let (store, window, _) = fixture()
        window.peekingSidebar = false
        send(window, phase: .began)
        XCTAssertFalse(store.spaceSwiping)
        window.peekingSidebar = true
        store.libraryOpen = true
        send(window, phase: .began)
        XCTAssertFalse(store.spaceSwiping)
        store.libraryOpen = false
        store.palette = .newTab
        send(window, phase: .began)
        XCTAssertTrue(store.spaceSwiping, "Cmd+T keeps sidebar swipes available")
    }

    func testDockedSidebarStillClaimsSwipesAndRemovalResetsFloatingDrag() {
        let (store, window, monitor) = fixture()
        store.sidebarShown = true
        window.peekingSidebar = false
        send(window, at: NSPoint(x: 4, y: 350))
        XCTAssertTrue(store.spaceSwiping)
        monitor.abort()
        store.sidebarShown = false
        window.peekingSidebar = true
        send(window, phase: .began)
        XCTAssertTrue(store.spaceSwiping)
        monitor.remove()
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertEqual(store.spacePull, 0)
    }
}

/// Native event payload at the AppKit boundary; all gesture classification and state
/// changes run through the installed production monitor.
private final class SidebarScrollEvent: NSEvent, @unchecked Sendable {
    private let target: NSWindow
    private let targetNumber: Int
    private let point: NSPoint
    private let dx: CGFloat
    private let dy: CGFloat
    private let scrollPhase: NSEvent.Phase

    @MainActor init(window: NSWindow, point: NSPoint, dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase) {
        target = window
        targetNumber = window.windowNumber
        self.point = point
        self.dx = dx
        self.dy = dy
        scrollPhase = phase
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { targetNumber }
    override var locationInWindow: NSPoint { point }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { scrollPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var timestamp: TimeInterval { 1 }
}
