import XCTest
import SwiftUI
@testable import vane

@MainActor final class SwipeTabPresentationTests: XCTestCase {
    func testGhostKeepsFullTitleWhenTidyingIsDisabled() {
        TestEnvironment.prepare()
        let profile = UUID()
        let wasEnabled = TidyTitles.enabled
        defer { TidyTitles.enabled = wasEnabled; TidyTitles.forget(profile) }
        TidyTitles.enabled = false
        let url = URL(string: "https://www.google.com/search?q=aksdhaskd")!
        XCTAssertEqual(TidyTitles.previewName(for: url, in: profile,
                                             saved: "aksdhaskd - Google"), "aksdhaskd - Google")
        TidyTitles.recordPinnedName("aksdhaskd - Google", for: url, in: profile)
        XCTAssertEqual(TidyTitles.previewName(for: url, in: profile, saved: nil),
                       "aksdhaskd - Google")
    }

    func testTodayGhostDoesNotBorrowAPinnedNameOrShortenThePageTitle() {
        TestEnvironment.prepare()
        let profile = UUID()
        let wasEnabled = TidyTitles.enabled
        defer { TidyTitles.enabled = wasEnabled; TidyTitles.forget(profile) }
        TidyTitles.enabled = true
        let url = URL(string: "https://www.google.com/search?q=aksdhaskd")!
        TidyTitles.recordPinnedName("Previous search - Google", for: url, in: profile)
        XCTAssertEqual(TidyTitles.previewName(for: url, in: profile,
            saved: "aksdhaskd - Google", stays: false), "aksdhaskd - Google")
        XCTAssertEqual(TidyTitles.previewName(for: url, in: profile,
            saved: "aksdhaskd - Google", stays: true), "Previous search")
        TidyTitles.rename(url, in: profile, to: "My search")
        XCTAssertEqual(TidyTitles.previewName(for: url, in: profile,
            saved: "aksdhaskd - Google", stays: false), "My search")
    }

    func testDeveloperEndpointKeepsExplicitPortsAndBracketsIPv6() {
        let cases = [
            ("http://127.0.0.1:8765/path?q=x", "127.0.0.1:8765"),
            ("http://localhost:3000/", "localhost:3000"),
            ("http://[::1]:8080/", "[::1]:8080"),
            ("https://staging.example.com/", "staging.example.com:443"),
            ("http://localhost/", "localhost:80"),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(DeveloperMode.endpoint(URL(string: url)), expected)
        }
        XCTAssertNil(DeveloperMode.endpoint(nil))
        XCTAssertNil(DeveloperMode.endpoint(URL(string: "about:blank")))
    }

    func testDeveloperTapeRendersOpaqueBlackBetweenYellowDashes() throws {
        let renderer = ImageRenderer(content: DeveloperTabBorder().frame(width: 228, height: 36))
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var black = 0, yellow = 0
        for x in 20..<208 {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 0)?.usingColorSpace(.deviceRGB))
            guard color.alphaComponent > 0.9 else { continue }
            if color.redComponent < 0.1 && color.greenComponent < 0.1 && color.blueComponent < 0.1 {
                black += 1
            }
            if color.redComponent > 0.9 && color.greenComponent > 0.7 && color.blueComponent < 0.1 {
                yellow += 1
            }
        }
        XCTAssertGreaterThan(black, 30, "The gaps must be black, even over a light sidebar")
        XCTAssertGreaterThan(yellow, 30, "Yellow must alternate with black along the border")
    }

    func testDuplicateLiveTodayTabsKeepTheirOwnGhostTitle() {
        TestEnvironment.prepare()
        let profile = UUID()
        let url = URL(string: "https://example.com/document")!
        let first = Tab(profileID: profile), second = Tab(profileID: profile)
        defer { first.tearDown(); second.tearDown(); Store.forget(profile) }
        first.park(url: url, Parked(title: "First document state"))
        second.park(url: url, Parked(title: "Second document state"))
        let preview = SpacePreviewList(space: Space(name: "Work", profileID: profile,
            tabURLs: [url, url]), liveTabs: [first, second])
        XCTAssertEqual(preview.rows.today.map { preview.title(for: $0, saved: [:]) },
                       ["First document state", "Second document state"])
    }
}
