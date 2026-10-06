import SwiftUI

/// One marker per sidebar, retained across destination handoffs until release. A target
/// exiting must not erase the last gap while AppKit is entering the next target.
@MainActor final class SidebarDropMarker: ObservableObject {
    @Published private(set) var target: String?
    @Published private(set) var frame: CGRect?
    @Published private(set) var session: UUID?

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

struct SidebarDropLineBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SidebarDropLineOverlay: View {
    @ObservedObject var marker: SidebarDropMarker
    let bounds: [String: Anchor<CGRect>]
    @ObservedObject private var dragging = Dragging.shared

    private struct Sample: Equatable {
        var frame: CGRect?
        var session: UUID?
    }

    var body: some View {
        GeometryReader { geometry in
            let candidate = marker.target.flatMap { bounds[$0] }.map { geometry[$0] }
            let rect = marker.frame ?? .zero
            let visible = marker.visible(session: dragging.session, active: dragging.active)
            Rectangle().fill(Color.white)
                .frame(width: rect.width, height: Look.dropLine)
                .position(x: rect.midX, y: rect.midY)
                .transaction { $0.animation = nil }
                .opacity(visible ? 1 : 0)
                // Only entering/leaving the drag fades. Moving to another gap keeps the
                // same rectangle fully visible and follows the destination immediately.
                .animation(Motion.reduced ? nil : Look.quick, value: visible)
                .onChange(of: Sample(frame: candidate, session: marker.session), initial: true) { _, sample in
                    if dragging.active && marker.session == dragging.session {
                        marker.remember(sample.frame)
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
