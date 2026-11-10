import AppKit
import SwiftUI

enum CaptureMarkupTool: String, CaseIterable, Identifiable {
    case crop, pen, arrow, rectangle, text
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .crop: "crop"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        }
    }
}

struct CaptureAnnotation: Equatable {
    var tool: CaptureMarkupTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
}

/// All edits live in original image points, with an origin at the top left. The bitmap
/// is retained separately, so a small preview never determines the exported resolution.
@MainActor final class CaptureEditorDocument: ObservableObject {
    private struct State: Equatable {
        var crop: CGRect
        var annotations: [CaptureAnnotation] = []
    }
    let source: CGImage
    let imageSize: CGSize
    @Published private var state: State
    @Published private var past: [State] = []
    @Published private var future: [State] = []
    var cropRect: CGRect { state.crop }
    var annotations: [CaptureAnnotation] { state.annotations }
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var hasEdits: Bool { state != State(crop: CGRect(origin: .zero, size: imageSize)) }

    init?(image: NSImage) {
        let size = image.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }?.cgImage
        guard let source = bitmap ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.source = source
        imageSize = size
        state = State(crop: CGRect(origin: .zero, size: size))
    }

    @discardableResult func crop(to rectangle: CGRect) -> Bool {
        guard [rectangle.origin.x, rectangle.origin.y, rectangle.size.width, rectangle.size.height].allSatisfy(\.isFinite) else { return false }
        let clipped = rectangle.standardized.intersection(state.crop)
        guard !clipped.isNull, clipped.width >= 4, clipped.height >= 4 else { return false }
        // Snap outward to source pixels, retaining the original backing scale.
        let sx = CGFloat(source.width) / imageSize.width, sy = CGFloat(source.height) / imageSize.height
        let left = floor(clipped.minX * sx) / sx, top = floor(clipped.minY * sy) / sy
        let right = ceil(clipped.maxX * sx) / sx, bottom = ceil(clipped.maxY * sy) / sy
        var next = state
        next.crop = CGRect(x: left, y: top, width: right - left, height: bottom - top).intersection(state.crop)
        return change(to: next)
    }

    func add(_ annotation: CaptureAnnotation) {
        guard annotation.tool != .crop, annotation.width.isFinite, annotation.width > 0,
              !annotation.points.isEmpty,
              annotation.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              annotation.tool != .text || !annotation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var next = state
        next.annotations.append(annotation)
        change(to: next)
    }

    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(state)
        state = previous
    }

    func redo() {
        guard let next = future.popLast() else { return }
        past.append(state)
        state = next
    }

    func reset() { change(to: State(crop: CGRect(origin: .zero, size: imageSize))) }

    @discardableResult private func change(to next: State) -> Bool {
        guard state != next else { return false }
        past.append(state)
        future.removeAll()
        state = next
        return true
    }

    func render() -> NSImage? {
        let crop = cropRect
        let width = max(1, Int((crop.width * CGFloat(source.width) / imageSize.width).rounded()))
        let height = max(1, Int((crop.height * CGFloat(source.height) / imageSize.height).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(width) / crop.width, y: CGFloat(height) / crop.height)
        context.translateBy(x: -crop.minX, y: crop.maxY)
        context.scaleBy(x: 1, y: -1)
        draw(in: context)
        guard let rendered = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        bitmap.size = crop.size
        let image = NSImage(size: crop.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Fit previews cache only the visible crop and at most four million pixels.
    /// Export and actual-size zoom continue to use the original source.
    func preview(maxPixelDimension: Int) -> CGImage? {
        guard maxPixelDimension > 0 else { return nil }
        let sx = CGFloat(source.width) / imageSize.width, sy = CGFloat(source.height) / imageSize.height
        let rect = CGRect(x: (cropRect.minX * sx).rounded(), y: (cropRect.minY * sy).rounded(),
                          width: (cropRect.width * sx).rounded(), height: (cropRect.height * sy).rounded())
        guard let cropped = source.cropping(to: rect) else { return nil }
        let factor = min(1, CGFloat(min(2000, maxPixelDimension)) / CGFloat(max(cropped.width, cropped.height)))
        if factor == 1 { return cropped }
        let width = max(1, Int((CGFloat(cropped.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(cropped.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The caller supplies a context whose coordinates already match original image points.
    func draw(in context: CGContext, preview: CGImage? = nil) {
        let rect = preview == nil ? CGRect(origin: .zero, size: imageSize) : cropRect
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(preview ?? source, in: rect)
        context.restoreGState()
        for annotation in annotations { Self.draw(annotation, in: context) }
    }

    static func draw(_ annotation: CaptureAnnotation, in context: CGContext) {
        guard let first = annotation.points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let last = annotation.points.last ?? first
        switch annotation.tool {
        case .crop: break
        case .pen:
            if annotation.points.count == 1 {
                context.fillEllipse(in: CGRect(x: first.x - annotation.width / 2, y: first.y - annotation.width / 2,
                                               width: annotation.width, height: annotation.width))
            } else {
                context.beginPath()
                context.addLines(between: annotation.points)
                context.strokePath()
            }
        case .rectangle:
            context.stroke(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                  width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            context.move(to: first)
            context.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(max(10, annotation.width * 4), hypot(last.x - first.x, last.y - first.y) * 0.4)
            for turn in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: CGPoint(x: last.x - head * cos(angle + turn), y: last.y - head * sin(angle + turn)))
                context.addLine(to: last)
            }
            context.strokePath()
        case .text:
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            (annotation.text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: max(14, annotation.width * 6), weight: .semibold),
                .foregroundColor: annotation.color,
            ])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

struct CaptureEditorViewport {
    let crop: CGRect
    let imageFrame: CGRect
    let scale: CGFloat

    init(bounds: CGRect, crop: CGRect, fixedScale: CGFloat? = nil) {
        self.crop = crop
        scale = max(0.0001, fixedScale ?? min(bounds.width / max(1, crop.width), bounds.height / max(1, crop.height)))
        let size = CGSize(width: crop.width * scale, height: crop.height * scale)
        imageFrame = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                            width: size.width, height: size.height)
    }

    func imagePoint(_ point: CGPoint, clamped: Bool = false) -> CGPoint? {
        guard clamped || imageFrame.contains(point) else { return nil }
        return CGPoint(x: min(crop.maxX, max(crop.minX, crop.minX + (point.x - imageFrame.minX) / scale)),
                       y: min(crop.maxY, max(crop.minY, crop.minY + (point.y - imageFrame.minY) / scale)))
    }

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + (rect.minX - crop.minX) * scale,
               y: imageFrame.minY + (rect.minY - crop.minY) * scale,
               width: rect.width * scale, height: rect.height * scale)
    }
}

@MainActor final class CaptureEditorController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let document: CaptureEditorDocument
    private let completion: @MainActor (NSImage) -> Void
    private var result: NSImage?
    private var finished = false

    static func present(image: NSImage, in window: NSWindow, completion: @escaping @MainActor (NSImage) -> Void) {
        guard window.attachedSheet == nil, let document = CaptureEditorDocument(image: image) else { NSSound.beep(); return }
        let controller = CaptureEditorController(document: document, owner: window, completion: completion)
        window.beginSheet(controller.panel) { [controller] _ in
            controller.panel.orderOut(nil)
            controller.panel.contentView = nil
            if let image = controller.result { controller.completion(image) }
        }
    }

    private init(document: CaptureEditorDocument, owner: NSWindow, completion: @escaping @MainActor (NSImage) -> Void) {
        self.document = document
        self.completion = completion
        let size = NSSize(width: max(420, min(960, owner.frame.width - 48)),
                          height: max(360, min(700, owner.frame.height - 80)))
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Edit Capture"
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = Motion.reduced ? .none : .documentWindow
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 420, height: 360)
        panel.contentView = SecondaryWindowStyle.host(CaptureEditorView(document: document,
            cancel: { [weak self] in self?.finish(applying: false) },
            apply: { [weak self] in self?.finish(applying: true) }), minimumSize: panel.contentMinSize)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(applying: false); return false }

    private func finish(applying: Bool) {
        guard !finished else { return }
        if applying {
            guard let image = document.render() else { NSSound.beep(); return }
            result = image
        }
        finished = true
        panel.animationBehavior = Motion.reduced ? .none : .documentWindow
        panel.sheetParent?.endSheet(panel, returnCode: applying ? .OK : .cancel)
    }
}

private struct CaptureEditorView: View {
    @ObservedObject var document: CaptureEditorDocument
    let cancel: () -> Void
    let apply: () -> Void
    @State private var tool: CaptureMarkupTool = .crop
    @State private var color = Color.red
    @State private var width: CGFloat = 3
    @State private var text = ""
    @State private var zoom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(CaptureMarkupTool.allCases.enumerated()), id: \.element.id) { index, item in
                        Button {
                            Motion.animate(.easeOut(duration: 0.15)) { tool = item }
                        } label: {
                            Label(item.title, systemImage: item.symbol).padding(.horizontal, 5).padding(.vertical, 6)
                                .background(tool == item ? Color.accentColor.opacity(0.14) : .clear,
                                            in: .rect(cornerRadius: Look.cardRadius))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .help("\(item.title) (⌘\(index + 1))")
                        .accessibilityLabel(item.title)
                        .accessibilityAddTraits(tool == item ? [.isSelected] : [])
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }.scrollIndicators(.hidden)
            HStack(spacing: 12) {
                ColorPicker("Color", selection: $color, supportsOpacity: false).fixedSize()
                Picker("Thickness", selection: $width) {
                    Text("Thin").tag(CGFloat(2))
                    Text("Medium").tag(CGFloat(3))
                    Text("Thick").tag(CGFloat(6))
                }.frame(maxWidth: 180)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.bottom, 10)
            if tool == .text {
                TextField("Type a label, then click the image", text: $text)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Annotation text")
                    .padding(.horizontal, 20).padding(.bottom, 10).transition(.opacity)
            }
            Divider()
            CaptureEditorCanvas(document: document, tool: tool, color: NSColor(color), width: width, text: text, zoom: zoom)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Text(tool == .crop ? "Drag to crop. Undo to restore the previous crop." : tool == .text ? "Enter a label above, then click to place it." : "Drag on the image to add markup.")
                        .font(Look.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Picker("Zoom", selection: $zoom) {
                        Text("Fit").tag(CGFloat(0))
                        Text("100%").tag(CGFloat(1))
                        Text("200%").tag(CGFloat(2))
                    }.labelsHidden().frame(width: 90).accessibilityLabel("Zoom")
                        .help("Zoom to actual size to mark up a full-page capture. Scroll to move around.")
                }
                HStack(spacing: 8) {
                    Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .accessibilityLabel("Undo").help("Undo (⌘Z)").keyboardShortcut("z", modifiers: .command)
                        .disabled(!document.canUndo)
                    Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .accessibilityLabel("Redo").help("Redo (⇧⌘Z)").keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!document.canRedo)
                    Button("Reset") { document.reset() }.disabled(!document.hasEdits)
                    Spacer(minLength: 0)
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    Button("Apply", action: apply).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }.padding(16)
        }.font(Look.text).vaneMotionPolicy()
    }
}

