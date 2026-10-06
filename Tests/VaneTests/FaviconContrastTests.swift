import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FaviconContrastTests: XCTestCase {
    private func cachedIcon(foreground: NSColor, background: NSColor = .clear,
                            detail: NSColor? = nil) throws -> NSImage {
        TestEnvironment.prepare()
        let profile = UUID()
        let directory = ProfileManager.faviconDir(for: profile, in: Store.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16,
            pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        func paint(_ color: NSColor, x: Int, y: Int) throws {
            let rgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
            bitmap.setColor(NSColor(calibratedRed: rgb.redComponent, green: rgb.greenComponent,
                blue: rgb.blueComponent, alpha: rgb.alphaComponent), atX: x, y: y)
        }
        for y in 0..<16 {
            for x in 0..<16 {
                let color = (4..<12).contains(x) && (4..<12).contains(y)
                    ? foreground : background
                try paint(color, x: x, y: y)
            }
        }
        if let detail {
            try paint(detail, x: 8, y: 8)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let file = directory.appendingPathComponent("contrast.example")
        try data.write(to: file)
        let cache = Favicons(profileID: profile)
        let image = try XCTUnwrap(cache.icon(for: URL(string: "https://contrast.example")!))
        XCTAssertEqual(try Data(contentsOf: file), data, "Display adaptation must not rewrite the site's icon")
        XCTAssertTrue(cache.icon(for: URL(string: "https://contrast.example/other")!) === image)
        return image
    }

    func testCachedDarkTransparentMarkAdaptsToInterfaceInk() throws {
        let image = try cachedIcon(foreground: NSColor(white: 0.08, alpha: 1))
        XCTAssertTrue(image.isTemplate, "A GitHub-style dark mark must follow the interface's light/dark ink")
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    func testMarkRendersWithLightInkInDarkChromeAndDarkInkInLightChrome() throws {
        let image = try cachedIcon(foreground: NSColor(white: 0.08, alpha: 1))
        for (scheme, ink, expected) in [(ColorScheme.dark, Color.white, 1.0),
                                        (ColorScheme.light, Color.black, 0.0)] {
            let renderer = ImageRenderer(content: SiteIcon(icon: image)
                .foregroundStyle(ink).environment(\.colorScheme, scheme))
            let rendered = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let pixel = try XCTUnwrap(rendered.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(pixel.redComponent, expected, accuracy: 0.02)
            XCTAssertEqual(pixel.greenComponent, expected, accuracy: 0.02)
            XCTAssertEqual(pixel.blueComponent, expected, accuracy: 0.02)
            XCTAssertEqual(pixel.alphaComponent, 1, accuracy: 0.02)
        }
    }

    func testColoredAndOpaqueIconsKeepTheirOriginalArtwork() throws {
        XCTAssertFalse(try cachedIcon(foreground: .systemRed).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground: .black, background: .white).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground: .black, background: .black).isTemplate)
    }

    func testOpaqueSiteIconRendersAsRoundBadgeAtRetinaScale() throws {
        let image = try cachedIcon(foreground: .systemGreen, background: .systemGreen)
        let renderer = ImageRenderer(content: SiteIcon(icon: image, size: 16))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertEqual(bitmap.pixelsHigh, 32)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 31, y: 0)).alphaComponent, 0, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 16, y: 16)).alphaComponent, 1, accuracy: 0.02)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 16, y: 1)).alphaComponent, 0.9)
    }

    func testLightArtworkAndInternalDetailsAreNotFlattened() throws {
        XCTAssertFalse(try cachedIcon(foreground: .white).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground: .black, detail: .white).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground: .black, detail: .systemBlue).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground: .clear).isTemplate)
    }

    func testTranslucentEdgesKeepColorClassification() throws {
        XCTAssertTrue(try cachedIcon(foreground: NSColor(white: 0.08, alpha: 0.5)).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground:
            NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 0.15)).isTemplate)
    }

    func testDarkGrayDetailsAndMutedBrandColorsAreNotFlattened() throws {
        XCTAssertFalse(try cachedIcon(foreground: NSColor(white: 0.08, alpha: 1),
            detail: NSColor(white: 0.20, alpha: 1)).isTemplate)
        XCTAssertFalse(try cachedIcon(foreground:
            NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1)).isTemplate)
    }
}
