import XCTest
@testable import vane

func makeReadingArticle(profileID: UUID = ProfileManager.defaultID, text: String = "Saved body contains Café and nebula.") -> ReadingArticle {
    ReadingArticle(profileID: profileID, title: "Fixture article", sourceURL: "https://example.test/article", nodes: [.init(e: "p", c: [.init(x: text)])])
}

final class ReadingQueueCodecTests: XCTestCase {
    func testRoundTripOwnershipAndBodySearch() throws {
        let article = makeReadingArticle()
        let bytes = try ReadingArticleCodec.encode(article)
        XCTAssertEqual(try ReadingArticleCodec.decode(bytes, profileID: article.profileID, articleID: article.id), article)
        XCTAssertThrowsError(try ReadingArticleCodec.decode(bytes, profileID: UUID(), articleID: article.id))
        XCTAssertTrue(ReadingArticleCodec.matches(article, query: "CAFE"))
        XCTAssertTrue(ReadingArticleCodec.matches(article, query: "nebula"))
        XCTAssertTrue(ReadingArticleCodec.matches(article, query: "example.test"))
    }
    func testRejectsActiveMarkupVersionsAndLimits() throws {
        var article = makeReadingArticle()
        article.nodes = [.init(e: "script", c: [.init(x: "alert(1)")])]
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        article = makeReadingArticle(); article.version = 99
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        article = makeReadingArticle(); article.sourceURL = "file:///etc/passwd"
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        article = makeReadingArticle(); article.nodes[0].a = ["onclick": "bad()"]
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        article = makeReadingArticle(text: String(repeating: "x", count: 2 * 1024 * 1024 + 1))
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        var node = ReadingArticle.Node(x: "deep")
        for _ in 0..<65 { node = .init(e: "p", c: [node]) }
        article = makeReadingArticle(); article.nodes = [node]
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
    }
    func testRejectsPrivateIdentityAndUnmappedImages() throws {
        XCTAssertThrowsError(try ReadingArticleCodec.encode(makeReadingArticle(profileID: Profile.incognito.id)))
        var article = makeReadingArticle()
        article.nodes.append(.init(e: "img", a: ["src": "https://tracker.test/image"]))
        XCTAssertThrowsError(try ReadingArticleCodec.encode(article))
        XCTAssertThrowsError(try ReadingArticleCodec.validate(.init(article: makeReadingArticle(), images: ["../bad.png": Data()])))
    }
}
