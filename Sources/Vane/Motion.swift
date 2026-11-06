import AppKit
import SwiftUI

/// How the tab list moves. A Today row fades out while its neighbours slide up into the
/// gap, a new one grows in under New Tab, a pin lifts a row out
/// of Today and settles it under the space's name. Clear removes Today as one batch.
/// Rearrangements use `Look.list`; closing uses the shorter `Look.tabClose`,
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
        try animate(Look.list, body)
    }

    static func animate<T>(_ animation: Animation, _ body: () throws -> T) rethrows -> T {
        guard reduced else { return try withAnimation(animation, body) }
        return try instant(body)
    }

    /// Acknowledgement and policy cancellation must also override an inherited spring.
    static func instant<T>(_ body: () throws -> T) rethrows -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return try withTransaction(transaction, body)
    }

    /// System-wide Reduce Motion. Read from AppKit rather than the SwiftUI environment
    /// because the writes this guards happen in the model, where there is no environment.
    static var reduced: Bool {
        spaceReduced || BatterySaver.shared.isActive
    }

    /// Space navigation stays continuous in Battery Saver, including its landing tail.
    static var spaceReduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    fileprivate struct SpaceTransition: TransactionKey {
        static let defaultValue = false
    }

    fileprivate struct SpaceHandoff: TransactionKey {
        static let defaultValue = false
    }

    /// The native sidebar owns visible travel. Descendant Space transitions must keep
    /// the covered live content replacement immediate, including in Battery Saver.
    static func spaceHandoff<T>(_ body: () throws -> T) rethrows -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        transaction[SpaceHandoff.self] = true
        return try withTransaction(transaction, body)
    }

    static func space<T>(_ animation: Animation,
                         completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                         _ body: () throws -> T, completion: @escaping () -> Void = {}) rethrows -> T {
        var transaction = Transaction(animation: spaceReduced ? nil : animation)
        transaction.disablesAnimations = spaceReduced
        transaction[SpaceTransition.self] = true
        transaction.addAnimationCompletion(criteria: completionCriteria, completion)
        return try withTransaction(transaction, body)
    }


}

extension Transaction {
    var isSpaceHandoff: Bool { self[Motion.SpaceHandoff.self] }
}

extension View {
    /// An outer animated transaction must not re-enable motion in a descendant.
    /// Observe both policies so an already-visible interface responds to changes.
    func vaneMotionPolicy() -> some View { modifier(VaneMotionPolicy()) }
}

private struct VaneMotionPolicy: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var batterySaver = BatterySaver.shared

    func body(content: Content) -> some View {
        content.transaction {
            if reduceMotion || (batterySaver.isActive && !$0[Motion.SpaceTransition.self]) {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }
}

extension AnyTransition {
    /// Incoming rows retain their full layout height while fading in. Starting them at
    /// zero height makes LazyVStack realize offscreen folder children to fill its viewport,
    /// stalling the opening animation. The list transaction moves neighbouring rows.
    /// Departing rows still collapse; negative padding consumes the list's gap too.
    static var rowCollapse: AnyTransition {
        .asymmetric(insertion: .opacity,
                    removal: .modifier(active: RowCollapse(collapsed: true),
                                       identity: RowCollapse(collapsed: false)))
    }

    /// Keep departing Today content at full size during its brief fade. The list's
    /// transaction still slides the surviving rows up with `Look.list`.
    static var todayRow: AnyTransition {
        .asymmetric(insertion: .rowCollapse,
                    removal: .opacity.animation(Look.tabRemovalFade))
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
    /// Layout, rename and status-bar rules proved offline.
    nonisolated static func check() -> [(String, Bool)] {
        var out: [(String, Bool)] = [
            ("a collapsed row eats the list's gap as well as its own height",
             Look.rowGap > 0 && Look.rowHeight > 0),
        ]
        out += Rename.check()
        out += StatusBar.check()
        return out
    }
}
