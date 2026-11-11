import AppKit
import WebKit

/// A drag owns one persistent native freeze. Painted lookahead lets pointer geometry
/// move independently of WebKit's presentation clock; only uncovered growth waits.
@MainActor final class LivePageResizeBuffer {
    @MainActor private final class Page {
        let web: WKWebView
        weak var host: WebHost?
        let originalSize: NSSize
        let parentSize: NSSize
        let mask: NSView.AutoresizingMask
        let autoSubviews: Bool
        let layout: PageResizeLayout
        let fraction: NSSize
        var painted: NSSize
        var prepared: NSSize
        var installed: NSSize
        var restored = false

        init(web: WKWebView, host: WebHost) {
            self.web = web
            self.host = host
            originalSize = web.frame.size
            parentSize = host.bounds.size
            mask = web.autoresizingMask
            autoSubviews = web.autoresizesSubviews
            layout = host.resizeLayout
            fraction = host.resizeFraction
            painted = originalSize
            prepared = originalSize
            installed = originalSize
        }

        var owned: Bool {
            guard let host else { return false }
            return web.superview === host && host.web === web && !host.offscreen
                && !web.isHiddenOrHasHiddenAncestor && web.frame.size == prepared
                && web.autoresizingMask.isEmpty && !web.autoresizesSubviews
                && host.resizeFraction == fraction && host.resizeLayout.enabled
                && host.resizeLayout.librarySection == layout.librarySection
                && host.resizeLayout.spaces == layout.spaces
                && host.resizeLayout.isPrivate == layout.isPrivate
        }

        func size(root: NSSize, baseline: NSSize, sidebar: CGFloat?) -> NSSize {
            var nextLayout = layout
            if let sidebar { nextLayout.sidebarWidth = sidebar }
            let dx = root.width - baseline.width + layout.leadingWidth(at: baseline.width)
                - nextLayout.leadingWidth(at: root.width)
            return NSSize(width: originalSize.width + (mask.contains(.width) ? dx * fraction.width : 0),
                          height: originalSize.height + (mask.contains(.height) ? (root.height - baseline.height) * fraction.height : 0))
        }

        func freeze() {
            web.autoresizingMask = []
            web.autoresizesSubviews = false
        }

        func prepare(_ size: NSSize) {
            prepared = size
            PageResizeStyle.prepare(web, nextSize: size)
            web.setFrameSize(size)
            web.prepareContent(in: NSRect(origin: .zero, size: size))
        }

        func install() {
            if autoSubviews {
                web.autoresizesSubviews = true
                web.resizeSubviews(withOldSize: installed)
                web.autoresizesSubviews = false
            }
            installed = prepared
            painted = prepared
        }

        var currentVisibleSize: NSSize {
            guard let host else { return originalSize }
            return NSSize(width: originalSize.width + (mask.contains(.width) ? host.bounds.width - parentSize.width : 0),
                          height: originalSize.height + (mask.contains(.height) ? host.bounds.height - parentSize.height : 0))
        }

        func parentReached(_ size: NSSize) -> Bool {
            guard let host else { return false }
            let tolerance = 1 / (host.window?.backingScaleFactor ?? 1) + 0.001
            return (!mask.contains(.width) || abs(host.bounds.width - (parentSize.width + size.width - originalSize.width)) < tolerance)
                && (!mask.contains(.height) || abs(host.bounds.height - (parentSize.height + size.height - originalSize.height)) < tolerance)
        }

        func restore(exact: Bool) {
            guard !restored else { return }
            restored = true
            if let host, web.superview === host {
                if !exact {
                    web.setFrameSize(currentVisibleSize)
                }
                web.autoresizingMask = mask
                web.autoresizesSubviews = autoSubviews
                if autoSubviews { web.resizeSubviews(withOldSize: installed) }
            } else if !web.autoresizesSubviews {
                // The new owner keeps its frame and mask, including any layout it
                // installed while this page's old presentation was in flight.
                web.autoresizesSubviews = autoSubviews
                if autoSubviews { web.resizeSubviews(withOldSize: installed) }
            }
            PageResizeStyle.finish(web)
            web.prepareContent(in: web.bounds)
        }
    }

    private struct Request {
        var frame: NSRect
        var sidebar: CGFloat?
    }

