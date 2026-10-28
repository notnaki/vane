import AppKit
import SwiftUI
import XCTest
@testable import vane

private final class ToastPresentationHostingView: NSHostingView<AnyView> {
    // XCTest can remain inactive while native events still exercise the real control.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class ToastPresentationTests: XCTestCase {
    func testHiddenSidebarShowsActionableToastInsidePage() async throws {
        try await assertHiddenSidebarToast(savingBattery: true)
    }

    func testHiddenSidebarShowsActionableToastWithMotion() async throws {
        try await assertHiddenSidebarToast(savingBattery: false)
    }

    private func assertHiddenSidebarToast(savingBattery: Bool) async throws {
        let (store, window, host) = fixture(savingBattery: savingBattery)
        store.sidebarShown = false
        store.sidebarPeeking = false
        try await settle(host, for: .milliseconds(350))
        let before = try pageCornerPixels(host)
        var actions = 0
        Toasts.show("Archived regression fixture with a long title", action: ("Undo", { actions += 1 }), in: store)
        try await settle(host, for: .milliseconds(350))
        XCTAssertNotEqual(try pageCornerPixels(host), before,
                          "Hiding the sidebar must leave its toast visible in the page corner")
        XCTAssertEqual(actions, 0)
        XCTAssertFalse(store.sidebarShown)
        try await clickAction("Undo", in: window)
        XCTAssertEqual(actions, 1, "The hidden-sidebar toast's native Undo must remain reachable")
        XCTAssertNil(Toasts.shared.current)
    }

    func testActiveToastKeepsItsActionAndHoverAcrossSidebarAndLibraryChanges() async throws {
        let (store, window, host) = fixture()
        var actions = 0
        Toasts.show("Saved transition fixture with a long title", action: ("Open", { actions += 1 }), in: store)
        let toast = try XCTUnwrap(Toasts.shared.current)
        Toasts.shared.hover(toast, true)
        for presentation in 0..<6 {
            switch presentation {
            case 0: store.sidebarShown = false
            case 1: store.sidebarPeeking = true
            case 2: store.sidebarShown = true
            case 3: store.libraryOpen = true
            case 4: store.libraryOpen = false; store.sidebarShown = false
            default: store.sidebarPeeking = true
            }
            try await settle(host)
            XCTAssertEqual(Toasts.shared.current?.id, toast.id)
            XCTAssertEqual(Toasts.shared.current?.actionGeneration, toast.actionGeneration)
            XCTAssertTrue(Toasts.shared.hovering.contains(toast.id),
                          "Moving the same pill must not run disappearance cleanup and restart its timer")
        }
        store.sidebarPeeking = false
        try await settle(host)
        try await clickAction("Open", in: window)
        try await clickAction("Open", in: window)
        XCTAssertEqual(actions, 1, "Only the live toast action may run, once")
        XCTAssertNil(Toasts.shared.current)
    }

    func testHiddenToastStaysInItsOwnerWindow() async throws {
        let (owner, _, ownerHost) = fixture()
        let (other, _, otherHost) = fixture()
        owner.sidebarShown = false
        other.sidebarShown = false
        try await settle(ownerHost)
        try await settle(otherHost)
        let ownerBefore = try pageCornerPixels(ownerHost)
        let otherBefore = try pageCornerPixels(otherHost)
        Toasts.show("Owned fixture", action: ("Undo", {}), in: owner)
        try await settle(ownerHost)
        try await settle(otherHost)
        XCTAssertNotEqual(try pageCornerPixels(ownerHost), ownerBefore)
        XCTAssertEqual(try pageCornerPixels(otherHost), otherBefore,
                       "Another private window must not display this window's notice")
    }

    func testNormalWindowRetainsHoveredToastAcrossTabChangesAndResizing() async throws {
        let (store, window, host) = fixture(isPrivate: false)
        store.sidebarShown = false
        let first = store.newBlankTab(focus: false)
        let second = store.newBlankTab(focus: false)
        store.current = second.id
        try await settle(host)
        var actions = 0
        Toasts.show("Normal window regression fixture with a long title", action: ("Open", { actions += 1 }), in: store)
        let toast = try XCTUnwrap(Toasts.shared.current)
        // Exercise retention while the action is held, independently of the ordinary
        // expiry clock and how long native tab materialization takes on this machine.
        Toasts.shared.hover(toast, true)
        store.current = first.id
        try await settle(host)
        XCTAssertEqual(store.current, first.id)
        XCTAssertEqual(Toasts.shared.current?.id, toast.id)
        XCTAssertEqual(Toasts.shared.current?.actionGeneration, toast.actionGeneration)
        XCTAssertTrue(Toasts.shared.hovering.contains(toast.id))
        store.current = second.id
        window.setContentSize(CGSize(width: 1100, height: 750))
        try await settle(host)
        XCTAssertEqual(store.current, second.id)
        XCTAssertEqual(Toasts.shared.current?.id, toast.id)
        XCTAssertEqual(Toasts.shared.current?.actionGeneration, toast.actionGeneration)
        XCTAssertTrue(Toasts.shared.hovering.contains(toast.id))
        try await clickAction("Open", in: window)
        try await clickAction("Open", in: window)
        XCTAssertEqual(actions, 1)
        XCTAssertNil(Toasts.shared.current)
    }

