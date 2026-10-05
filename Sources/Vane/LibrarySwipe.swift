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

    func body(content: Content) -> some View {
        let monitor = store.librarySwipeMonitor
        content
            .onAppear { monitor.install(store) }
            .onDisappear { monitor.remove() }
    }
}

/// Left closes Library; right opens it from the first Space, anywhere in the window.
/// Decide on fingers-up and consume momentum so one gesture cannot do both.
/// Vertical scrolling and other Spaces' gestures keep their original recipient.
@MainActor final class LibrarySwipeMonitor {
    private var monitor: Any?
    private var watchers: [any NSObjectProtocol] = []
    private enum Claim { case idle, undecided, mine, theirs }
    private enum Action { case close, open(UUID) }
    private var action: Action?
    private var claim = Claim.idle
    private weak var lastEvent: NSEvent?
    private var lastWasConsumed = false
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
        action = nil
        travel = (0, 0, 0)
        finished = false
        lastEvent = nil
        lastWasConsumed = false
    }

    /// Both local monitors consult this shared owner. An undecided event can pass
    /// through both, so classify and accumulate each native event exactly once.
    func handle(_ event: NSEvent, in store: TabStore) -> NSEvent? {
        if lastEvent === event { return lastWasConsumed ? nil : event }
        let result = process(event, in: store)
        lastEvent = event
        lastWasConsumed = result == nil
        return result
    }

    private func valid(_ action: Action, in store: TabStore) -> Bool {
        switch action {
        case .close: return store.libraryOpen
        case .open(let space):
            return !store.libraryOpen && !store.isPrivate && !store.isLittle
                && !store.creatingSpace && !store.spaceSwiping && store.currentSpaceID == space
        }
    }

    private func process(_ event: NSEvent, in store: TabStore) -> NSEvent? {
        guard let window = event.window, window === store.window,
              event.hasPreciseScrollingDeltas else { return event }
        if !event.momentumPhase.isEmpty {
            // Keep the verdict after fingers-up even though Library has now closed.
            return claim == .mine ? nil : event
        }
        guard !event.phase.isEmpty else { return event }
        if event.phase.contains(.began) {
            reset()
            if store.libraryOpen { action = .close }
            else if let space = store.currentSpaceID, !store.isPrivate, !store.isLittle,
                    !store.creatingSpace, !store.spaceSwiping {
                action = .open(space)
            }
            claim = action == nil ? .theirs : .undecided
        }
        guard claim == .undecided || claim == .mine else { return event }
        if finished { return claim == .mine ? nil : event }
        guard let action else { return event }
        if claim == .undecided && !valid(action, in: store) { claim = .theirs; return event }
        if event.phase.contains(.cancelled) {
            finished = true
            return claim == .mine ? nil : event
        }
        if event.phase.contains(.ended) {
            finished = true
            if claim == .mine, valid(action, in: store) {
                switch action {
                case .close:
                    if travel.x <= -60 { Library.close(store) }
                case .open(let space):
                    if travel.x >= 60, store.strip.first?.id == space {
                        store.palette = nil
                        Library.open(Library.shared.section, in: store)
                    }
                }
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
            guard travel.horizontal > travel.vertical * 1.5 else { claim = .theirs; return event }
            switch action {
            case .close: claim = travel.x < 0 ? .mine : .theirs
            case .open(let space):
                // Read the strip only after a rightward horizontal gesture qualifies,
                // rather than decoding every profile's Spaces on vertical/page scrolls.
                claim = travel.x > 0 && store.strip.first?.id == space ? .mine : .theirs
            }
        }
        return claim == .mine ? nil : event
    }
}
