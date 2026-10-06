import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FavoriteIconPaletteTests: XCTestCase {
    private func icon(_ paint: (Int, Int) -> NSColor) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8,
            bytesPerRow: 24 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        for y in 0..<24 {
            for x in 0..<24 {
                context.setFillColor(paint(x, y).cgColor)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 24, height: 24))
    }

    func testRedLogoIgnoresWhiteDetailsAndTransparentPadding() throws {
        let image = try icon { x, y in
            guard (4..<20).contains(x), (6..<18).contains(y) else { return .clear }
            return (10..<14).contains(x) ? .white : NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        }
        let colors = FavoriteIconPalette.colors(for: image)
        XCTAssertEqual(colors.count, 1)
        let red = try XCTUnwrap(colors.first?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.redComponent, 0.9)
        XCTAssertLessThan(red.greenComponent, 0.1)
        XCTAssertLessThan(red.blueComponent, 0.1)
    }

    func testMulticolorLogoRetainsDistinctColorsInArtworkOrder() throws {
        let colors: [NSColor] = [.init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            .init(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            .init(srgbRed: 1, green: 1, blue: 0, alpha: 1),
            .init(srgbRed: 0, green: 1, blue: 0, alpha: 1)]
        let image = try icon { x, _ in colors[x / 6] }
        let palette = FavoriteIconPalette.colors(for: image)
        XCTAssertEqual(palette.count, 4)
        for (actual, expected) in zip(palette, colors) {
            let rgb = try XCTUnwrap(actual.usingColorSpace(.sRGB))
            XCTAssertEqual(rgb.redComponent, expected.redComponent, accuracy: 0.02)
            XCTAssertEqual(rgb.greenComponent, expected.greenComponent, accuracy: 0.02)
            XCTAssertEqual(rgb.blueComponent, expected.blueComponent, accuracy: 0.02)
        }
    }

    func testMissingMonochromeAndTemplateIconsUseInterfaceInk() throws {
        XCTAssertTrue(FavoriteIconPalette.colors(for: nil).isEmpty)
        for color in [NSColor.black, .white, .clear] {
            XCTAssertTrue(FavoriteIconPalette.colors(for: try icon { _, _ in color }).isEmpty)
        }
        let template = try icon { _, _ in .systemRed }
        template.isTemplate = true
        XCTAssertTrue(FavoriteIconPalette.colors(for: template).isEmpty)
    }

    func testTranslucentBrandColorIsNotMistakenForDarkInk() throws {
        let image = try icon { _, _ in NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5) }
        let blue = try XCTUnwrap(FavoriteIconPalette.colors(for: image).first?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(blue.blueComponent, 0.9)
        XCTAssertLessThan(blue.redComponent, 0.1)
    }

    func testOnlyOpenFavoriteHasColoredOutlineAndStrongerFill() throws {
        let image = try icon { _, _ in NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1) }
        for scheme in [ColorScheme.dark, .light] {
            func render(selected: Bool) throws -> NSBitmapImageRep {
                let renderer = ImageRenderer(content: FavoriteTileBackground(selected: selected,
                    hovering: false, icon: image).environment(\.colorScheme, scheme)
                    .transaction { $0.disablesAnimations = true }
                    .frame(width: 72, height: 46)
                    .background(scheme == .dark ? Color.black : Color.white))
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                return bitmap
            }
            let resting = try render(selected: false)
            let selected = try render(selected: true)
            let edge = try XCTUnwrap(selected.colorAt(x: 1, y: 23)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(edge.redComponent - edge.greenComponent, 0.3,
                                 "The open favorite must have its red icon's outline")
            let restEdge = try XCTUnwrap(resting.colorAt(x: 1, y: 23)?.usingColorSpace(.sRGB))
            XCTAssertEqual(restEdge.redComponent, restEdge.greenComponent, accuracy: 0.02,
                           "Closed favorites must not have a colored outline")
            let fill = try XCTUnwrap(selected.colorAt(x: 12, y: 23)?.usingColorSpace(.sRGB))
            let restFill = try XCTUnwrap(resting.colorAt(x: 12, y: 23)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(abs(fill.greenComponent - restFill.greenComponent), 0.15,
                                 "Selection must be visibly stronger than the resting tile")
        }
    }
}
