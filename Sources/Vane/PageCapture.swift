import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A native selection overlay keeps capture controls out of the page DOM and image.
/// WebKit supplies page pixels, so no macOS screen-recording permission is needed.
@MainActor enum PageCapture {
    private static var session: CaptureSession?

    static func available(_ tab: Tab?) -> Bool {
        guard let tab else { return false }
        return tab.web.window != nil && !tab.web.isHiddenOrHasHiddenAncestor
            && !tab.web.isLoading && tab.web.url != nil && !tab.web.bounds.isEmpty
    }

    static func start(_ tab: Tab?) {
        session?.cancel()
        guard let tab, available(tab), let window = tab.web.window, window.attachedSheet == nil else {
            Toasts.show("Load a page before capturing it.")
            return
        }
        let capture = CaptureSession(tab: tab, window: window)
        session = capture
        capture.begin()
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
    private var hoverTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var live = true
    private var taking = false

    init(tab: Tab, window: NSWindow) {
        self.tab = tab
        self.window = window
        previousResponder = window.firstResponder
    }

    func begin() {
        let web = tab.web
        overlay.frame = web.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.hover = { [weak self] point in self?.hover(point) }
        overlay.select = { [weak self] rect, point in self?.select(rect, point: point) }
        overlay.cancel = { [weak self] in self?.cancel() }
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
    }

    private func hover(_ point: CGPoint) {
        hoverTask?.cancel()
        guard point.x >= 0, point.y >= 0 else { return }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard let self, self.live, !self.taking, !Task.isCancelled else { return }
            let rect = await PageCapture.element(at: point, in: self.tab.web)
            guard self.live, !self.taking, !Task.isCancelled else { return }
            self.overlay.region = rect
        }
    }

    private func select(_ rect: CGRect?, point: CGPoint?) {
        guard live, !taking else { return }
        taking = true
        hoverTask?.cancel()
        captureTask = Task { [weak self] in
            guard let self else { return }
            let chosen: CGRect?
            if let point { chosen = await PageCapture.element(at: point, in: self.tab.web) }
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
            do {
                let image = try await PageCapture.snapshot(chosen, in: self.tab.web)
                guard self.live, !Task.isCancelled, let window = self.window else { return }
                guard let png = PageCapture.png(image) else { throw CaptureError.encoding }
                self.cancel()
                CapturePreviewController.present(image: image, png: png, in: window)
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
        hoverTask?.cancel()
        captureTask?.cancel()
        observations.removeAll()
        subscriptions.removeAll()
        if window?.firstResponder === overlay { window?.makeFirstResponder(previousResponder) }
        overlay.removeFromSuperview()
        PageCapture.release(self)
    }

    private enum CaptureError: LocalizedError {
        case encoding
        var errorDescription: String? { "The captured image could not be converted to PNG. Please try again." }
    }
}

@MainActor private final class CaptureOverlay: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var region: CGRect? { didSet { needsDisplay = true } }
    var hover: ((CGPoint) -> Void)?
    var select: ((CGRect?, CGPoint?) -> Void)?
    var cancel: (() -> Void)?
    private var origin: CGPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Page capture. Return captures the visible page. Escape cancels.")
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
        else { super.keyDown(with: event) }
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
    }
    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if let region { mask.append(NSBezierPath(rect: region)); mask.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.36).setFill()
        mask.fill()
        if let region {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1.5
            border.stroke()
        }
        let text = "Click an element or drag to capture · Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let box = CGRect(x: max(8, (bounds.width - size.width - 24) / 2), y: 16, width: size.width + 24, height: 32)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 12, y: box.minY + 8), withAttributes: attributes)
    }
}

@MainActor private final class CapturePreviewController {
    private let panel: NSPanel
    private let image: NSImage
    private let png: Data
    private var picker: NSSharingServicePicker?

    static func present(image: NSImage, png: Data, in window: NSWindow) {
        let controller = CapturePreviewController(image: image, png: png)
        window.beginSheet(controller.panel) { _ in _ = controller }
    }

    init(image: NSImage, png: Data) {
        self.image = image
        self.png = png
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Page Capture"
        panel.contentView = NSHostingView(rootView: CapturePreview(image: image,
            copy: { [weak self] in self?.copy() }, save: { [weak self] in self?.save() },
            share: { [weak self] in self?.share() }, close: { [weak self] in self?.close() }))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setData(png, forType: .png) { close(); Toasts.show("Copied capture") }
    }
    private func save() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = "Vane Capture.png"
        save.canCreateDirectories = true
        save.beginSheetModal(for: panel) { [self] response in
            guard response == .OK, let url = save.url else { return }
            do { try png.write(to: url, options: .atomic); close() }
            catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t save the capture"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: panel)
            }
        }
    }
    private func share() {
        guard let view = panel.contentView else { return }
        picker = NSSharingServicePicker(items: [image])
        picker?.show(relativeTo: CGRect(x: view.bounds.midX, y: 24, width: 1, height: 1), of: view, preferredEdge: .minY)
    }
    private func close() {
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
    }
}

private struct CapturePreview: View {
    let image: NSImage
    let copy: () -> Void
    let save: () -> Void
    let share: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Captured page region")
            HStack {
                Button("Close", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Share…", action: share)
                Button("Save PNG…", action: save)
                Button("Copy", action: copy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 440)
    }
}
