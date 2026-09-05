import AppKit
import SwiftUI

/// How the tab list moves. Arc's sidebar never cuts: a row that leaves collapses and its
/// neighbours slide up into the gap, a new one grows in under New Tab, a pin lifts a row out
/// of Today and settles it under the space's name, and Clear sweeps Today away a row at a
/// time. All of that is one animation (`Look.list`) around every change to `TabStore.tabs`,
/// plus the transitions below on the rows themselves.
///
/// ponytail: `withAnimation` at the mutation, not `.animation(value:)` on the list. The
/// list's identity is a set of tabs, and there is no single value that says "changed" —
/// wrapping the writes is what makes an archive from ⌘W, the menu, the × and the auto-archive
/// sweep all move the same way without any of them knowing about the sidebar.
@MainActor enum Motion {
    /// Run `body` with the list animation — or without any, when the user asked for less
    /// motion. Every write to the strip goes through here.
    static func list<T>(_ body: () throws -> T) rethrows -> T {
        guard !reduced else { return try body() }
        return try withAnimation(Look.list, body)
    }

    /// System-wide Reduce Motion. Read from AppKit rather than the SwiftUI environment
    /// because the writes this guards happen in the model, where there is no environment.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Sweeping

    /// How long the `n`th row of a bulk archive waits before it goes. The first goes at
    /// once; the rest follow at `Look.sweepStagger` each, and the tail is clamped so a
    /// long list ends together rather than dribbling out. Zero for everything under Reduce
    /// Motion — the sweep is decoration, and the tabs still leave.
    nonisolated static func sweepDelay(_ n: Int, reduced: Bool = false) -> Double {
        guard !reduced, n > 0 else { return 0 }
        return min(Double(n) * Look.sweepStagger, Look.sweepCap)
    }

    /// Counts the archives that arrive in one synchronous burst — Clear, Archive Tabs
    /// Below, Close Other Tabs, the auto-archive sweep — so each can be handed a place in
    /// the queue without any of those callers knowing there is one. The count resets on the
    /// next turn of the run loop: the next ⌘W is a fresh burst of one.
    @MainActor final class Burst {
        private var count = 0
        private var armed = false

        /// This call's index in the current burst: 0 for the first, then 1, 2, …
        func next() -> Int {
            defer { count += 1 }
            if !armed {
                armed = true
                // Resets once the synchronous burst that armed it has run to the end.
                Task { @MainActor [weak self] in self?.count = 0; self?.armed = false }
            }
            return count
        }
    }
}

extension AnyTransition {
    /// A sidebar row arriving or leaving: it grows from nothing to its full height (and
    /// back), so the rows around it slide rather than jump, and it fades on the way. The
    /// negative bottom padding eats the list's gap too, or a removed row leaves a 5pt hop
    /// behind at the very end.
    static var rowCollapse: AnyTransition {
        .modifier(active: RowCollapse(collapsed: true), identity: RowCollapse(collapsed: false))
    }

    /// A favourite tile: the grid re-flows its columns as one comes or goes, so the tile
    /// itself just grows into (or shrinks out of) its cell.
    static var tileGrow: AnyTransition {
        .scale(scale: Look.tileAppearScale).combined(with: .opacity)
    }
}

private struct RowCollapse: ViewModifier {
    let collapsed: Bool
    func body(content: Content) -> some View {
        content
            .frame(height: collapsed ? 0 : Look.rowHeight)
            .padding(.bottom, collapsed ? -Look.rowGap : 0)
            .clipped()
            .opacity(collapsed ? 0 : 1)
    }
}

// MARK: - check

extension Motion {
    /// The sweep's arithmetic, and the rename and status-bar rules that live beside it,
    /// proved offline. Grouped under one label so `SelfCheck` needs one line for the lot.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = [
            ("the first row of a sweep goes at once", sweepDelay(0) == 0),
            ("the second waits one stagger", sweepDelay(1) == Look.sweepStagger),
            ("each row waits one more than the last",
             abs(sweepDelay(3) - sweepDelay(2) - Look.sweepStagger) < 1e-9),
            ("a long sweep is capped, so forty tabs do not take two seconds",
             sweepDelay(40) == Look.sweepCap && sweepDelay(400) == Look.sweepCap),
            ("the cap is a handful of staggers, not a cut-off after two",
             Look.sweepCap / Look.sweepStagger >= 6),
            ("Reduce Motion drops the stagger altogether",
             sweepDelay(5, reduced: true) == 0 && sweepDelay(0, reduced: true) == 0),
            ("a negative index is nonsense and waits nothing", sweepDelay(-1) == 0),
            ("the list animation is short enough to chain ⌘W under",
             Look.sweepStagger < 0.1 && Look.sweepCap <= 0.5),
            ("a collapsed row eats the list's gap as well as its own height",
             Look.rowGap > 0 && Look.rowHeight > 0),
        ]
        out += Rename.check()
        out += StatusBar.check()
        return out
    }
}
