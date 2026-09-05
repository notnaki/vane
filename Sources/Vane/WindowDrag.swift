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
/// and `VaneWindow.sendEvent` only has to believe the answer.
@MainActor final class WindowDragGround {
    static let shared = WindowDragGround()

    /// How many ground patches the pointer is currently inside. A count, not a bool: the
    /// sidebar has more than one patch of ground (behind the chrome, and behind the tab list
    /// inside the scroll view), and with a bool the one the pointer *left* would clear the
    /// flag the one it *entered* had just set — whichever order the two callbacks arrive in.
    private var inside = 0

    /// True while the pointer is over sidebar ground and nothing else. Read on the way
    /// through `sendEvent`, so this is one integer rather than a hit-test of our own.
    var over: Bool { inside > 0 }

    func hover(_ entered: Bool) { inside = max(0, inside + (entered ? 1 : -1)) }
}

/// The ground itself: nothing to see, one job, and it is the lowest thing in the sidebar so
/// anything interactive above it takes the pointer first.
struct WindowDragArea: View {
    /// Whether *this* patch is counted in the shared total. A patch that goes away while the
    /// pointer is on it — a Little Arc closing under the pointer, the sidebar sliding out —
    /// never gets its `onHover(false)`, and the leaked count left the app believing every
    /// click was on bare ground: a click on a page dragged the window instead of pressing
    /// the link, and the window it dragged never became key.
    @State private var counted = false

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .onHover { over in
                guard over != counted else { return }      // idempotent, so it cannot double-count
                counted = over
                WindowDragGround.shared.hover(over)
            }
            .onDisappear {
                guard counted else { return }
                counted = false
                WindowDragGround.shared.hover(false)
            }
            // Decoration. "Move window" is what the window's own accessibility offers; a
            // second, invisible copy of it in the middle of the tab list is noise.
            .accessibilityHidden(true)
    }
}
