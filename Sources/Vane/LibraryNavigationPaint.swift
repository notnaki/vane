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

@MainActor final class LibraryNavigationPaint: ObservableObject {
    let owner = UUID()
    private lazy var mountReceiptSource = LibraryPageMountReceiptSource(paint: self)

    func pageMountReceiptSource(store: TabStore?, gesture: LibraryGesture,
                                monitor: LibrarySwipeMonitor) -> LibraryPageMountReceiptSource? {
        mountReceiptSource.bind(store: store, gesture: gesture, monitor: monitor)
        return store == nil ? nil : mountReceiptSource
    }

    @Published private(set) var progress: CGFloat
    private var requested: CGFloat
    private var submitted: CGFloat
    private var sampledAt = CACurrentMediaTime()
    private weak var marker: NSView?
    private var leading: (CGFloat) -> CGFloat = { $0 }
    private var buffer: LivePageResizeBuffer?
    private var ending = false
    private var generation = UUID()
    private var queued = false
    private var idle: Timer?
    private var arrival: (target: CGFloat, visible: () -> Bool, completion: () -> Void)?
    private var stopArrivalFrames: (() -> Void)?

    var isPreparing: Bool { queued || buffer != nil || requested != progress }

    private(set) var pageMountEpoch: LibraryPageMountEpoch
    private weak var pageMountWindow: NSWindow?
    var pageMountMarker: LibraryPaintView? { marker as? LibraryPaintView }
    var pageMountGeneration: UUID { generation }
    func invalidatePageMountMetadata() { pageMountEpoch.invalidate() }
    func pageMountIsIdle(in window: NSWindow) -> Bool {
        !pageMountEpoch.exhausted && pageMountWindow === window
            && progress == 0 && requested == 0 && submitted == 0
            && !queued && buffer == nil && !ending && arrival == nil
            && idle == nil && stopArrivalFrames == nil
    }
    func pageMountAttachmentChanged(_ view: LibraryPaintView) {
        guard marker === view else { return }
        invalidatePageMountMetadata()
        pageMountWindow = view.window
    }

    init(progress: CGFloat, mountEpoch: LibraryPageMountEpoch = .init()) {
        pageMountEpoch = mountEpoch
        self.progress = progress; requested = progress; submitted = progress
    }

    func afterPresentation(of target: CGFloat, when visible: @escaping () -> Bool,
                           _ completion: @escaping () -> Void) {
        invalidatePageMountMetadata()
        arrival = (target, visible, completion)
        if submitted == target { finish() }
        schedule()
    }

