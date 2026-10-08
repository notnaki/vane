import XCTest
@testable import vane

final class ReadingQueueLibraryTests: XCTestCase {
    func testSearchesSavedBodyAndFiltersExplicitReadState() {
        var article = makeReadingArticle(text: "A buried nebula appears here")
        article.isRead = true
        let unrelated = makeReadingArticle(text: "A different text")
        XCTAssertEqual(ReadingQueueSearch.results(articles: [article, unrelated], query: "nebula", filter: .read).map(\.id), [article.id])
        XCTAssertTrue(ReadingQueueSearch.results(articles: [article], query: "nebula", filter: .unread).isEmpty)
        XCTAssertFalse(LibrarySection.readingQueue.available(private: true))
        XCTAssertEqual(Command(rawValue: "saveForOffline")?.title, "Save for Offline")
        XCTAssertEqual(Command(rawValue: "readingQueue")?.title, "Reading Queue")
    }
    func testCaptureOrderHasStableTieBreakAndNoReadStateEffect() {
        var first = makeReadingArticle(), second = makeReadingArticle()
        first.capturedAt = Date(timeIntervalSince1970: 100)
        second.capturedAt = first.capturedAt
        let expected = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(ReadingQueueSearch.results(articles: [second, first], query: "", filter: .all).map(\.id), expected)
        first.isRead = true
        XCTAssertEqual(ReadingQueueSearch.results(articles: [second, first], query: "", filter: .all).map(\.id), expected)
    }
}
