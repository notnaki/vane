import XCTest
@testable import vane

final class FavouriteSessionFingerprintTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String = ".google.com", expires: Date = Date(timeIntervalSince1970: 4_000_000_000)) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE", .expires: expires])!
    }
    func testGoogleRotationAndExpiryRefreshKeepSessionButReplacementAndDeletionRetireIt() {
        let original = FavouriteSessionFingerprint([cookie("SID", "fixture-session"), cookie("__Secure-3PSIDTS", "rotation-one")])
        let rotated = FavouriteSessionFingerprint([cookie("SID", "fixture-session", expires: Date(timeIntervalSince1970: 4_100_000_000)), cookie("__Secure-3PSIDTS", "rotation-two")])
        XCTAssertEqual(original, rotated)
        XCTAssertNotEqual(original, FavouriteSessionFingerprint([cookie("SID", "replacement-session")]))
        XCTAssertNotEqual(original, FavouriteSessionFingerprint([]))
    }
    func testLookalikeHostsCannotSupplySessionProof() {
        XCTAssertEqual(FavouriteSessionFingerprint([cookie("SID", "fixture", domain: ".google.com.example.test")]), FavouriteSessionFingerprint([]))
        XCTAssertEqual(FavouriteSessionFingerprint([cookie("user_session", "fixture", domain: ".github.com.example.test")]), FavouriteSessionFingerprint([]))
    }
    func testSessionCacheIsBoundToProfileAccountRouteAndSelectionCookies() throws {
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/0/")!)!
        let otherProfile = FavouritePreviewContext(profileID: UUID(), url: context.siteURL)!
        let otherRoute = FavouritePreviewContext(profileID: context.profileID, url: URL(string: "https://mail.google.com/mail/u/1/")!)!
        let session = FavouriteSessionFingerprint([cookie("SID", "fixture"), cookie("ACCOUNT_CHOOSER", "selection-one")])
        let changed = FavouriteSessionFingerprint([cookie("SID", "fixture"), cookie("ACCOUNT_CHOOSER", "selection-two")])
        let snapshot = FavouritePreviewSnapshot(account: "fixture@example.test", items: [])
        var cache = FavouritePreviewCache()
        cache.store(snapshot, context: context, session: session)
        XCTAssertEqual(cache.lookup(context: context, session: session)?.snapshot, snapshot)
        XCTAssertNil(cache.lookup(context: otherProfile, session: session))
        XCTAssertNil(cache.lookup(context: otherRoute, session: session))
        XCTAssertNil(cache.lookup(context: context, session: changed))
        cache.invalidate(profileID: context.profileID)
        XCTAssertNil(cache.lookup(context: context, session: session))
    }

    func testLoggedInFlagAloneCannotAuthorizeSessionCacheReuse() {
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!
        let flag = FavouriteSessionFingerprint([cookie("logged_in", "yes", domain: ".github.com")])
        var cache = FavouritePreviewCache()
        cache.store(.init(account: "fixture", items: []), context: context, session: flag)
        XCTAssertNil(cache.lookup(context: context, session: flag))
    }

}
