import AppKit
import SwiftUI
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

    @MainActor func testVisibleDownloadPreviewValidatesAnAlreadyCachedImage() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("cached.png")
        func write(width: Int) throws {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 10,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file, options: .atomic)
        }
        func waitForWidth(_ width: CGFloat) async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while Thumbnails.shared.image(for: file)?.size.width != width, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Thumbnails.shared.image(for: file)?.size.width, width)
        }
        try write(width: 20)
        await Thumbnails.shared.requestVisible(file)
        try await waitForWidth(20)
        try write(width: 40)
        let downloads = Downloads(directory: dir, sandboxed: true)
        let item = downloads.add(.init(name: "cached.png", destination: file, state: "done"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: Feel05DownloadThumbnail(item: item))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await waitForWidth(40)
    }

}
