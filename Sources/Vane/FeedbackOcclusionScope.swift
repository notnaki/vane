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
        /// Notification tokens have their own nonisolated lifetime so releasing a
        /// marker never needs to enter AppKit from an actor-isolated deinitializer.
        private final class GeometryObservations {
            var tokens: [NSObjectProtocol] = []
            deinit {
                for token in tokens { NotificationCenter.default.removeObserver(token) }
            }
        }
        private var geometryObservations: GeometryObservations?
        private var observedAncestors: [ObjectIdentifier] = []
        private weak var observedWindow: NSWindow?
        weak var scope: FeedbackOcclusionScope? {
            didSet { refreshGeometryObservations() }
        }

        private func refreshGeometryObservations() {
            guard scope != nil, let window else {
                geometryObservations = nil
                observedAncestors = []
                observedWindow = nil
                return
            }
            var ancestors: [NSView] = []
            var ancestor = superview
            while let view = ancestor {
                ancestors.append(view)
                ancestor = view.superview
            }
            let identities = ancestors.map(ObjectIdentifier.init)
            guard geometryObservations == nil || observedWindow !== window
                    || observedAncestors != identities else { return }
            geometryObservations = nil
            observedAncestors = identities
            observedWindow = window
            let observations = GeometryObservations()
            func observe(_ name: Notification.Name, object: AnyObject) {
                observations.tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.geometryChanged() }
                })
            }
            for view in ancestors {
                // Notification capability is shared with AppKit and other
                // observers. Never disable a peer's request during teardown.
                view.postsFrameChangedNotifications = true
                view.postsBoundsChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: view)
                observe(NSView.boundsDidChangeNotification, object: view)
            }
            observe(NSWindow.didMoveNotification, object: window)
            observe(NSWindow.didResizeNotification, object: window)
            // A same-window ancestor reparent can leave the marker's own frame
            // and window unchanged. Refresh its chain at the native update too.
            observe(NSWindow.didUpdateNotification, object: window)
            geometryObservations = observations
        }

        private func geometryChanged() {
            refreshGeometryObservations()
            scope?.geometryChanged()
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func setFrameOrigin(_ origin: NSPoint) {
            super.setFrameOrigin(origin)
            geometryChanged()
        }
        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            geometryChanged()
        }
        override func setBoundsOrigin(_ origin: NSPoint) {
            super.setBoundsOrigin(origin)
            geometryChanged()
        }
        override func setBoundsSize(_ size: NSSize) {
            super.setBoundsSize(size)
            geometryChanged()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            geometryChanged()
        }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            geometryChanged()
        }
        override func layout() {
            super.layout()
            geometryChanged()
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
