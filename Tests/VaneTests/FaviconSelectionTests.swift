import XCTest
@testable import vane

@MainActor final class FaviconSelectionTests: XCTestCase {
    func testTouchRoleAndDimensionsChooseSharpArtworkWithoutSpecialFilename() {
        let urls = Favicons.declared([
            ["href": "https://icons.example/small.png", "rel": "icon", "sizes": "16x16"],
            ["href": "https://icons.example/brand.png", "rel": "apple-touch-icon", "sizes": "180x180"],
            ["href": "https://icons.example/touch.png", "rel": "apple-touch-icon", "sizes": "57x57"]
        ])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["brand.png", "touch.png", "small.png"])
    }

    func testManageBacStylePreloadedTouchIconWinsOverLegacyICO() {
        let urls = Favicons.declared([
            ["href": "https://icons.example/old.ico", "rel": "icon"],
            ["href": "https://icons.example/apple-touch-icon-hash.png", "rel": "preload"]
        ])
        XCTAssertEqual(urls.first?.lastPathComponent, "apple-touch-icon-hash.png")
    }

    func testCialfoStyleJPEGMatteDoesNotReplaceTransparentFavicon() {
        let urls = Favicons.declared([
            ["href": "https://icons.example/crest.jpg", "rel": "apple-touch-icon"],
            ["href": "https://icons.example/transparent.ico", "rel": "icon"]
        ])
        XCTAssertEqual(urls.first?.lastPathComponent, "transparent.ico")
    }

    func testLargestRetinaIconWinsAndTiesKeepPageOrder() {
        let urls = Favicons.declared([
            ["href": "https://icons.example/favicon-16x16.png", "rel": "icon"],
            ["href": "https://icons.example/favicon-196x196.png", "rel": "icon"],
            ["href": "https://icons.example/a.png", "rel": "icon", "sizes": "32x32 96x96"],
            ["href": "https://icons.example/b.png", "rel": "icon", "sizes": "96x96"]
        ])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["favicon-196x196.png", "a.png", "b.png", "favicon-16x16.png"])
    }

    func testInvalidSchemesAndDuplicateDeclarationsAreIgnored() {
        let urls = Favicons.declared([
            ["href": "file:///tmp/private.png", "rel": "icon"],
            ["href": "https://icons.example/brand.png", "rel": "icon", "sizes": "invalid"],
            ["href": "https://icons.example/brand.png", "rel": "apple-touch-icon", "sizes": "180x180"]
        ])
        XCTAssertEqual(urls.map(\.absoluteString), ["https://icons.example/brand.png"])
    }
}