private struct CaptureEditorCanvas: NSViewRepresentable {
    @ObservedObject var document: CaptureEditorDocument
    var tool: CaptureMarkupTool
    var color: NSColor
    var width: CGFloat
    var text: String
    var zoom: CGFloat

    func makeNSView(context: Context) -> CaptureEditorScrollView { CaptureEditorScrollView(document: document) }
    func updateNSView(_ scroll: CaptureEditorScrollView, context: Context) {
        let view = scroll.canvas
        view.tool = tool; view.color = color; view.strokeWidth = width; view.text = text
        view.setAccessibilityValue(tool.title)
        scroll.zoom = zoom
        scroll.needsLayout = true
        view.needsDisplay = true
    }
}

@MainActor private final class CaptureEditorScrollView: NSScrollView {
    let canvas: CaptureEditorCanvasView
    var zoom: CGFloat = 0

    init(document: CaptureEditorDocument) {
        canvas = CaptureEditorCanvasView(document: document)
        super.init(frame: .zero)
        drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        documentView = canvas
        setAccessibilityLabel("Capture zoom and scroll area")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let available = contentView.bounds.size
        guard available.width > 0, available.height > 0 else { return }
        let crop = canvas.document.cropRect
        let size = zoom == 0 ? available : CGSize(width: max(available.width, crop.width * zoom + 4),
                                                  height: max(available.height, crop.height * zoom + 4))
        canvas.frame = CGRect(origin: .zero, size: size)
        canvas.usesPreview = zoom == 0
        canvas.fixedScale = zoom > 0 ? zoom : nil
        canvas.needsDisplay = true
    }
}

