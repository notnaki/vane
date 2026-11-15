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
                                        pointerLocation: () -> NSPoint = { NSEvent.mouseLocation },
                                        observePresentation: (NSWindow) -> Void = { _ in },
                                        allowRecovery: (NSWindow) -> Bool = { _ in true },
                                        ready: (NSView) -> Bool) async throws -> CGImage {
        _ = NSApplication.shared
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let window = SidebarSnapshotWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        try positionAwayFromPointer(window, pointer: pointerLocation())
        func newHost() -> NSView {
            let host = NSHostingView(rootView: view.frame(width: width, height: height)
                .environment(\.colorScheme, .dark).background(Color(white: 0.25)))
            host.frame = bounds
            return host
        }
        var host = newHost()
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close() }
        var admission = "starting"
        var occlusionRecoveryPending = false
        var lastRepresentation = ContinuousClock.now
        // Reported on timeout so a stalled admission names its exact gate and
        // when it changed: ready(host) is only consulted after every gate held.
        let start = ContinuousClock.now
        var gates = "", history: [String] = []
        var rebuilds = 0, readyCalls = 0, representations = 0, placement = 0
        do {
            try await compatibilityWait {
                // The live return tile has its own SwiftUI hover caption. A static
                // parity sample must not admit a pointer-hovered live presentation.
                // Recreate the graph if the user moved into this task-owned window:
                // moving it away alone preserves the return tile's animated hover exit.
                if window.frame.contains(pointerLocation()) {
                    window.contentView = nil
                    try positionAwayFromPointer(window, pointer: pointerLocation())
                    host = newHost()
                    window.contentView = host
                    rebuilds += 1
                    return false
                }
                // Another fixture can take focus or obscure a still-key window.
                // Waiting alone cannot restore that exact visible owner.
                if NSApp.isHidden { NSApp.unhide(nil) }
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                if window.occlusionState.contains(.visible) { occlusionRecoveryPending = false }
                observePresentation(window)
                if !allowRecovery(window) { return false }
                let placed = NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
                if !window.isVisible || !window.isKeyWindow || NSApp.keyWindow !== window
                    || !window.occlusionState.contains(.visible) || !placed {
                    if !placed && !window.occlusionState.contains(.visible) {
                        try positionAwayFromPointer(window, pointer: pointerLocation())
                    }
                    // Re-keying an already-key window can leave its occlusion
                    // state stale. Re-present that exact owner to refresh it.
                    // If it stays occluded in place (another window covers that
                    // corner, or no fresh occlusion arrives), re-present it at the
                    // next pointer-free placement instead of waiting on one attempt.
                    if window.isVisible && window.isKeyWindow && !window.occlusionState.contains(.visible)
                        && (!occlusionRecoveryPending
                            || ContinuousClock.now - lastRepresentation > occlusionRetryInterval) {
                        if occlusionRecoveryPending {
                            placement += 1
                            try positionAwayFromPointer(window, pointer: pointerLocation(), skipping: placement)
                        }
                        window.orderOut(nil)
                        occlusionRecoveryPending = true
                        lastRepresentation = ContinuousClock.now
                        representations += 1
                    }
                    window.makeKeyAndOrderFront(nil)
                }
                host.layoutSubtreeIfNeeded()
                let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(window.frame) }
                let pointerInside = window.frame.contains(pointerLocation())
                let populated = sidebarScope.map { nativePopulationIsReady(in: host, scope: $0) } ?? true
                let admitted = NSApp.isRunning && NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow
                    && window.isVisible && window.occlusionState.contains(.visible) && onScreen
                    && NSApp.modalWindow == nil && window.attachedSheet == nil && host.window === window
                    && !pointerInside && populated
                if admitted { readyCalls += 1 }
                let current = "active=\(NSApp.isActive) key=\(window.isKeyWindow) owner=\(NSApp.keyWindow === window) "
                    + "visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) placed=\(onScreen) "
                    + "pointerInside=\(pointerInside) populated=\(populated) frame=\(window.frame) "
                    + "representations=\(representations) admitted=\(admitted)"
                if current != gates, history.count < 40 {
                    history.append("t=\(ContinuousClock.now - start) \(current)")
                }
                gates = current
                admission = "running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow) "
                    + "owner=\(NSApp.keyWindow === window) visible=\(window.isVisible) "
                    + "occlusion=\(window.occlusionState.rawValue) attached=\(host.window === window) "
                    + "placed=\(onScreen) modal=\(NSApp.modalWindow != nil) sheet=\(window.attachedSheet != nil) "
                    + "pointerInside=\(pointerInside) populated=\(populated) frame=\(window.frame) "
                    + "host=\(ObjectIdentifier(host)) rebuilds=\(rebuilds) readyCalls=\(readyCalls) "
                    + "representations=\(representations)"
                return admitted && ready(host)
            }
        } catch {
            print("Sidebar snapshot admission failed: \(admission)\n  "
                  + history.joined(separator: "\n  ") + "\n  windows above: \(windowsAbove(window))")
            throw error
        }
        host.layoutSubtreeIfNeeded()
        return try XCTUnwrap(captureBitmap(in: host).cgImage)
    }

    /// How long a re-presented owner may stay occluded before moving it.
    static let occlusionRetryInterval: Duration = .milliseconds(400)

    /// Pick a fully visible presentation owner without moving the user's cursor.
    /// Accept an explicit point/screen so every corner and nonzero screen origin
    /// can be covered without depending on the machine's physical pointer.
    static func frame(avoiding pointer: NSPoint, size: NSSize, within screen: NSRect) -> NSRect? {
        frames(avoiding: pointer, size: size, within: screen).first
    }

    static func frames(avoiding pointer: NSPoint, size: NSSize, within screen: NSRect) -> [NSRect] {
        guard size.width <= screen.width, size.height <= screen.height else { return [] }
        let origins = [NSPoint(x: screen.minX, y: screen.minY),
                       NSPoint(x: screen.maxX - size.width, y: screen.minY),
                       NSPoint(x: screen.minX, y: screen.maxY - size.height),
                       NSPoint(x: screen.maxX - size.width, y: screen.maxY - size.height)]
        return origins.map { NSRect(origin: $0, size: size) }.filter { !$0.contains(pointer) }
    }

    /// `skipping` cycles through every pointer-free corner of every screen,
    /// starting with the main screen's first, so a covered placement is left.
    private static func positionAwayFromPointer(_ window: NSWindow, pointer: NSPoint, skipping: Int = 0) throws {
        let screen = NSScreen.main.map { [$0] } ?? []
        let candidates = (screen + NSScreen.screens.filter { $0 !== NSScreen.main }).flatMap {
            frames(avoiding: pointer, size: window.frame.size, within: $0.visibleFrame.insetBy(dx: 20, dy: 20))
        }
        let placement = try XCTUnwrap(candidates.isEmpty ? nil : candidates[skipping % candidates.count],
                                      "No visible snapshot placement excludes the pointer")
        window.setFrameOrigin(placement.origin)
    }

    /// Windows the window server orders above the snapshot owner (any process),
    /// in AppKit screen coordinates, so a timeout names what covers it.
    private static func windowsAbove(_ window: NSWindow) -> String {
        guard window.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                    CGWindowID(window.windowNumber)) as? [[String: Any]]
        else { return "unavailable" }
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        let rows = list.prefix(12).map { info -> String in
            let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            var frame = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: bounds) {
                frame = NSRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            }
            return "\(owner) layer=\(layer) alpha=\(alpha) frame=\(frame) covers=\(frame.intersects(window.frame))"
        }
        return "\(list.count)[\(rows.joined(separator: "; "))]"
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
