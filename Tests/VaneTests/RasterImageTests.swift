import AppKit
import XCTest
@testable import vane

@MainActor final class RasterImageTests: XCTestCase {
    private final class DrawingSource {
        func draw(_ bounds: NSRect) {
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            bounds.fill()
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height / 2).fill()
        }
    }

    func testRasterFreezesPixelsWithoutRetainingOrRedrawingItsSource() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        weak var retainedSource: DrawingSource?
        var drawCount = 0
        let size = NSSize(width: 32, height: 25.25)
        let image = try autoreleasepool {
            let source = DrawingSource()
            retainedSource = source
            return try XCTUnwrap(RasterImage.make(size: size) { bounds in
                drawCount += 1
                source.draw(bounds)
            })
        }
        XCTAssertNil(retainedSource, "A privacy thumbnail must release its source after capture")
        XCTAssertEqual(drawCount, 1)
        XCTAssertEqual(image.size, size)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let reps = NSBitmapImageRep.imageReps(with: data)
        XCTAssertEqual(reps.count, 1, "TIFF must contain only the captured display-scale raster")
        let bitmap = try XCTUnwrap(reps.first as? NSBitmapImageRep)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        XCTAssertEqual(bitmap.pixelsWide, Int(ceil(size.width * scale)))
        XCTAssertEqual(bitmap.pixelsHigh, Int(ceil(size.height * scale)))
        let top = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(top.redComponent, 0.75)
        XCTAssertLessThan(top.blueComponent, 0.25)
        XCTAssertGreaterThan(bottom.blueComponent, 0.75, "The raster must preserve bottom-up AppKit drawing")
        // A fractional last pixel remains partly transparent instead of stretching
        // the drawing to cover the rounded bitmap dimensions.
        XCTAssertEqual(top.alphaComponent, (size.height * scale).truncatingRemainder(dividingBy: 1), accuracy: 0.01)
        _ = image.tiffRepresentation
        XCTAssertEqual(drawCount, 1, "Serializing again must not re-enter live drawing code")
    }

    func testIconPlateSerializationKeepsOneBoundedRepresentation() throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let size = NSSize(width: 512, height: 512)
        let image = try XCTUnwrap(RasterImage.make(size: size) { bounds in
            NSColor.white.setFill()
            bounds.fill()
        })
        let reps = NSBitmapImageRep.imageReps(with: try XCTUnwrap(image.tiffRepresentation))
        XCTAssertEqual(image.size, size)
        XCTAssertEqual(reps.count, 1)
        let bitmap = try XCTUnwrap(reps.first as? NSBitmapImageRep)
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        XCTAssertEqual(bitmap.pixelsWide, Int(size.width * scale))
        XCTAssertEqual(bitmap.pixelsHigh, Int(size.height * scale))
    }
}
