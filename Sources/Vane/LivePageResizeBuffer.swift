import AppKit
import WebKit

#if DEBUG
/// Fixture-owned, in-memory timing only. Ordinary drags do not read a clock or
/// format log messages; the fixture installs a sink only for an opted-in run.
@MainActor enum ResizeTimingDiagnostics {
    static var sink: ((String, TimeInterval, CGFloat?, CGFloat?) -> Void)?
    static var stateSink: ((String, TimeInterval, [String: String]) -> Void)?

    static func record(_ event: String, width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let sink else { return }
        sink(event, CACurrentMediaTime(), width, height)
    }

    /// Keep state collection lazy: the ordinary DEBUG path must not construct
    /// dictionaries, format native geometry, or read a clock for this trace.
    static func recordState(_ event: String, fields: @autoclosure () -> [String: String]) {
        guard let stateSink else { return }
        stateSink(event, CACurrentMediaTime(), fields())
    }
}
#endif

/// Native overscan extends below the visible top edge in either coordinate system.
/// Capture the full original frame so a parent resize never accumulates origin lead.
struct LivePageResizeAnchor {
    let originalFrame: NSRect
    let originalParentBounds: NSRect
    let flipped: Bool

    func frame(for size: NSSize, in parentBounds: NSRect) -> NSRect {
        let left = originalFrame.minX - originalParentBounds.minX
        let top = flipped ? originalFrame.minY - originalParentBounds.minY
            : originalParentBounds.maxY - originalFrame.maxY
        return NSRect(x: parentBounds.minX + left,
                      y: flipped ? parentBounds.minY + top : parentBounds.maxY - top - size.height,
                      width: size.width, height: size.height)
    }
}

/// A drag suspends parent-driven page sizing behind a native host clip. Painted lookahead lets pointer geometry
/// move independently of WebKit's presentation clock; only uncovered growth waits.
@MainActor final class LivePageResizeBuffer {
    struct Navigation {
        let owner: UUID
        let leading: CGFloat
    }

