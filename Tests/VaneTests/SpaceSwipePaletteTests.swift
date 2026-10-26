import AppKit
import XCTest
@testable import vane

@MainActor final class SpaceSwipePaletteTests: XCTestCase {
    private func fixture() -> (TabStore, Space, ScrollWindow) {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Swipe palette fixture").id
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        let third = Space(name: "Third", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second, third], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        let window = ScrollWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        store.window = window
        store.sidebarShown = true
        store.libraryOpen = false
        store.palette = .newTab
        addTeardownBlock { @MainActor in
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            _ = ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (store, second, window)
    }

    func testOriginalAxisLockIgnoresSubpixelNoiseAndClaimsDeliberateTravel() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -0.2, dy: 0.1))
        XCTAssertFalse(store.spaceSwiping)
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 12))
        XCTAssertFalse(store.spaceSwiping)
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, -12)
    }

    func testOriginalAxisLockAcceptsHorizontalTravelAfterVerticalStartupNoise() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        for (dx, dy): (CGFloat, CGFloat) in [(0, 0.5), (0.1, 0.2), (-0.2, 0.1)] {
            NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: dx, dy: dy))
            XCTAssertFalse(store.spaceSwiping)
            NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -12))
            XCTAssertTrue(store.spaceSwiping, "Startup noise must not reject a deliberate horizontal drag")
            monitor.abort()
        }
    }

    func testSidebarSwipeIsClaimedWithNewTabPaletteOpen() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40))

        XCTAssertEqual(window.scrolls, 1, "Only the undecided opening frame reaches the window")
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertLessThan(store.spaceDrag, 0)
        XCTAssertEqual(store.palette, .newTab)
    }

    func testPaletteDoesNotLetSidebarMonitorTakeOtherScrolls() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        // A vertical scroll is locked to its original recipient, even if it later drifts sideways.
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 12))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40))
        XCTAssertFalse(store.spaceSwiping)
        // A horizontal gesture over the page/results remains with the palette.
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began, x: 800))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40, x: 800))
        XCTAssertFalse(store.spaceSwiping)
        // A rightward Library gesture must not become a Space swipe.
        store.libraryOpen = true
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: 40))
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        XCTAssertEqual(window.scrolls, 7, "Every non-Space gesture reaches its original recipient")
    }

    func testEnteringEmptySpaceKeepsAnOpenNewTabPalette() {
        let (store, second, _) = fixture()
        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertEqual(store.palette, .newTab)
    }

    func testSwipeHoldsBetweenSpacesUntilReleaseAndReplacementMonitorConsumesTheTail() async throws {
        let (store, second, window) = fixture()
        let first = try XCTUnwrap(store.spaces.first)
        store.switchTo(space: second)
        let page = store.newBlankTab(focus: false)
        page.park(url: URL(string: "https://swipe.example/")!, Parked(title: "Swipe destination"))
        store.current = page.id
        store.switchTo(space: first)
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -SidebarWidth.shared.width * 0.31))
        // Holding past the threshold must remain interactive until fingers-up.
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.currentSpaceID, first.id)
        XCTAssertTrue(store.spaceSwiping)
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertTrue(store.active === page)
        XCTAssertEqual(store.active?.currentURL, URL(string: "https://swipe.example/"))
        monitor.remove()
        // A profile hop remounts the monitor in this same window. It must not interpret
        // the remaining finger movement as the beginning of a second Space switch.
        let replacement = SwipeMonitor()
        replacement.install(store)
        defer { replacement.remove() }
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -SidebarWidth.shared.width))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -SidebarWidth.shared.width,
                                                   phase: [], momentum: .changed))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
        let scrolls = window.scrolls
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 20, precise: false))
        XCTAssertEqual(window.scrolls, scrolls + 1, "An ordinary mouse wheel remains available")
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: SidebarWidth.shared.width * 0.31))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(store.currentSpaceID, first.id, "A new gesture can switch back")
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .ended))
    }
}

/// Observe events after local monitors have had their turn. A second swallowing
/// monitor would depend on AppKit's unspecified ordering of multiple monitors.
private final class ScrollWindow: NSWindow {
    var scrolls = 0
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { scrolls += 1 }
        else { super.sendEvent(event) }
    }
}

/// Trackpad samples enter through AppKit's real local event monitors without moving
/// the user's cursor or requiring accessibility permissions.
final class ScrollEvent: NSEvent, @unchecked Sendable {
    private let owner: NSWindow
    private let ownerNumber: Int
    private let eventPhase: NSEvent.Phase
    private let dx: CGFloat
    private let dy: CGFloat
    private let x: CGFloat
    private let y: CGFloat
    private let momentum: NSEvent.Phase
    private let precise: Bool

    @MainActor init(window: NSWindow, dx: CGFloat = 0, dy: CGFloat = 0,
         phase: NSEvent.Phase = .changed, x: CGFloat = 30, y: CGFloat = 150,
         momentum: NSEvent.Phase = [], precise: Bool = true) {
        owner = window
        ownerNumber = window.windowNumber
        self.dx = dx
        self.dy = dy
        eventPhase = phase
        self.x = x
        self.y = y
        self.momentum = momentum
        self.precise = precise
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { owner }
    override var windowNumber: Int { ownerNumber }
    override var locationInWindow: NSPoint { NSPoint(x: x, y: y) }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { true }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { 1 }
}
