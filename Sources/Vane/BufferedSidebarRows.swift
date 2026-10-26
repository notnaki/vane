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
    @Published private(set) var focusedRows: Set<String> = []
    private var focusOwners: [UUID: String] = [:]
    private var focusUpdateScheduled = false
    private weak var anchor: NSView?
    private var rowIDs: [String] = []
    private var pendingFocusReveal: (UUID, String)?

    func configure(rows: [String], anchor: NSView) {
        rowIDs = rows
        self.anchor = anchor
        if pendingFocusReveal != nil { scheduleFocusUpdate() }
    }
    private var pending: (Int, CGRect)?
    private weak var clip: NSClipView?
    private var scheduled = false

    func setFocus(_ active: Bool, row: String, owner: UUID) {
        if active {
            if focusOwners[owner] != row { pendingFocusReveal = (owner, row) }
            focusOwners[owner] = row
        } else { focusOwners.removeValue(forKey: owner) }
        scheduleFocusUpdate()
    }

    private func scheduleFocusUpdate() {
        guard !focusUpdateScheduled else { return }
        focusUpdateScheduled = true
        // SwiftUI may deliver focus changes during layout. Independent owner tokens
        // prevent a departing pane from clearing its newly focused sibling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusUpdateScheduled = false
            let next = Set(self.focusOwners.values)
            if self.focusedRows != next { self.focusedRows = next }
            // Reveal only newly entered focus. Bounds notifications must never
            // pull a wheel gesture back to an unchanged, retained focused row.
            if let (owner, row) = self.pendingFocusReveal {
                guard self.focusOwners[owner] == row else {
                    self.pendingFocusReveal = nil
                    return
                }
                // A focus callback may precede native attachment or the first clip
                // report. Keep its reveal until configure/receive supplies geometry.
                guard let index = self.rowIDs.firstIndex(of: row),
                      let anchor = self.anchor, anchor.window != nil,
                      anchor.bounds.width > 0, anchor.bounds.height > 0,
                      let clip = self.clip, clip.bounds.height > 0,
                      anchor.enclosingScrollView?.contentView === clip else { return }
                let rect = NSRect(x: 0, y: CGFloat(index) * (Look.rowHeight + Look.rowGap),
                                  width: anchor.bounds.width, height: Look.rowHeight)
                // Only this vertical clip owns sidebar offsets. NSView's
                // scrollToVisible may propagate into an enclosing scroll view.
                let target = anchor.convert(rect, to: clip)
                var bounds = clip.bounds
                if target.minY < bounds.minY { bounds.origin.y = target.minY }
                else if target.maxY > bounds.maxY { bounds.origin.y += target.maxY - bounds.maxY }
                let constrained = clip.constrainBoundsRect(bounds)
                if constrained.minY != clip.bounds.minY {
                    clip.scroll(to: NSPoint(x: clip.bounds.minX, y: constrained.minY))
                    anchor.enclosingScrollView?.reflectScrolledClipView(clip)
                }
            }
            self.pendingFocusReveal = nil
        }
    }

    func receive(count: Int, visible: CGRect, clip: NSClipView) {
        pending = (count, visible)
        self.clip = clip
        if pendingFocusReveal != nil { scheduleFocusUpdate() }
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
    let rows: [String]
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
        view.count = rows.count
        view.viewport = viewport
        viewport.configure(rows: rows, anchor: view)
        view.refresh()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}

private struct MountedSidebarRow: Identifiable {
    let row: SidebarRows.Row
    let index: Int
    let skipped: Int
    var id: String { row.id }
}

struct BufferedSidebarSectionRows<Content: View>: View {
    let rows: [SidebarRows.Row]
    var editingRows: Set<String> = []
    @ViewBuilder let content: (SidebarRows.Row, Int, Int) -> Content
    @StateObject private var viewport = SidebarRowsViewport()
    @ObservedObject private var dragging = Dragging.shared

    private var range: Range<Int> {
        let start = min(rows.count, viewport.window.range.lowerBound)
        return start..<min(rows.count, max(start, viewport.window.range.upperBound))
    }
    private var pitch: CGFloat { Look.rowHeight + Look.rowGap }
    private var height: CGFloat { max(0, CGFloat(rows.count) * pitch - Look.rowGap) }

    private var mountedIndices: [Int] {
        // Retain only the actual drag source. Multi-selection can contain thousands
        // of tabs, but AppKit's drag session has one source view and preview owner.
        let dragIDs = Set([dragging.tab?.uuidString, dragging.folder?.uuidString].compactMap { $0 })
        let retained = editingRows.union(dragIDs).union(viewport.focusedRows)
        var neighbors: Set<Int> = []
        if !rows.isEmpty { neighbors.formUnion([0, rows.count - 1]) }
        for index in rows.indices where viewport.focusedRows.contains(rows[index].id) {
            if index > 0 { neighbors.insert(index - 1) }
            if index + 1 < rows.count { neighbors.insert(index + 1) }
        }
        return rows.indices.filter {
            range.contains($0) || neighbors.contains($0) || retained.contains(rows[$0].id)
        }
    }

    var body: some View {
        let mounted = mountedIndices
        let entries = mounted.enumerated().map { slot, index in
            MountedSidebarRow(row: rows[index], index: index,
                skipped: index - (slot == 0 ? -1 : mounted[slot - 1]) - 1)
        }
        VStack(spacing: 0) {
            if mounted.isEmpty {
                blank(height)
            } else {
                // One ForEach keeps an interacting row's identity when it moves
                // between the viewport and a sparse keepalive slot. A separate
                // keepalive subtree would destroy the native field editor.
                ForEach(entries) { entry in
                    content(entry.row, entry.index, rows.count)
                        .environment(\.bufferedSidebarFocus, BufferedSidebarFocus(row: entry.id, viewport: viewport))
                        .frame(height: Look.rowHeight)
                        .padding(.top, CGFloat(entry.skipped) * pitch)
                        .padding(.bottom, entry.index == rows.count - 1 ? 0 : Look.rowGap)
                }
                let remaining = rows.count - (mounted.last! + 1)
                if remaining > 0 { blank(CGFloat(remaining) * pitch - Look.rowGap) }
            }
        }
        .background(SidebarRowsViewportAnchor(rows: rows.map(\.id), viewport: viewport))
    }

    private func blank(_ height: CGFloat) -> some View {
        Color.clear.frame(height: height).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct BufferedSidebarFocus: Sendable {
    let row: String
    weak var viewport: SidebarRowsViewport?
    @MainActor func set(_ active: Bool, owner: UUID) {
        viewport?.setFocus(active, row: row, owner: owner)
    }
}

private struct BufferedSidebarFocusKey: EnvironmentKey {
    static let defaultValue: BufferedSidebarFocus? = nil
}

extension EnvironmentValues {
    var bufferedSidebarFocus: BufferedSidebarFocus? {
        get { self[BufferedSidebarFocusKey.self] }
        set { self[BufferedSidebarFocusKey.self] = newValue }
    }
}
