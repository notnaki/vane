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

/// Observe release completion only. The animatable Library layout and WebHost's
/// ordinary autoresizing own geometry; this relay never publishes a second phase,
/// changes a native frame/mask, or forces the containing window to lay out.
@MainActor final class LibraryNavigationPaint: ObservableObject {
    let owner = UUID()
    private(set) var progress: CGFloat
    private weak var marker: NSView?
    private var generation = UUID()
    private var queued = false
    private var arrival: (target: CGFloat, visible: () -> Bool, completion: () -> Void)?
    private var stopArrivalFrames: (() -> Void)?
    private var pendingPaints = Set<ObjectIdentifier>()
    private var deadline: Timer?

    var isPreparing: Bool { arrival != nil }

    init(progress: CGFloat) { self.progress = progress }

    func afterPresentation(of target: CGFloat, when visible: @escaping () -> Bool,
                           _ completion: @escaping () -> Void) {
        retirePaint()
        arrival = (target, visible, completion)
        schedule()
    }

    func request(_ value: CGFloat, marker: NSView) {
        let value = min(1, max(0, value))
        if self.marker !== marker || progress != value { retirePaint() }
        self.marker = marker
        progress = value
        if arrival != nil { schedule() }
    }

    private func schedule() {
        guard !queued else { return }
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

    private func drain() {
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
        retirePaint()
        stopArrivalFrames?(); stopArrivalFrames = nil
        arrival = nil
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

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { paint?.cancel() }
        super.viewWillMove(toSuperview: newSuperview)
    }
}

struct LibraryPaintBridge: NSViewRepresentable {
    let paint: LibraryNavigationPaint
    let target: CGFloat
    func makeNSView(context: Context) -> LibraryPaintView { LibraryPaintView() }
    func updateNSView(_ view: LibraryPaintView, context: Context) {
        view.paint = paint; view.target = min(1, max(0, target))
        paint.request(target, marker: view)
    }
    func makeCoordinator() -> LibraryNavigationPaint { paint }
    static func dismantleNSView(_ view: LibraryPaintView, coordinator: LibraryNavigationPaint) { coordinator.cancel() }
}
