import XCTest
import WebKit
@testable import vane

@MainActor final class FavouritePreviewTests: XCTestCase {
    func testServiceRoutesAreExactAndPreserveGoogleAccount() throws {
        XCTAssertEqual(FavouritePreviewService.resolve(URL(string: "https://mail.google.com/mail/u/2/#inbox")!), .gmail)
        XCTAssertNil(FavouritePreviewService.resolve(URL(string: "https://mail.google.com.evil.test/")!))
        XCTAssertNil(FavouritePreviewService.resolve(URL(string: "http://github.com/")!))
        let route = try XCTUnwrap(FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/2/#inbox")!))
        XCTAssertEqual(route.siteURL.absoluteString, "https://mail.google.com/mail/u/2/#inbox")
        XCTAssertEqual(route.composeURL?.absoluteString, "https://mail.google.com/mail/u/2/#inbox?compose=new")
    }

    func testParserRejectsMissingIdentityUnknownMarkupAndUnsafeLinks() throws {
        let adapter = DOMFavouritePreviewAdapter(service: .gmail)
        XCTAssertEqual(adapter.parse(.init(state: "ready", account: "", items: [])), .unavailable)
        XCTAssertEqual(adapter.parse(.init(state: "unknown", account: "a@test.com", items: [])), .unavailable)
        let bad = FavouritePreviewExtraction.Row(title: "Subject", subtitle: "Sender", url: "https://evil.test/a")
        XCTAssertEqual(adapter.parse(.init(state: "ready", account: "a@test.com", items: [bad])), .unavailable)
        XCTAssertEqual(adapter.parse(.init(state: "signedOut", account: "", items: [])), .signedOut)
        XCTAssertEqual(adapter.parse(.init(state: "ready", account: "a@test.com", items: [])), .unavailable)
        guard case .ready(let snapshot) = adapter.parse(.init(state: "empty", account: "a@test.com", items: [])) else { return XCTFail("Verified empty expected") }
        XCTAssertTrue(snapshot.items.isEmpty)
    }

    func testCacheIsolatedByProfileAccountAndRouteAndExpires() throws {
        let a = try XCTUnwrap(FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/0/")!))
        let b = try XCTUnwrap(FavouritePreviewContext(profileID: UUID(), url: a.siteURL))
        let c = try XCTUnwrap(FavouritePreviewContext(profileID: a.profileID, url: URL(string: "https://mail.google.com/mail/u/1/")!))
        var cache = FavouritePreviewCache()
        let now = Date(timeIntervalSince1970: 1000)
        let snapshot = FavouritePreviewSnapshot(account: "a@test.com", items: [])
        cache.store(snapshot, context: a, now: now)
        XCTAssertNotNil(cache.lookup(context: a, account: "a@test.com", now: now))
        XCTAssertNil(cache.lookup(context: a, account: "b@test.com", now: now))
        XCTAssertNil(cache.lookup(context: b, account: "a@test.com", now: now))
        XCTAssertNil(cache.lookup(context: c, account: "a@test.com", now: now))
        XCTAssertTrue(try XCTUnwrap(cache.lookup(context: a, account: "a@test.com", now: now.addingTimeInterval(121))).stale)
        XCTAssertNil(cache.lookup(context: a, account: "a@test.com", now: now.addingTimeInterval(601)))
        cache.invalidate(profileID: b.profileID)
        XCTAssertNotNil(cache.lookup(context: a, account: "a@test.com", now: now))
        cache.invalidate(profileID: a.profileID)
        XCTAssertNil(cache.lookup(context: a, account: "a@test.com", now: now))
    }

    func testParserKeepsUnreadAndOnlyAvailableStatus() throws {
        let adapter = DOMFavouritePreviewAdapter(service: .gmail)
        let row = FavouritePreviewExtraction.Row(title: "Fixture subject", subtitle: "Fixture Sender", url: "https://mail.google.com/mail/u/1/#inbox/abc123", unread: true)
        guard case .ready(let snapshot) = adapter.parse(.init(state: "ready", account: "fixture@example.test", items: [row])) else { return XCTFail("Expected content") }
        XCTAssertTrue(snapshot.items[0].unread)
        XCTAssertEqual(snapshot.items[0].subtitle, "Fixture Sender")
        XCTAssertNil(snapshot.items[0].meetingURL)
        XCTAssertNil(FavouritePreviewURL.item("https://user:secret@github.com/a/b/pull/1", service: .github))
        XCTAssertNil(FavouritePreviewURL.item("javascript:alert(1)", service: .gmail))
    }
}
