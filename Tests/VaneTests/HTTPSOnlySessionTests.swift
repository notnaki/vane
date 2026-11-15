import Foundation
import XCTest
@testable import vane

@MainActor final class HTTPSOnlySessionTests: XCTestCase {
    private var originalDefaults: UserDefaults!
    private var suite: String!
    private let normal = UUID()
    private let other = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let http = URL(string: "http://probe.example/path")!
    private let https = URL(string: "https://probe.example/path")!
    private let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

    override func setUp() async throws {
        TestEnvironment.prepare()
        suite = "vane.https-session-tests.\(UUID())"
        originalDefaults = HTTPSOnly.defaults
        HTTPSOnly.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        HTTPSOnly.enabled = true
        HTTPSOnly.forgetAll()
        HTTPSOnly.forgetLoopState()
    }

    override func tearDown() async throws {
        HTTPSOnly.forgetAll()
        HTTPSOnly.forgetLoopState()
        HTTPSOnly.defaults = originalDefaults
        UserDefaults.dropScratchSuite(suite)
    }

    private var isolationPairs: [(UUID, UUID)] {
        [(normal, Profile.incognito.id), (Profile.incognito.id, normal), (normal, other)]
    }

    func testUpgradeAttemptsStayWithinTheirBrowsingSession() {
        for (source, destination) in isolationPairs {
            HTTPSOnly.forgetLoopState()
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .upgrade(https))
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: destination, now: now), .upgrade(https),
                           "A different session must make its own observable HTTPS request")
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .block(http))
        }
    }

    func testConnectionFailuresAreAttributedOnlyToTheSessionThatUpgraded() {
        for (source, destination) in isolationPairs {
            HTTPSOnly.forgetLoopState()
            _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now)
            XCTAssertNil(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: destination, now: now))
            XCTAssertEqual(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: source, now: now), http)
        }
    }

    func testRedirectInterstitialAllowanceCannotBeConsumedByAnotherSession() {
        for (source, destination) in isolationPairs {
            HTTPSOnly.forgetLoopState()
            _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now)
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .block(http))
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: destination, now: now), .upgrade(https))
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .allow)
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .block(http))
        }
    }

    func testFailureInterstitialAllowanceCannotBeConsumedByAnotherSession() {
        for (source, destination) in isolationPairs {
            HTTPSOnly.forgetLoopState()
            _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now)
            XCTAssertEqual(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: source, now: now), http)
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: destination, now: now), .upgrade(https))
            XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: source, now: now), .allow)
        }
    }

    func testPrivateExceptionsEndOnlyAfterTheLastPrivateWindow() {
        let first = TabStore(isPrivate: true, profileID: normal, session: [])
        let floating = TabStore(isPrivate: true, profileID: normal, isLittle: true, session: [])
        defer { TabStore.all.removeAll { $0 === first || $0 === floating } }
        HTTPSOnly.allow(host: "probe.example", profileID: Profile.incognito.id)
        HTTPSOnly.allow(host: "probe.example", profileID: normal)
        TabStore.all.removeAll { $0 === first }
        XCTAssertTrue(HTTPSOnly.isExcepted(host: "probe.example", profileID: Profile.incognito.id))
        TabStore.all.removeAll { $0 === floating }
        XCTAssertFalse(HTTPSOnly.isExcepted(host: "probe.example", profileID: Profile.incognito.id))
        XCTAssertEqual(HTTPSOnly.upgrade(http, profileID: Profile.incognito.id), https)
        XCTAssertTrue(HTTPSOnly.isExcepted(host: "probe.example", profileID: normal))
    }

    func testLastPrivateStoreClearsAttemptsAndInterstitialAllowanceOnlyForPrivateBrowsing() {
        let first = TabStore(isPrivate: true, profileID: normal, session: [])
        defer { TabStore.all.removeAll { $0 === first } }
        let privateID = Profile.incognito.id
        _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: normal, now: now)
        _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: privateID, now: now)
        XCTAssertEqual(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: privateID, now: now), http)
        // Same registry removal used by browser and floating window teardown; no NSWindow needed.
        TabStore.all.removeAll { $0 === first }
        XCTAssertNil(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: privateID, now: now))
        XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: privateID, now: now), .upgrade(https),
                       "The next private session inherits neither an attempt nor the old one-shot allowance")
        XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: normal, now: now), .block(http),
                       "Ending private browsing must preserve normal session attempts")
    }

    func testPrivatePageOutlivingItsWindowKeepsTheSessionUntilPageTeardown() {
        let window = TabStore(isPrivate: true, profileID: normal, session: [])
        // A website popup owns a private Tab without a TabStore. Keep its model alive,
        // without making the WebKit configuration or window needed by an actual popup.
        let page = Tab(isPrivate: true, profileID: normal)
        defer {
            TabStore.all.removeAll { $0 === window }
            page.tearDown()
        }
        HTTPSOnly.allow(host: "exception.example", profileID: Profile.incognito.id)
        _ = HTTPSOnly.decide(url: http, isMainFrame: true, profileID: Profile.incognito.id, now: now)
        TabStore.all.removeAll { $0 === window }
        XCTAssertTrue(HTTPSOnly.isExcepted(host: "exception.example", profileID: Profile.incognito.id))
        page.tearDown()
        page.tearDown() // Teardown is idempotent.
        XCTAssertFalse(HTTPSOnly.isExcepted(host: "exception.example", profileID: Profile.incognito.id))
        XCTAssertNil(HTTPSOnly.downgradeOffer(after: timeout, url: https, profileID: Profile.incognito.id, now: now))
        XCTAssertEqual(HTTPSOnly.decide(url: http, isMainFrame: true, profileID: Profile.incognito.id, now: now), .upgrade(https))
    }
}
