import AppKit
import SwiftUI
import WebKit

/// Discrete navigation intent, independent of the interpolated native host frame.
/// Tracking remains on LibraryGesture's existing fixed-page path.
struct NavigationViewportIntent: Equatable, Sendable {
    let libraryOpen: Bool
    let sidebarShown: Bool
    let sidebarWidth: CGFloat
    let panelWidth: CGFloat
    let tracking: Bool

    var leadingWidth: CGFloat { libraryOpen ? panelWidth : (sidebarShown ? sidebarWidth : 0) }
}

private struct NavigationViewportIntentKey: EnvironmentKey {
    static let defaultValue: NavigationViewportIntent? = nil
}

extension EnvironmentValues {
    var navigationViewportIntent: NavigationViewportIntent? {
        get { self[NavigationViewportIntentKey.self] }
        set { self[NavigationViewportIntentKey.self] = newValue }
    }
}

/// Keep WebKit's width stable while the live native host translates/clips. Height
/// remains live. There is no snapshot, scale, reparenting, or replacement page.
/// Only shrinking viewports defer; growing viewports retain live autoresizing.
/// A bounded quiet tail covers both existing navigation durations (150/200ms).
@MainActor final class NavigationViewportDeferral {
    private struct FrozenPage {
        weak var page: WKWebView?
        let mask: NSView.AutoresizingMask
    }
    private var previous: NavigationViewportIntent?
    private var frozen: [FrozenPage] = []
    private weak var host: NSView?
    private var windowSize: CGSize?
    private var completion: Task<Void, Never>?

    func prepare(_ intent: NavigationViewportIntent?, in host: NSView,
                 pages: [WKWebView], animated: Bool, reduced: Bool, eligible: Bool) {
        let old = previous
        previous = intent
        guard let intent, !reduced, !intent.tracking, eligible else {
            finish()
            return
        }
        // Ordinary progress/metadata publications have unanimated transactions;
        // they must not release or restart a navigation already in flight.
        guard old != intent else { return }
        guard let old, animated, host.bounds.width > 0 else {
            finish()
            return
        }
        // An undersized live page would expose host ground while expanding.
        // Growing/equal-width intents therefore use native autoresizing, including
        // reversals of an in-flight shrinking transition.
        guard intent.leadingWidth > old.leadingWidth else {
            finish()
            return
        }
        if !frozen.isEmpty, windowSize != host.window?.contentView?.bounds.size {
            finish()
            return
        }
        if frozen.isEmpty {
            // Inspector docking and other custom child layouts stay on AppKit's
            // original autoresizing path. Only full-surface pages are eligible.
            guard !pages.isEmpty, pages.allSatisfy({
                $0.superview === host && $0.autoresizingMask.contains(.width)
                    && abs($0.frame.width - host.bounds.width) < 0.5
                    && abs($0.frame.minX - host.bounds.minX) < 0.5
            }) else { return }
            self.host = host
            windowSize = host.window?.contentView?.bounds.size
            frozen = pages.map { FrozenPage(page: $0, mask: $0.autoresizingMask) }
            for page in pages { page.autoresizingMask.remove(.width) }
        }
        completion?.cancel()
        completion = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(Look.librarySlideDuration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func hostDidResize(eligible: Bool) {
        guard let host, !frozen.isEmpty else { return }
        if !eligible || host.inLiveResize || windowSize != host.window?.contentView?.bounds.size {
            finish()
        }
    }

    /// Also called before ownership changes, so a page never leaves with an
    /// experiment-specific autoresizing mask. Cancelled tails cannot win later.
    func finish() {
        completion?.cancel()
        completion = nil
        let pages = frozen
        frozen.removeAll()
        guard let host else { return }
        for saved in pages {
            guard let page = saved.page, page.superview === host else { continue }
            page.autoresizingMask = saved.mask
            if abs(page.frame.width - host.bounds.width) > 0.01 {
                page.setFrameSize(NSSize(width: host.bounds.width, height: page.frame.height))
            }
        }
        self.host = nil
        windowSize = nil
    }
}
