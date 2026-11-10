import AppKit
import SwiftUI
import WebKit

/// AppKit proposes a frame size. Preserve the opposite edges of the native drag
/// when the matching painted frame is committed asynchronously.
struct WindowResizeAnchor {
    let frame: NSRect
    let fixedRight: Bool
    let fixedTop: Bool

    init(frame: NSRect, pointer: NSPoint) {
        self.frame = frame
        fixedRight = abs(pointer.x - frame.minX) < abs(pointer.x - frame.maxX)
        fixedTop = abs(pointer.y - frame.minY) < abs(pointer.y - frame.maxY)
    }

    func frame(for size: NSSize) -> NSRect {
        NSRect(x: fixedRight ? frame.maxX - size.width : frame.minX,
               y: fixedTop ? frame.maxY - size.height : frame.minY,
               width: size.width, height: size.height)
    }
}

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
    private var installed = false
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

    var parentReachedPreparedSize: Bool {
        guard let parent, web.superview === parent else { return false }
        let expected = NSSize(width: originalParentSize.width + size.width - originalSize.width,
                              height: originalParentSize.height + size.height - originalSize.height)
        return abs(parent.bounds.width - expected.width) < 0.001
            && abs(parent.bounds.height - expected.height) < 0.001
    }

    func prepare() {
        web.autoresizingMask = []
        web.autoresizesSubviews = false
        prepareStyle()
        web.setFrameSize(size)
        web.prepareContent(in: NSRect(origin: .zero, size: size))
    }

    func prepareStyle() { PageResizeStyle.prepare(web, nextSize: size) }

    func installNativeGeometry() {
        guard !installed, web.superview === parent else { return }
        installed = true
        web.autoresizesSubviews = autoSubviews
        if autoSubviews { web.resizeSubviews(withOldSize: originalSize) }
    }

    func restore(committed: Bool) {
        guard !restored else { return }
        restored = true
        if web.superview === parent {
            if committed { installNativeGeometry() }
            if !committed {
                let parentSize = parent?.bounds.size ?? originalParentSize
                web.setFrameSize(NSSize(
                    width: originalSize.width + (mask.contains(.width) ? parentSize.width - originalParentSize.width : 0),
                    height: originalSize.height + (mask.contains(.height) ? parentSize.height - originalParentSize.height : 0)))
            }
            web.autoresizingMask = mask
            web.autoresizesSubviews = autoSubviews
            if autoSubviews && !installed { web.resizeSubviews(withOldSize: originalSize) }
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
    typealias Presenter = @MainActor (WKWebView, @escaping @MainActor @Sendable () -> Void) -> Void
    typealias Deadline = @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void
    struct Request {
        let frame: NSRect
        let display: Bool
    }

    private weak var window: NSWindow?
    private let commit: @MainActor (NSRect, Bool) -> Void
    private let presenter: Presenter?
    private let deadline: Deadline?
    private var pending: Request?
    private var pages: [PreparedPageResize] = []
    private weak var root: NSView?
    private var active: Request?
    private var startingFrame: NSRect?
    private var generation = UUID()
    private var remaining = 0
    private var nextScheduled = false
    private var watchdog: Timer?
    private var recoveryToken: UUID?
    private var recoveryRemaining = 0
    private let styledPages = NSHashTable<WKWebView>.weakObjects()
    private var liveResizeEnded = false
    private(set) var bypassForDrag = false
    var isPreparing: Bool { active != nil || nextScheduled }

    init(window: NSWindow, presenter: Presenter? = nil, deadline: Deadline? = nil,
         commit: @escaping @MainActor (NSRect, Bool) -> Void) {
        self.window = window
        self.presenter = presenter
        self.deadline = deadline
        self.commit = commit
    }

    func endLiveResize() {
        liveResizeEnded = true
        bypassForDrag = false
        recoveryToken = nil
        recoveryRemaining = 0
        if !isPreparing { finishStyles() }
    }

    func beginLiveResize() { liveResizeEnded = false }

    private func finishStyles() {
        styledPages.allObjects.forEach(PageResizeStyle.finish)
        styledPages.removeAllObjects()
    }

    @discardableResult func request(frame: NSRect, display: Bool) -> Bool {
        guard !bypassForDrag, let window, window.isVisible, let root = window.contentView else { return false }
        let request = Request(frame: frame, display: display)
        if isPreparing {
            pending = request
            return true
        }
        // On shrink, AppKit can clip the existing larger page immediately.
        // Preparing the smaller viewport first can reveal its new right edge
        // inside the still-larger window before the window geometry commits.
        // Growth needs the opposite order: paint the extra area before exposing it.
        guard frame.size != window.frame.size else { return false }
        let nextSize = NSSize(width: root.bounds.width + frame.width - window.frame.width,
                              height: root.bounds.height + frame.height - window.frame.height)
        let targets = Self.targets(in: root, nextSize: nextSize)
        guard !targets.isEmpty else { return false }
        guard frame.width > window.frame.width || frame.height > window.frame.height else {
            for target in targets {
                styledPages.add(target.web)
                target.prepareStyle()
            }
            return false
        }
        self.root = root
        startingFrame = window.frame
        active = request
        pages = targets
        targets.forEach { styledPages.add($0.web) }
        remaining = targets.count
        generation = UUID()
        let token = generation
        // All views must receive their new viewport before requesting any paint.
        targets.forEach { $0.prepare() }
        for target in targets {
            if let presenter {
                presenter(target.web) { [weak self] in self?.presented(token) }
                continue
            }
            let callback: @convention(block) () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.presented(token) }
            }
            target.web.perform(Self.presentation, with: callback)
        }
        let timeout: @MainActor @Sendable () -> Void = { [weak self] in self?.timedOut(token) }
        if let deadline { deadline(timeout) }
        else if generation == token, active != nil {
            // A real GitHub resize can paint after116ms. Treating that as a
            // stalled process exposed unpainted queued width for the whole drag.
            let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { timeout() } }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return true
    }

    func cancel() {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        pending = nil
        active = nil
        startingFrame = nil
        remaining = 0
        nextScheduled = false
        recoveryToken = nil
        recoveryRemaining = 0
        pages.forEach { $0.restore(committed: false) }
        pages = []
        root = nil
        finishStyles()
    }

    private func presented(_ token: UUID) {
        guard generation == token, let active else {
            // A fallback must not stay latched after WebKit becomes responsive.
            // Its old callback only readmits coordination; it never commits a frame.
            if recoveryToken == token, recoveryRemaining > 0 {
                recoveryRemaining -= 1
                if recoveryRemaining == 0 {
                    recoveryToken = nil
                    bypassForDrag = false
                }
            }
            return
        }
        remaining -= 1
        guard remaining == 0 else { return }
        watchdog?.invalidate()
        watchdog = nil
        guard let window, window.frame == startingFrame else {
            // A programmatic resize/move supersedes the pending native drag.
            cancel()
            return
        }
        guard window.isVisible, window.contentView === root,
              pages.allSatisfy({ $0.stillOwned && $0.web.window === window }) else {
            cancel()
            return
        }
        // WebKit invokes this inside its layer-tree transaction, after the new
        // content is installed. Commit the window and child geometry together.
        // setFrame(display:true) may flush AppKit drawing synchronously. Install
        // the already-painted child's clip first, while keeping the web view's
        // own autoresizing mask disabled so the window cannot apply its delta twice.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            pages.forEach { $0.installNativeGeometry() }
            commit(active.frame, active.display)
        }
        pages.forEach { $0.restore(committed: true) }
        pages = []
        self.active = nil
        startingFrame = nil
        generation = UUID()
        if pending != nil {
            nextScheduled = true
            let nextToken = generation
            let committedFrame = window.frame
            let committedRootID = root.map(ObjectIdentifier.init)
            // Finish this paint transaction before preparing another viewport.
            // Otherwise its native clips can enter the previous size's commit.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == nextToken, self.nextScheduled else { return }
                    guard let window = self.window, window.frame == committedFrame,
                          window.contentView.map(ObjectIdentifier.init) == committedRootID else {
                        self.cancel()
                        return
                    }
                    CATransaction.flush()
                    self.nextScheduled = false
                    guard let next = self.pending else { return }
                    self.pending = nil
                    if !self.request(frame: next.frame, display: next.display) { self.commit(next.frame, next.display) }
                    if self.liveResizeEnded && !self.isPreparing { self.finishStyles() }
                }
            }
        } else if liveResizeEnded {
            finishStyles()
        }
    }

    private func timedOut(_ token: UUID) {
        guard generation == token, let active else { return }
        guard let window, window.frame == startingFrame, window.isVisible,
              window.contentView === root,
              pages.allSatisfy({ $0.stillOwned && $0.web.window === window })
        else { cancel(); return }
        let latest = pending ?? active
        let outstanding = remaining
        cancel()
        bypassForDrag = window.inLiveResize
        if bypassForDrag {
            recoveryToken = token
            recoveryRemaining = outstanding
        }
        if window.isVisible { commit(latest.frame, latest.display) }
    }

    private static let presentation = NSSelectorFromString("_doAfterNextPresentationUpdate:")

    static func targets(in root: NSView, nextSize: NSSize, leadingExpansion: CGFloat = 0) -> [PreparedPageResize] {
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
                let dx = delta.width + leadingExpansion - layout.leadingWidth(at: nextSize.width)
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

/// A sidebar close reveals extra page width without a native window proposal.
/// Paint its final viewport under the existing clip before starting the slide.
/// Keep the page's autoresizing mask suspended until SwiftUI installs that layout.
@MainActor final class SidebarPageResizePreparation {
    private weak var window: NSWindow?
    private weak var root: NSView?
    private let frame: NSRect
    private var pages: [PreparedPageResize]
    private let isCurrent: @MainActor () -> Bool
    private let commit: @MainActor () -> Void
    private let presenter: WindowResizePreparation.Presenter?
    private let deadline: WindowResizePreparation.Deadline?
    private var remaining: Int
    private var timer: Timer?
    private var deadlineToken = UUID()
    private let hosts = NSHashTable<WebHost>.weakObjects()
    private var active = false
    private(set) var published = false
    var awaitingPaint: Bool { active && !published }


    init(window: NSWindow, pages: [PreparedPageResize],
         presenter: WindowResizePreparation.Presenter? = nil,
         deadline: WindowResizePreparation.Deadline? = nil,
         isCurrent: @escaping @MainActor () -> Bool,
         commit: @escaping @MainActor () -> Void) {
        self.window = window
        root = window.contentView
        frame = window.frame
        self.pages = pages
        remaining = pages.count
        self.presenter = presenter
        self.deadline = deadline
        self.isCurrent = isCurrent
        self.commit = commit
    }

    func start() {
        guard !pages.isEmpty else { return }
        active = true
        for page in pages {
            if let host = page.web.superview as? WebHost {
                hosts.add(host)
                host.pageLayoutDidResize = { [weak self] in self?.layoutChanged() }
            }
        }
        pages.forEach { $0.prepare() }
        armDeadline(after: 0.25)
        for page in pages {
            let callback: @MainActor @Sendable () -> Void = { [weak self] in self?.presented() }
            if let presenter { presenter(page.web, callback) }
            else {
                let block: @convention(block) () -> Void = { MainActor.assumeIsolated { callback() } }
                page.web.perform(NSSelectorFromString("_doAfterNextPresentationUpdate:"), with: block)
            }
        }
    }

    private func armDeadline(after interval: TimeInterval) {
        timer?.invalidate()
        deadlineToken = UUID()
        let token = deadlineToken
        let timeout: @MainActor @Sendable () -> Void = { [weak self] in self?.timedOut(token) }
        if let deadline { deadline(timeout) }
        else {
            let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { timeout() } }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func cancel() {
        guard active else { return }
        active = false
        deadlineToken = UUID()
        timer?.invalidate()
        timer = nil
        hosts.allObjects.forEach { $0.pageLayoutDidResize = nil }
        hosts.removeAllObjects()
        for page in pages {
            page.restore(committed: published && page.parentReachedPreparedSize)
            PageResizeStyle.finish(page.web)
        }
        pages.removeAll()
    }

    private var ownsLayout: Bool {
        guard let window, window.isVisible, window.frame == frame,
              window.contentView === root else { return false }
        return true
    }

    private func presented() {
        guard active, !published else { return }
        remaining -= 1
        guard remaining == 0 else { return }
        guard ownsLayout, isCurrent(), pages.allSatisfy(\.stillOwned) else { cancel(); return }
        pages.forEach { $0.installNativeGeometry() }
        published = true
        // Painting and native interpolation are separate phases. A slow but
        // successful paint must still leave the sidebar its full configured slide.
        armDeadline(after: UIAnimation.sidebar.duration(0.2) + 0.25)
        commit()
        root?.layoutSubtreeIfNeeded()
        layoutChanged()
    }

    private func layoutChanged() {
        guard active else { return }
        guard ownsLayout else { cancel(); return }
        if !published {
            if !pages.allSatisfy(\.stillOwned) { cancel() }
            return
        }
        // Each split pane can receive its layout in a separate native callback.
        for page in pages where page.parentReachedPreparedSize { page.restore(committed: true) }
        if pages.allSatisfy(\.parentReachedPreparedSize) { cancel() }
    }

    private func timedOut(_ token: UUID) {
        guard active, deadlineToken == token else { return }
        let shouldCommit = !published && ownsLayout && isCurrent()
        cancel()
        // A stalled WebContent process must not disable the sidebar command.
        if shouldCommit { commit() }
    }
}
