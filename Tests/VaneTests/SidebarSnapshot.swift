import AppKit
import SwiftUI
import XCTest
@testable import vane

/// ImageRenderer omits AppKit-backed scroll contents. Capture the hosted sidebar so
/// comparisons include the same native viewport users see during and after a swipe.
@MainActor enum SidebarSnapshot {
    private static var count = 0

    static func imageWhenReady<V: View>(_ view: V, width: CGFloat = 250, height: CGFloat = 400,
                                        sidebarScope: SidebarNativeReadinessScope? = nil,
                                        ready: (NSView) -> Bool) async throws -> CGImage {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = SidebarSnapshotWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        try positionAwayFromPointer(window)
        let host = NSHostingView(rootView: view.frame(width: width, height: height)
            .environment(\.colorScheme, .dark).background(Color(white: 0.25)))
        host.frame = bounds
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        try await compatibilityWait {
            // The live return tile has its own SwiftUI hover caption. A static
            // parity sample must not admit a pointer-hovered live presentation.
            // Reposition if the user moved into this task-owned window meanwhile.
            if window.frame.contains(NSEvent.mouseLocation) {
                try positionAwayFromPointer(window)
                return false
            }
            host.layoutSubtreeIfNeeded()
            return NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow
                && window.isVisible && window.occlusionState.contains(.visible)
                && NSApp.modalWindow == nil && window.attachedSheet == nil && host.window === window
                && !window.frame.contains(NSEvent.mouseLocation)
                && (sidebarScope.map { nativePopulationIsReady(in: host, scope: $0) } ?? true) && ready(host)
        }
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(captureBitmap(in: host).cgImage)
    }

    /// Pick a fully visible presentation owner without moving the user's cursor.
    /// Accept an explicit point/screen so every corner and nonzero screen origin
    /// can be covered without depending on the machine's physical pointer.
    static func frame(avoiding pointer: NSPoint, size: NSSize, within screen: NSRect) -> NSRect? {
        guard size.width <= screen.width, size.height <= screen.height else { return nil }
        let origins = [NSPoint(x: screen.minX, y: screen.minY),
                       NSPoint(x: screen.maxX - size.width, y: screen.minY),
                       NSPoint(x: screen.minX, y: screen.maxY - size.height),
                       NSPoint(x: screen.maxX - size.width, y: screen.maxY - size.height)]
        return origins.lazy.map { NSRect(origin: $0, size: size) }.first { !$0.contains(pointer) }
    }

    private static func positionAwayFromPointer(_ window: NSWindow) throws {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.main.map { [$0] } ?? []
        let candidates = screen + NSScreen.screens.filter { $0 !== NSScreen.main }
        let placement = try XCTUnwrap(candidates.lazy.compactMap {
            frame(avoiding: pointer, size: window.frame.size, within: $0.visibleFrame.insetBy(dx: 20, dy: 20))
        }.first, "No visible snapshot placement excludes the pointer")
        window.setFrameOrigin(placement.origin)
    }

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
        let population = SectionsPopulation(store: store)
        defer { population.close() }
        return try pixels(population.view(store: store), sidebarScope: population.scope)
    }

    static func imageWhenReady(sectionsOf store: TabStore, ready: (NSView) -> Bool) async throws -> CGImage {
        let population = SectionsPopulation(store: store)
        defer { population.close() }
        return try await imageWhenReady(population.view(store: store), sidebarScope: population.scope, ready: ready)
    }

    @MainActor private final class SectionsPopulation {
        // Standalone sections omit the live strip's declaration. Give this exact
        // mounted surface its own population lifetime, including empty sections.
        let scope: SidebarNativeReadinessScope
        private let owner = NSObject(), ownerID = UUID()

        init(store: TabStore) {
            scope = SidebarNativeReadinessScope(store: store, spaceID: store.currentSpaceID, surfaceID: UUID())
            let cache = Feel02SidebarRowsCache()
            let pinned = cache.resolve(in: store, shape: store.pins).rows
            let today = cache.resolve(in: store, shape: store.todayShape).rows
            let coordinator = SidebarNativeReadinessCoordinator.shared
            coordinator.expectPopulation(scope, sections: ["today": today.map(\.id),
                "pinned": store.pinnedSectionCollapsed ? [] : pinned.map(\.id)], populationOwnerID: ownerID)
            coordinator.retainPopulationExpectation(scope, owner: ObjectIdentifier(owner), populationOwnerID: ownerID)
        }

        func view(store: TabStore) -> some View {
            SidebarSpaceSections().environmentObject(store)
                .environment(\.sidebarNativeReadinessScope, scope)
                .environment(\.sidebarNativeReadinessOwnerID, ownerID)
        }

        func close() {
            SidebarNativeReadinessCoordinator.shared.releasePopulationExpectation(scope, owner: ObjectIdentifier(owner))
        }
    }

    private static func nativePopulationIsReady(in host: NSView, scope: SidebarNativeReadinessScope) -> Bool {
        guard let window = host.window, let scroll = SidebarSectionsViewport.scrollView(in: host),
              scroll.window === window, let document = scroll.documentView,
              document.isDescendant(of: host), scroll.contentView.bounds.height > 0 else { return false }
        return SidebarNativeReadinessCoordinator.shared.isReady(scope)
    }

    static func admitNativePopulation(in host: NSView, scope: SidebarNativeReadinessScope) throws {
        let window = try XCTUnwrap(host.window)
        let deadline = Date(timeIntervalSinceNow: 2)
        while true {
            host.layoutSubtreeIfNeeded()
            if host.window === window, nativePopulationIsReady(in: host, scope: scope) { return }
            guard Date() < deadline else {
                XCTFail("Snapshot sidebar population did not commit for \(scope)")
                throw NSError(domain: "SidebarSnapshotReadiness", code: 1)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    static func pixels(in host: NSView) throws -> Data {
        let bitmap = try captureBitmap(in: host)
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private static func captureBitmap(in host: NSView) throws -> NSBitmapImageRep {
        let bounds = host.bounds
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["VANE_SIDEBAR_SNAPSHOT_DIR"] {
            count += 1
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(count).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        return bitmap
    }
}

@MainActor private final class SidebarSnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
