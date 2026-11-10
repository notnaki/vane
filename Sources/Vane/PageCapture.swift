import AppKit
import Combine
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A native selection overlay keeps capture controls out of the page DOM and image.
/// WebKit supplies page pixels, so no macOS screen-recording permission is needed.
@MainActor enum PageCapture {
    private static var session: CaptureSession?
    private static var result: CaptureResultController?

    static func available(_ tab: Tab?) -> Bool {
        guard let tab, tab.easelID == nil, !tab.needsRecovery,
              let web = tab.existingWeb else { return false }
        return web.window != nil && !web.isHiddenOrHasHiddenAncestor
            && !web.isLoading && web.url != nil && !web.bounds.isEmpty
    }

    static func start(_ tab: Tab?, fullPage: Bool = false) {
        session?.cancel()
        result?.close()
        guard let tab, available(tab), let window = tab.web.window, window.attachedSheet == nil else {
            Toasts.show("Load a page before capturing it.")
            return
        }
        let capture = CaptureSession(tab: tab, window: window)
        session = capture
        capture.begin(fullPage: fullPage)
    }

    static func present(image: NSImage, png: Data, title: String, source: URL?,
                        in window: NSWindow, store: TabStore?, tab: Tab?, region: CGRect?) {
        result?.close()
        let controller = CaptureResultController(image: image, png: png, title: title, source: source,
            window: window, store: store, tab: tab, region: region)
        result = controller
        controller.begin()
    }

    static func releaseResult(_ controller: CaptureResultController) {
        if result === controller { result = nil }
    }

    fileprivate static func release(_ capture: CaptureSession) {
        if session === capture { session = nil }
    }

