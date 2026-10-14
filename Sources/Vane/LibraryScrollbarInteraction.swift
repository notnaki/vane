import Foundation

/// The Library scrollbar owns its hover/use timing rather than inheriting macOS's
/// global scrollbar preference. Time is supplied by the caller for deterministic tests.
struct LibraryScrollbarInteraction {
    static let settleDelay = 0.65
    static let fadeDelay = 0.45
    private(set) var hovering = false
    private(set) var scrolling = false
    private(set) var dragging = false
    private(set) var visible = false
    private(set) var settleAt: Double?
    private(set) var hideAt: Double?

    var busy: Bool { scrolling || dragging }
    var width: CGFloat { busy || settleAt != nil ? 8 : hovering ? 6 : 3 }
    var nextDeadline: Double? { settleAt ?? hideAt }

    mutating func hover(_ inside: Bool, at now: Double) {
        hovering = inside
        if inside {
            visible = true
            hideAt = nil
        } else if !busy && settleAt == nil {
            hideAt = now + Self.fadeDelay
        }
    }

    mutating func scroll(_ active: Bool, at now: Double) {
        scrolling = active
        pulse(at: now)
    }

    mutating func drag(_ active: Bool, at now: Double) {
        dragging = active
        pulse(at: now)
    }

    /// Also covers wheel/keyboard/programmatic offsets that have no live-scroll phase.
    mutating func pulse(at now: Double) {
        visible = true
        hideAt = nil
        settleAt = busy ? nil : now + Self.settleDelay
    }

    mutating func advance(to now: Double) {
        if let deadline = settleAt, now >= deadline {
            settleAt = nil
            if !hovering && !busy { hideAt = deadline + Self.fadeDelay }
        }
        if let deadline = hideAt, now >= deadline, !hovering && !busy {
            hideAt = nil
            visible = false
        }
    }
}
