import AppKit
import SwiftUI
@testable import vane

/// A diagnostic delay before the real hosting root joins its native window.
/// Detached SwiftUI content may already have registered controls; registration
/// alone therefore cannot admit native input. No production scheduling changes.
@MainActor enum NativeFixtureMountAdmission {
    private static func recipient(at point: NSPoint, root: NSView) -> NSView? {
        root.hitTest(root.superview?.convert(point, from: nil) ?? point)
    }
    static func surfaceReady(_ root: NSView, in window: NSWindow) -> Bool {
        // A detached SwiftUI layout can consume onAppear before its native
        // viewport exists. Ownership must be established before the first layout.
        guard window.isVisible, window.contentView === root, root.window === window,
              !root.isHiddenOrHasHiddenAncestor else { return false }
        root.layoutSubtreeIfNeeded()
        return root.bounds.width > 1 && root.bounds.height > 1
    }

    /// Resolve AppKit's front route in the same coordinate system as sendEvent.
    /// Passive SwiftUI geometry probes must route into their exact hosting root;
    /// actual native controls additionally require their own descendant recipient.
    static func hitPoint(_ view: NSView, root: NSView, window: NSWindow,
                         nativeControl: Bool = false) -> NSPoint? {
        guard surfaceReady(root, in: window), view.window === window,
              view.isDescendant(of: root), !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let anchor = view as? NativeFixtureGeometry.Anchor, !anchor.hasCommittedCurrentGeometry { return nil }
        let visible = view.visibleRect.intersection(view.bounds)
        guard visible.width > 1, visible.height > 1 else { return nil }
        let point = view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil)
        guard let hit = recipient(at: point, root: root), hit === root || hit.isDescendant(of: root),
              !nativeControl || hit === view || hit.isDescendant(of: view) else { return nil }
        if nativeControl, let control = view as? NSControl, !control.isEnabled { return nil }
        return point
    }

    static func scrollReady(_ scroll: NSScrollView, root: NSView, window: NSWindow,
                            minimumHeight: CGFloat) -> Bool {
        guard surfaceReady(root, in: window), scroll.window === window,
              scroll.isDescendant(of: root), let document = scroll.documentView,
              document.window === window, document.frame.height >= minimumHeight - 1,
              scroll.contentView.bounds.width > 1, scroll.contentView.bounds.height > 1 else { return false }
        let visible = document.bounds.intersection(scroll.documentVisibleRect)
        return visible.width > 1 && visible.height > 1
            && scrollPoint(scroll, root: root, window: window) != nil
    }

    static func scrollPoint(_ scroll: NSScrollView, root: NSView, window: NSWindow) -> NSPoint? {
        let clip = scroll.contentView
        guard let point = hitPoint(clip, root: root, window: window),
              let hit = recipient(at: point, root: root),
              hit === clip || hit.isDescendant(of: clip) else { return nil }
        return point
    }

    /// Positive coverage of the current viewport, independent of how many rows
    /// were mounted outside it. Overmounting must still fail the caller's count
    /// assertion immediately after admission.
    static func populated(_ scroll: NSScrollView, by views: [NSView], root: NSView,
                          window: NSWindow, spacing: CGFloat, topInset: CGFloat = 0,
                          nativeControls: Bool = false, slotHeight: CGFloat? = nil,
                          region: NSRect? = nil) -> Bool {
        guard let document = scroll.documentView else { return false }
        var visible = document.bounds.intersection(scroll.documentVisibleRect)
        if let region { visible = visible.intersection(region) }
        guard visible.width > 1, visible.height > 1 else { return false }
        let rects = views.compactMap { view -> NSRect? in
            guard hitPoint(view, root: root, window: window, nativeControl: nativeControls) != nil else { return nil }
            var slot = view.convert(view.bounds, to: document)
            // The native bezel is centered in the fixture's explicit row slot.
            // Hit testing still uses the actual control rectangle above.
            if let slotHeight { slot = NSRect(x: slot.minX, y: slot.midY - slotHeight / 2,
                width: slot.width, height: slotHeight) }
            let rect = slot.intersection(visible)
            return rect.height > 1 ? rect : nil
        }.sorted { $0.minY < $1.minY }
        guard let first = rects.first, let last = rects.last,
              first.minY <= visible.minY + spacing + topInset + 1,
              last.maxY >= visible.maxY - spacing - 1 else { return false }
        return zip(rects, rects.dropFirst()).allSatisfy { $1.minY - $0.maxY <= spacing + 1 }
    }

    static func attach(_ root: NSView, to window: NSWindow) -> Task<Void, Never>? {
        let delay = Int(ProcessInfo.processInfo.environment["VANE_FIXTURE_MOUNT_DELAY_MS"] ?? "0") ?? 0
        precondition((0...2_000).contains(delay))
        guard delay > 0 else {
            window.contentView = root
            return nil
        }
        let bounds = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        window.contentView = NSView(frame: bounds)
        return Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }
    }
}

