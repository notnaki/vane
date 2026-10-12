import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SpaceSwipeLandingTests: XCTestCase {
    func testCommittedSwipeSwitchesPageAndAddressPromptlyAfterRelease() async throws {
        try await checkCommittedSwipe(saving: false)
    }

    func testBatterySaverKeepsCommittedSwipeAnimatedUntilThePreviewReachesRest() async throws {
        try await checkCommittedSwipe(saving: true)
    }

    func testSwipeIntoEmptySpaceDoesNotAnimateTheLiveSidebarAgain() async throws {
        try await checkCommittedSwipe(saving: false, empty: true)
    }

    func testClickIntoEmptySpaceDoesNotAnimateTheLiveSidebarAgain() async throws {
        try await checkCommittedSwipe(saving: false, empty: true, clicking: true)
    }

    private func checkCommittedSwipe(saving: Bool, empty: Bool = false, clicking: Bool = false) async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                      "Focus timing requires the animated landing path")
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(saving ? .alwaysOn : .off)
        defer { saver.setMode(previousMode) }
        let sidebar = SidebarWidth.shared
        let previousWidth = sidebar.width
        sidebar.width = 250
        defer { sidebar.width = previousWidth }
        let profile = ProfileManager.shared.create(name: "Landing fixture").id
        let first = Space(name: "First", profileID: profile)
        let second = Space(name: "Second", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: profile))
        let store = TabStore(profileID: profile, space: first, session: [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let monitor = SwipeMonitor()
        defer {
            monitor.abort()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            _ = ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        store.switchTo(space: second)
        var remembered: vane.Tab?
        if !empty {
            let other = store.newBlankTab(focus: false)
            other.park(url: URL(string: "https://other.example/")!, Parked(title: "Other"))
            let selected = store.newBlankTab(focus: false)
            selected.park(url: URL(string: "https://remembered.example/")!, Parked(title: "Remembered"))
            store.current = selected.id
            remembered = selected
        }
        store.switchTo(space: first)
        store.palette = nil
        let position = LandingPosition(target: second.id)
        window.contentView = NSHostingView(rootView: LandingStrip(store: store, position: position).vaneMotionPolicy())
        var handoffOffset: CGFloat?
        let observation = store.$currentSpaceID.sink { id in
            if id == second.id { handoffOffset = position.offset }
        }
        defer { observation.cancel() }
        window.orderFront(nil)
        if !clicking {
            store.spaceSwiping = true
            store.spaceDrag = -90
        }
        // Mount the actual sliding modifier before measuring its completion.
        try await Task.sleep(for: .milliseconds(50))

        let start = ProcessInfo.processInfo.systemUptime
        if clicking { monitor.select(second, in: store) }
        else { monitor.land(1, to: second, width: 250, store: store) }
        while store.currentSpaceID != second.id,
              ProcessInfo.processInfo.systemUptime - start < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("COMMITTED_SPACE_FOCUS_SECONDS: \(elapsed)")
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertEqual(store.current, remembered?.id)
        // Allow several frames for scheduling and disk work while rejecting the old
        // 160 ms response, which delayed the page and address by roughly 190 ms.
        XCTAssertLessThan(elapsed, clicking ? 0.4 : 1.0 / 6, "The page and address must switch promptly after release")
        XCTAssertTrue(store.active === remembered)
        if !empty { XCTAssertEqual(store.active?.currentURL, URL(string: "https://remembered.example/")) }
        XCTAssertEqual(store.spaceDrag, 0)
        print("HANDOFF_PRESENTATION_OFFSET: \(handoffOffset ?? 0)")
        XCTAssertEqual(try XCTUnwrap(handoffOffset), -250, accuracy: 0.125,
                       "The ghost must reach its endpoint before the live sidebar replaces it")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(position.handoffAnimations.isEmpty, "Observe the incoming live sidebar")
        XCTAssertTrue(position.handoffAnimations.allSatisfy { !$0 },
                      "The live sidebar must replace the landed preview without another animation")
    }
}

private struct LandingStrip: View {
    @ObservedObject var store: TabStore
    @ObservedObject private var gesture: SpaceGesture
    let position: LandingPosition

    init(store: TabStore, position: LandingPosition) {
        self.store = store
        gesture = store.spaceGesture
        self.position = position
    }

    var body: some View {
        SpaceSidebarStrip(store: store, favorites: EmptyView(),
                          sections: Text(store.currentSpaceID?.uuidString ?? "Empty")
                            .transaction { transaction in
                                if store.currentSpaceID == position.target {
                                    position.handoffAnimations.append(transaction.animation != nil)
                                }
                            })
            .frame(width: 250, height: 300)
            // Sample the landing's presentation value, rather than its model endpoint.
            .background {
                Color.clear.frame(width: 1, height: 1)
                    .modifier(LandingPositionProbe(offset: gesture.drag, position: position))
            }
            // Match BrowserWindow's palette animation when an empty Space opens Cmd+T.
            .animation(Motion.reduced ? nil : Look.appear, value: store.palette == nil)
    }
}

@MainActor private final class LandingPosition {
    var offset: CGFloat = 0
    let target: UUID
    var handoffAnimations: [Bool] = []
    init(target: UUID) { self.target = target }
}

private struct LandingPositionProbe: AnimatableModifier {
    var offset: CGFloat
    let position: LandingPosition
    nonisolated var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }
    func body(content: Content) -> some View {
        position.offset = offset
        return content.offset(x: offset)
    }
}