    private weak var window: NSWindow?
    private weak var root: NSView?
    private let baselineFrame: NSRect
    private let baselineSize: NSSize
    private var expectedFrame: NSRect
    private var pages: [Page]
    private var axes: NSSize
    private let apply: @MainActor (NSRect, CGFloat?) -> Void
    private let isCurrent: @MainActor () -> Bool
    private let completion: @MainActor () -> Void
    private let presenter: WindowResizePreparation.Presenter?
    private let deadline: WindowResizePreparation.Deadline?
    private let now: @MainActor () -> TimeInterval
    private var latest: Request
    private var lastSize: NSSize
    private var lastTime: TimeInterval
    private var sampledVelocity = false
    private var lead = NSSize(width: 48, height: 48)
    private var generation = UUID()
    private var pendingPaints = Set<ObjectIdentifier>()
    private var timer: Timer?
    private var started = false
    private var active = true
    private var ending = false
    private var exactPaint = false
    private var applying = false
    private var driving = false
    private var driveAgain = false
    private var windowObservers: [NSObjectProtocol] = []
    private var exactPresented = false
    private var releaseLayoutFlushed = false
    private var awaitingFinalLayout = false
    private var endpointCompletion: (@MainActor () -> Void)?
    private var recoveryToken: UUID?
    private var recoveryPaints = Set<ObjectIdentifier>()
    private(set) var bypassForDrag = false
    private var published: Request?
    var isPreparing: Bool { active && (ending || !pendingPaints.isEmpty) }

