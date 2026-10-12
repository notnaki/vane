import XCTest
@testable import vane

@MainActor final class FavouritePreviewHoverTests: XCTestCase {
    func testBriefHoverDoesNotOpenAndTransferKeepsCardOpen() async throws {
        let hover = FavouritePreviewHover()
        hover.setHovered(true, over: .tile)
        try await Task.sleep(for: .milliseconds(40))
        hover.setHovered(false, over: .tile)
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertFalse(hover.visible)
        hover.setHovered(true, over: .tile)
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertTrue(hover.visible)
        hover.setHovered(false, over: .tile)
        try await Task.sleep(for: .milliseconds(50))
        hover.setHovered(true, over: .card)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hover.visible)
        hover.setHovered(false, over: .card)
        try await Task.sleep(for: .milliseconds(210))
        XCTAssertFalse(hover.visible)
    }
    func testKeyboardOpeningStaysUntilEscapeAndDismissCancelsDwell() async throws {
        let hover = FavouritePreviewHover()
        hover.openForKeyboard()
        hover.setHovered(false, over: .tile)
        try await Task.sleep(for: .milliseconds(210))
        XCTAssertTrue(hover.visible)
        hover.dismiss()
        XCTAssertFalse(hover.visible)
        hover.setHovered(true, over: .tile)
        hover.dismiss()
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertFalse(hover.visible)
    }
}
