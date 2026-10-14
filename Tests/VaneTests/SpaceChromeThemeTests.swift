import AppKit
import SwiftUI
import XCTest
@testable import vane

final class SpaceChromeThemeTests: XCTestCase {
    func testPrimaryDotOwnsInteractionColourAndProfileIsFallback() {
        var space = Space(name: "Theme", profileID: UUID())
        let primary = ThemeColor(red: 0.2, green: 0.7, blue: 0.3)
        Spaces.setPalette([primary, ThemeColor(red: 0.9, green: 0.2, blue: 0.7)], on: &space)
        XCTAssertEqual(SpaceChromeTheme(space: space, fallback: "#2233FF").primary, primary)
        XCTAssertEqual(SpaceChromeTheme(space: nil, fallback: "#2233FF").primary,
                       ThemeColor(hex: "#2233FF"))
    }

    @MainActor func testSelectedFavoriteUsesSpacePrimaryInsteadOfItsWebsiteIcon() throws {
        let icon = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let theme = SpaceChromeTheme(primary: ThemeColor(hex: "#22BB55"))
        for scheme in [ColorScheme.dark, .light] {
            let renderer = ImageRenderer(content: FavoriteTileBackground(selected: true,
                hovering: false, icon: icon)
                .environment(\.spaceChromeTheme, theme)
                .environment(\.colorScheme, scheme)
                .frame(width: 72, height: 46)
                .background(scheme == .dark ? Color.black : Color.white))
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let edge = try XCTUnwrap(bitmap.colorAt(x: 1, y: 23)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(edge.greenComponent - edge.redComponent, 0.3,
                                 "The open favorite's outline should follow the space's green primary")
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
