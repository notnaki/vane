import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SpaceChromeThemeTests: XCTestCase {
    @MainActor func testFloatingSurfacesDarkenContinuouslyToBlackWithThePrimary() throws {
        var previous = -1.0
        for lightness in [0.0, 0.02, 0.1, 0.25, 0.5, 0.75, 1.0] {
            let theme = SpaceChromeTheme(primary: .hsl(h: 0.35, s: 0.6, l: lightness))
            for fill in [theme.bubble, theme.barFill] {
                let color = try XCTUnwrap(NSColor(fill).usingColorSpace(.displayP3))
                let peak = max(color.redComponent, color.greenComponent, color.blueComponent)
                let floor = min(color.redComponent, color.greenComponent, color.blueComponent)
                if lightness == 0 { XCTAssertEqual(peak, 0, accuracy: 0.0001) }
                XCTAssertLessThanOrEqual((peak + floor) / 2, 0.0801,
                    "Light spaces should retain the near-black floating surface")
                XCTAssertGreaterThanOrEqual((peak + floor) / 2 + 0.0001, previous)
            }
            let color = try XCTUnwrap(NSColor(theme.bubble).usingColorSpace(.displayP3))
            previous = (max(color.redComponent, color.greenComponent, color.blueComponent)
                + min(color.redComponent, color.greenComponent, color.blueComponent)) / 2
        }
    }

    func testPrimaryDotOwnsInteractionColourAndProfileIsFallback() {
        var space = Space(name: "Theme", profileID: UUID())
        let primary = ThemeColor(red: 0.2, green: 0.7, blue: 0.3)
        Spaces.setPalette([primary, ThemeColor(red: 0.9, green: 0.2, blue: 0.7)], on: &space)
        XCTAssertEqual(SpaceChromeTheme(space: space, fallback: "#2233FF").primary, primary)
        XCTAssertEqual(SpaceChromeTheme(space: nil, fallback: "#2233FF").primary,
                       ThemeColor(hex: "#2233FF"))
    }

    @MainActor func testHoverAndSelectionOverlaysStayNeutralAcrossSpaceColours() throws {
        for hex in ["#22BB55", "#DD3355", "#3355EE"] {
            let theme = SpaceChromeTheme(primary: ThemeColor(hex: hex))
            let fills = [theme.hovered, theme.selected, theme.favoriteSelected,
                         theme.pillFill, theme.controlFill, theme.cardFill,
                         theme.barHovered, theme.barSelected, theme.bubbleHover]
            for scheme in [ColorScheme.dark, .light] {
                for fill in fills {
                    let renderer = ImageRenderer(content: Rectangle().fill(fill)
                        .frame(width: 12, height: 12)
                        .background(Color(white: 0.5))
                        .environment(\.colorScheme, scheme))
                    let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB))
                    XCTAssertEqual(pixel.redComponent, pixel.greenComponent, accuracy: 0.01,
                                   "Interaction overlays must stay gray for primary \(hex)")
                    XCTAssertEqual(pixel.greenComponent, pixel.blueComponent, accuracy: 0.01)
                }
            }
        }
    }

    @MainActor func testFloatingBackgroundsKeepADarkVersionOfThePrimaryHue() throws {
        for (hex, dominant) in [("#22BB55", 1), ("#DD3355", 0), ("#3355EE", 2)] {
            let theme = SpaceChromeTheme(primary: ThemeColor(hex: hex))
            for fill in [theme.bubble, theme.barFill] {
                let renderer = ImageRenderer(content: Rectangle().fill(fill).frame(width: 12, height: 12))
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let pixel = try XCTUnwrap(bitmap.colorAt(x: 6, y: 6)?.usingColorSpace(.sRGB))
                let rgb = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
                XCTAssertLessThan(try XCTUnwrap(rgb.max()), 0.18,
                                  "Floating surfaces should stay near black with a subtle primary tint")
                for index in rgb.indices where index != dominant {
                    XCTAssertGreaterThan(rgb[dominant], rgb[index])
                }
            }
        }
    }

    @MainActor func testNativeControlAccentRemainsReadableForDarkAndPalePrimaries() throws {
        for hex in ["#080808", "#FAFAFA", "#FFFF22", "#2222FF", "#22BB55"] {
            let theme = SpaceChromeTheme(primary: ThemeColor(hex: hex))
            let pixel = try XCTUnwrap(NSColor(theme.accent).usingColorSpace(.sRGB))
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(pixel.redComponent) + 0.7152 * linear(pixel.greenComponent)
                + 0.0722 * linear(pixel.blueComponent)
            XCTAssertGreaterThan((luminance + 0.05) / (0.02 + 0.05), 2.99,
                                 "Tinted controls need contrast against dark surfaces")
            XCTAssertGreaterThan(1.05 / (luminance + 0.05), 3.5,
                                 "Pale primaries must preserve contrast for native controls and white button labels")
        }
    }

    @MainActor func testSelectedFavoriteUsesWebsiteIconAcrossSpaceThemes() throws {
        let icon = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        for hex in ["#777777", "#22BB55", "#3355EE"] {
            let theme = SpaceChromeTheme(primary: ThemeColor(hex: hex))
            for scheme in [ColorScheme.dark, .light] {
                let renderer = ImageRenderer(content: FavoriteTileBackground(selected: true,
                    hovering: false, icon: icon)
                    .environment(\.spaceChromeTheme, theme)
                    .environment(\.colorScheme, scheme)
                    .frame(width: 72, height: 46)
                    .background(scheme == .dark ? Color.black : Color.white))
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
                let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: 23)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(edge.redComponent - edge.greenComponent, 0.3,
                                     "The red favicon must supply the outline in space \(hex)")
                XCTAssertGreaterThan(edge.redComponent - edge.blueComponent, 0.3)
            }
        }
    }

    @MainActor func testTooltipAnchorReceivesThemeEditsWithoutChangingItsHint() {
        let anchor = TabTooltipAnchorView(tooltip: TabTooltip())
        let green = SpaceChromeTheme(primary: ThemeColor(hex: "#22AA55"))
        anchor.configure(title: "Docs", enabled: true, theme: green)
        XCTAssertEqual(anchor.theme, green)
        let red = SpaceChromeTheme(primary: ThemeColor(hex: "#DD3355"))
        anchor.configure(title: "Docs", enabled: true, theme: red)
        XCTAssertEqual(anchor.theme, red)
        XCTAssertEqual(anchor.hint, "Double-click to rename")
    }
}
