import AppKit
import SwiftUI

/// One marker per sidebar, retained across destination handoffs until release. A target
/// exiting must not erase the last gap while AppKit is entering the next target.
@MainActor final class SidebarDropMarker: ObservableObject {
    @Published private(set) var target: String?
    @Published private(set) var frame: CGRect?
    @Published private(set) var session: UUID?
    private weak var nativeOverlay: NSView?

    func offer(_ target: String?, session: UUID) {
        if self.session != session {
            self.session = session
            frame = nil
        }
        if self.target != target { self.target = target }
    }

    func remember(_ frame: CGRect?) {
        guard let frame, self.frame != frame else { return }
        self.frame = frame
    }

    func registerNativeOverlay(_ view: NSView) { nativeOverlay = view }

    func unregisterNativeOverlay(_ view: NSView) {
        if nativeOverlay === view { nativeOverlay = nil }
    }

    /// Child hosting roots cannot propagate SwiftUI anchor preferences. Convert
    /// their resolved gap into the retained outer marker's native coordinate space.
    func rememberNative(_ rect: CGRect, in view: NSView, target: String, session: UUID) {
        guard self.session == session, self.target == target,
              let overlay = nativeOverlay, let window = view.window,
              overlay.window === window, rect.width.isFinite, rect.height.isFinite,
              rect.minX.isFinite, rect.minY.isFinite else { return }
        remember(view.convert(rect, to: overlay))
    }

    func visible(session: UUID, active: Bool) -> Bool {
        active && self.session == session && target != nil && frame != nil
    }
}

private struct SidebarDropMarkerKey: EnvironmentKey {
    static let defaultValue: SidebarDropMarker? = nil
}

extension EnvironmentValues {
    var sidebarDropMarker: SidebarDropMarker? {
        get { self[SidebarDropMarkerKey.self] }
        set { self[SidebarDropMarkerKey.self] = newValue }
    }
}

struct SidebarDropLineOverlay: View {
    @ObservedObject var marker: SidebarDropMarker
    @ObservedObject private var dragging = Dragging.shared

    var body: some View {
        GeometryReader { _ in
            let rect = marker.frame ?? .zero
            let visible = marker.visible(session: dragging.session, active: dragging.active)
                && dragging.favouriteGhostWidth == nil
            Rectangle().fill(Color.white)
                .frame(width: rect.width, height: Look.dropLine)
                .position(x: rect.midX, y: rect.midY)
                .transaction { $0.animation = nil }
                .opacity(visible ? 1 : 0)
                // Only entering/leaving the drag fades. Moving to another gap keeps the
                // same rectangle fully visible and follows the destination immediately.
                .animation(Motion.reduced ? nil : Look.quick, value: visible)
        }
        .background(NativeSidebarMarkerOverlayAnchor(marker: marker))
        .vaneMotionPolicy()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}


private struct NativeSidebarMarkerOverlayAnchor: NSViewRepresentable {
    let marker: SidebarDropMarker
    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) { marker.registerNativeOverlay(view) }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) {
        // The marker holds only a weak anchor; a replacement registers independently.
    }
}

struct NativeSidebarMarkerRelay: NSViewRepresentable {
    let marker: SidebarDropMarker
    let rect: CGRect?
    let target: String?
    let session: UUID?
    final class Anchor: NSView {
        weak var marker: SidebarDropMarker?
        var rect: CGRect?
        var target: String?
        var session: UUID?
        private var pending = false
        var live = true
        private weak var clip: NSClipView?
        private var observation: ClipObservation?
        @MainActor private final class ClipObservation: NSObject {
            weak var anchor: Anchor?
            init(clip: NSClipView, anchor: Anchor) {
                self.anchor = anchor
                super.init()
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(changed),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
            @objc private func changed(_ note: Notification) { anchor?.schedule() }
            deinit { NotificationCenter.default.removeObserver(self) }
        }
        private func refreshClip() {
            let next = live && window != nil && rect != nil && target != nil && session != nil
                ? enclosingScrollView?.contentView : nil
            if clip !== next {
                observation = nil; clip = next
                if let next { observation = ClipObservation(clip: next, anchor: self) }
            }
        }
        func detach() { live = false; observation = nil; clip = nil; marker = nil }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func schedule() {
            refreshClip()
            guard live, rect != nil, target != nil, session != nil, !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard self.live, let rect = self.rect, let target = self.target,
                      let session = self.session else { return }
                self.marker?.rememberNative(rect, in: self, target: target, session: session)
            }
        }
        override func layout() { super.layout(); schedule() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); schedule() }
        override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(point); schedule() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); schedule() }
    }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(frame: .zero)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        view.marker = marker; view.rect = rect; view.target = target; view.session = session
        view.schedule()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}
