import AppKit
import SwiftUI

/// When the sidebar under the Library is disabled. Flipping `.disabled` walks every
/// sidebar row, which is tens of milliseconds; published with `libraryOpen` it lands in
/// the update that starts the slide and holds its first frame. An animated opening
/// applies it once the panel has covered the sidebar, and a close once the sidebar is
/// back, where the pause shows as nothing. A disabled sidebar draws the same as an
/// enabled one, so the returning one is only inert until it has arrived.
///
/// Nothing may be focused under the panel in the meantime, so the wait is gated:
/// the responder leaves the sidebar as the slide starts, the native row hosts refuse
/// focus from `libraryOpen` itself and the window refuses it for anything inside them,
/// hit testing and accessibility still follow `libraryOpen`, and a key that could move
/// focus applies the flip before it is delivered.
@MainActor final class LibrarySidebarCover: ObservableObject {
    /// What the sidebar's `.disabled` reads. Converges on `libraryOpen`.
    @Published private(set) var covered = false
    private weak var store: TabStore?
    private var generation = 0
    private var input: Any?

    /// Whether `window`'s sidebar is under an open Library, applied or not.
    static func hidesSidebar(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return TabStore.all.contains { $0.window === window && $0.profileVisible && $0.libraryOpen }
    }

    /// AppKit is about to hand `responder` the keyboard in `window`; false refuses it.
    /// Rows are native hosts whose inner key views answer for themselves, so they are
    /// refused here. Any other control ends the wait, and SwiftUI answers for it from
    /// the disabled sidebar. The Library's own field and the page pass untouched.
    static func admits(_ responder: NSResponder?, in window: NSWindow) -> Bool {
        guard let view = responder as? NSView,
              let store = TabStore.all.first(where: { $0.window === window && $0.profileVisible && $0.libraryOpen })
        else { return true }
        if NativeSidebarNavigation.owns(view) { return false }
        let cover = store.librarySidebarCover
        guard cover.input != nil, !(view is NSText), !(view is NSTextField) else { return true }
        var ancestor: NSView? = view
        while let current = ancestor {
            if current is WebHost { return true }
            ancestor = current.superview
        }
        // Possibly inside a SwiftUI update, where publishing is not allowed.
        DispatchQueue.main.async { cover.settle() }
        return true
    }

    /// `libraryOpen` changed.
    func follow(_ store: TabStore) {
        self.store = store
        generation &+= 1
        let open = store.libraryOpen
        guard open != covered else { stopWatchingInput(); return }
        // Only an animated slide is worth waiting for. A swipe publishes its
        // destination with the panel already there.
        guard !Motion.reduced, let window = store.window, window.isVisible,
              store.libraryGesture.paint != nil,
              store.librarySwipeProgress != (open ? 1 : 0) else { settle(); return }
        if open { releaseSidebarFocus(in: window, store: store) }
        watchInput(in: window)
        wait(generation, after: Look.appearDuration, until: .now() + 1)
    }

    /// Apply the pending flip now.
    func settle() {
        generation &+= 1
        stopWatchingInput()
        guard let store, covered != store.libraryOpen else { return }
        // Its own transaction: the flip is never part of whatever is animating.
        Motion.instant { covered = store.libraryOpen }
    }

    /// Where the panel is on screen, which trails the model by the page's paint.
    private var presentedPanel: CGFloat? {
        guard let view = store?.librarySwipeMonitor.presentationView, let layer = view.layer?.presentation(),
              let root = view.window?.contentView?.layer?.presentation() else { return nil }
        return layer.convert(.zero, to: root).x
    }

    private func wait(_ token: Int, after delay: TimeInterval, until deadline: DispatchTime,
                      last: CGFloat? = nil) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == token, let store = self.store else { return }
            // Landed is the model at its destination and the panel where it was a
            // frame ago: the flip must not hold even the slide's last pixels.
            let panel = self.presentedPanel
            if let paint = store.libraryGesture.paint, .now() < deadline,
               paint.progress != (store.libraryOpen ? 1 : 0) || paint.isPreparing || panel != last {
                self.wait(token, after: 1.0 / 60, until: deadline, last: panel)
            } else { self.settle() }
        }
    }

    /// Where the keyboard goes as an opening starts: out of the sidebar, before the
    /// Library's search field asks for it. A page keeps it until then, as before.
    private func releaseSidebarFocus(in window: NSWindow, store: TabStore) {
        guard store.palette == nil, window.attachedSheet == nil, NSApp.modalWindow == nil,
              let responder = window.firstResponder, responder !== window else { return }
        var view = ((responder as? NSTextView)?.delegate as? NSView) ?? (responder as? NSView)
        while let current = view {
            if current is WebHost { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }

    private func watchInput(in window: NSWindow) {
        guard input == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        input = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak window] event in
            MainActor.assumeIsolated {
                // Typing belongs to the search field or the page and moves nothing.
                // Tab, a shortcut or a function key may move focus, Escape and Return
                // press default and cancel buttons, and a click may land on the
                // returning sidebar: they meet its final state.
                guard let self, let window, event.window === window,
                      event.type != .keyDown || [48, 53, 36, 76].contains(event.keyCode)
                        || !event.modifierFlags.intersection([.command, .control, .function]).isEmpty
                else { return }
                self.settle()
                window.contentView?.layoutSubtreeIfNeeded()
            }
            return event
        }
    }

    private func stopWatchingInput() {
        if let input { NSEvent.removeMonitor(input) }
        input = nil
    }

    isolated deinit { stopWatchingInput() }
}

/// The one observer of the cover, so applying it re-evaluates nothing but the sidebar.
struct LibrarySidebarCoverGate: ViewModifier {
    @ObservedObject var cover: LibrarySidebarCover
    let blocked: Bool
    func body(content: Content) -> some View { content.disabled(blocked || cover.covered) }
}
