import AppKit
import SwiftUI
import WebKit

/// Limit a Library paint owner to its own visible documents, including split
/// panes, without touching another retained profile's WebKit hosts.
private struct LibraryNavigationPaintOwner: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var libraryNavigationPaintOwner: UUID? {
        get { self[LibraryNavigationPaintOwner.self] }
        set { self[LibraryNavigationPaintOwner.self] = newValue }
    }
}

/// Publish one Library geometry phase only after its exact document viewport
/// covers it. Shrinking clips use existing paint; growth waits for presentation.
@MainActor final class LibraryNavigationPaint: ObservableObject {
    let owner = UUID()
    @Published private(set) var progress: CGFloat {
        didSet { if progress != oldValue { didPublishPhase() } }
    }
    /// While a slide animates, accept at most one phase per display frame. Each
    /// accepted phase renders, and that render advances the animation and requests
    /// the next phase; drained at once, those renders chained back to back and kept
    /// the main thread busy between frames. Finger samples are never held back.
    private var pacesPhases = false
    private var publishedThisFrame = false
    private var deferredDrain = false
    private var deferral = 0
    private var stopPublicationFrames: (() -> Void)?
    private weak var marker: NSView?
    private var generation = UUID()
    private var queued = false
    private var arrival: (target: CGFloat, visible: () -> Bool, completion: () -> Void)?
    private var stopArrivalFrames: (() -> Void)?
    private var pendingPaints = Set<ObjectIdentifier>()
    private var deadline: Timer?

    private var requestedProgress: CGFloat
    private var startLeading: CGFloat = 0
    private var endLeading: CGFloat = 0
    private var acceptedLeading: CGFloat?
    private var buffer: LivePageResizeBuffer?
    private var finishingBuffer = false
    private var bufferToken = UUID()
    private var requestedLeading: CGFloat = 0
    private var currentLeading: CGFloat = 0
    var isPreparing: Bool { arrival != nil || requestedProgress != progress || buffer != nil }

    private let presenter: WindowResizePreparation.Presenter?
    private let deadlineDriver: WindowResizePreparation.Deadline?

    /// Tests inject the buffer's paint and watchdog clocks; production passes neither.
    init(progress: CGFloat, presenter: WindowResizePreparation.Presenter? = nil,
         deadline: WindowResizePreparation.Deadline? = nil) {
        self.progress = progress; requestedProgress = progress
        self.presenter = presenter; deadlineDriver = deadline
    }

    /// Where AppKit has actually installed the page edge, which can trail the
    /// accepted phase by one SwiftUI layout.
    private func installedLeading(in window: NSWindow) -> CGFloat? {
        guard let marker, marker.window === window, let root = window.contentView else { return nil }
        return marker.convert(.zero, to: root).x - root.bounds.minX
    }

    func afterPresentation(of target: CGFloat, when visible: @escaping () -> Bool,
                           _ completion: @escaping () -> Void) {
        retirePaint()
        arrival = (target, visible, completion)
        schedule()
    }

    func request(_ value: CGFloat, marker: NSView, startLeading: CGFloat, endLeading: CGFloat, targetLeading: CGFloat, currentLeading: CGFloat, animating: Bool = false) {
        pacesPhases = animating
        let value = min(1, max(0, value))
        if self.marker !== marker || requestedProgress != value { retirePaint() }
        self.marker = marker
        requestedProgress = value
        self.startLeading = startLeading
        self.endLeading = endLeading
        requestedLeading = targetLeading
        self.currentLeading = currentLeading
        // Ordinary window layout also updates this bridge. An idle Library has
        // no paint work and must not enqueue another main-thread turn per size.
        if requestedProgress != progress || buffer != nil || arrival != nil { schedule() }
    }

    isolated deinit {
        stopPublicationFrames?()
        stopArrivalFrames?()
    }

    private func didPublishPhase() {
        guard pacesPhases else { return }
        publishedThisFrame = true
        guard stopPublicationFrames == nil, let window = marker?.window else { return }
        stopPublicationFrames = SidebarResizePublication.displayFrames(for: window)({ [weak self] in
            self?.publicationFrameDidPass()
        })
    }

    private func publicationFrameDidPass() {
        publishedThisFrame = false
        guard deferredDrain else {
            stopPublicationFrames?(); stopPublicationFrames = nil
            return
        }
        deferredDrain = false
        schedule()
    }

