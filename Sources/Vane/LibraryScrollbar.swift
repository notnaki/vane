import AppKit
import SwiftUI

/// Scroll geometry and drag mapping share the same inset, clamping, and minimum thumb.
struct LibraryScrollbarMetrics: Equatable {
    static let railWidth: CGFloat = 18
    var viewport: CGFloat = 0
    var content: CGFloat = 0
    var offset: CGFloat = 0
    var visibleHeight: CGFloat?

    private var extent: CGFloat { visibleHeight ?? viewport }

    var maximumOffset: CGFloat { max(0, content - extent) }
    var scrolls: Bool { maximumOffset > 1 && viewport > 8 }
    var track: CGFloat { max(0, viewport - 8) }
    var thumb: CGFloat { min(track, max(28, track * extent / max(1, content))) }
    var travel: CGFloat { track - thumb }
    var fraction: CGFloat { min(1, max(0, offset / max(1, maximumOffset))) }
    var top: CGFloat { 4 + travel * fraction }

    func offset(forThumbTop top: CGFloat) -> CGFloat {
        min(1, max(0, (top - 4) / max(1, travel))) * maximumOffset
    }
}

/// A persistent invisible rail makes a hidden thumb discoverable by hovering. Only the
/// thumb fades; its hit target stays put, including throughout a drag outside the rail.
struct LibraryScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var position = ScrollPosition(edge: .top)
    @State private var metrics = LibraryScrollbarMetrics()
    @State private var interaction = LibraryScrollbarInteraction()
    @State private var dragOrigin: CGFloat?
    @State private var bridge = LibraryScrollbarBridge()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    private var animation: Animation? {
        reduceMotion || batterySaver.isActive ? nil : Look.quick
    }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    var body: some View {
        ScrollView {
            content().padding(.trailing, LibraryScrollbarMetrics.railWidth)
                .background(LibraryScrollAnchor(bridge: bridge))
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .scrollPosition($position)
        .onScrollGeometryChange(for: LibraryScrollbarMetrics.self) {
            LibraryScrollbarMetrics(viewport: $0.containerSize.height,
                                    content: $0.contentSize.height, offset: $0.contentOffset.y,
                                    visibleHeight: $0.visibleRect.height)
        } action: { old, new in
            metrics = new
            if !new.scrolls {
                interaction = LibraryScrollbarInteraction()
                dragOrigin = nil
            } else if old.scrolls && old.offset != new.offset {
                interaction.pulse(at: now)
            }
        }
        .onScrollPhaseChange { _, phase in
            guard metrics.scrolls else { return }
            interaction.scroll(phase != .idle, at: now)
        }
        .overlay(alignment: .topTrailing) {
            if metrics.scrolls { rail }
        }
        .task(id: interaction.nextDeadline) {
            guard let deadline = interaction.nextDeadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, deadline - now))) }
            catch { return }
            guard !Task.isCancelled else { return }
            // Shrink and fade are distinct deadlines, so their animations never overlap.
            interaction.advance(to: now)
        }
    }

    private var rail: some View {
        LibraryScrollbarRail(bridge: bridge, hover: { interaction.hover($0, at: now) },
            begin: { y in
                dragOrigin = (metrics.top...(metrics.top + metrics.thumb)).contains(y)
                    ? metrics.offset : metrics.offset(forThumbTop: y - metrics.thumb / 2)
                interaction.drag(true, at: now)
            }, move: { translation in
                let offset = (dragOrigin ?? 0)
                    + translation / max(1, metrics.travel) * metrics.maximumOffset
                position.scrollTo(y: min(metrics.maximumOffset, max(0, offset)))
            }, end: {
                dragOrigin = nil
                interaction.drag(false, at: now)
            })
        .frame(width: LibraryScrollbarMetrics.railWidth, height: metrics.viewport)
        .overlay(alignment: .topTrailing) {
            Capsule()
                .fill(Look.inkSecondary)
                .frame(width: interaction.width, height: metrics.thumb)
                .animation(animation, value: interaction.width)
                .opacity(interaction.visible ? 0.65 : 0)
                .animation(animation, value: interaction.visible)
                .padding(.trailing, 3)
                .offset(y: metrics.top)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scroll list")
        .accessibilityValue("\(Int(metrics.fraction * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? metrics.viewport * 0.8 : -metrics.viewport * 0.8
            interaction.pulse(at: now)
            position.scrollTo(y: min(metrics.maximumOffset, max(0, metrics.offset + delta)))
        }
        .vaneMotionPolicy()
    }
}

/// SwiftUI overlays sit outside NSScrollView's responder chain. Forward wheel events
/// over the rail to the list so discovering its thumb never creates a dead scroll strip.
@MainActor private final class LibraryScrollbarBridge {
    weak var scroll: NSScrollView?
}

private struct LibraryScrollAnchor: NSViewRepresentable {
    let bridge: LibraryScrollbarBridge
    final class Anchor: NSView {
        var bridge: LibraryScrollbarBridge?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            bridge?.scroll = enclosingScrollView
        }
        override func layout() {
            super.layout()
            bridge?.scroll = enclosingScrollView
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.bridge = bridge
        bridge.scroll = view.enclosingScrollView
    }
}

private struct LibraryScrollbarRail: NSViewRepresentable {
    let bridge: LibraryScrollbarBridge
    var hover: (Bool) -> Void
    var begin: (CGFloat) -> Void
    var move: (CGFloat) -> Void
    var end: () -> Void

    final class Rail: NSView {
        var handlers: LibraryScrollbarRail?
        private var dragStart: CGFloat?
        override var isFlipped: Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect,
                          .enabledDuringMouseDrag], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { handlers?.hover(true) }
        override func mouseExited(with event: NSEvent) { handlers?.hover(false) }
        override func scrollWheel(with event: NSEvent) {
            handlers?.bridge.scroll?.scrollWheel(with: event)
        }
        override func mouseDown(with event: NSEvent) {
            let y = convert(event.locationInWindow, from: nil).y
            dragStart = y
            handlers?.begin(y)
            handlers?.move(0)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            handlers?.move(convert(event.locationInWindow, from: nil).y - dragStart)
        }
        override func mouseUp(with event: NSEvent) {
            guard dragStart != nil else { return }
            dragStart = nil
            handlers?.end()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, dragStart != nil {
                dragStart = nil
                handlers?.end()
            }
        }
    }
    func makeNSView(context: Context) -> Rail { Rail() }
    func updateNSView(_ view: Rail, context: Context) { view.handlers = self }
}