/// Noninteractive measurements of the actual SwiftUI label/control rectangles.
/// No guessed event coordinates or private SwiftUI view inspection is required.
@MainActor final class NativeFixtureGeometry {
    final class Anchor: NSView {
        private var committedFrame: NSRect?
        private var committedBounds: NSRect?
        private weak var committedWindow: NSWindow?
        var hasCommittedCurrentGeometry: Bool {
            window != nil && committedWindow === window && committedFrame == frame && committedBounds == bounds
        }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
        override func setFrameOrigin(_ origin: NSPoint) {
            let changed = frame.origin != origin
            super.setFrameOrigin(origin)
            if changed { needsLayout = true }
        }
        override func setFrameSize(_ size: NSSize) {
            let changed = frame.size != size
            super.setFrameSize(size)
            if changed { needsLayout = true }
        }
        override func layout() {
            super.layout()
            committedFrame = frame; committedBounds = bounds; committedWindow = window
        }
    }
    private final class WeakAnchor {
        weak var view: Anchor?
        init(_ view: Anchor) { self.view = view }
    }
    private var anchors: [String: WeakAnchor] = [:]
    subscript(_ id: String) -> Anchor? { anchors[id]?.view }
    var views: [NSView] { anchors.values.compactMap(\.view) }
    func record(_ view: Anchor, id: String) { anchors[id] = WeakAnchor(view) }
}

struct NativeFixtureGeometryProbe: NSViewRepresentable {
    let id: String
    let geometry: NativeFixtureGeometry
    func makeNSView(context: Context) -> NativeFixtureGeometry.Anchor {
        let view = NativeFixtureGeometry.Anchor(frame: .zero)
        geometry.record(view, id: id)
        return view
    }
    func updateNSView(_ view: NativeFixtureGeometry.Anchor, context: Context) { geometry.record(view, id: id) }
}

#if DEBUG
/// Test-owned native receipt. A body evaluation or representable update alone
/// cannot acknowledge layout; configuration invalidates the previous commitment.
@MainActor final class NativeFixtureSnapshotMarker: NSView {
    struct Snapshot: Equatable {
        let store: ObjectIdentifier
        let section: String?
        let ids: [String]
    }
    private var declared: Snapshot?
    private var committed: Snapshot?
    private weak var committedWindow: NSWindow?
    private var committedBounds: NSRect?
    private var committedFrame: NSRect?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func configure(_ next: Snapshot) {
        guard declared != next else { return }
        declared = next
        invalidate()
    }
    private func invalidate() { committed = nil; needsLayout = true }
    override func layout() {
        super.layout()
        committed = declared
        committedWindow = window
        committedBounds = bounds
        committedFrame = frame
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); invalidate() }
    override func setFrameOrigin(_ origin: NSPoint) {
        let changed = frame.origin != origin
        super.setFrameOrigin(origin)
        if changed { invalidate() }
    }
    override func setFrameSize(_ size: NSSize) {
        let changed = frame.size != size
        super.setFrameSize(size)
        if changed { invalidate() }
    }
    func belongs(to store: ObjectIdentifier, section: String) -> Bool {
        declared?.store == store && declared?.section == section
    }
    func acknowledges(_ expected: Snapshot, root: NSView, window: NSWindow) -> Bool {
        committed == expected && declared == expected && committedWindow === window
            && self.window === window && isDescendant(of: root) && !isHiddenOrHasHiddenAncestor
            && committedBounds == bounds && committedFrame == frame
            && bounds.width > 1 && bounds.height > 1
    }
}

private struct NativeFixtureSnapshotAnchor: NSViewRepresentable {
    let snapshot: NativeFixtureSnapshotMarker.Snapshot
    func makeNSView(context: Context) -> NativeFixtureSnapshotMarker { NativeFixtureSnapshotMarker(frame: .zero) }
    func updateNSView(_ view: NativeFixtureSnapshotMarker, context: Context) { view.configure(snapshot) }
}
#endif

/// The only consumer of the debug-only product seam. A release browser has no
/// added environment key, native receipt view, or scheduling behavior.
struct NativeFixtureSnapshotReceipt: ViewModifier {
    func body(content: Content) -> some View {
#if DEBUG
        let receipt: @MainActor @Sendable (ObjectIdentifier, String?, [String]) -> AnyView = { store, section, ids in
            AnyView(NativeFixtureSnapshotAnchor(snapshot: .init(store: store, section: section, ids: ids)))
        }
        content.environment(\.sidebarSnapshotReceipt, receipt)
#else
        content
#endif
    }
}
