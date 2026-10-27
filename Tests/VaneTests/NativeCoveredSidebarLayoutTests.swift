import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class NativeCoveredSidebarLayoutTests: XCTestCase {
    func testNativeLandingKeepsTheCoveredLiveViewportAtRest() async throws {
        TestEnvironment.prepare()
        try XCTSkipIf(Motion.spaceReduced, "Requires a native landing")
        let manager = ProfileManager.shared
        let profile = manager.create(name: "Covered live layout")
        let spaces = ["Origin", "Destination"].map { manager.createSpace(name: $0, in: profile.id) }
        let store = TabStore(profileID: profile.id, space: spaces[0], session: [])
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1100, height: 800),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        let monitor = store.spaceGesture.monitor
        addTeardownBlock { @MainActor in
            monitor.remove()
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            manager.delete(profile.id)
        }
        for space in spaces {
            store.switchTo(space: space)
            store.tabs = (0..<32).map { index in
                let tab = Tab(profileID: profile.id)
                tab.park(url: URL(string: "about:blank#covered-\(index)")!,
                         Parked(title: "Covered row \(index)"))
                return tab
            }
            store.syncShapes()
        }
        store.switchTo(space: spaces[0]); store.palette = nil
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        monitor.install(store)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let live = try XCTUnwrap(host.subviews.first { !($0 is ProfileSpaceSlide) })
        let viewport = try XCTUnwrap(SidebarSectionsViewport.scrollView(in: live))
        func x(_ view: NSView) -> CGFloat {
            if let layer = view.layer, let root = host.layer {
                return layer.convert(CGPoint(x: view.bounds.minX, y: view.bounds.minY), to: root).x
            }
            return view.convert(view.bounds, to: host).minX
        }
        let atRest = x(viewport)
        let width = SidebarWidth.shared.width
        monitor.track(-80, width: width, in: store)
        monitor.land(1, to: spaces[1], width: width, store: store, duration: 1.5)
        try await compatibilityWait { store.currentSpaceID == spaces[1].id }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.spaceSlide?.isActive == true)
        XCTAssertTrue(SidebarSectionsViewport.scrollView(in: live) === viewport,
                      "Keep the live scroll shell mounted under the native cover")
        XCTAssertEqual(x(viewport), atRest, accuracy: 0.5,
                       "The native overlay owns travel; moving the covered live tree adds avoidable layout work")
    }
}
