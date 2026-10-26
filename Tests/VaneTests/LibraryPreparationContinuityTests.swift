import AppKit
import SwiftUI
import XCTest
@testable import vane

/// Guards the native preparation workload behind a real Library edge gesture.
/// This is a content/lifetime regression, not a displayed-frame-rate assertion.
@MainActor final class LibraryPreparationContinuityTests: XCTestCase {
    private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The real native presentation must reach its endpoint")
    }

    private func contentPhase(_ scroll: NSScrollView) throws -> CGPoint {
        let outer = try XCTUnwrap(scroll.layer?.presentation())
        let document = try XCTUnwrap(scroll.documentView?.layer?.presentation())
        return document.convert(.zero, to: outer)
    }

    func testScrolledLibraryRoundTripKeepsPopulatedNeighbourPrepared() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        try XCTSkipIf(Motion.spaceReduced, "Requires interactive Library presentation")
        let previousSaver = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.off)
        let previousWidth = SidebarWidth.shared.width
        SidebarWidth.shared.width = 250
        let manager = ProfileManager.shared
        let profile = manager.profiles[0]
        let savedSpaces = manager.spaces(for: profile.id)
        let favoriteKey = TabStore.defaultsKey(.favourite, profile.id)
        let savedFavorites = UserDefaults.vane.stringArray(forKey: favoriteKey)
        let lastSpaceKey = TabStore.lastSpaceKey(profile.id)
        let savedLastSpace = UserDefaults.vane.string(forKey: lastSpaceKey)
        let first = Space(name: "Library edge", profileID: profile.id)
        let next = Space(name: "Populated neighbour", profileID: profile.id)
        XCTAssertTrue(manager.saveSpaces([first, next], for: profile.id))
        let store = TabStore(profileID: profile.id, space: first, session: [])
        let previousSection = Library.shared.section
        let previousQuery = Library.shared.query
        let previousCompleted = Library.shared.completedOnly
        let previousLittleArc = Library.shared.littleArcOnly
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        store.window = window
        let host = BrowserWindowHost(shown: ShownStore(store))
        window.contentView = host
        let monitor = store.spaceGesture.monitor
        addTeardownBlock { @MainActor in
            monitor.remove()
            store.librarySwipeMonitor.remove()
            Library.open(previousSection, in: store)
            store.libraryOpen = false
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile.id)
            XCTAssertTrue(manager.saveSpaces(savedSpaces, for: profile.id))
            if let savedFavorites { UserDefaults.vane.set(savedFavorites, forKey: favoriteKey) }
            else { UserDefaults.vane.removeObject(forKey: favoriteKey) }
            if let savedLastSpace { UserDefaults.vane.set(savedLastSpace, forKey: lastSpaceKey) }
            else { UserDefaults.vane.removeObject(forKey: lastSpaceKey) }
            Library.shared.query = previousQuery
            Library.shared.completedOnly = previousCompleted
            Library.shared.littleArcOnly = previousLittleArc
            SidebarWidth.shared.width = previousWidth
            BatterySaver.shared.setMode(previousSaver)
        }
        // Keep the real next-Space workload. A single-Space edge cannot expose
        // repeated construction/layout of an adjacent prepared hosting tree.
        for space in [next, first] {
            store.switchTo(space: space)
            store.tabs = (0..<31).map { index in
                let tab = Tab(profileID: profile.id)
                tab.park(url: URL(string: "https://library-continuity.invalid/\(space.id)/\(index)")!,
                         Parked(title: "\(space.name) row \(index)"))
                return tab
            }
            store.current = nil
            store.syncShapes()
        }
        store.palette = nil
        store.sidebarShown = true
        Library.open(.downloads, in: store)
        store.libraryOpen = false
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        monitor.install(store)
        store.librarySwipeMonitor.install(store)
        XCTAssertEqual(store.strip.first?.id, first.id, "Library must own the actual first edge")
        XCTAssertEqual(store.strip.dropFirst().first?.id, next.id)
        XCTAssertEqual(store.swipePreview(in: next).rows.today.count, 31,
                       "The prepared neighbour must contain real row content")
        try await Task.sleep(for: .milliseconds(250))
        let candidates = descendants(host, NSScrollView.self).filter {
            let rect = $0.convert($0.bounds, to: host)
            return !$0.isHiddenOrHasHiddenAncestor && rect.minX >= -1 && rect.maxX <= 270
                && rect.height > 100 && ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 200
        }
        XCTAssertEqual(candidates.count, 1, "Select the live sidebar, never a hidden prepared list")
        let live = try XCTUnwrap(candidates.first)
        let point = live.convert(NSPoint(x: 100, y: 80), to: nil)
        func send(_ dx: CGFloat = 0, dy: CGFloat = 0, phase: NSEvent.Phase = .changed) {
            NSApp.sendEvent(ScrollEvent(window: window, dx: dx, dy: dy, phase: phase, x: point.x, y: point.y))
        }
        send(phase: .began)
        for _ in 0..<8 {
            send(dy: -20)
            try await Task.sleep(for: .milliseconds(20))
        }
        send(phase: .ended)
        try await Task.sleep(for: .milliseconds(450))
        var lastOffset = live.documentVisibleRect.minY
        var stable = 0
        try await waitUntil {
            let offset = live.documentVisibleRect.minY
            stable = abs(offset - lastOffset) < 0.25 ? stable + 1 : 0
            lastOffset = offset
            return offset > 100 && stable >= 5
        }
        try await waitUntil { monitor.preparedSlides[next.id] != nil }
        let prepared = try XCTUnwrap(monitor.preparedSlides[next.id])
        let offset = live.documentVisibleRect.minY
        let phase = try contentPhase(live)
        func assertContentAndPreparation(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertTrue(live.window === window, file: file, line: line)
            XCTAssertEqual(live.documentVisibleRect.minX, 0, accuracy: 1, file: file, line: line)
            XCTAssertEqual(live.documentVisibleRect.minY, offset, accuracy: 1, file: file, line: line)
            let current = try contentPhase(live)
            XCTAssertEqual(current.x, phase.x, accuracy: 1, file: file, line: line)
            XCTAssertEqual(current.y, phase.y, accuracy: 1, file: file, line: line)
            XCTAssertTrue(monitor.preparedSlides[next.id] === prepared,
                          "Library must not replace an unchanged adjacent hosting tree", file: file, line: line)
            XCTAssertTrue(prepared.superview === host, file: file, line: line)
            XCTAssertTrue(prepared.isHidden, file: file, line: line)
            XCTAssertNil(host.spaceSlide, "Library must retain its own gesture owner", file: file, line: line)
        }
        // Fine-grained startup earns Library ownership, then reverses and cancels.
        // Do not force layout/display while fingers are moving.
        send(phase: .began)
        for dx: CGFloat in [2, 3, 6, 20, -10] {
            send(dx)
            try await Task.sleep(for: .milliseconds(12))
            if store.librarySwipeProgress != nil { try assertContentAndPreparation() }
        }
        XCTAssertNotNil(store.librarySwipeProgress)
        XCTAssertFalse(store.spaceSwiping)
        send(phase: .cancelled)
        try await waitUntil { store.librarySwipeProgress == nil }
        XCTAssertFalse(store.libraryOpen)
        try assertContentAndPreparation()
        // Commit opening and closing through the shared native event monitor.
        send(phase: .began)
        for dx: CGFloat in [4, 6, 20, 25, 35] {
            send(dx)
            try await Task.sleep(for: .milliseconds(12))
            if store.librarySwipeProgress != nil { try assertContentAndPreparation() }
        }
        send(phase: .ended)
        try await waitUntil { store.libraryOpen && store.librarySwipeProgress == nil }
        try assertContentAndPreparation()
        send(phase: .began)
        for dx: CGFloat in [-4, -6, -20, -25, -35] {
            send(dx)
            try await Task.sleep(for: .milliseconds(12))
            if store.librarySwipeProgress != nil { try assertContentAndPreparation() }
        }
        send(phase: .ended)
        try await waitUntil { !store.libraryOpen && store.librarySwipeProgress == nil }
        // Include the preparation deadline after geometry has returned to rest.
        try await Task.sleep(for: .milliseconds(450))
        try assertContentAndPreparation()
        let liveAnchor = try XCTUnwrap(store.spaceGesture.sectionsView)
        let currentTarget = try XCTUnwrap(store.strip.first { $0.id == next.id })
        XCTAssertTrue(prepared.preparedFor(origin: try XCTUnwrap(store.swipeSpace), target: currentTarget,
            frame: liveAnchor.convert(liveAnchor.bounds, to: host), width: SidebarWidth.shared.width),
            "The retained capture must still match returned live geometry")
    }
}
