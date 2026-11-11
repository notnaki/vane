import AppKit
import XCTest
@testable import vane

@MainActor final class CaptureEditorTests: XCTestCase {
    // Catch lost Retina backing resolution and a vertically inverted crop.
    func testCropPreservesRetinaPixelsAndTopLeftCoordinates() throws {
        let source = fixture()
        let editor = try XCTUnwrap(CaptureEditorDocument(image: source))
        XCTAssertTrue(editor.crop(to: CGRect(x: 10, y: 0, width: 30, height: 20)))
        let result = try XCTUnwrap(editor.render())
        let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(result.size, NSSize(width: 30, height: 20))
        XCTAssertEqual(bitmap.pixelsWide, 60)
        XCTAssertEqual(bitmap.pixelsHigh, 40)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 30, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.9)
        XCTAssertLessThan(pixel.blueComponent, 0.1)
    }

    // Catch annotations drifting when the displayed image is scaled or cropped.
    func testAnnotationUsesOriginalCoordinatesAfterCropAtTwoTimesScale() throws {
        let editor = try XCTUnwrap(CaptureEditorDocument(image: fixture()))
        editor.add(CaptureAnnotation(tool: .rectangle,
            points: [CGPoint(x: 20, y: 8), CGPoint(x: 40, y: 18)], color: .green, width: 4))
        XCTAssertTrue(editor.crop(to: CGRect(x: 10, y: 0, width: 50, height: 25)))
        let bitmap = try XCTUnwrap(editor.render()?.representations.first as? NSBitmapImageRep)
        let stroke = try XCTUnwrap(bitmap.colorAt(x: 20, y: 24)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(stroke.greenComponent, 0.8)
        XCTAssertLessThan(stroke.redComponent, 0.2)
        let outside = try XCTUnwrap(bitmap.colorAt(x: 70, y: 24)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(outside.redComponent, 0.9)
    }

    func testCropClampsBoundsRejectsTinyAndNonFiniteRectangles() throws {
        let editor = try XCTUnwrap(CaptureEditorDocument(image: fixture()))
        XCTAssertFalse(editor.crop(to: CGRect(x: 5, y: 5, width: 0.2, height: 10)))
        XCTAssertFalse(editor.crop(to: CGRect(x: 200, y: 200, width: 10, height: 10)))
        XCTAssertFalse(editor.crop(to: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)))
        XCTAssertEqual(editor.cropRect, CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertTrue(editor.crop(to: CGRect(x: -5, y: -8, width: 35, height: 28)))
        XCTAssertEqual(editor.cropRect, CGRect(x: 0, y: 0, width: 30, height: 20))
    }

    // Catch history losing crop state, keeping stale redo, or mutating the input.
    func testUndoRedoResetAndDiscardLeaveSourceUntouched() throws {
        let source = fixture()
        let original = source.tiffRepresentation
        let editor = try XCTUnwrap(CaptureEditorDocument(image: source))
        editor.add(CaptureAnnotation(tool: .pen, points: [CGPoint(x: 5, y: 5), CGPoint(x: 30, y: 5)], color: .black, width: 3))
        XCTAssertTrue(editor.crop(to: CGRect(x: 0, y: 0, width: 40, height: 20)))
        editor.undo()
        XCTAssertEqual(editor.cropRect.width, 100)
        XCTAssertEqual(editor.annotations.count, 1)
        editor.undo()
        XCTAssertTrue(editor.annotations.isEmpty)
        editor.redo()
        XCTAssertEqual(editor.annotations.count, 1)
        editor.reset()
        XCTAssertTrue(editor.annotations.isEmpty)
        XCTAssertFalse(editor.canRedo)
        editor.undo()
        XCTAssertEqual(editor.annotations.count, 1)
        XCTAssertEqual(source.tiffRepresentation, original)
    }

    func testAspectFitMappingAccountsForLetterboxAndCrop() {
        let viewport = CaptureEditorViewport(bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                             crop: CGRect(x: 20, y: 10, width: 100, height: 50))
        XCTAssertEqual(viewport.imageFrame, CGRect(x: 0, y: 50, width: 400, height: 200))
        XCTAssertNil(viewport.imagePoint(CGPoint(x: 10, y: 20)))
        XCTAssertEqual(viewport.imagePoint(CGPoint(x: 200, y: 150)), CGPoint(x: 70, y: 35))
        XCTAssertEqual(viewport.imagePoint(CGPoint(x: 500, y: -10), clamped: true), CGPoint(x: 120, y: 10))
    }

    func testPenArrowAndTextRenderIntoExport() throws {
        for tool in [CaptureMarkupTool.pen, .arrow, .text] {
            let editor = try XCTUnwrap(CaptureEditorDocument(image: fixture()))
            editor.add(CaptureAnnotation(tool: tool,
                points: [CGPoint(x: 10, y: 5), CGPoint(x: 40, y: 15)],
                color: .black, width: 3, text: "TEST"))
            let bitmap = try XCTUnwrap(editor.render()?.representations.first as? NSBitmapImageRep)
            var markedPixels = 0
            for y in 0..<50 {
                for x in 0..<130 {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.redComponent < 0.5 { markedPixels += 1 }
                }
            }
            XCTAssertGreaterThan(markedPixels, 30, "\(tool) must appear in the exported pixels")
        }
    }

    func testRejectsEmptyImageAndInvalidAnnotationsWithoutGrowingHistory() throws {
        XCTAssertNil(CaptureEditorDocument(image: NSImage(size: .zero)))
        let editor = try XCTUnwrap(CaptureEditorDocument(image: fixture()))
        editor.add(CaptureAnnotation(tool: .pen, points: [], color: .black, width: 3))
        editor.add(CaptureAnnotation(tool: .text, points: [.zero], color: .black, width: 3, text: "  "))
        XCTAssertTrue(editor.annotations.isEmpty)
        XCTAssertFalse(editor.canUndo)
    }

    func testFixedZoomKeepsSmallCapturesAtTheirStatedScale() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 400)
        let crop = CGRect(x: 0, y: 0, width: 100, height: 50)
        let actual = CaptureEditorViewport(bounds: bounds, crop: crop, fixedScale: 1)
        let doubled = CaptureEditorViewport(bounds: bounds, crop: crop, fixedScale: 2)
        XCTAssertEqual(actual.imageFrame, CGRect(x: 400, y: 175, width: 100, height: 50))
        XCTAssertEqual(doubled.imageFrame, CGRect(x: 350, y: 150, width: 200, height: 100))
        XCTAssertEqual(actual.imagePoint(CGPoint(x: 425, y: 185)), CGPoint(x: 25, y: 10))
        XCTAssertEqual(doubled.imagePoint(CGPoint(x: 400, y: 170)), CGPoint(x: 25, y: 10))
    }

    func testPreviewBoundsMemoryAndTracksCropWithoutReducingExportResolution() throws {
        let editor = try XCTUnwrap(CaptureEditorDocument(image: fixture()))
        let preview = try XCTUnwrap(editor.preview(maxPixelDimension: 100))
        XCTAssertEqual(preview.width, 100)
        XCTAssertEqual(preview.height, 50)
        XCTAssertTrue(editor.crop(to: CGRect(x: 10, y: 0, width: 30, height: 20)))
        let croppedPreview = try XCTUnwrap(editor.preview(maxPixelDimension: 100))
        XCTAssertEqual(croppedPreview.width, 60)
        XCTAssertEqual(croppedPreview.height, 40)
        let bitmap = NSBitmapImageRep(cgImage: croppedPreview)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 30, y: 20)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertEqual(try XCTUnwrap(editor.render()?.representations.first as? NSBitmapImageRep).pixelsWide, 60)
    }

    func testNativeSheetCropMarkupCancelAndApply() async throws {
        TestEnvironment.prepare()
        // Exercise the real sheet and keyboard-equivalent API under XCTest's
        // callback pump; this does not inject system input or claim foreground AX.
        _ = NSApplication.shared
        try await exerciseNativeSheet()
    }

    private func exerciseNativeSheet() async throws {
        let owner = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1000, height: 760),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentView = NSView()
        defer {
            if let sheet = owner.attachedSheet { owner.endSheet(sheet, returnCode: .cancel) }
            owner.orderOut(nil); owner.contentView = nil; owner.close()
        }
        owner.orderFront(nil)
        let source = fixture()
        let original = source.tiffRepresentation
        var results: [NSImage] = []
        CaptureEditorController.present(image: source, in: owner) { results.append($0) }
        try await compatibilityWait { owner.attachedSheet?.isVisible == true }
        let cancelled = try XCTUnwrap(owner.attachedSheet)
        try await compatibilityWait { cancelled.sheetParent === owner && cancelled.contentView?.window === cancelled }
        XCTAssertTrue(cancelled.performKeyEquivalent(with: try key("\u{1b}", code: 53, in: cancelled)), "The real Cancel shortcut must dismiss the sheet")
        try await compatibilityWait { owner.attachedSheet == nil && !cancelled.isVisible }
        XCTAssertTrue(results.isEmpty, "Cancel must never deliver an edited image")
        XCTAssertEqual(source.tiffRepresentation, original)

        CaptureEditorController.present(image: source, in: owner) { results.append($0) }
        try await compatibilityWait { owner.attachedSheet?.isVisible == true }
        let sheet = try XCTUnwrap(owner.attachedSheet)
        try await compatibilityWait { sheet.sheetParent === owner && self.canvas(in: sheet.contentView)?.window === sheet }
        let canvas = try XCTUnwrap(canvas(in: sheet.contentView))
        try await compatibilityWait { canvas.bounds.width > 300 && canvas.bounds.height > 100 }
        let imageFrame = CaptureEditorViewport(bounds: canvas.bounds.insetBy(dx: 2, dy: 2),
            crop: CGRect(x: 0, y: 0, width: 100, height: 50)).imageFrame
        try drag(in: canvas, from: CGPoint(x: imageFrame.minX + imageFrame.width * 0.1, y: imageFrame.minY + imageFrame.height * 0.1),
                 to: CGPoint(x: imageFrame.minX + imageFrame.width * 0.9, y: imageFrame.minY + imageFrame.height * 0.9))
        XCTAssertTrue(sheet.performKeyEquivalent(with: try key("2", code: 19, modifiers: .command, in: sheet)), "The Pen shortcut must select the tool")
        try await compatibilityWait { canvas.accessibilityValue() as? String == "Pen" }
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        try drag(in: canvas, from: CGPoint(x: center.x - 80, y: center.y - 20),
                 to: CGPoint(x: center.x + 80, y: center.y + 20))

        if let path = ProcessInfo.processInfo.environment["VANE_CAPTURE_EDITOR_SCREENSHOT"] {
            let host = try XCTUnwrap(sheet.contentView)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        sheet.setContentSize(NSSize(width: 420, height: 430))
        try await compatibilityWait { sheet.contentView?.bounds.width == 420 }
        XCTAssertTrue(sheet.performKeyEquivalent(with: try key("\r", code: 36, in: sheet)), "The real Apply shortcut must export the edits")
        try await compatibilityWait { owner.attachedSheet == nil && results.count == 1 }
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.size.width, 80, accuracy: 1)
        XCTAssertEqual(result.size.height, 40, accuracy: 1)
        let bitmap = try XCTUnwrap(result.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / result.size.width, 2, accuracy: 0.01)
        XCTAssertEqual(source.tiffRepresentation, original, "Applying edits must leave the input unchanged")
    }

    private func canvas(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.accessibilityLabel() == "Capture markup canvas" { return view }
        return view.subviews.lazy.compactMap { self.canvas(in: $0) }.first
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func drag(in view: NSView, from start: CGPoint, to end: CGPoint) throws {
        let window = try XCTUnwrap(view.window)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    private func fixture() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let bytes = bitmap.bitmapData!
        for y in 0..<100 {
            for x in 0..<200 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = y < 50 ? 255 : 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = y < 50 ? 0 : 255
                bytes[offset + 3] = 255
            }
        }
        bitmap.size = NSSize(width: 100, height: 50)
        let image = NSImage(size: bitmap.size)
        image.addRepresentation(bitmap)
        return image
    }
}
