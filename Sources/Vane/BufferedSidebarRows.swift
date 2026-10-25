import AppKit
import SwiftUI

/// Diagnostic only until offscreen keyboard and accessibility navigation are
/// bridged. Keep this separate from the production lazy/retained policies.
@MainActor enum BufferedSidebarRowsExperiment {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["VANE_EXPERIMENT_BUFFERED_SIDEBAR"] == "1"
    }
}

/// Fixed row geometry lets us remove offscreen responder nodes without asking a
/// lazy layout to discover their sizes. The guard band amortizes realization.
struct SidebarRowWindow {
    private(set) var range = 0..<16
    static let buffer = 8
    static let batch = 8
    static let guardRows = 4

    mutating func update(count: Int, visible: CGRect, pitch: CGFloat) -> Bool {
        guard pitch > 0, pitch.isFinite, visible.minY.isFinite,
              visible.maxY.isFinite else { return false }
        let first = min(count, max(0, Int(floor(visible.minY / pitch))))
        let end = min(count, max(0, Int(ceil(visible.maxY / pitch))))
        let next: Range<Int>
        if end <= first {
            next = first..<first
        } else if range.lowerBound <= max(0, first - Self.guardRows),
                  range.upperBound >= min(count, end + Self.guardRows),
                  range.upperBound <= count {
            return false
        } else {
            let lower = max(0, first - Self.buffer) / Self.batch * Self.batch
            let upper = min(count, (end + Self.buffer + Self.batch - 1) / Self.batch * Self.batch)
            next = lower..<upper
        }
        guard range != next else { return false }
        range = next
        return true
    }
}

@MainActor final class SidebarRowsViewport: ObservableObject {
    @Published private(set) var window = SidebarRowWindow()
    private var pending: (Int, CGRect)?
    private weak var clip: NSClipView?
    private var scheduled = false

    func receive(count: Int, visible: CGRect, clip: NSClipView) {
        pending = (count, visible)
        self.clip = clip
        guard !scheduled else { return }
        scheduled = true
        // Native geometry callbacks may run inside SwiftUI layout. Coalesce their
        // latest geometry and publish only an actual buffered-range change.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard let (count, visible) = self.pending else { return }
            self.pending = nil
            var next = self.window
            guard next.update(count: count, visible: visible,
                              pitch: Look.rowHeight + Look.rowGap) else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.window = next }
            SidebarScrollTrace.recordRowWindow(next.range, count: count, clip: self.clip)
        }
    }
}

private struct SidebarRowsViewportAnchor: NSViewRepresentable {
    let count: Int
    let viewport: SidebarRowsViewport

    final class Anchor: NSView {
        var count = 0
        weak var viewport: SidebarRowsViewport?
        private weak var clip: NSClipView?
        private var observer: NSObjectProtocol?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func refresh() {
            let next = window == nil ? nil : enclosingScrollView?.contentView
            if next !== clip {
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
                clip = next
                if let next {
                    next.postsBoundsChangedNotifications = true
                    observer = NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: next, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }
                }
            }
            report()
        }
        private func report() {
            guard let clip, clip.bounds.height > 0, bounds.height > 0 else { return }
            viewport?.receive(count: count, visible: convert(clip.bounds, from: clip), clip: clip)
        }
        override func layout() { super.layout(); refresh() }
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            let changed = frame.origin != newOrigin
            super.setFrameOrigin(newOrigin)
            if changed { report() }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refresh() }
        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            clip = nil
            viewport = nil
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor(frame: .zero) }
    func updateNSView(_ view: Anchor, context: Context) {
        view.count = count
        view.viewport = viewport
        view.refresh()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}

struct BufferedSidebarSectionRows<Content: View>: View {
    let rows: [SidebarRows.Row]
    @ViewBuilder let content: (SidebarRows.Row, Int, Int) -> Content
    @StateObject private var viewport = SidebarRowsViewport()

    private var range: Range<Int> {
        let start = min(rows.count, viewport.window.range.lowerBound)
        return start..<min(rows.count, max(start, viewport.window.range.upperBound))
    }
    private var pitch: CGFloat { Look.rowHeight + Look.rowGap }
    private var height: CGFloat { max(0, CGFloat(rows.count) * pitch - Look.rowGap) }

    var body: some View {
        let visible = range
        VStack(spacing: 0) {
            if visible.isEmpty {
                blank(height)
            } else {
                blank(CGFloat(visible.lowerBound) * pitch)
                VStack(spacing: Look.rowGap) {
                    ForEach(Array(rows[visible].enumerated()), id: \.element.id) { index, row in
                        content(row, visible.lowerBound + index, rows.count)
                            .frame(height: Look.rowHeight)
                    }
                }
                blank(CGFloat(rows.count - visible.upperBound) * pitch)
            }
        }
        .background(SidebarRowsViewportAnchor(count: rows.count, viewport: viewport))
    }

    private func blank(_ height: CGFloat) -> some View {
        Color.clear.frame(height: height).allowsHitTesting(false).accessibilityHidden(true)
    }
}
