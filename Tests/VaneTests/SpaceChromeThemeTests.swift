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
