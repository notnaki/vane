import AppKit
import SwiftUI

/// The sidebar's bare ground, as a place to pick the window up by.
///
/// Arc has no title bar: the whole sidebar is the window's handle, and the only parts of it
/// that are not are the ones that do something else — a tab row, a button, the address pill.
/// Vane's window is `.fullSizeContentView` with a hidden title, so without this there is
/// nowhere to grab it but the 8pt strip of ground beside the page card.
///
/// ponytail: SwiftUI decides *whether* the pointer is on bare ground, AppKit does the drag.
/// Three simpler spellings were built and driven with the real pointer first, and all three
/// are wrong:
///
/// - `NSWindow.isMovableByWindowBackground` moves the window from a mouse-down on a tab row,
///   on the address pill and on the web page. A SwiftUI `onTapGesture` does not consume a
///   *drag*, so AppKit sees almost every drag in the window as unhandled and takes it —
///   which also kills drag-to-reorder.
/// - A `DragGesture` on a SwiftUI view in `.background` never fires: `WindowGlass`'s
///   `NSVisualEffectView` and the hosting view take the mouse-down first.
/// - An `NSViewRepresentable` calling `performDrag(with:)` never receives a `mouseDown` at
///   all — SwiftUI laid it out at zero by zero and never attached it to a window, with or
///   without an explicit frame and a `sizeThatFits`.
///
/// What is left is the one thing SwiftUI does report reliably from a view underneath
/// everything else: hover. A row, a button or the pill takes the hover before the ground
/// does, so "the pointer is over bare ground" is a question SwiftUI is already answering —
/// and `VaneWindow.sendEvent` validates that the patch still belongs to its window.
@MainActor final class WindowDragGround {
    static let shared = WindowDragGround()

    private let patches = NSHashTable<WindowDragPatch>.weakObjects()

    func hover(_ entered: Bool, patch: WindowDragPatch) {
        patches.add(patch)
        patch.hovered = entered
    }

    /// Cached profile hosts retain SwiftUI state while detached. Only a visible patch
    /// in the receiving window can claim this mouse-down; a parked host cannot.
    func over(in window: NSWindow, at point: NSPoint) -> Bool {
        patches.allObjects.contains { patch in
            patch.hovered && patch.window === window && !patch.isHiddenOrHasHiddenAncestor
                && patch.bounds.intersection(patch.visibleRect).contains(patch.convert(point, from: nil))
        }
    }
}

/// A passive native anchor gives hover state the same lifetime as its actual window
/// attachment. SwiftUI does not always call onDisappear when a cached host is parked.
@MainActor final class WindowDragPatch: NSView, ObservableObject {
    var hovered = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hovered = false }
    }
}

private struct WindowDragAnchor: NSViewRepresentable {
    let patch: WindowDragPatch
    func makeNSView(context: Context) -> WindowDragPatch { patch }
    func updateNSView(_ view: WindowDragPatch, context: Context) {}
    static func dismantleNSView(_ view: WindowDragPatch, coordinator: ()) { view.hovered = false }
}

/// The ground itself: nothing to see, one job, and it is the lowest thing in the sidebar so
/// anything interactive above it takes the pointer first.
struct WindowDragArea: View {
    @StateObject private var patch = WindowDragPatch()

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .background(WindowDragAnchor(patch: patch))
            .onHover { WindowDragGround.shared.hover($0, patch: patch) }
            .onDisappear { WindowDragGround.shared.hover(false, patch: patch) }
            // Decoration. "Move window" is what the window's own accessibility offers; a
            // second, invisible copy of it in the middle of the tab list is noise.
            .accessibilityHidden(true)
    }
}