    init?(window: NSWindow, axes: NSSize,
          presenter: WindowResizePreparation.Presenter? = nil,
          deadline: WindowResizePreparation.Deadline? = nil,
          now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
          isCurrent: @escaping @MainActor () -> Bool = { true },
          apply: @escaping @MainActor (NSRect, CGFloat?) -> Void,
          completion: @escaping @MainActor () -> Void = {}) {
        guard window.isVisible, !window.styleMask.contains(.fullScreen), let root = window.contentView else { return nil }
        var pages: [Page] = []
        var admitted = true
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let host = view as? WebHost {
                guard !host.offscreen else { return }
                guard host.resizeLayout.enabled else { admitted = false; return }
                let visible = host.subviews.compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
                guard !visible.isEmpty else { return }
                // Docked inspector frontends are WKWebView siblings with their own
                // geometry. Fall back before freezing any part of that arrangement.
                guard visible.count == 1, let web = visible.first, host.web === web,
                      web.frame.width > 0, web.frame.height > 0,
                      web.responds(to: NSSelectorFromString("_doAfterNextPresentationUpdate:")) else { admitted = false; return }
                pages.append(Page(web: web, host: host))
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        guard admitted, !pages.isEmpty else { return nil }
        self.window = window
        self.root = root
        baselineFrame = window.frame
        baselineSize = root.bounds.size
        expectedFrame = window.frame
        latest = Request(frame: window.frame, sidebar: nil)
        lastSize = root.bounds.size
        self.pages = pages
        self.axes = axes
        self.presenter = presenter
        self.deadline = deadline
        self.now = now
        lastTime = now()
        self.isCurrent = isCurrent
        self.apply = apply
        self.completion = completion
    }

    func start() {
        guard active, !started else { return }
        started = true
        pages.forEach { page in
            page.freeze()
            page.host?.pageLayoutDidResize = { [weak self] in self?.layoutChanged() }
            page.host?.pageResizeOwnershipWillChange = { [weak self] in self?.cancel() }
        }
        if let window {
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                let closing = name == NSWindow.willCloseNotification
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if closing { self.cancel() }
                        else if !self.applying && !(self.bypassForDrag ? self.ownsWindow : self.ownsLayout) { self.cancel() }
                    }
                })
            }
        }
        prepare(exact: ending)
    }

    /// True means this buffer owns the proposal, even if it needs more coverage.
    @discardableResult func request(frame: NSRect, sidebarWidth: CGFloat? = nil) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              sidebarWidth?.isFinite != false else { return false }
        if bypassForDrag {
            guard ownsWindow else { cancel(); return false }
            latest = Request(frame: frame, sidebar: sidebarWidth)
            expectedFrame = frame
            apply(frame, sidebarWidth)
            return true
        }
        guard active, !ending, ownsLayout else { if active { cancel() }; return false }
        let request = Request(frame: frame, sidebar: sidebarWidth)
        let size = viewportRoot(request)
        // Constructor-to-first-event time is not a pointer sample interval.
        // Admit a normal first frame before using subsequent observed intervals.
        let elapsed = max(sampledVelocity ? 1.0 / 240 : 1.0 / 60, now() - lastTime)
        sampledVelocity = true
        // Viewport velocity includes sidebar movement, whose window frame is fixed.
        let oldLeading = pages.first?.layout.leadingWidth(at: lastSize.width) ?? 0
        var layout = pages.first?.layout ?? PageResizeLayout()
        if let sidebarWidth { layout.sidebarWidth = sidebarWidth }
        let oldSidebar = latest.sidebar.map { SidebarWidth.fitting($0, in: lastSize.width) } ?? oldLeading
        let horizontal = size.width - lastSize.width + oldSidebar - layout.leadingWidth(at: size.width)
        if horizontal != 0 { lead.width = min(192, max(48, abs(horizontal) / elapsed * 0.18)); axes.width = 1 }
        if size.height != lastSize.height { lead.height = min(192, max(48, abs(size.height - lastSize.height) / elapsed * 0.18)); axes.height = 1 }
        lastSize = size
        lastTime = now()
        latest = request
        if !started { start() }
        drive()
        return true
    }

    func finish(_ completion: @escaping @MainActor () -> Void = {}) {
        if bypassForDrag {
            cancel()
            completion()
            return
        }
        guard active, !ending else { return }
        endpointCompletion = completion
        ending = true
        if !started { start() }
        drive()
    }

    func cancel() {
        if bypassForDrag {
            bypassForDrag = false
            recoveryToken = nil
            recoveryPaints.removeAll()
            pages.forEach { PageResizeStyle.finish($0.web) }
            completion()
        } else { complete(exact: false) }
    }

    private var ownsWindow: Bool {
        guard let window else { return false }
        return window.isVisible && !window.styleMask.contains(.fullScreen)
            && window.contentView === root && window.frame == expectedFrame && isCurrent()
    }

    private var ownsLayout: Bool {
        guard ownsWindow, let window else { return false }
        return !started || pages.allSatisfy { page in
            page.owned && page.web.window === window
                && (latest.sidebar != nil || page.host?.resizeLayout.sidebarWidth == page.layout.sidebarWidth)
        }
    }

    private func viewportRoot(_ request: Request) -> NSSize {
        NSSize(width: baselineSize.width + request.frame.width - baselineFrame.width,
               height: baselineSize.height + request.frame.height - baselineFrame.height)
    }

    private func sizes(_ request: Request) -> [NSSize] {
        pages.map { $0.size(root: viewportRoot(request), baseline: baselineSize, sidebar: request.sidebar) }
    }

    private func covered(_ sizes: [NSSize]) -> Bool {
        zip(pages, sizes).allSatisfy { page, size in
            size.width <= min(page.painted.width, page.prepared.width) + 0.001
                && size.height <= min(page.painted.height, page.prepared.height) + 0.001
        }
    }

    private func publish() {
        guard !applying else { return }
        if let published, published.frame == latest.frame, published.sidebar == latest.sidebar { return }
        published = latest
        applying = true
        expectedFrame = latest.frame
        apply(latest.frame, latest.sidebar)
        applying = false
    }

    private func drive() {
        guard active else { return }
        guard !driving, !applying else { driveAgain = true; return }
        driving = true
        repeat {
            driveAgain = false
            driveOnce()
        } while active && driveAgain
        driving = false
    }

    private func driveOnce() {
        guard ownsLayout else { cancel(); return }
        let desired = sizes(latest)
        let hasCoverage = covered(desired)
        if hasCoverage { publish() }
        guard active else { return }
        if ending, hasCoverage, !releaseLayoutFlushed {
            // Publication deliberately coalesces native host layout during the
            // drag. A covered release must reconcile it before the exact-size
            // floor is calculated, even if this geometry was already published.
            releaseLayoutFlushed = true
            flushFinalLayout()
            guard active else { return }
            guard ownsLayout else { cancel(); return }
        }
        guard pendingPaints.isEmpty else { return }
        if ending {
            if hasCoverage && zip(pages, desired).contains(where: {
                $0.currentVisibleSize.width > $1.width + 0.001 || $0.currentVisibleSize.height > $1.height + 0.001
            }) {
                // SwiftUI can still owe a native host update after the flush.
                // Await that callback instead of repainting its stale larger
                // extent forever (or spinning a synchronous presenter).
                waitForFinalLayout()
                return
            }
            if exactPresented && zip(pages, desired).allSatisfy({ $0.prepared == $1 }) {
                if pages.enumerated().allSatisfy({ $0.element.parentReached(desired[$0.offset]) }) { complete(exact: true) }
                else { waitForFinalLayout() }
            } else { prepare(exact: true) }
            return
        }
        // Refill at half the rolling lead, and reduce obsolete coverage on shrink.
        let needsRefill = zip(pages, desired).contains { page, size in
            let horizontal = page.mask.contains(.width) ? axes.width * lead.width * page.fraction.width : 0
            let vertical = page.mask.contains(.height) ? axes.height * lead.height * page.fraction.height : 0
            return (horizontal > 0 && (page.painted.width - size.width < horizontal / 2
                || page.painted.width - size.width > horizontal + 0.001))
                || (vertical > 0 && (page.painted.height - size.height < vertical / 2
                    || page.painted.height - size.height > vertical + 0.001))
        }
        if needsRefill { prepare(exact: false) }
    }

    private func prepare(exact: Bool) {
        guard active, pendingPaints.isEmpty else { return }
        exactPresented = false
        awaitingFinalLayout = false
        generation = UUID()
        let token = generation
        let desired = sizes(latest)
        let targets = zip(pages, desired).map { page, size in
            // A mixed-axis proposal can wait for growth while its other axis
            // shrinks. Do not prepare a viewport smaller than the still-visible clip.
            NSSize(width: max(page.currentVisibleSize.width, size.width + (exact || !page.mask.contains(.width) ? 0 : axes.width * lead.width * page.fraction.width)),
                   height: max(page.currentVisibleSize.height, size.height + (exact || !page.mask.contains(.height) ? 0 : axes.height * lead.height * page.fraction.height)))
        }
        exactPaint = exact && targets == desired
        guard targets.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }) else { cancel(); return }
        pendingPaints = Set(pages.map { ObjectIdentifier($0.web) })
        zip(pages, targets).forEach { $0.prepare($1) }
        armDeadline(token)
        for page in pages {
            let id = ObjectIdentifier(page.web)
            let callback: @MainActor @Sendable () -> Void = { [weak self] in self?.presented(token, page: id) }
            if let presenter { presenter(page.web, callback) }
            else {
                let block: @convention(block) () -> Void = { MainActor.assumeIsolated { callback() } }
                page.web.perform(NSSelectorFromString("_doAfterNextPresentationUpdate:"), with: block)
            }
        }
    }

    private func presented(_ token: UUID, page: ObjectIdentifier) {
        if bypassForDrag, recoveryToken == token {
            recoveryPaints.remove(page)
            if recoveryPaints.isEmpty { cancel() }
            return
        }
        guard active, generation == token, pendingPaints.remove(page) != nil else { return }
        guard ownsLayout else { cancel(); return }
        guard pendingPaints.isEmpty else { return }
        timer?.invalidate(); timer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            pages.forEach { $0.install() }
            if covered(sizes(latest)) { publish() }
        }
        exactPresented = exactPaint
        if exactPresented { flushFinalLayout() }
        drive()
        // Exact paint may precede SwiftUI's host layout. Its native callback can
        // finish normally; the same bounded watchdog covers a missing layout.
        if active, ending, exactPresented, pendingPaints.isEmpty { waitForFinalLayout() }
    }

    private func flushFinalLayout() {
        applying = true
        root?.layoutSubtreeIfNeeded()
        applying = false
    }

    private func waitForFinalLayout() {
        guard active, !awaitingFinalLayout else { return }
        awaitingFinalLayout = true
        // The completed paint's deadline must not expire this separate phase.
        generation = UUID()
        armDeadline(generation)
    }

    private func layoutChanged() {
        guard active else { return }
        drive()
    }

    private func armDeadline(_ token: UUID) {
        timer?.invalidate()
        let timeout: @MainActor @Sendable () -> Void = { [weak self] in self?.timedOut(token) }
        if let deadline { deadline(0.25, timeout) }
        else {
            let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { timeout() } }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func timedOut(_ token: UUID) {
        guard active, generation == token, !pendingPaints.isEmpty || (ending && (exactPresented || awaitingFinalLayout)) else { return }
        guard ownsLayout else { cancel(); return }
        // Preserve the existing bounded policy for an unresponsive WebContent
        // process: restore native sizing and allow the latest pointer geometry.
        let request = latest
        let apply = self.apply
        let endpoint = endpointCompletion
        let outstanding = pendingPaints
        let released = ending
        complete(exact: false, notify: false)
        expectedFrame = request.frame
        apply(request.frame, request.sidebar)
        if released || outstanding.isEmpty {
            pages.forEach { PageResizeStyle.finish($0.web) }
            completion()
            endpoint?()
        } else {
            // Keep this retired buffer only as the drag's bounded bypass owner.
            // Every outstanding split callback must return before readmission;
            // none may publish its stale geometry or refreeze a replaced page.
            bypassForDrag = true
            recoveryToken = token
            recoveryPaints = outstanding
        }
    }

    private func complete(exact: Bool, notify: Bool = true) {
        guard active else { return }
        active = false
        awaitingFinalLayout = false
        generation = UUID()
        timer?.invalidate(); timer = nil
        pendingPaints.removeAll()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        pages.forEach { page in
            page.host?.pageLayoutDidResize = nil
            page.host?.pageResizeOwnershipWillChange = nil
            page.restore(exact: exact)
        }
        if notify { completion() }
        if exact { endpointCompletion?() }
        endpointCompletion = nil
    }
}
