import AppKit
import SwiftUI
import XCTest
@testable import vane

/// No screenshot timing assumption: the actual native sections must finish their
/// current committed geometry before the fixed empty/nonempty slot checks.
@MainActor final class EmptyPinnedSectionGeometryTests: XCTestCase {
    private func descendants<T: NSView>(_ root: NSView, _: T.Type) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, T.self) }
    }

    func testEmptyPinnedReadinessAddsNoStackGapAndNonemptyRoundTripKeepsTodayControl() async throws {
        TestEnvironment.prepare()
        XCTAssertTrue(NativeCachedSidebarBatchesExperiment.enabled, "Exercise the shipping native path")
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        app.setActivationPolicy(.accessory)
        defer { app.setActivationPolicy(policy) }
        let lease = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await checkGeometry() } catch { failure = error }
        do { try await lease.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Geometry fixture loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func checkGeometry() async throws {
        let profile = UUID()
        let space = Space(name: "Pinned geometry", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([space], for: profile))
        let store = TabStore(profileID: profile, space: space, session: [])
        store.sharingReady = false
        let today = Tab(profileID: profile), pin = Tab(profileID: profile)
        pin.kind = .pinned
        today.park(url: URL(string: "https://www.swift.org/documentation/#today-geometry")!,
                   Parked(title: "Geometry today", needsRecovery: true))
        pin.park(url: URL(string: "https://www.swift.org/documentation/#pinned-geometry")!,
                 Parked(title: "Geometry pin", needsRecovery: true))
        store.tabs = [today]
        store.pins = Pins(entries: [])
        store.todayShape = Pins(entries: [.init(row: .tab(today.id.uuidString))])
        store.current = nil
        store.palette = nil
        let host = NSHostingView(rootView: SidebarSpaceContent().environmentObject(store)
            .environmentObject(SidebarDragPreview())
            .transaction { $0.disablesAnimations = true })
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 250, height: 400),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        store.window = window
        defer {
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            window.close()
            store.spaceGesture.monitor.remove()
            store.librarySwipeMonitor.remove()
            store.dropStashes()
            SharedTabs.release([today, pin])
            today.tearDown(); pin.tearDown()
            TabStore.all.removeAll { $0 === store }
            Store.forget(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        let scope = SidebarNativeReadinessScope(store: store, spaceID: space.id)
        var firstToday: TabTooltipAnchorView?
        for hasPin in [false, true, false] {
            Motion.instant {
                store.tabs = hasPin ? [today, pin] : [today]
                store.pins = Pins(entries: hasPin ? [.init(row: .tab(pin.id.uuidString))] : [])
            }
            func anchor(_ title: String) -> TabTooltipAnchorView? {
                descendants(host, TabTooltipAnchorView.self).first { $0.title == title && $0.window === window }
            }
            do {
                try await compatibilityWait {
                    host.layoutSubtreeIfNeeded()
                    return SidebarNativeReadinessCoordinator.shared.isReady(scope)
                        && anchor("Geometry today") != nil && anchor("New Tab") != nil
                        && ((anchor("Geometry pin") != nil) == hasPin)
                }
            } catch {
                print("EMPTY_PIN_GEOMETRY_DIAGNOSTIC hasPin=\(hasPin) ready=\(SidebarNativeReadinessCoordinator.shared.isReady(scope)) currentSpace=\(String(describing: store.currentSpaceID)) expectedSpace=\(space.id) titles=\(descendants(host, TabTooltipAnchorView.self).map { ($0.title, $0.window === window, $0.frame) })")
                throw error
            }
            let scroll = try XCTUnwrap(SidebarSectionsViewport.scrollView(in: host))
            let document = try XCTUnwrap(scroll.documentView)
            let todayControl = try XCTUnwrap(anchor("Geometry today"))
            let newTabControl = try XCTUnwrap(anchor("New Tab"))
            let pinExtent = hasPin ? Look.rowHeight + Look.rowGap : 0
            let tidyExtent = Look.tidyRow + 2 * (Look.sectionGap / 2 - Look.rowGap)
            let newTabY = pinExtent + tidyExtent + Look.rowGap
            XCTAssertEqual(newTabControl.convert(newTabControl.bounds, to: document).minY,
                           newTabY, accuracy: 1, "An empty native pinned owner must not add a spaced child")
            XCTAssertEqual(todayControl.convert(todayControl.bounds, to: document).minY,
                           newTabY + Look.rowHeight + Look.rowGap, accuracy: 1)
            if let firstToday { XCTAssertTrue(todayControl === firstToday) }
            else { firstToday = todayControl }
            XCTAssertTrue(SidebarNativeReadinessCoordinator.shared.isReady(scope),
                          "Zero-height pinned ownership still must complete real native readiness")
        }
    }
}
