import AppKit
import XCTest
@testable import vane

@MainActor final class IconServicePixelsTests: XCTestCase {
    func testOnlyExactRawPixelsReachTheHelper() throws {
        let red = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let pixels = try XCTUnwrap(AppIconPersistence.pixels(from: red))
        XCTAssertEqual(pixels.count, AppIconPersistence.pixelBytes)
        XCTAssertGreaterThan(pixels[0], 200); XCTAssertLessThan(pixels[1], 50); XCTAssertEqual(pixels[3], 255)
        XCTAssertNotNil(AppIconPersistence.image(fromPixels: pixels))
        // Encoded images are refused outright: the helper never decodes them.
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(red.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        XCTAssertNil(AppIconPersistence.image(fromPixels: png))
        XCTAssertNil(AppIconPersistence.image(fromPixels: Data([0, 1, 2])))
        XCTAssertNil(AppIconPersistence.image(fromPixels: pixels + Data([0])))
    }
}
