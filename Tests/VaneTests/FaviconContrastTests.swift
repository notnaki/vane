import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FaviconContrastTests: XCTestCase {
    private func cachedIcon(foreground: NSColor, background: NSColor = .clear,
                            detail: NSColor? = nil) async throws -> NSImage {
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
        XCTAssertNil(cache.icon(for: URL(string: "https://contrast.example")!))
        try await compatibilityWait { cache.generation == 1 }
        let image = try XCTUnwrap(cache.icon(for: URL(string: "https://contrast.example")!))
        XCTAssertEqual(try Data(contentsOf: file), data, "Display adaptation must not rewrite the site's icon")
        XCTAssertTrue(cache.icon(for: URL(string: "https://contrast.example/other")!) === image)
        return image
    }

    func testCachedDarkTransparentMarkAdaptsToInterfaceInk() async throws {
        let image = try await cachedIcon(foreground: NSColor(white: 0.08, alpha: 1))
        XCTAssertTrue(image.isTemplate, "A GitHub-style dark mark must follow the interface's light/dark ink")
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    func testMarkRendersWithLightInkInDarkChromeAndDarkInkInLightChrome() async throws {
        let image = try await cachedIcon(foreground: NSColor(white: 0.08, alpha: 1))
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

    func testColoredAndOpaqueIconsKeepTheirOriginalArtwork() async throws {
        let colored = try await cachedIcon(foreground: .systemRed)
        let white = try await cachedIcon(foreground: .black, background: .white)
        let black = try await cachedIcon(foreground: .black, background: .black)
        XCTAssertFalse(colored.isTemplate)
        XCTAssertFalse(white.isTemplate)
        XCTAssertFalse(black.isTemplate)
    }

    func testOpaqueSiteIconRendersAsRoundBadgeAtRetinaScale() async throws {
        let image = try await cachedIcon(foreground: .systemGreen, background: .systemGreen)
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

    func testTransparentColoredLogoKeepsArtworkOutsideTheCircularBadge() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16,
            pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        // A wide logo with transparent space above and below, like YouTube's play mark.
        // Its left edge lies outside a circle but is part of the site's artwork.
        for y in 0..<16 {
            for x in 0..<16 {
                bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0,
                    alpha: (3..<13).contains(y) ? 1 : 0), atX: x, y: y)
            }
        }
        let image = try XCTUnwrap(Favicons.image(from:
            XCTUnwrap(bitmap.representation(using: .png, properties: [:]))))
        for scale in [1.0, 2.0] {
            let renderer = ImageRenderer(content: SiteIcon(icon: image, size: 16))
            renderer.scale = scale
            let rendered = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let edge = try XCTUnwrap(rendered.colorAt(x: 0, y: Int(4 * scale)))
            XCTAssertEqual(edge.alphaComponent, 1, accuracy: 0.02,
                           "Transparent logos must retain their own silhouette at scale \(scale)")
            XCTAssertEqual(edge.redComponent, 1, accuracy: 0.02)
            XCTAssertEqual(try XCTUnwrap(rendered.colorAt(x: 0, y: 0)).alphaComponent,
                           0, accuracy: 0.02)
        }
    }

    func testAlternateOpaqueRepresentationDoesNotCropTransparentLogo() throws {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for pixels in [16, 32] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<pixels {
                for x in 0..<pixels {
                    let visible = pixels == 32 || (3..<13).contains(y)
                    bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0,
                        alpha: visible ? 1 : 0), atX: x, y: y)
                }
            }
            bitmap.size = image.size
            image.addRepresentation(bitmap)
        }
        let renderer = ImageRenderer(content: SiteIcon(icon: image, size: 16))
        renderer.scale = 1
        let rendered = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        XCTAssertEqual(try XCTUnwrap(rendered.colorAt(x: 0, y: 4)).alphaComponent,
                       1, accuracy: 0.02,
                       "A solid Retina variant must not crop the transparent normal-scale logo")
    }

    func testParkingAtUncachedHostClearsPreviousSiteArtwork() async throws {
        let image = try await cachedIcon(foreground: .systemGreen, background: .systemGreen)
        let tab = Tab(profileID: UUID())
        defer { tab.tearDown(); Favicons.forget(tab.profileID) }
        tab.favicon = image
        // An unreachable local origin cannot supply replacement artwork. This also
        // exercises the parked path without creating a WebContent process.
        tab.park(url: URL(string: "http://127.0.0.1:1/home")!, Parked(title: "Pinned home"))
        let deadline = Date.now.addingTimeInterval(2)
        while tab.favicon != nil, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(tab.favicon, "Returning home must not display the previous host's artwork")
        XCTAssertNil(tab.existingWeb, "Clearing parked artwork must not create a page")
    }

    func testLightArtworkAndInternalDetailsAreNotFlattened() async throws {
        let white = try await cachedIcon(foreground: .white)
        let detailed = try await cachedIcon(foreground: .black, detail: .white)
        let colored = try await cachedIcon(foreground: .black, detail: .systemBlue)
        let clear = try await cachedIcon(foreground: .clear)
        for image in [white, detailed, colored, clear] { XCTAssertFalse(image.isTemplate) }
    }

    func testTranslucentEdgesKeepColorClassification() async throws {
        let gray = try await cachedIcon(foreground: NSColor(white: 0.08, alpha: 0.5))
        let blue = try await cachedIcon(foreground: NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 0.15))
        XCTAssertTrue(gray.isTemplate)
        XCTAssertFalse(blue.isTemplate)
    }

    func testDarkGrayDetailsAndMutedBrandColorsAreNotFlattened() async throws {
        let gray = try await cachedIcon(foreground: NSColor(white: 0.08, alpha: 1),
            detail: NSColor(white: 0.20, alpha: 1))
        let colored = try await cachedIcon(foreground: NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.14, alpha: 1))
        XCTAssertFalse(gray.isTemplate)
        XCTAssertFalse(colored.isTemplate)
    }
}
