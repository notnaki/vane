import AppKit
import SwiftUI

/// Feedback-only admission for one known overlay cluster. It never affects hit
/// testing, activation, keyboard routing, or unrelated rows in the same window.
@MainActor final class FeedbackOcclusionScope {
    private let occluders = NSHashTable<NSView>.weakObjects()
    private let monitors = NSHashTable<Feel02PressMonitor>.weakObjects()

    func track(_ monitor: Feel02PressMonitor?) {
        if let monitor { monitors.add(monitor) }
    }

    func attach(_ view: NSView) {
        occluders.add(view)
        geometryChanged()
    }

    func detach(_ view: NSView) {
        occluders.remove(view)
        // Removing a cover never admits a new hover. Physical movement must do so.
    }

    func contains(_ point: CGPoint, in window: NSWindow) -> Bool {
        guard occluders.count > 0 else { return false }
        return occluders.allObjects.contains { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return false }
            let local = view.convert(point, from: nil)
            return view.bounds.contains(local) && view.visibleRect.contains(local)
        }
    }

    func geometryChanged() {
        for monitor in monitors.allObjects { monitor.feedbackOcclusionChanged(self) }
    }
}

private struct FeedbackOcclusionScopeKey: EnvironmentKey {
    static let defaultValue: FeedbackOcclusionScope? = nil
}

extension EnvironmentValues {
    var feedbackOcclusionScope: FeedbackOcclusionScope? {
        get { self[FeedbackOcclusionScopeKey.self] }
        set { self[FeedbackOcclusionScopeKey.self] = newValue }
    }
}

/// Place behind the known RecentLibraryPreview's actual bounds, before footer
/// padding. Multiple weak markers support overlapping entrance/removal transitions.
struct FeedbackOccluder: NSViewRepresentable {
    let scope: FeedbackOcclusionScope

    final class Marker: NSView {
        weak var scope: FeedbackOcclusionScope?
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameOrigin(_ origin: NSPoint) {
            super.setFrameOrigin(origin)
            scope?.geometryChanged()
        }
        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            scope?.geometryChanged()
        }
        override func setBoundsOrigin(_ origin: NSPoint) {
            super.setBoundsOrigin(origin)
            scope?.geometryChanged()
        }
        override func setBoundsSize(_ size: NSSize) {
            super.setBoundsSize(size)
            scope?.geometryChanged()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scope?.geometryChanged()
        }
        override func layout() {
            super.layout()
            scope?.geometryChanged()
        }
    }

    func makeNSView(context: Context) -> Marker { Marker(frame: .zero) }
    func updateNSView(_ view: Marker, context: Context) {
        if view.scope !== scope {
            view.scope?.detach(view)
            view.scope = scope
        }
        scope.attach(view)
    }
    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        view.scope?.detach(view)
        view.scope = nil
    }
}
