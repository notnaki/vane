import AppKit
import SwiftUI
import XCTest
@testable import vane

/// ImageRenderer omits AppKit-backed scroll contents. Capture the hosted sidebar so
/// comparisons include the same native viewport users see during and after a swipe.
@MainActor enum SidebarSnapshot {
    private static var count = 0

    static func pixels<V: View>(_ view: V, width: CGFloat = 250, height: CGFloat = 400, appearance: NSAppearance.Name = .darkAqua,
                                sidebarScope: SidebarNativeReadinessScope? = nil,
                                beforeCapture: (NSView) -> Void = { _ in }) throws -> Data {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
            .background(Color(white: 0.25)))
        host.frame = bounds
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        if let sidebarScope {
            // A hosting shell can lay out before its native row owners populate.
            // Admit the exact store/Space's committed visible rows independently
            // of the pixel result. Keep raw pixels(in:) immediate for motion tests.
            try admitNativePopulation(in: host, scope: sidebarScope)
        } else {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
        beforeCapture(host)
        return try pixels(in: host)
    }

    static func pixels(contentOf store: TabStore) throws -> Data {
        try pixels(SidebarSpaceContent().environmentObject(store)
            .environmentObject(SidebarDragPreview()),
            sidebarScope: SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID))
    }

    static func pixels(sectionsOf store: TabStore) throws -> Data {
        // Standalone sections omit the live strip's declaration. Give this exact
        // mounted surface its own population lifetime, including empty sections.
        let scope = SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID, surfaceID: UUID())
        let owner = NSObject(), ownerID = UUID()
        let cache = Feel02SidebarRowsCache()
        let pinned = cache.resolve(in: store, shape: store.pins).rows
        let today = cache.resolve(in: store, shape: store.todayShape).rows
        let coordinator = SidebarNativeReadinessCoordinator.shared
        coordinator.expectPopulation(scope, sections: ["today": today.map(\.id),
            "pinned": store.pinnedSectionCollapsed ? [] : pinned.map(\.id)], populationOwnerID: ownerID)
        coordinator.retainPopulationExpectation(scope, owner: ObjectIdentifier(owner), populationOwnerID: ownerID)
        defer { coordinator.releasePopulationExpectation(scope, owner: ObjectIdentifier(owner)) }
        return try pixels(SidebarSpaceSections().environmentObject(store)
            .environment(\.sidebarNativeReadinessScope, scope)
            .environment(\.sidebarNativeReadinessOwnerID, ownerID), sidebarScope: scope)
    }

    static func admitNativePopulation(in host: NSView, scope: SidebarNativeReadinessScope) throws {
        let window = try XCTUnwrap(host.window)
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            host.layoutSubtreeIfNeeded()
            if let scroll = SidebarSectionsViewport.scrollView(in: host),
               scroll.window === window, let document = scroll.documentView,
               document.isDescendant(of: host), scroll.contentView.bounds.height > 0,
               SidebarNativeReadinessCoordinator.shared.isReady(scope) { return }
            guard Date() < deadline else {
                XCTFail("Snapshot sidebar population did not commit for \(scope)")
                throw NSError(domain: "SidebarSnapshotReadiness", code: 1)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    static func pixels(in host: NSView) throws -> Data {
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] {
            count += 1
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(count).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }
}
