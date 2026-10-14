import XCTest
@testable import vane

@MainActor final class FavouritePreviewNavigationTests: XCTestCase {
    func testEmbeddedFrameFailureDoesNotAbortPreview() {
        for displayable in [true, false] {
            XCTAssertTrue(FavouriteWebLoader.acceptsResponse(isMainFrame: false, canShowMIMEType: displayable, statusCode: 429),
                          "A cookie-refresh or auxiliary frame cannot retire the service page")
        }
    }

    func testMainPageStillRejectsFailuresAndUnsupportedContent() {
        XCTAssertFalse(FavouriteWebLoader.acceptsResponse(isMainFrame: true, canShowMIMEType: true, statusCode: 429))
        XCTAssertFalse(FavouriteWebLoader.acceptsResponse(isMainFrame: true, canShowMIMEType: false, statusCode: 200))
        XCTAssertTrue(FavouriteWebLoader.acceptsResponse(isMainFrame: true, canShowMIMEType: true, statusCode: 200))
    }
}
