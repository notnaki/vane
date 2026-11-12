import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import vane

@MainActor final class NewTabDisclosureTests: XCTestCase {
    func testNewTabStaysBelowVisibleFolderChildrenDuringDisclosure() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do { try await checkDisclosure() } catch { failure = error }
        do { try await loop.close() } catch {
            if failure == nil { failure = error } else { XCTFail("Loop cleanup: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkDisclosure() async throws {
        let previousMode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        defer { BatterySaver.shared.setMode(previousMode) }
        try XCTSkipIf(Motion.spaceReduced, "Normal-motion regression requires Reduce Motion off")
        let store = TabStore(isPrivate: true, session: [])
        store.sharingReady = false
        let folder = Folder(name: "Pull Requests")
        let tabs = (0..<6).map { index in
            let tab = Tab(isPrivate: true, profileID: store.profileID)
            tab.kind = .pinned
            tab.park(url: URL(string: "about:blank#disclosure-\(index)")!, Parked(title: "Child \(index)"))
            return tab
        }
        store.tabs = tabs
        store.pins = Pins(entries: [.init(row: .folder(folder))] + tabs.map {
            .init(row: .tab($0.id.uuidString), parent: folder.id)
        })
        store.palette = nil
        let host = NSHostingView(rootView: SidebarSpaceSections().environmentObject(store)
            .environmentObject(ProfileManager.shared))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 250, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
        }
        func anchors(_ root: NSView) -> [TabTooltipAnchorView] {
            ((root as? TabTooltipAnchorView).map { [$0] } ?? []) + root.subviews.flatMap(anchors)
        }
        func display() {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        }
        try await compatibilityWait {
            display()
            return NSApp.isRunning && NSApp.isActive && window.isKeyWindow
                && window.occlusionState.contains(.visible)
                && anchors(host).contains { $0.title == "Child 5" && $0.bounds.width > 0 }
                && anchors(host).contains { $0.title == "New Tab" && $0.bounds.width > 0 }
        }
        let newTab = try XCTUnwrap(anchors(host).first { $0.title == "New Tab" })
        func rect(_ view: NSView) -> CGRect { view.convert(view.bounds, to: host) }
        func presentedRect(_ view: NSView) throws -> CGRect {
            var owner = view
            while owner.layer == nil, let parent = owner.superview { owner = parent }
            let source = try XCTUnwrap(owner.layer?.presentation(), "The visible row must have a presentation owner")
            let target = try XCTUnwrap(host.layer?.presentation(), "The visible sidebar must have a presentation owner")
            return source.convert(view.convert(view.bounds, to: owner), to: target)
        }
        // The outer hosting view is flipped: increasing y goes down the list.
        XCTAssertTrue(host.isFlipped)
        try await compatibilityWait {
            display()
            return host.layer?.presentation() != nil
        }
        XCTAssertEqual(try presentedRect(newTab).minY, rect(newTab).minY, accuracy: 1,
                       "Admit the resting presentation before starting disclosure")
        let start = rect(newTab).minY
        var samples: [(CGFloat, CGFloat)] = []
        var checkedMovingHit = false
        for frame in 0..<48 {
            if [0, 6, 12, 18].contains(frame) { Motion.list { store.pins.toggle(folder: folder.id) } }
            try await Task.sleep(for: .milliseconds(8))
            display()
            if let current = anchors(host).first(where: { $0.title == "Child 5" }) {
                samples.append((try presentedRect(current).maxY, try presentedRect(newTab).minY))
                if [9, 21].contains(frame), current.enabled {
                    XCTAssertEqual(try presentedRect(current).midY, rect(current).midY, accuracy: 1,
                                   "The native hit target must track the presented row during motion")
                    let point = current.convert(NSPoint(x: current.bounds.midX, y: current.bounds.midY), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
                    }
                    XCTAssertEqual(store.current, tabs[5].id, "A moving child must receive clicks at its visible position")
                    XCTAssertNil(store.palette, "The child hit must not open New Tab")
                    checkedMovingHit = true
                }
            }
        }
        print("NEW_TAB_DISCLOSURE start=\(start) samples=\(samples)")
        XCTAssertFalse(samples.isEmpty, "Closing children must remain visible while folding")
        XCTAssertTrue(checkedMovingHit, "The regression must exercise an opening row's hit target")
        XCTAssertTrue(samples.allSatisfy { $0.0 <= $0.1 + 1 },
                      "New Tab must stay below the closing strip, including intermediate frames: \(samples)")
        Motion.instant { store.pins.edit(folder: folder.id) { $0.collapsed = true } }
        try await compatibilityWait {
            display()
            return !anchors(host).contains { $0.title == "Child 5" }
                && abs(start - rect(newTab).minY - 6 * (Look.rowHeight + Look.rowGap)) < 1
        }
        XCTAssertEqual(start - rect(newTab).minY, 6 * (Look.rowHeight + Look.rowGap), accuracy: 1)
    }
}