    typealias FrameDriver = (@escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    @MainActor private final class Page {
        let web: WKWebView
        weak var host: WebHost?
        let originalSize: NSSize
        let anchor: LivePageResizeAnchor
        private var expectedFrame: NSRect
        let parentSize: NSSize
        let mask: NSView.AutoresizingMask
        let autoSubviews: Bool
        let hostClip: Bool
        let layout: PageResizeLayout
        let fraction: NSSize
        let navigation: Navigation?
        var painted: NSSize
        var prepared: NSSize
        var restored = false
        private var stylePreparation: UUID?

        init(web: WKWebView, host: WebHost, navigation: Navigation? = nil) {
            self.navigation = navigation
            self.web = web
            self.host = host
            originalSize = web.frame.size
            anchor = LivePageResizeAnchor(originalFrame: web.frame, originalParentBounds: host.bounds, flipped: host.isFlipped)
            expectedFrame = web.frame
            parentSize = host.bounds.size
            mask = web.autoresizingMask
            autoSubviews = web.autoresizesSubviews
            hostClip = host.clipsToBounds
            layout = host.resizeLayout
            fraction = host.resizeFraction
            painted = originalSize
            prepared = originalSize
        }

        var owned: Bool {
            guard let host else { return false }
            return web.superview === host && host.web === web && !host.offscreen
                && !web.isHiddenOrHasHiddenAncestor && web.frame == expectedFrame && host.isFlipped == anchor.flipped
                && web.autoresizingMask.isEmpty && web.autoresizesSubviews == autoSubviews && host.clipsToBounds
                && host.resizeFraction == fraction && host.resizeLayout.enabled
                && host.resizeLayout.librarySection == layout.librarySection
                && host.resizeLayout.spaces == layout.spaces
                && host.resizeLayout.isPrivate == layout.isPrivate
                && (navigation == nil || host.libraryNavigationPaintOwner == navigation?.owner)
        }

        func size(root: NSSize, baseline: NSSize, sidebar: CGFloat?) -> NSSize {
            var nextLayout = layout
            if let sidebar { nextLayout.sidebarWidth = sidebar }
            let dx = root.width - baseline.width + (navigation.map { $0.leading - (sidebar ?? $0.leading) }
                ?? (layout.leadingWidth(at: baseline.width) - nextLayout.leadingWidth(at: root.width)))
            return NSSize(width: originalSize.width + (mask.contains(.width) ? dx * fraction.width : 0),
                          height: originalSize.height + (mask.contains(.height) ? (root.height - baseline.height) * fraction.height : 0))
        }

        func freeze() {
            host?.clipsToBounds = true
            web.autoresizingMask = []
        }

        private func assignFrame(size: NSSize) {
            guard let host, web.superview === host else { return }
            expectedFrame = anchor.frame(for: size, in: host.bounds)
            if web.frame != expectedFrame { web.frame = expectedFrame }
        }

        func prepare(_ size: NSSize, progress: (() -> Void)? = nil) {
            prepared = size
            // Move and size together before reading safeAreaInsets. Growing up
            // into a titled window's unsafe area does not grow its CSS viewport.
            assignFrame(size: size)
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.prepare.frameAssigned", width: size.width, height: size.height)
#endif
            stylePreparation = PageResizeStyle.prepare(web, nextSize: size, completion: progress)
            web.prepareContent(in: NSRect(origin: .zero, size: size))
        }

        func reanchor() {
            guard owned, let host else { return }
            let frame = anchor.frame(for: prepared, in: host.bounds)
            guard frame != expectedFrame else { return }
            assignFrame(size: prepared)
            stylePreparation = PageResizeStyle.prepare(web, nextSize: prepared)
        }

        func acknowledgePaint() { painted = prepared }

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
            if let host, host.web === web {
                let ownsSizing = web.superview === host && web.frame == expectedFrame
                    && web.autoresizingMask.isEmpty && web.autoresizesSubviews == autoSubviews
                if ownsSizing {
                    assignFrame(size: exact ? prepared : currentVisibleSize)
                    web.autoresizingMask = mask
                }
                // A moved page keeps its new owner's native frame and flags.
                // The old host can retire its clip only while that clip still
                // belongs to this page, rather than a replacement in this host.
                if host.clipsToBounds, ownsSizing || web.superview !== host {
                    host.clipsToBounds = hostClip
                }
            }
            finishStyle()
            web.prepareContent(in: web.bounds)
        }

        func finishStyle() {
            // A timeout can outlive this host. The queued script must not retire
            // hints prepared later by either a transferred or a renewed owner.
            if let stylePreparation { PageResizeStyle.finish(web, matching: stylePreparation) }
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
    private let navigation: Navigation?
    private let frameDriver: FrameDriver?
    private var stopFrames: (@MainActor () -> Void)?
    private var inPublicationFrame = false
    private var publicationAllowed = false
    private var latest: Request
    private var lastSize: NSSize
    private var lastTime: TimeInterval
    private var sampledVelocity = false
    private var lead = NSSize(width: 48, height: 48)
    private var shrinkingWidth = false
    private var shrinkingHeight = false
    private var generation = UUID()
    private var pendingPaints = Set<ObjectIdentifier>()
    private var pendingStyleReplies = Set<ObjectIdentifier>()
    private var styleReplyDeadline: TimeInterval?
    private var deadlineRevision = UUID()
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
    private var hasPresentedViewport = false
    private var releaseLayoutFlushed = false
    private var awaitingFinalLayout = false
    private var endpointCompletion: (@MainActor () -> Void)?
    private var recoveryToken: UUID?
    private var recoveryPaints = Set<ObjectIdentifier>()
    private(set) var bypassForDrag = false
    private(set) var usesNativeSidebarSizing = false
    private var published: Request?
    private var submittedSidebar: CGFloat?
    private var submittedSidebarSizes: [NSSize]?
    private var submittedSidebarFloor: [NSSize]?
    private var submittedSidebarRevisions: [UInt]?
    var isPreparing: Bool { active && (ending || !pendingPaints.isEmpty) }

#if DEBUG
    private func trace(_ event: String, token: UUID? = nil, page: ObjectIdentifier? = nil, sidebar: CGFloat? = nil) {
        guard let stateSink = ResizeTimingDiagnostics.stateSink else { return }
        let timestamp = CACurrentMediaTime()
        var fields: [String: String] = [
            "buffer": String(describing: ObjectIdentifier(self)), "generation": generation.uuidString,
            "callbackGeneration": token?.uuidString ?? "nil", "callbackPage": page.map(String.init(describing:)) ?? "nil",
            "active": String(active), "ending": String(ending), "bypass": String(bypassForDrag),
            "started": String(started), "hasPresentedViewport": String(hasPresentedViewport),
            "nativeSizing": String(usesNativeSidebarSizing), "applying": String(applying),
            "exactPaint": String(exactPaint), "exactPresented": String(exactPresented),
            "awaitingFinalLayout": String(awaitingFinalLayout), "ownsWindow": String(ownsWindow),
            "ownsLayout": String(ownsLayout), "pending": String(pendingPaints.count),
            "recoveryGeneration": recoveryToken?.uuidString ?? "nil", "recoveryPending": String(recoveryPaints.count),
            "requestedFrame": NSStringFromRect(latest.frame), "expectedFrame": NSStringFromRect(expectedFrame),
            "windowFrame": window.map { NSStringFromRect($0.frame) } ?? "nil",
            "rootBounds": root.map { NSStringFromRect($0.bounds) } ?? "nil",
            "requestedSidebar": latest.sidebar.map { String(Double($0)) } ?? "nil",
            "candidateSidebar": sidebar.map { String(Double($0)) } ?? "nil",
            "submittedSidebar": submittedSidebar.map { String(Double($0)) } ?? "nil",
            "publishedSidebar": published?.sidebar.map { String(Double($0)) } ?? "nil"
        ]
        let desired = sizes(latest)
        for (index, page) in pages.enumerated() {
            let prefix = "page.\(index)."
            fields[prefix + "id"] = String(describing: ObjectIdentifier(page.web))
            fields[prefix + "owned"] = String(page.owned)
            fields[prefix + "pending"] = String(pendingPaints.contains(ObjectIdentifier(page.web)))
            fields[prefix + "desired"] = NSStringFromSize(desired[index])
            fields[prefix + "prepared"] = NSStringFromSize(page.prepared)
            fields[prefix + "painted"] = NSStringFromSize(page.painted)
            fields[prefix + "visible"] = NSStringFromSize(page.currentVisibleSize)
            fields[prefix + "webFrame"] = NSStringFromRect(page.web.frame)
            fields[prefix + "webBounds"] = NSStringFromRect(page.web.bounds)
            fields[prefix + "parentBounds"] = page.host.map { NSStringFromRect($0.bounds) } ?? "nil"
            fields[prefix + "parentFrame"] = page.host.map { NSStringFromRect($0.frame) } ?? "nil"
            fields[prefix + "parentClip"] = page.host.map { String($0.clipsToBounds) } ?? "nil"
            fields[prefix + "metadataSidebar"] = page.host.map { String(Double($0.resizeLayout.sidebarWidth)) } ?? "nil"
            fields[prefix + "metadataRevision"] = page.host.map { String($0.resizeLayoutRevision) } ?? "nil"
            fields[prefix + "submittedRevision"] = submittedSidebarRevisions.map { String($0[index]) } ?? "nil"
            fields[prefix + "submittedSize"] = submittedSidebarSizes.map { NSStringFromSize($0[index]) } ?? "nil"
            fields[prefix + "submittedFloor"] = submittedSidebarFloor.map { NSStringFromSize($0[index]) } ?? "nil"
            fields[prefix + "publicationReached"] = String(sidebarPublicationReached(page: page, index: index, afterEndingFlush: false))
            fields[prefix + "nativeChildren"] = page.web.subviews.prefix(8).map { child in
                "\(type(of: child)):\(NSStringFromRect(child.frame)) children=" + child.subviews.prefix(8).map {
                    "\(type(of: $0)):\(NSStringFromRect($0.frame))"
                }.joined(separator: ";")
            }.joined(separator: "|")
        }
        stateSink(event, timestamp, fields)
    }
#endif

    init?(window: NSWindow, axes: NSSize,
          presenter: WindowResizePreparation.Presenter? = nil,
          deadline: WindowResizePreparation.Deadline? = nil,
          now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
          frameDriver: FrameDriver? = nil,
          navigation: Navigation? = nil,
          isCurrent: @escaping @MainActor () -> Bool = { true },
          apply: @escaping @MainActor (NSRect, CGFloat?) -> Void,
          completion: @escaping @MainActor () -> Void = {}) {
        guard window.isVisible, !window.styleMask.contains(.fullScreen), let root = window.contentView else { return nil }
        var candidates: [(host: WebHost, web: WKWebView)] = []
        var admitted = true
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let host = view as? WebHost {
                if let navigation, host.libraryNavigationPaintOwner != navigation.owner { return }
                guard !host.offscreen else { return }
                // A navigation request waits for an active native pointer resize.
                // Native resize admission below retires the previous viewport owner.
                if navigation != nil, host.pageResizeOwnershipWillChange != nil { admitted = false; return }
                guard host.resizeLayout.enabled else { admitted = false; return }
                let visible = host.subviews.compactMap { $0 as? WKWebView }.filter { !$0.isHiddenOrHasHiddenAncestor }
                guard !visible.isEmpty else { return }
                // Docked inspector frontends are WKWebView siblings with their own
                // geometry. Fall back before freezing any part of that arrangement.
                guard visible.count == 1, let web = visible.first, host.web === web,
                      web.frame.width > 0, web.frame.height > 0,
                      web.responds(to: NSSelectorFromString("_doAfterNextPresentationUpdate:")) else { admitted = false; return }
                candidates.append((host, web))
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        guard admitted, !candidates.isEmpty else { return nil }
        if navigation == nil { candidates.forEach { $0.host.pageResizeOwnershipWillChange?() } }
        guard window.contentView === root, candidates.allSatisfy({
            $0.host.web === $0.web && $0.web.superview === $0.host && !$0.host.isHiddenOrHasHiddenAncestor
        }) else { return nil }
        // Capture masks and frames only after the previous owner has restored
        // them. Otherwise a window drag inherits Library's temporary empty mask.
        let pages = candidates.map { Page(web: $0.web, host: $0.host, navigation: navigation) }
        self.window = window
        self.root = root
        baselineFrame = window.frame
        baselineSize = root.bounds.size
        expectedFrame = window.frame
        latest = Request(frame: window.frame, sidebar: navigation?.leading)
        // The admitted baseline is already installed. Publishing its first
        // unchanged proposal would dirty the native window while WebKit is
        // preparing the initial buffer, without moving any visible geometry.
        published = latest
        lastSize = root.bounds.size
        self.pages = pages
        self.axes = axes
        self.presenter = presenter
        self.deadline = deadline
        self.now = now
        self.navigation = navigation
        self.frameDriver = frameDriver
        lastTime = now()
        self.isCurrent = isCurrent
        self.apply = apply
        self.completion = completion
    }

    isolated deinit { stopFrames?() }

    private func stopPublicationFrames() {
        let stop = stopFrames
        stopFrames = nil
        stop?()
    }

    private func advancePublicationFrame() {
        guard active, !ending, !inPublicationFrame else { return }
        inPublicationFrame = true
        publicationAllowed = true
        defer { publicationAllowed = false; inPublicationFrame = false }
        drive()
    }

    func start() {
        guard active, !started else { return }
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.start")
        trace("buffer.start")
#endif
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
        if !ending { stopFrames = frameDriver? { [weak self] in self?.advancePublicationFrame() } }
        prepare(exact: ending)
    }

    /// True means this buffer owns the proposal, even if it needs more coverage.
    @discardableResult func request(frame: NSRect, sidebarWidth: CGFloat? = nil) -> Bool {
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.request", width: frame.width, height: sidebarWidth)
        trace("buffer.request.before")
#endif
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              sidebarWidth?.isFinite != false else { return false }
        if bypassForDrag {
            guard ownsWindow else { cancel(); return false }
            latest = Request(frame: frame, sidebar: sidebarWidth)
            expectedFrame = frame
            apply(frame, sidebarWidth)
#if DEBUG
            trace("buffer.bypass.applied")
#endif
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
        let oldSidebar = navigation.map { latest.sidebar ?? $0.leading }
            ?? latest.sidebar.map { SidebarWidth.fitting($0, in: lastSize.width) } ?? oldLeading
        let nextLeading = navigation.map { sidebarWidth ?? latest.sidebar ?? $0.leading }
            ?? layout.leadingWidth(at: size.width)
        let horizontal = size.width - lastSize.width + oldSidebar - nextLeading
        if horizontal != 0 { shrinkingWidth = horizontal < 0; lead.width = min(navigation == nil ? 192 : 64, max(48, abs(horizontal) / elapsed * 0.18)); axes.width = 1 }
        if size.height != lastSize.height { shrinkingHeight = size.height < lastSize.height; lead.height = min(192, max(48, abs(size.height - lastSize.height) / elapsed * 0.18)); axes.height = 1 }
        lastSize = size
        lastTime = now()
        latest = request
#if DEBUG
        trace("buffer.request.accepted")
#endif
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
        stopPublicationFrames()
        if !started { start() }
        // A paused Library clip is already installed and covered. Supersede
        // lookahead with its exact native viewport immediately; waiting for the
        // older paint would leave native sizing ahead after fingers stop.
        if navigation != nil, !pendingPaints.isEmpty, covered(sizes(latest)),
           zip(pages, sizes(latest)).allSatisfy({ $0.parentReached($1) }) {
            prepare(exact: true)
        }
        drive()
    }

    func cancel() {
#if DEBUG
        trace("buffer.cancel")
#endif
        usesNativeSidebarSizing = false
        if bypassForDrag {
            bypassForDrag = false
            recoveryToken = nil
            recoveryPaints.removeAll()
            pages.forEach { $0.finishStyle() }
#if DEBUG
            trace("buffer.bypass.retired")
#endif
            completion()
#if DEBUG
            trace("buffer.completion.returned")
#endif
        } else { complete(exact: false) }
    }

    /// Only a sidebar coalescer needs same-size metadata acknowledgment layouts.
    func trackSidebarPublicationLayout() {
        pages.forEach { page in
            page.host?.pageResizeLayoutDidUpdate = { [weak self] in self?.layoutChanged() }
            let host = page.host
            host?.pageResizeLayoutNeedsUpdate = { [weak self, weak host] in
                guard let self, let host, self.active, self.ownsLayout,
                      let index = self.pages.firstIndex(where: { $0.host === host }) else { return false }
#if DEBUG
                self.trace("buffer.sidebar.metadata.checked", page: ObjectIdentifier(self.pages[index].web))
#endif
                return self.sidebarPublicationReached(page: self.pages[index], index: index, afterEndingFlush: false)
            }
        }
    }

    /// A display callback is later than the covered apply callback. Revalidate
    /// the native owners and both paints at the point of actual publication.
    func validateSidebarPublication() -> Bool {
#if DEBUG
        trace("buffer.sidebar.validate")
#endif
        guard (active || usesNativeSidebarSizing), ownsWindow, !active || ownsLayout else {
            cancel()
            return false
        }
        return true
    }

    func publishSidebarWidth(_ width: CGFloat, _ publication: @MainActor (CGFloat) -> Void) {
#if DEBUG
        trace("buffer.sidebar.candidate", sidebar: width)
#endif
        guard validateSidebarPublication() else { return }
        if active {
            let desired = sizes(Request(frame: expectedFrame, sidebar: width))
            guard covered(desired) else {
#if DEBUG
                trace("buffer.sidebar.uncovered")
#endif
                return
            }
            // Raw proposals can differ while fitting to identical geometry and
            // therefore cause no new SwiftUI state update. Keep the original
            // acknowledgment requirement for that same effective submission.
            if submittedSidebarSizes != desired {
                submittedSidebarRevisions = pages.map { $0.host?.resizeLayoutRevision ?? 0 }
            }
            submittedSidebar = width
            submittedSidebarSizes = desired
            if let floor = submittedSidebarFloor {
                submittedSidebarFloor = zip(floor, desired).map {
                    NSSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
                }
            } else { submittedSidebarFloor = desired }
        }
#if DEBUG
        trace("buffer.sidebar.publication.before")
#endif
        publication(width)
#if DEBUG
        trace("buffer.sidebar.publication.after")
#endif
    }

    private func acknowledgeSidebarPublication(afterEndingFlush: Bool = false) {
        guard pages.enumerated().allSatisfy({ index, page in
            sidebarPublicationReached(page: page, index: index, afterEndingFlush: afterEndingFlush)
        }) else { return }
#if DEBUG
        trace(afterEndingFlush ? "buffer.sidebar.ack.endingFlush" : "buffer.sidebar.ack.layout")
#endif
        submittedSidebar = nil
        submittedSidebarSizes = nil
        submittedSidebarFloor = nil
        submittedSidebarRevisions = nil
    }

    private func sidebarPublicationReached(page: Page, index: Int, afterEndingFlush: Bool) -> Bool {
        guard let sidebar = submittedSidebar, let target = submittedSidebarSizes,
              let revisions = submittedSidebarRevisions else { return false }
        let rootWidth = viewportRoot(Request(frame: expectedFrame, sidebar: sidebar)).width
        var layout = page.layout
        layout.sidebarWidth = sidebar
        if navigation != nil { return page.parentReached(target[index]) }
        return (afterEndingFlush || page.host?.resizeLayoutRevision != revisions[index])
            && page.parentReached(target[index])
            && page.host?.resizeLayout.leadingWidth(at: rootWidth) == layout.leadingWidth(at: rootWidth)
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
        // Native frame proposals can outpace the compositor. Keep every input
        // for coverage/velocity, but install only the latest covered geometry at
        // a display boundary. Release drains synchronously without another tick.
        guard frameDriver == nil || ending || publicationAllowed else { return }
        publicationAllowed = false
        published = latest
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.publish.begin", width: latest.frame.width, height: latest.sidebar)
        trace("buffer.publish.begin")
#endif
        applying = true
        expectedFrame = latest.frame
        apply(latest.frame, latest.sidebar)
        pages.forEach { $0.reanchor() }
        applying = false
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.publish.end", width: window?.frame.width, height: latest.sidebar)
        trace("buffer.publish.end")
#endif
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
            let submittedParentIsLarger = submittedSidebarFloor.map { floor in
                zip(floor, desired).contains { $0.width > $1.width + 0.001 || $0.height > $1.height + 0.001 }
            } ?? false
            if hasCoverage && (submittedParentIsLarger || zip(pages, desired).contains(where: {
                $0.currentVisibleSize.width > $1.width + 0.001 || $0.currentVisibleSize.height > $1.height + 0.001
            })) {
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
        // Growth needs painted lookahead. Shrinking already has coverage: keep
        // only a small hysteresis band, otherwise responsive pages retain entire
        // columns outside the visible card and jump by up to 192pt at release.
        let needsRefill = zip(pages, desired).contains { page, size in
            let horizontal = page.mask.contains(.width) ? axes.width * lead.width * page.fraction.width : 0
            let vertical = page.mask.contains(.height) ? axes.height * lead.height * page.fraction.height : 0
            // A sidebar publication may still be waiting for SwiftUI's native
            // parent update. Trimming to that future size would reflow the page
            // twice while its actual clip has not moved at all.
            let visible = page.currentVisibleSize
            let dx = page.painted.width - (shrinkingWidth ? max(size.width, visible.width) : size.width)
            let dy = page.painted.height - (shrinkingHeight ? max(size.height, visible.height) : size.height)
            return (horizontal > 0 && (shrinkingWidth ? dx > 48 * page.fraction.width + 0.001
                : dx < horizontal / 2 || dx > 192 * page.fraction.width + 0.001))
                || (vertical > 0 && (shrinkingHeight ? dy > 48 * page.fraction.height + 0.001
                : dy < vertical / 2 || dy > 192 * page.fraction.height + 0.001))
        }
        if needsRefill { prepare(exact: false) }
    }

    private func prepare(exact: Bool) {
        guard active, pendingPaints.isEmpty else { return }
        let desired = sizes(latest)
        let targets = zip(pages, desired).enumerated().map { index, pair in
            let (page, size) = pair
            // SwiftUI may still install an earlier submitted parent after a
            // newer width was queued. Keep those actual submissions covered
            // until native layout acknowledges the latest one, even if it
            // coalesces past every intermediate parent.
            let submitted = submittedSidebarFloor?[index] ?? .zero
            // A mixed-axis proposal can wait for growth while its other axis
            // shrinks. Do not prepare a viewport smaller than the still-visible clip.
            return NSSize(width: max(submitted.width, page.currentVisibleSize.width,
                                    size.width + (exact || !page.mask.contains(.width) || (navigation != nil && shrinkingWidth && !hasPresentedViewport) ? 0 : axes.width * (shrinkingWidth ? 24 : lead.width) * page.fraction.width)),
                          height: max(submitted.height, page.currentVisibleSize.height,
                                     size.height + (exact || !page.mask.contains(.height) ? 0 : axes.height * (shrinkingHeight ? 24 : lead.height) * page.fraction.height)))
        }
        // Deferred native submissions can hold a larger floor through several
        // drag inputs. Repainting the same effective target cannot reduce it.
        // Keep the initial presentation even when a native axis is fixed.
        if !exact, hasPresentedViewport,
           zip(pages, targets).allSatisfy({ $0.prepared == $1 && $0.painted == $1 }) { return }
        exactPresented = false
        awaitingFinalLayout = false
        generation = UUID()
        let token = generation
        exactPaint = exact && targets == desired
        guard targets.allSatisfy({ $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }) else { cancel(); return }
        pendingPaints = Set(pages.map { ObjectIdentifier($0.web) })
        pendingStyleReplies = pendingPaints
#if DEBUG
        trace("buffer.prepare.before")
#endif
        zip(pages, targets).forEach { page, target in
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.prepare.begin", width: target.width, height: target.height)
#endif
            let id = ObjectIdentifier(page.web)
            page.prepare(target, progress: { [weak self] in self?.styleReplied(token, page: id) })
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.prepare.end", width: target.width, height: target.height)
#endif
        }
#if DEBUG
        trace("buffer.prepare.after")
#endif
        styleReplyDeadline = now() + 0.25
        armDeadline(token)
        for page in pages {
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.presentation.request", width: page.prepared.width, height: page.prepared.height)
            trace("buffer.presentation.request", token: token, page: ObjectIdentifier(page.web))
#endif
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
#if DEBUG
        trace("buffer.presentation.arrived", token: token, page: page)
#endif
        if bypassForDrag, recoveryToken == token {
            recoveryPaints.remove(page)
            if recoveryPaints.isEmpty { cancel() }
            return
        }
        guard active, generation == token, pendingPaints.remove(page) != nil else { return }
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.presentation.callback")
#endif
        guard ownsLayout else { cancel(); return }
        guard pendingPaints.isEmpty else { return }
        timer?.invalidate(); timer = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.install.begin")
#endif
            pages.forEach { $0.acknowledgePaint() }
            hasPresentedViewport = true
#if DEBUG
            ResizeTimingDiagnostics.record("buffer.install.end")
            trace("buffer.paint.acknowledged", token: token, page: page)
#endif
            if covered(sizes(latest)) { publish() }
        }
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.presentation.groupClosed")
#endif
        exactPresented = exactPaint
        if exactPresented { flushFinalLayout() }
        drive()
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.presentation.drained")
#endif
        // Exact paint may precede SwiftUI's host layout. Its native callback can
        // finish normally; the same bounded watchdog covers a missing layout.
        if active, ending, exactPresented, pendingPaints.isEmpty { waitForFinalLayout() }
    }

    private func flushFinalLayout() {
        applying = true
        root?.layoutSubtreeIfNeeded()
        pages.forEach { $0.reanchor() }
        // SwiftUI can diff-elide a child when several publications return to its
        // existing value. The explicit ending flush is its acknowledgment even
        // without a new representable revision, but only if metadata and every
        // actual native parent already match the latest submission.
        if ending { acknowledgeSidebarPublication(afterEndingFlush: true) }
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
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.host.layout", width: pages.first?.host?.bounds.width, height: pages.first?.host?.bounds.height)
        trace("buffer.host.layout.before")
#endif
        // Native host callbacks may arrive inside apply(). Reposition the frozen
        // viewport immediately, without recursively laying out retained chrome.
        pages.forEach { $0.reanchor() }
        acknowledgeSidebarPublication()
#if DEBUG
        trace("buffer.host.layout.after")
#endif
        drive()
    }

    private func armDeadline(_ token: UUID) {
#if DEBUG
        trace("buffer.deadline.armed", token: token)
#endif
        timer?.invalidate()
        let revision = UUID()
        deadlineRevision = revision
        let timeout: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.deadlineRevision == revision else { return }
            self.timedOut(token)
        }
        if let deadline { deadline(0.25, timeout) }
        else {
            let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { timeout() } }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func styleReplied(_ token: UUID, page: ObjectIdentifier) {
        guard active, generation == token, pendingStyleReplies.remove(page) != nil,
              pendingStyleReplies.isEmpty, !pendingPaints.isEmpty, ownsLayout else { return }
        // An overdue timer can sit behind this reply in the main queue. Its
        // original monotonic deadline still applies even before it is delivered.
        guard let styleReplyDeadline, now() <= styleReplyDeadline else {
            timedOut(token)
            return
        }
#if DEBUG
        trace("buffer.progress.styleReplied", token: token, page: page)
#endif
        // A reply proves the process is advancing through queued geometry, not
        // hung. Renew once for the subsequent paint phase; absent replies still
        // retain the original deadline, and paint itself remains bounded.
        armDeadline(token)
    }

    private func timedOut(_ token: UUID) {
#if DEBUG
        trace("buffer.deadline.fired", token: token)
#endif
        guard active, generation == token, !pendingPaints.isEmpty || (ending && (exactPresented || awaitingFinalLayout)) else { return }
#if DEBUG
        ResizeTimingDiagnostics.record("buffer.timeout")
        trace("buffer.timeout", token: token)
#endif
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
        usesNativeSidebarSizing = true
        apply(request.frame, request.sidebar)
        if released || outstanding.isEmpty {
            pages.forEach { $0.finishStyle() }
            completion()
#if DEBUG
            trace("buffer.completion.returned")
#endif
            endpoint?()
        } else {
            // Keep this retired buffer only as the drag's bounded bypass owner.
            // Every outstanding split callback must return before readmission;
            // none may publish its stale geometry or refreeze a replaced page.
            bypassForDrag = true
            recoveryToken = token
            recoveryPaints = outstanding
#if DEBUG
            trace("buffer.bypass.started", token: token)
#endif
        }
    }

    private func complete(exact: Bool, notify: Bool = true) {
        guard active else { return }
#if DEBUG
        trace(exact ? "buffer.complete.exact" : "buffer.complete.restore")
#endif
        active = false
        stopPublicationFrames()
        awaitingFinalLayout = false
        generation = UUID()
        timer?.invalidate(); timer = nil
        pendingPaints.removeAll()
        pendingStyleReplies.removeAll()
        styleReplyDeadline = nil
        submittedSidebar = nil
        submittedSidebarSizes = nil
        submittedSidebarFloor = nil
        submittedSidebarRevisions = nil
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        pages.forEach { page in
            page.host?.pageLayoutDidResize = nil
            page.host?.pageResizeLayoutDidUpdate = nil
            page.host?.pageResizeLayoutNeedsUpdate = nil
            page.host?.pageResizeOwnershipWillChange = nil
            page.restore(exact: exact)
        }
#if DEBUG
        trace("buffer.restored")
#endif
        if notify {
            completion()
#if DEBUG
            trace("buffer.completion.returned")
#endif
        }
        if exact { endpointCompletion?() }
        endpointCompletion = nil
    }
}