@MainActor private final class CaptureEditorCanvasView: NSView {
    let document: CaptureEditorDocument
    var tool: CaptureMarkupTool = .crop {
        didSet {
            if tool != oldValue { draft = nil; window?.invalidateCursorRects(for: self) }
        }
    }
    var color = NSColor.systemRed
    var strokeWidth: CGFloat = 3
    var text = ""
    var usesPreview = true
    var fixedScale: CGFloat?
    private var draft: CaptureAnnotation?
    private var previewCrop: CGRect?
    private var previewDimension = 0
    private var previewImage: CGImage?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var viewport: CaptureEditorViewport { CaptureEditorViewport(bounds: bounds.insetBy(dx: 2, dy: 2), crop: document.cropRect, fixedScale: fixedScale) }

    init(document: CaptureEditorDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Capture markup canvas")
        setAccessibilityHelp("Choose a tool above. Drag to crop or draw; click to place text.")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let viewport = viewport
        context.saveGState()
        context.clip(to: viewport.imageFrame)
        context.translateBy(x: viewport.imageFrame.minX, y: viewport.imageFrame.minY)
        context.scaleBy(x: viewport.scale, y: viewport.scale)
        context.translateBy(x: -document.cropRect.minX, y: -document.cropRect.minY)
        if usesPreview {
            let dimension = min(2000, max(1, Int(ceil(max(viewport.imageFrame.width, viewport.imageFrame.height) * (window?.backingScaleFactor ?? 2)))))
            if previewCrop != document.cropRect || previewDimension != dimension {
                previewImage = document.preview(maxPixelDimension: dimension)
                previewCrop = document.cropRect; previewDimension = dimension
            }
        }
        document.draw(in: context, preview: usesPreview ? previewImage : nil)
        if let draft, draft.tool != .crop { CaptureEditorDocument.draw(draft, in: context) }
        context.restoreGState()
        if let draft, draft.tool == .crop, let first = draft.points.first, let last = draft.points.last {
            let rect = viewport.viewRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                                width: abs(first.x - last.x), height: abs(first.y - last.y)))
            let shade = NSBezierPath(rect: viewport.imageFrame)
            shade.appendRect(rect)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.45).setFill()
            shade.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5
            border.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = viewport.imagePoint(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        if tool == .text {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
            document.add(CaptureAnnotation(tool: .text, points: [point], color: color, width: strokeWidth, text: text))
        } else {
            draft = CaptureAnnotation(tool: tool, points: [point], color: color, width: strokeWidth)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var draft, let point = viewport.imagePoint(convert(event.locationInWindow, from: nil), clamped: true) else { return }
        if draft.tool == .pen || draft.points.count == 1 { draft.points.append(point) }
        else { draft.points[draft.points.count - 1] = point }
        self.draft = draft
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let draft else { return }
        self.draft = nil
        if draft.tool == .crop, let first = draft.points.first, let last = draft.points.last {
            document.crop(to: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                    width: abs(first.x - last.x), height: abs(first.y - last.y)))
        } else if draft.tool == .pen || draft.points.count > 1 { document.add(draft) }
        needsDisplay = true
    }

    @objc func undo(_ sender: Any?) { draft = nil; document.undo(); needsDisplay = true }
    @objc func redo(_ sender: Any?) { draft = nil; document.redo(); needsDisplay = true }
}