    func testHiddenToastLeavesRoomForDownloadFeedback() async throws {
        // Exercise placement independently of the 1.2s feedback expiry clock.
        // DownloadFeedbackTests covers notification admission and timed dismissal.
        let feedback = DownloadFeedback()
        let (store, window, host) = fixture(feedback: feedback)
        store.sidebarShown = false
        try await settle(host)
        var actions = 0
        Toasts.show("Download collision regression fixture with a long title", action: ("Open", { actions += 1 }), in: store)
        let toast = try XCTUnwrap(Toasts.shared.current)
        Toasts.shared.hover(toast, true)
        try await settle(host)
        try await clickAction("Open", in: window, bottom: 64)
        XCTAssertEqual(actions, 0, "The raised target must not hit the ordinary page-corner toast")
        XCTAssertEqual(Toasts.shared.current?.id, toast.id)
        let start = DownloadFeedback.Start(name: "report.pdf", profileID: Profile.incognito.id, window: window)
        feedback.receive(start, in: window, isPrivate: true, reduced: true)
        try await settle(host)
        XCTAssertTrue(feedback.start === start)
        XCTAssertEqual(Toasts.shared.current?.id, toast.id)
        // Reserve the 40pt download footprint and its 8pt gap above the usual
        // 16pt corner inset; the raised toast's real native action must work.
        try await clickAction("Open", in: window, bottom: 64)
        XCTAssertEqual(actions, 1, "The live action must sit above the download landing control")
    }

    private func clickAction(_ title: String, in window: NSWindow, bottom: CGFloat = 16) async throws {
        // These fixture messages force a full-width, one-row pill. Measure the actual
        // native label font as Feel09NativeInteractionTests does, then send real input.
        if ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] != nil,
           let view = window.contentView { _ = try SidebarSnapshot.pixels(in: view) }
        let label = ImageRenderer(content: Text(title).font(Look.Typography.shortcut.font).fixedSize())
        let actionWidth = try XCTUnwrap(label.nsImage).size.width + Look.inset
        let pillRight: CGFloat = 16 + 228 - 2 * Look.inset
        let dismissLeft = pillRight - Look.inset / 2 - Look.rowTarget
        let point = CGPoint(x: dismissLeft - Look.inset / 2 - actionWidth / 2,
                            y: bottom + Look.toastHeight / 2)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func fixture(savingBattery: Bool = true, isPrivate: Bool = true, feedback: DownloadFeedback? = nil)
        -> (TabStore, NSWindow, NSHostingView<AnyView>) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        saver.setMode(savingBattery ? .alwaysOn : .off)
        let previousWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = 228
        let toasts = Toasts.shared
        toasts.showing.forEach { toasts.dismiss($0) }
        let profileID = isPrivate ? Profile.incognito.id : UUID()
        let store = TabStore(isPrivate: isPrivate, profileID: profileID, session: [])
        store.palette = nil
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let content: AnyView
        if let feedback {
            content = AnyView(Color.clear
                .anchorPreference(key: ToastBounds.self, value: .bounds) { [.page: $0] }
                .modifier(ToastPresentation(store: store, sidebarWidth: SidebarWidth.shared.width))
                .environmentObject(feedback))
        } else { content = AnyView(BrowserWindow()) }
        let host = ToastPresentationHostingView(rootView: AnyView(content.environmentObject(store)
            .environmentObject(ProfileManager.shared)))
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            toasts.showing.forEach { toasts.dismiss($0) }
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
            if !isPrivate { Store.forget(profileID) }
            saver.setMode(previousMode)
            SidebarWidth.shared.width = previousWidth
        }
        return (store, window, host)
    }

    private func settle(_ host: NSView, for duration: Duration = .milliseconds(150)) async throws {
        try await Task.sleep(for: duration)
        host.layoutSubtreeIfNeeded()
    }

    private func pageCornerPixels(_ host: NSView) throws -> Data {
        let rect = CGRect(x: 8, y: host.isFlipped ? host.bounds.height - 120 : 8,
                          width: 320, height: 112)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
