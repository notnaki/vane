import AppKit
import XCTest
@testable import vane

final class Feel05ThumbnailTests: XCTestCase {
    func testMissingAndReplacedFilesInvalidateDecodedAndFailedResults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("picture.png")
        let loader = Feel05ThumbnailLoader()
        let missing = await loader.load(file, knownSignature: nil)
        XCTAssertNil(missing.image)
        func write(width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file, options: .atomic)
        }
        try write(width: 20)
        let first = await loader.load(file, knownSignature: missing.signature)
        XCTAssertNotNil(first.image)
        XCTAssertFalse(first.unchanged)
        let cached = await loader.load(file, knownSignature: first.signature)
        XCTAssertTrue(cached.unchanged)
        try write(width: 40)
        let replaced = await loader.load(file, knownSignature: first.signature)
        XCTAssertFalse(replaced.unchanged)
        XCTAssertNotEqual(replaced.signature, first.signature)
        XCTAssertEqual(replaced.image?.size.width, 40)
        try FileManager.default.removeItem(at: file)
        let removed = await loader.load(file, knownSignature: replaced.signature)
        XCTAssertNil(removed.image)
        XCTAssertFalse(removed.unchanged)
    }
}
