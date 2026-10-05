import AppKit
import SwiftUI

/// A single pointer surface avoids competing scroll, tap, and drag recognizers.
struct EaselPointer: NSViewRepresentable {
    let selected: Bool
    let editing: Bool
    var footer = false
    var live = false
    let select: () -> Void
    let edit: () -> Void
    let drag: (CGSize, EaselItemLayout.Corner?, Bool) -> Void
    func makeNSView(context: Context) -> EaselPointerView { EaselPointerView() }
    func updateNSView(_ view: EaselPointerView, context: Context) {
        view.selected = selected; view.editing = editing; view.footer = footer; view.live = live
        view.select = select; view.edit = edit; view.drag = drag
        view.window?.invalidateCursorRects(for: view)
    }
}

final class EaselPointerView: NSView {
    var selected = false
    var editing = false
    var footer = false
    var live = false
    var select: () -> Void = {}
    var edit: () -> Void = {}
    var drag: (CGSize, EaselItemLayout.Corner?, Bool) -> Void = { _, _, _ in }
    private var start: CGPoint?
    private var corner: EaselItemLayout.Corner?
    private var dragging = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        let edge = local.x < 10 || local.y < 10 || local.x > bounds.width - 10 || local.y > bounds.height - 10
        if selected && (edge || resizeCorner(at: local) != nil) { return self }
        if editing || live || (footer && local.y > bounds.height - 44) { return nil }
        return self
    }
    private func resizeCorner(at point: CGPoint) -> EaselItemLayout.Corner? {
        guard selected else { return nil }
        for corner in EaselItemLayout.Corner.allCases {
            let rect = CGRect(x: corner.leading ? 0 : bounds.width - 24,
                              y: corner.top ? 0 : bounds.height - 24, width: 24, height: 24)
            if rect.contains(point) { return corner }
        }
        return nil
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        if selected {
            for corner in EaselItemLayout.Corner.allCases {
                addCursorRect(CGRect(x: corner.leading ? 0 : bounds.width - 24,
                                     y: corner.top ? 0 : bounds.height - 24, width: 24, height: 24), cursor: .crosshair)
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        corner = resizeCorner(at: convert(event.locationInWindow, from: nil))
        start = event.locationInWindow; dragging = false
        select()
        if event.clickCount == 2 && corner == nil { start = nil; edit() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let delta = CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y)
        guard dragging || hypot(delta.width, delta.height) >= 3 else { return }
        dragging = true
        drag(delta, corner, false)
    }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; dragging = false; corner = nil }
        guard let start, dragging else { return }
        drag(CGSize(width: event.locationInWindow.x - start.x, height: start.y - event.locationInWindow.y), corner, true)
    }
}

struct EaselPan: NSViewRepresentable {
    func makeNSView(context: Context) -> EaselPanView { EaselPanView() }
    func updateNSView(_ view: EaselPanView, context: Context) {}
}

final class EaselPanView: NSView {
    private var start: CGPoint?
    private var origin = CGPoint.zero
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let proposed = CGRect(origin: CGPoint(x: origin.x - (event.locationInWindow.x - start.x),
                                              y: origin.y + (event.locationInWindow.y - start.y)), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
    }
    override func mouseUp(with event: NSEvent) { start = nil }
}