    func request(_ value: CGFloat, sampledAt: TimeInterval?, marker: NSView, leading: @escaping (CGFloat) -> CGFloat) {
        if self.marker !== marker || pageMountWindow !== marker.window || min(1, max(0, value)) != requested {
            invalidatePageMountMetadata()
        }
        pageMountWindow = marker.window
        self.marker = marker
        self.leading = leading
        let value = min(1, max(0, value))
        if value != requested {
            self.sampledAt = sampledAt ?? CACurrentMediaTime()
            idle?.invalidate(); idle = nil
        }
        requested = value
#if DEBUG
        ResizeTimingDiagnostics.recordState("library.request", fields: ["requested": String(Double(requested)),
            "progress": String(Double(progress)), "sample": String(self.sampledAt),
            "provided": String(describing: sampledAt), "buffer": String(buffer != nil)])
#endif
        schedule()
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
        guard let window = marker?.window, window.isVisible, let root = window.contentView else {
            stopArrivalFrames?(); stopArrivalFrames = nil
            return
        }
        if ending, submitted != requested { retireBuffer() }
        // Different animation samples can resolve to the same native edge.
        // Still publish their logical endpoint, without another viewport resize.
        if progress != requested, leading(progress) == leading(requested) {
            Motion.instant { progress = requested; root.needsLayout = true; root.layoutSubtreeIfNeeded() }
        }
        if buffer != nil, submitted == requested { return }
        if buffer == nil, requested == progress {
            if arrival == nil { stopArrivalFrames?(); stopArrivalFrames = nil }
            if let arrival, arrival.target == progress {
                guard arrival.visible() else {
                    waitForFrame(in: window)
                    return
                }
                stopArrivalFrames?(); stopArrivalFrames = nil
                self.arrival = nil
                arrival.completion()
            }
            return
        }
        if buffer == nil {
            func hasResizeOwner(_ view: NSView) -> Bool {
                guard !view.isHiddenOrHasHiddenAncestor else { return false }
                if let host = view as? WebHost, host.libraryNavigationPaintOwner == owner, !host.offscreen {
                    return host.pageResizeOwnershipWillChange != nil
                }
                return view.subviews.contains(where: hasResizeOwner)
            }
            if hasResizeOwner(root) { waitForFrame(in: window); return }
            stopArrivalFrames?(); stopArrivalFrames = nil
            invalidatePageMountMetadata()
            generation = UUID()
            let token = generation
            buffer = LivePageResizeBuffer(window: window, axes: NSSize(width: 1, height: 0),
                frameDriver: SidebarResizePublication.displayFrames(for: window),
                navigation: .init(owner: owner, leading: leading(progress)),
                isCurrent: { [weak self, weak window] in
                    self?.generation == token && self?.marker?.window === window
                },
                apply: { [weak self, weak root] _, width in
                    guard let self, self.generation == token, let root, let width else { return }
#if DEBUG
                    ResizeTimingDiagnostics.record("library.publication.begin", width: width)
#endif
                    self.buffer?.publishSidebarWidth(width) { _ in
                        Motion.instant {
                            self.progress = self.submitted
#if DEBUG
                            ResizeTimingDiagnostics.record("library.root.layout.begin", width: width)
#endif
                            root.needsLayout = true
                            root.layoutSubtreeIfNeeded()
#if DEBUG
                            ResizeTimingDiagnostics.record("library.root.layout.end", width: width)
#endif
                        }
                    }
#if DEBUG
                    ResizeTimingDiagnostics.record("library.publication.end", width: width)
#endif
                },
                completion: { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.buffer = nil; self.ending = false
                    self.schedule()
                })
            guard buffer != nil else {
                Motion.instant { progress = requested; root.needsLayout = true; root.layoutSubtreeIfNeeded() }
                schedule()
                return
            }
        }
        guard !ending else { return }
        submitted = requested
        guard buffer?.request(frame: window.frame, sidebarWidth: leading(submitted)) == true else {
            retireBuffer(); schedule(); return
        }
        if idle == nil {
            // Settle the exact document viewport when fingers pause, while
            // continuous samples keep the existing covered resize owner alive.
            let quiet = max(submitted == 0 || submitted == 1 ? 0.05 : 1.0 / 60,
                            2.0 / Double(window.screen?.maximumFramesPerSecond ?? 60))
            let interval = max(0.001, quiet - (CACurrentMediaTime() - sampledAt))
#if DEBUG
            ResizeTimingDiagnostics.recordState("library.idle", fields: ["interval": String(interval), "quiet": String(quiet)])
#endif
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
            idle = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func finish() {
#if DEBUG
        ResizeTimingDiagnostics.recordState("library.finish", fields: ["requested": String(Double(requested)),
            "progress": String(Double(progress)), "sample": String(sampledAt), "ending": String(ending)])
#endif
        idle?.invalidate(); idle = nil
        guard let buffer, !ending else { return }
        ending = true
        buffer.finish()
    }

    private func retireBuffer() {
        invalidatePageMountMetadata()
        generation = UUID()
        idle?.invalidate(); idle = nil
        let previous = buffer
        buffer = nil; ending = false
        previous?.cancel()
    }

    func cancel() {
        invalidatePageMountMetadata()
        stopArrivalFrames?(); stopArrivalFrames = nil
        retireBuffer()
        requested = progress
        arrival = nil
    }
}

final class LibraryPaintView: NSView {
    weak var paint: LibraryNavigationPaint? {
        willSet {
            if paint !== newValue {
                paint?.invalidatePageMountMetadata()
                newValue?.invalidatePageMountMetadata()
            }
        }
    }
    private(set) var pageMountAttachmentChanging = false
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        pageMountAttachmentChanging = true
        paint?.pageMountAttachmentChanged(self)
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        paint?.pageMountAttachmentChanged(self)
        pageMountAttachmentChanging = false
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        pageMountAttachmentChanging = true
        paint?.pageMountAttachmentChanged(self)
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        paint?.pageMountAttachmentChanged(self)
        pageMountAttachmentChanging = false
    }
    var target: CGFloat = 0
    var isSettled: Bool { paint?.progress == target && paint?.isPreparing == false }
}

struct LibraryPaintBridge: NSViewRepresentable {
    let paint: LibraryNavigationPaint
    let target: CGFloat
    let sampledAt: TimeInterval?
    let leading: (CGFloat) -> CGFloat
    func makeNSView(context: Context) -> LibraryPaintView { LibraryPaintView() }
    func updateNSView(_ view: LibraryPaintView, context: Context) {
        view.paint = paint; view.target = min(1, max(0, target))
        paint.request(target, sampledAt: sampledAt, marker: view, leading: leading)
    }
    func makeCoordinator() -> LibraryNavigationPaint { paint }
    static func dismantleNSView(_ view: LibraryPaintView, coordinator: LibraryNavigationPaint) { coordinator.cancel() }
}