    /// All geometry is in points from the viewport's upper left, including reversed drags.
    static func rectangle(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect? {
        guard [start.x, start.y, end.x, end.y].allSatisfy(\.isFinite) else { return nil }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        return !rect.isNull && rect.width >= 3 && rect.height >= 3 ? rect : nil
    }

    /// DOM coordinates are CSS pixels; snapshots and the overlay use view points.
    /// An iframe is selected as a whole. Open shadow roots can be inspected safely.
    static func element(at point: CGPoint, in web: WKWebView) async -> CGRect? {
        let zoom = web.pageZoom
        guard zoom.isFinite, zoom > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let script = """
        (() => {
          const x = \(point.x / zoom), y = \(point.y / zoom);
          let el = document.elementFromPoint(x, y);
          while (el && el.shadowRoot) {
            const inner = el.shadowRoot.elementFromPoint(x, y);
            if (!inner || inner === el) break;
            el = inner;
          }
          while (el && el !== document.body && el !== document.documentElement) {
            const r = el.getBoundingClientRect();
            if (r.width >= 3 && r.height >= 3) return [r.x, r.y, r.width, r.height];
            el = el.parentElement;
          }
          return null;
        })()
        """
        let result = await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? [Double])
                case .failure: continuation.resume(returning: nil as [Double]?)
                }
            }
        }
        guard let values = result, values.count == 4,
              values.allSatisfy(\.isFinite) else { return nil }
        let rect = CGRect(x: values[0] * zoom, y: values[1] * zoom,
                          width: values[2] * zoom, height: values[3] * zoom)
        return rectangle(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY), in: web.bounds)
    }

    static func snapshot(_ rect: CGRect, in web: WKWebView) async throws -> NSImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        return try await web.takeSnapshot(configuration: configuration)
    }

    /// PDF rendering includes the document outside the viewport without moving the live page.
    static func fullPage(in web: WKWebView) async throws -> NSImage {
        let dimensions: [Double] = try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript("""
            (() => {
              const d = document.documentElement, b = document.body;
              return [Math.max(d.scrollWidth, b?.scrollWidth || 0, innerWidth),
                      Math.max(d.scrollHeight, b?.scrollHeight || 0, innerHeight)];
            })()
            """, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    if let values = value as? [Double], values.count == 2 { continuation.resume(returning: values) }
                    else { continuation.resume(throwing: Failure.rendering) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        let zoom = web.pageZoom
        let size = CGSize(width: max(web.bounds.width, dimensions[0] * zoom),
                          height: max(web.bounds.height, dimensions[1] * zoom))
        let scale = web.window?.backingScaleFactor ?? 2
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width * scale <= 32768, size.height * scale <= 32768,
              size.width * size.height * scale * scale <= 64_000_000 else { throw Failure.tooLarge }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            web.createPDF(configuration: configuration) { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
        guard let document = PDFDocument(data: data), document.pageCount == 1,
              let page = document.page(at: 0),
              let cg = CGContext(data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.rendering }
        cg.scaleBy(x: scale, y: scale)
        cg.setFillColor(NSColor.white.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { throw Failure.rendering }
        cg.scaleBy(x: size.width / box.width, y: size.height / box.height)
        cg.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: cg)
        guard let pixels = cg.makeImage() else { throw Failure.rendering }
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    enum Failure: LocalizedError {
        case tooLarge, rendering, encoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: "This page is too large to capture at full resolution. Capture a smaller region instead."
            case .rendering: "The page could not be rendered. Try capturing a region instead."
            case .encoding: "The captured image could not be converted to PNG. Please try again."
            }
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

@MainActor fileprivate final class CaptureSession {
    private let tab: Tab
    private weak var window: NSWindow?
    private weak var previousResponder: NSResponder?
    private let overlay = CaptureOverlay(frame: .zero)
    private var observations: [NSKeyValueObservation] = []
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var elementHover = CaptureElementHover(query: { [weak self] point in
        guard let self, self.live, !self.taking else { return nil }
        return await PageCapture.element(at: point, in: self.tab.web)
    }, update: { [weak self] rect in
        guard let self, self.live, !self.taking else { return }
        if self.overlay.region != rect { self.overlay.region = rect }
    })
    private var captureTask: Task<Void, Never>?
    private var captureInputMonitor: Any?
    private var live = true
    private var taking = false

    init(tab: Tab, window: NSWindow) {
        self.tab = tab
        self.window = window
        previousResponder = window.firstResponder
    }

    func begin(fullPage: Bool) {
        let web = tab.web
        overlay.frame = web.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.hover = { [weak self] point in self?.hover(point) }
        overlay.select = { [weak self] rect, point in self?.select(rect, point: point) }
        overlay.cancel = { [weak self] in self?.cancel() }
        overlay.fullPage = { [weak self] in self?.select(nil, point: nil, fullPage: true) }
        web.addSubview(overlay, positioned: .above, relativeTo: nil)
        window?.makeFirstResponder(overlay)
        // Same-URL reloads, zoom, tab switches and window dismissal invalidate the region.
        observations = [
            web.observe(\.isLoading) { [weak self] _, _ in
                MainActor.assumeIsolated { if web.isLoading { self?.cancel() } }
            },
            web.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.cancel() } },
            web.observe(\.pageZoom) { [weak self] _, _ in MainActor.assumeIsolated { self?.cancel() } },
        ]
        if let store = TabStore.all.first(where: { $0.window === window && $0.active === tab }) {
            store.$profileVisible.sink { [weak self] visible in
                if !visible { self?.cancel() }
            }.store(in: &subscriptions)
            let tabID = tab.id
            store.$current.sink { [weak self] id in
                if id != tabID { self?.cancel() }
            }.store(in: &subscriptions)
            store.$tabs.sink { [weak self] tabs in
                guard let self else { return }
                if !tabs.contains(where: { $0 === self.tab }) { self.cancel() }
            }.store(in: &subscriptions)
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.publisher(for: name, object: window)
                .sink { [weak self] _ in self?.cancel() }.store(in: &subscriptions)
        }
        NSAccessibility.post(element: overlay, notification: .announcementRequested,
            userInfo: [.announcement: "Capture mode. Click an element or drag a region. Return captures the highlighted region or visible page. Escape cancels.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        if fullPage { select(nil, point: nil, fullPage: true) }
    }

    private func hover(_ point: CGPoint) {
        elementHover.move(to: point)
    }

    private func select(_ rect: CGRect?, point: CGPoint?, fullPage: Bool = false) {
        guard live, !taking else { return }
        taking = true
        elementHover.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let chosen: CGRect?
            if fullPage { chosen = self.tab.web.bounds }
            else if let point { chosen = await PageCapture.element(at: point, in: self.tab.web) }
            else { chosen = rect }
            guard self.live, !Task.isCancelled else { return }
            guard let chosen else {
                self.taking = false
                self.overlay.region = nil
                return
            }
            // Removing the overlay for the snapshot is intentional; keep document
            // observations alive until WebKit has returned the image.
            self.overlay.cancel = nil
            if self.window?.firstResponder === self.overlay {
                self.window?.makeFirstResponder(self.previousResponder)
            }
            self.overlay.removeFromSuperview()
            let viewport = self.tab.web.bounds
            // Keep the selected document stable while WebKit produces its pixels.
            self.captureInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] event in
                guard let self, self.live, self.taking, event.window === self.window else { return event }
                if event.type == .keyDown && event.keyCode == 53 { self.cancel() }
                return nil
            }
            do {
                let source = self.tab.currentURL
                let title = self.tab.title
                let image = try await (fullPage ? PageCapture.fullPage(in: self.tab.web) : PageCapture.snapshot(chosen, in: self.tab.web))
                guard self.live, !Task.isCancelled, let window = self.window else { return }
                guard self.tab.web.bounds == viewport else { self.cancel(); return }
                guard let png = PageCapture.png(image) else { throw PageCapture.Failure.encoding }
                self.cancel()
                let store = TabStore.all.first { $0.window === window && $0.profileID == self.tab.profileID }
                PageCapture.present(image: image, png: png, title: title, source: source,
                    in: window, store: store, tab: self.tab, region: fullPage ? nil : chosen)
            } catch {
                guard self.live, !Task.isCancelled else { return }
                let window = self.window
                self.cancel()
                let alert = NSAlert()
                alert.messageText = "Couldn’t capture this page"
                alert.informativeText = error.localizedDescription
                if let window { alert.beginSheetModal(for: window, completionHandler: nil) }
            }
        }
    }

    func cancel() {
        guard live else { return }
        live = false
        elementHover.cancel()
        captureTask?.cancel()
        if let captureInputMonitor { NSEvent.removeMonitor(captureInputMonitor) }
        captureInputMonitor = nil
        observations.removeAll()
        subscriptions.removeAll()
        if window?.firstResponder === overlay { window?.makeFirstResponder(previousResponder) }
        overlay.removeFromSuperview()
        PageCapture.release(self)
    }


}

@MainActor private final class CaptureOverlay: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var region: CGRect? { didSet { needsDisplay = true } }
    var hover: ((CGPoint) -> Void)?
    var select: ((CGRect?, CGPoint?) -> Void)?
    var cancel: (() -> Void)?
    var fullPage: (() -> Void)?
    private var instructions: NSView?
    private var origin: CGPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page capture. Click an element, drag a region, or choose Full Page. Return captures the visible page. Escape cancels.")
        identifier = NSUserInterfaceItemIdentifier("page-capture-selection")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseMoved(with event: NSEvent) { hover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hover?(CGPoint(x: -1, y: -1)); region = nil }
    override func mouseDown(with event: NSEvent) {
        origin = convert(event.locationInWindow, from: nil)
        dragged = false
        hover?(CGPoint(x: -1, y: -1))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - origin.x) >= 3 || abs(point.y - origin.y) >= 3 { dragged = true }
        if dragged { region = PageCapture.rectangle(from: origin, to: point, in: bounds) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let origin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if dragged {
            if let rect = PageCapture.rectangle(from: origin, to: point, in: bounds) { select?(rect, nil) }
        } else { select?(nil, point) }
        self.origin = nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { select?(region ?? bounds, nil) }
        // Unhandled keys must not reach WebKit: Space, arrows and Page Down scroll
        // the page underneath the highlighted region and invalidate its coordinates.
    }
    override func scrollWheel(with event: NSEvent) {} // Keep the selected viewport stable.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { cancel?() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancel?() }
        else if instructions == nil {
            let host = NSHostingView(rootView: CaptureInstructions(
                fullPage: { [weak self] in self?.fullPage?() }, cancel: { [weak self] in self?.cancel?() }))
            instructions = host
            addSubview(host)
            needsLayout = true
            if !Motion.reduced {
                host.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    host.animator().alphaValue = 1
                }
            }
        }
    }
    override func layout() {
        super.layout()
        guard let instructions else { return }
        let width = max(0, min(520, bounds.width - 24))
        instructions.frame = CGRect(x: (bounds.width - width) / 2, y: max(0, bounds.height - 88), width: width, height: 72)
    }
    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if let region { mask.append(NSBezierPath(roundedRect: region, xRadius: 8, yRadius: 8)); mask.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.36).setFill()
        mask.fill()
        if let region {
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: region.insetBy(dx: -0.5, dy: -0.5), xRadius: 8.5, yRadius: 8.5)
            border.lineWidth = 3
            border.stroke()
        }
    }
}
