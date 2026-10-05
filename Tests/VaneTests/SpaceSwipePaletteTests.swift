import AppKit
import XCTest
@testable import vane

@MainActor final class SpaceSwipePaletteTests: XCTestCase {
    private func fixture() -> (TabStore, Space, NSWindow) {
        TestEnvironment.prepare()
        let profile = UUID()
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
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
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (store, second, window)
    }

    func testSidebarSwipeIsClaimedWithNewTabPaletteOpen() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        var forwarded = 0
        let sink = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { _ in
            forwarded += 1
            return nil
        }!
        defer { NSEvent.removeMonitor(sink) }

        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40))

        XCTAssertEqual(forwarded, 1, "Only the undecided opening frame reaches the scroll view")
        XCTAssertTrue(store.spaceSwiping)
        XCTAssertLessThan(store.spaceDrag, 0)
        XCTAssertEqual(store.palette, .newTab)
    }

    func testPaletteDoesNotLetSidebarMonitorTakeOtherScrolls() {
        let (store, _, window) = fixture()
        let monitor = SwipeMonitor()
        monitor.install(store)
        defer { monitor.remove() }
        let sink = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { _ in nil }!
        defer { NSEvent.removeMonitor(sink) }

        // A vertical scroll is locked to its original recipient, even if it later drifts sideways.
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dy: 12))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40))
        XCTAssertFalse(store.spaceSwiping)
        // A horizontal gesture over the page/results remains with the palette.
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began, x: 800))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40, x: 800))
        XCTAssertFalse(store.spaceSwiping)
        // Library still owns its column's gestures.
        store.libraryOpen = true
        NSApplication.shared.sendEvent(ScrollEvent(window: window, phase: .began))
        NSApplication.shared.sendEvent(ScrollEvent(window: window, dx: -40))
        XCTAssertFalse(store.spaceSwiping)
        XCTAssertEqual(store.spaceDrag, 0)
    }

    func testEnteringEmptySpaceKeepsAnOpenNewTabPalette() {
        let (store, second, _) = fixture()
        store.switchTo(space: second)
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertEqual(store.palette, .newTab)
    }
}

/// Trackpad samples enter through AppKit's real local event monitors without moving
/// the user's cursor or requiring accessibility permissions.
private final class ScrollEvent: NSEvent, @unchecked Sendable {
    private let owner: NSWindow
    private let eventPhase: NSEvent.Phase
    private let dx: CGFloat
    private let dy: CGFloat
    private let x: CGFloat

    init(window: NSWindow, dx: CGFloat = 0, dy: CGFloat = 0,
         phase: NSEvent.Phase = .changed, x: CGFloat = 30) {
        owner = window
        self.dx = dx
        self.dy = dy
        eventPhase = phase
        self.x = x
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { owner }
    override var locationInWindow: NSPoint { NSPoint(x: x, y: 150) }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var timestamp: TimeInterval { 1 }
}
