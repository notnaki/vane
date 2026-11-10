import AppKit
import SwiftUI
import WebKit

/// The same column sizing used by LibraryNavigationLayout, captured by its root.
/// Native resize preparation needs the next viewport before SwiftUI's next layout.
struct PageResizeLayout {
    var sidebarWidth: CGFloat = 0
    var librarySection: LibrarySection?
    var spaces = 0
    var isPrivate = false
    var enabled = true

    func leadingWidth(at width: CGFloat) -> CGFloat {
        guard let librarySection else { return sidebarWidth }
        return Library.panelWidth(section: librarySection, spaces: spaces,
                                  private: isPrivate, available: width)
    }
}

private struct PageResizeLayoutKey: EnvironmentKey {
    static let defaultValue = PageResizeLayout()
}

extension EnvironmentValues {
    var pageResizeLayout: PageResizeLayout {
        get { self[PageResizeLayoutKey.self] }
        set { self[PageResizeLayoutKey.self] = newValue }
    }
}

/// One native viewport's temporary sizing state. WebKit's native hosting child
/// normally clips immediately when its parent shrinks, ahead of the web paint.
/// Keep that child at its painted size until the matching frame is committed.
@MainActor final class PreparedPageResize {
    let web: WKWebView
    private weak var parent: NSView?
    private let size: NSSize
    private let originalSize: NSSize
    private let originalParentSize: NSSize
    private let mask: NSView.AutoresizingMask
    private let autoSubviews: Bool
    private var restored = false

    init(web: WKWebView, size: NSSize) {
        self.web = web
        self.size = size
        parent = web.superview
        originalSize = web.frame.size
        originalParentSize = web.superview?.bounds.size ?? .zero
        mask = web.autoresizingMask
        autoSubviews = web.autoresizesSubviews
    }

    var stillOwned: Bool {
        web.superview === parent && parent != nil && !web.isHiddenOrHasHiddenAncestor
            && parent?.bounds.size == originalParentSize && web.frame.size == size
    }

    func prepare() {
        web.autoresizingMask = []
        web.autoresizesSubviews = false
        web.setFrameSize(size)
        web.prepareContent(in: NSRect(origin: .zero, size: size))
    }

    func restore(committed: Bool) {
        guard !restored else { return }
        restored = true
        if web.superview === parent {
            if !committed {
                let parentSize = parent?.bounds.size ?? originalParentSize
                web.setFrameSize(NSSize(
                    width: originalSize.width + (mask.contains(.width) ? parentSize.width - originalParentSize.width : 0),
                    height: originalSize.height + (mask.contains(.height) ? parentSize.height - originalParentSize.height : 0)))
            }
            web.autoresizingMask = mask
            web.autoresizesSubviews = autoSubviews
            if autoSubviews { web.resizeSubviews(withOldSize: originalSize) }
            web.prepareContent(in: web.bounds)
        } else {
            // A new host already owns its frame/mask. Restore only the temporary
            // child-sizing flag, so a moved page cannot remain frozen.
            let frozen = !web.autoresizesSubviews
            web.autoresizesSubviews = autoSubviews
            if frozen && autoSubviews { web.resizeSubviews(withOldSize: originalSize) }
            web.prepareContent(in: web.bounds)
        }
    }
}

/// Keeps native window geometry and the rendered document in one CA commit.
/// There is at most one preparation and one latest request; no event-loop waits.
@MainActor final class WindowResizePreparation {
    struct Request {
        let frame: NSRect
        let display: Bool
    }

    private weak var window: NSWindow?
    private let commit: @MainActor (NSRect, Bool) -> Void
    private var pending: Request?
    private var pages: [PreparedPageResize] = []
    private weak var root: NSView?
    private var active: Request?
    private var generation = UUID()
    private var remaining = 0
    private(set) var bypassForDrag = false
    var isPreparing: Bool { active != nil }

    init(window: NSWindow, commit: @escaping @MainActor (NSRect, Bool) -> Void) {
        self.window = window
        self.commit = commit
    }

    func endLiveResize() { bypassForDrag = false }

    @discardableResult func request(frame: NSRect, display: Bool) -> Bool {
        guard !bypassForDrag, let window, window.isVisible, let root = window.contentView else { return false }
        let request = Request(frame: frame, display: display)
        if active != nil {
            pending = request
            return true
        }
        guard frame.size != window.frame.size else { return false }
        let nextSize = NSSize(width: root.bounds.width + frame.width - window.frame.width,
                              height: root.bounds.height + frame.height - window.frame.height)
        let targets = Self.targets(in: root, nextSize: nextSize)
        guard !targets.isEmpty else { return false }
        self.root = root
        active = request
        pages = targets
        remaining = targets.count
        generation = UUID()
        let token = generation
        // All views must receive their new viewport before requesting any paint.
        targets.forEach { $0.prepare() }
        for target in targets {
            let callback: @convention(block) () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.presented(token) }
            }
            target.web.perform(Self.presentation, with: callback)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.timedOut(token)
        }
        return true
    }

    func cancel() {
        generation = UUID()
        pending = nil
        active = nil
        remaining = 0
        pages.forEach { $0.restore(committed: false) }
        pages = []
        root = nil
    }

    private func presented(_ token: UUID) {
        guard generation == token, let active else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        guard let window, window.isVisible, window.contentView === root,
              pages.allSatisfy({ $0.stillOwned && $0.web.window === window }) else {
            let latest = pending ?? active
            cancel()
            if let window, window.isVisible { commit(latest.frame, latest.display) }
            return
        }
        // WebKit invokes this inside its layer-tree transaction, after the new
        // content is installed. Commit the window and child geometry together.
        commit(active.frame, active.display)
        pages.forEach { $0.restore(committed: true) }
        pages = []
        self.active = nil
        generation = UUID()
        if let next = pending {
            pending = nil
            if !request(frame: next.frame, display: next.display) { commit(next.frame, next.display) }
        }
    }

    private func timedOut(_ token: UUID) {
        guard generation == token, let active else { return }
        let latest = pending ?? active
        cancel()
        bypassForDrag = window?.inLiveResize == true
        if let window, window.isVisible { commit(latest.frame, latest.display) }
    }

    private static let presentation = NSSelectorFromString("_doAfterNextPresentationUpdate:")

    private static func targets(in root: NSView, nextSize: NSSize) -> [PreparedPageResize] {
        let delta = NSSize(width: nextSize.width - root.bounds.width,
                           height: nextSize.height - root.bounds.height)
        var result: [PreparedPageResize] = []
        var admitted = true
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let host = view as? WebHost {
                guard !host.offscreen else { return }
                guard host.resizeLayout.enabled else { admitted = false; return }
                let layout = host.resizeLayout
                let dx = delta.width - layout.leadingWidth(at: nextSize.width)
                    + layout.leadingWidth(at: root.bounds.width)
                for web in host.subviews.compactMap({ $0 as? WKWebView })
                where !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 0 && web.bounds.height > 0 {
                    guard web.responds(to: presentation) else { admitted = false; return }
                    let mask = web.autoresizingMask
                    let size = NSSize(width: web.frame.width + (mask.contains(.width) ? dx * host.resizeFraction.width : 0),
                                      height: web.frame.height + (mask.contains(.height) ? delta.height * host.resizeFraction.height : 0))
                    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
                    else { admitted = false; return }
                    guard size != web.frame.size else { continue }
                    result.append(PreparedPageResize(web: web, size: size))
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return admitted ? result : []
    }
}