    private func schedule() {
        guard !queued else { return }
        if pacesPhases, publishedThisFrame, stopPublicationFrames != nil {
            guard !deferredDrain else { return }
            deferredDrain = true
            deferral &+= 1
            let token = deferral
            // The display clock normally lands this first. Keep a bound in case the
            // screen stops delivering frames, so a landing still reaches rest; the
            // next phase then starts a link on the window's current screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.deferredDrain, self.deferral == token else { return }
                self.stopPublicationFrames?(); self.stopPublicationFrames = nil
                self.publicationFrameDidPass()
            }
            return
        }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false
            self.drain()
        }
    }

    private func waitForFrame(in window: NSWindow) {
        guard stopArrivalFrames == nil else { return }
        stopArrivalFrames = SidebarResizePublication.displayFrames(for: window)({ [weak self] in self?.schedule() })
    }

    func drain() {
        if !finishingBuffer, let window = marker?.window, window.isVisible {
            let leading = requestedLeading
            // Different logical phases can round to the same backing-pixel edge.
            // Their already-settled native viewport needs no new paint transaction.
            if buffer == nil, leading == currentLeading, progress != requestedProgress {
                Motion.instant { progress = requestedProgress }
            }
            if requestedProgress != progress || buffer != nil {
                if buffer == nil {
                    // The buffer captures native widths now. Pair them with the
                    // leading native layout has installed, not an accepted phase
                    // still in flight (a cancelled gesture can leave one): a
                    // mismatched pair offsets every later width by their difference.
                    let installed = installedLeading(in: window) ?? currentLeading
                    let initial = abs(installed - currentLeading) < 0.001 ? currentLeading : installed
                    acceptedLeading = initial
                    let token = UUID()
                    bufferToken = token
                    buffer = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
                        presenter: presenter, deadline: deadlineDriver,
                        navigation: .init(owner: owner, leading: initial, exactRequests: true,
                            layoutLeading: { [weak self, weak window] in
                                guard let self, let window else { return nil }
                                return self.installedLeading(in: window)
                            }),
                        apply: { [weak self] _, accepted in
                            guard let self, self.bufferToken == token, let accepted else { return }
                            self.acceptedLeading = accepted
                            let latest = self.requestedLeading
                            let phase = accepted == latest || self.startLeading == self.endLeading
                                ? self.requestedProgress : (accepted - self.startLeading) / (self.endLeading - self.startLeading)
                            Motion.instant { self.progress = phase }
                            self.schedule()
                        }, completion: { [weak self] in
                            guard let self, self.bufferToken == token else { return }
                            self.buffer = nil
                            self.finishingBuffer = false
                            self.schedule()
                        })
                }
                if let buffer {
                    if !buffer.request(frame: window.frame, sidebarWidth: leading) {
                        buffer.cancel(); self.buffer = nil
                        Motion.instant { progress = requestedProgress }
                        schedule()
                        return
                    }
                    // Rounded or zero-distance requests can share one native size.
                    if acceptedLeading == leading, !buffer.isPreparing, progress != requestedProgress {
                        Motion.instant { progress = requestedProgress }
                    }
                    if requestedProgress == progress, !buffer.isPreparing {
                        finishingBuffer = true
                        buffer.finish()
                    }
                } else { Motion.instant { progress = requestedProgress } }
            }
        }
        guard buffer == nil else {
            if let window = marker?.window { waitForFrame(in: window) }
            return
        }
        guard let arrival, let window = marker?.window, window.isVisible,
              let root = window.contentView else {
            stopArrivalFrames?(); stopArrivalFrames = nil
            return
        }
        guard arrival.target == progress, arrival.visible() else {
            waitForFrame(in: window)
            return
        }
        guard pendingPaints.isEmpty else { return }
        var pages: [WKWebView] = []
        var resizeOwned = false
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let host = view as? WebHost {
                guard host.libraryNavigationPaintOwner == owner, !host.offscreen else { return }
                if host.pageResizeOwnershipWillChange != nil { resizeOwned = true }
                if let web = host.web, web.superview === host, !web.isHiddenOrHasHiddenAncestor,
                   web.bounds.width > 0, web.bounds.height > 0,
                   web.responds(to: NSSelectorFromString("_doAfterNextPresentationUpdate:")) {
                    pages.append(web)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        guard !resizeOwned else { waitForFrame(in: window); return }
        stopArrivalFrames?(); stopArrivalFrames = nil
        guard !pages.isEmpty else { complete(); return }

        // Request the final native presentation after the panel actually arrives.
        // Reversal/detachment retires these callbacks, without holding WebKit at
        // an oversized lookahead viewport during the next gesture.
        let token = generation
        pendingPaints = Set(pages.map { ObjectIdentifier($0) })
        // Preserve the existing resize paint wait's bounded fallback. Expiration
        // releases only the gesture tail; it never publishes or certifies paint.
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, let window,
                      self.marker?.window === window else { return }
                self.complete()
            }
        }
        deadline = timer
        RunLoop.main.add(timer, forMode: .common)
        for web in pages {
            let id = ObjectIdentifier(web)
            let frame = web.frame
            let block: @convention(block) () -> Void = { [weak self, weak web, weak window] in
                MainActor.assumeIsolated {
                    guard let self, self.generation == token, let window,
                          self.marker?.window === window else { return }
                    guard let web, web.window === window, web.frame == frame,
                          let host = web.superview as? WebHost,
                          host.libraryNavigationPaintOwner == self.owner, !host.offscreen,
                          !web.isHiddenOrHasHiddenAncestor,
                          host.pageResizeOwnershipWillChange == nil else {
                        self.retirePaint()
                        self.schedule()
                        return
                    }
                    self.pendingPaints.remove(id)
                    if self.pendingPaints.isEmpty { self.complete() }
                }
            }
            web.perform(NSSelectorFromString("_doAfterNextPresentationUpdate:"), with: block)
        }
    }

    private func complete() {
        retirePaint()
        guard let arrival, arrival.target == progress, arrival.visible(),
              marker?.window?.isVisible == true else { schedule(); return }
        self.arrival = nil
        stopArrivalFrames?(); stopArrivalFrames = nil
        arrival.completion()
    }

    private func retirePaint() {
        generation = UUID()
        deadline?.invalidate(); deadline = nil
        pendingPaints.removeAll()
    }

    func cancel() {
        stopPublicationFrames?(); stopPublicationFrames = nil
        publishedThisFrame = false; deferredDrain = false
        bufferToken = UUID()
        buffer?.cancel(); buffer = nil; finishingBuffer = false
        let interrupted = requestedProgress != progress
        requestedProgress = progress
        retirePaint()
        stopArrivalFrames?(); stopArrivalFrames = nil
        arrival = nil
        if interrupted { resumeLatestTarget() }
    }

    /// A cancellation stops at the phase on screen, so a reversal can take over from
    /// there. SwiftUI only sends the bridge another request when its target changes.
    /// A swipe dragged all the way and released at its endpoint cancels with that
    /// endpoint already requested and the page's paint still behind it: nothing asked
    /// again, and the panel stayed where the paint had got to (fully open, with the
    /// Library closed underneath it). Resume toward the bridge's latest target unless
    /// this turn brought a replacement.
    func resumeLatestTarget() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.marker as? LibraryPaintView, view.paint === self,
                  view.window != nil, self.buffer == nil,
                  self.requestedProgress == self.progress, view.target != self.progress else { return }
            self.requestedProgress = view.target
            self.schedule()
        }
    }
}

