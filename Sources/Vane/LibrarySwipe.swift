import AppKit
import SwiftUI

extension View {
    /// Keep the monitor on the window root: closing Library must still consume the
    /// gesture's momentum instead of handing it to the newly exposed page or sidebar.
    func librarySwipe(_ store: TabStore) -> some View {
        modifier(LibrarySwipe(store: store))
    }
}

private struct LibrarySwipe: ViewModifier {
    let store: TabStore
    @State private var monitor = LibrarySwipeMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.install(store) }
            .onDisappear { monitor.remove() }
    }
}

/// A right-to-left trackpad gesture anywhere in this browser window closes Library
/// on fingers-up. Vertical scrolling and gestures started outside Library retain
/// their original recipient for their whole lifetime.
@MainActor final class LibrarySwipeMonitor {
    private var monitor: Any?
    private var watchers: [any NSObjectProtocol] = []
    private enum Claim { case idle, undecided, mine, theirs }
    private var claim = Claim.idle
    private var travel = (x: CGFloat(0), horizontal: CGFloat(0), vertical: CGFloat(0))
    private var finished = false

    func install(_ store: TabStore) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak store] event in
            guard let self, let store else { return event }
            return self.handle(event, in: store)
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            watchers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSWindow.didResignKeyNotification ? store.window : nil,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reset() }
                })
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        watchers.forEach(NotificationCenter.default.removeObserver)
        watchers = []
        reset()
    }

    private func reset() {
        claim = .idle
        travel = (0, 0, 0)
        finished = false
    }

    private func handle(_ event: NSEvent, in store: TabStore) -> NSEvent? {
        guard let window = event.window, window === store.window,
              event.hasPreciseScrollingDeltas else { return event }
        if !event.momentumPhase.isEmpty {
            // Keep the verdict after fingers-up even though Library has now closed.
            return claim == .mine ? nil : event
        }
        guard !event.phase.isEmpty else { return event }
        if event.phase.contains(.began) {
            reset()
            claim = store.libraryOpen ? .undecided : .theirs
        }
        guard claim == .undecided || claim == .mine else { return event }
        if finished { return claim == .mine ? nil : event }
        if claim == .undecided && !store.libraryOpen { claim = .theirs; return event }
        if event.phase.contains(.cancelled) {
            finished = true
            return claim == .mine ? nil : event
        }
        if event.phase.contains(.ended) {
            finished = true
            if claim == .mine, travel.x <= -60, store.libraryOpen {
                Library.close(store)
            }
            return claim == .mine ? nil : event
        }
        // Navigation follows the fingers, independent of the scrolling preference.
        // Device deltas are positive for left; Natural Scrolling inverts them.
        let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        travel.x += dx
        travel.horizontal += abs(event.scrollingDeltaX)
        travel.vertical += abs(event.scrollingDeltaY)
        if claim == .undecided {
            // Match the sidebar's axis lock: a vertical scroll cannot later become
            // navigation as the fingers drift sideways.
            if travel.vertical >= 6 { claim = .theirs; return event }
            guard travel.horizontal + travel.vertical >= 10 else { return event }
            claim = travel.horizontal > travel.vertical * 1.5 && travel.x < 0 ? .mine : .theirs
        }
        return claim == .mine ? nil : event
    }
}
