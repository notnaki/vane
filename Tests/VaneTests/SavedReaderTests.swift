import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SavedReaderTests: XCTestCase {
    func testEscapingLabelAndNoNetworkImages() {
        TestEnvironment.prepare()
        let article = makeReadingArticle(text: "<script>window.bad=true</script>")
        let html = SavedReaderDocument.html(article: article)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("Saved copy"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("src=\"https://"))
    }
    func testNavigationRejectsSiblingAndUnrequestedLivePage() {
        let directory = URL(fileURLWithPath: "/tmp/article")
        XCTAssertTrue(SavedReaderNavigation.allowed(url: directory.appendingPathComponent("article.html"), articleDirectory: directory, userInitiated: false))
        XCTAssertFalse(SavedReaderNavigation.allowed(url: URL(fileURLWithPath: "/tmp/article-other/article.html"), articleDirectory: directory, userInitiated: false))
        XCTAssertFalse(SavedReaderNavigation.allowed(url: URL(string: "https://tracker.test/pixel")!, articleDirectory: directory, userInitiated: false))
    }
    func testCurrentPreferencesDoNotChangeSnapshot() throws {
        TestEnvironment.prepare()
        let article = makeReadingArticle()
        let data = try ReadingArticleCodec.encode(article), old = Reader.fontSize
        defer { Reader.fontSize = old }
        Reader.fontSize = 27
        XCTAssertTrue(SavedReaderDocument.html(article: article).contains("--r-size: 27px"))
        XCTAssertEqual(try ReadingArticleCodec.encode(article), data)
        XCTAssertFalse(article.isRead)
    }
}