final class LibraryPaintView: NSView {
    weak var paint: LibraryNavigationPaint?
    var target: CGFloat = 0
    var isSettled: Bool { paint?.progress == target && paint?.isPreparing == false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { paint?.cancel() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// A parked profile's host leaves the window mid-slide and returns with it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { paint?.resumeLatestTarget() }
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { paint?.cancel() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}

struct LibraryPaintBridge: NSViewRepresentable {
    let paint: LibraryNavigationPaint
    let target: CGFloat
    let startLeading: CGFloat
    let endLeading: CGFloat
    let targetLeading: CGFloat
    let currentLeading: CGFloat
    /// The slide is interpolating toward its model value, rather than following fingers.
    let animating: Bool
    func makeNSView(context: Context) -> LibraryPaintView { LibraryPaintView() }
    func updateNSView(_ view: LibraryPaintView, context: Context) {
        view.paint = paint; view.target = min(1, max(0, target))
        paint.request(target, marker: view, startLeading: startLeading, endLeading: endLeading, targetLeading: targetLeading, currentLeading: currentLeading, animating: animating)
    }
    func makeCoordinator() -> LibraryNavigationPaint { paint }
    static func dismantleNSView(_ view: LibraryPaintView, coordinator: LibraryNavigationPaint) { coordinator.cancel() }
}
