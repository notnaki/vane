import XCTest
@testable import vane

@MainActor final class FavouritePreviewHoverTests: XCTestCase {
    private func waitForVisibility(_ visible: Bool, of hover: FavouritePreviewHover,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while hover.visible != visible, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(hover.visible, visible, file: file, line: line)
    }

    func testBriefHoverDoesNotOpenAndTransferKeepsCardOpen() async throws {
        let hover = FavouritePreviewHover()
        hover.setHovered(true, over: .tile)
        try await Task.sleep(for: .milliseconds(40))
        hover.setHovered(false, over: .tile)
        try await Task.sleep(for: .milliseconds(280))
        XCTAssertFalse(hover.visible)
        hover.setHovered(true, over: .tile)
        try await waitForVisibility(true, of: hover)
        hover.setHovered(false, over: .tile)
        hover.setHovered(true, over: .card)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(hover.visible)
        hover.setHovered(false, over: .card)
        try await waitForVisibility(false, of: hover)
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
