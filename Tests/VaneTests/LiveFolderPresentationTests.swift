import XCTest
@testable import vane

final class LiveFolderPresentationTests: XCTestCase {
    private let url = "https://github.com/notnaki/vane/pull/195"

    func testSearchAuthorAppearsWithoutAnOpenBadge() throws {
        let data = Data(#"{"items":[{"html_url":"https://github.com/notnaki/vane/pull/195","title":"Show rounded placeholders","number":195,"draft":false,"user":{"login":"notnaki"}}]}"#.utf8)
        let prs = try XCTUnwrap(GitHub.decode(data))
        let row = try XCTUnwrap(GitHub.presentation(prs, goodbyes: [], previous: [:], details: [:])[url])
        XCTAssertEqual(row.subtitle, "notnaki")
        XCTAssertEqual(row.state, .open)
    }

    func testMergedAndUnmergedClosedPRsAreDistinct() throws {
        let merged = try XCTUnwrap(GitHub.detail(Data(#"{"state":"closed","merged":true,"merged_at":"2026-10-02T08:00:00Z","user":{"login":"notnaki"}}"#.utf8)))
        let closed = try XCTUnwrap(GitHub.detail(Data(#"{"state":"closed","merged":false,"merged_at":null,"user":{"login":"notnaki"}}"#.utf8)))
        XCTAssertEqual(merged.subtitle, "notnaki · Merged")
        XCTAssertEqual(closed.subtitle, "notnaki · Closed")
        XCTAssertEqual(GitHub.detail(Data(#"{"state":"closed","merged_at":"2026-10-02T08:00:00Z"}"#.utf8))?.state, .merged)
        XCTAssertNil(GitHub.detail(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(GitHub.detail(Data(#"{"state":"bogus"}"#.utf8)))
    }

    func testDisappearanceDoesNotProveAMergeAndKeepsAuthor() throws {
        let previous = [url: GitHub.Row(author: "notnaki", state: .open)]
        let unknown = try XCTUnwrap(GitHub.presentation([], goodbyes: [url], previous: previous, details: [:])[url])
        XCTAssertEqual(unknown.subtitle, "notnaki")
        XCTAssertEqual(unknown.state, .unavailable)
        let stillOpen = GitHub.Row(author: "notnaki", state: .open)
        XCTAssertEqual(GitHub.presentation([], goodbyes: [url], previous: previous, details: [url: stillOpen])[url]?.subtitle, "notnaki")
        let merged = GitHub.Row(author: "", state: .merged)
        let confirmed = try XCTUnwrap(GitHub.presentation([], goodbyes: [url], previous: previous, details: [url: merged])[url])
        XCTAssertEqual(confirmed.subtitle, "notnaki · Merged")
        XCTAssertEqual(GitHub.presentation([], goodbyes: [url], previous: [url: confirmed], details: [:])[url], confirmed)
    }

    func testBrowsedPRKeepsMetadataDuringGoodbyeAndReopensCleanly() throws {
        let browsed = url + "/files"
        let rows = GitHub.presentation([], goodbyes: [browsed], previous: [url: .init(author: "notnaki", state: .open)], details: [browsed: .init(author: "notnaki", state: .merged)])
        XCTAssertEqual(rows[browsed]?.subtitle, "notnaki · Merged")
        let reopened = GitHub.PR(url: url, title: "Reopened", draft: true, repo: "notnaki/vane", number: 195, author: "notnaki")
        let fresh = GitHub.presentation([reopened], goodbyes: [], previous: rows, details: [:])
        XCTAssertNil(fresh[browsed])
        XCTAssertEqual(fresh[url]?.state, .draft)
        XCTAssertEqual(fresh[url]?.subtitle, "notnaki")
        XCTAssertTrue(GitHub.presentation([], goodbyes: [], previous: rows, details: [:]).isEmpty)
    }

    func testHeldClosedPRIsRecheckedBecauseItCanReopenAndMerge() {
        let closed = [url: GitHub.Row(author: "notnaki", state: .closed)]
        XCTAssertEqual(GitHub.detailRows(have: [url], found: [], previous: closed), [url])
        let merged = [url: GitHub.Row(author: "notnaki", state: .merged)]
        XCTAssertTrue(GitHub.detailRows(have: [url], found: [], previous: merged).isEmpty)
        XCTAssertTrue(GitHub.detailRows(have: [url + "/files"], found: [url], previous: closed).isEmpty)
    }

    func testDetailRequestsUseOnlyTrustedPRPaths() {
        XCTAssertEqual(GitHub.detailURL(url + "/files")?.absoluteString, "https://api.github.com/repos/notnaki/vane/pulls/195")
        for bad in ["https://evil.test/notnaki/vane/pull/195", "http://github.com/notnaki/vane/pull/195", "https://github.com@evil.test/notnaki/vane/pull/195", "https://user@github.com/notnaki/vane/pull/195", "https://github.com/notnaki/vane/pull/0", "https://github.com/notnaki/vane/issues/195"] {
            XCTAssertNil(GitHub.detailURL(bad), bad)
        }
    }
}
