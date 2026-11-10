import AppKit
import WebKit
import XCTest
@testable import vane

/// Native cookies only: no WebViews, windows, foreground ownership, network or Keychain.
@MainActor final class ChromiumCookieWebKitTests: XCTestCase {
    private final class Reply {
        var report: ChromiumCookies.Report?
        var cookies: [HTTPCookie]?
    }

    private func wait(_ stage: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), stage)
        guard condition() else { throw BrowserImport.Failure("Synthetic cookie fixture timed out: " + stage) }
    }

    // Keep callback admission synchronous so the test's observable deadline is retained.
    private func read(_ store: WKHTTPCookieStore, reply: Reply) {
        store.getAllCookies { reply.cookies = $0 }
    }

    private func cookies(_ store: WKHTTPCookieStore) async throws -> [HTTPCookie] {
        let reply = Reply()
        read(store, reply: reply)
        try await wait("Cookie readback") { reply.cookies != nil }
        return try XCTUnwrap(reply.cookies)
    }

    func testNativePublicationKeepsSecurityLifetimeExistingSessionsAndOtherProfilePrivateStores() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let ids = [UUID(), UUID()]
        let directory = try XCTUnwrap(Store.overrideDirectory)
        for id in ids { _ = try NativeFixtureRetirement.recordIfEnabled(profile: id, directory: directory) }
        addTeardownBlock { @MainActor in try await NativeFixtureProfileCleanup.release(Set(ids)) }
        let first = ProfileManager.dataStore(for: ids[0])
        let second = ProfileManager.dataStore(for: ids[1])
        let temporary = WKWebsiteDataStore.nonPersistent()
        let expiry = Int64(Date().timeIntervalSince1970) + 3600
        let row = ChromiumCookies.Row(host: ".cookie-fixture.invalid", name: "sid", path: "/account", value: Data(),
            expires: (expiry + 11_644_473_600) * 1_000_000, secure: true, httpOnly: true, sameSite: 2)
        let cookie = try XCTUnwrap(ChromiumCookies.cookie(row, value: "synthetic-session"))
        let access = ChromiumCookies.Access(store: first.httpCookieStore)
        let reply = Reply()
        let job = Task {
            reply.report = await ChromiumCookies.publish([cookie], validate: { true }, fetch: access.fetch, set: access.set)
        }
        defer { job.cancel() }
        try await wait("Verified native cookie publication") { reply.report != nil }
        XCTAssertEqual(reply.report?.imported, 1)
        XCTAssertEqual(reply.report?.failed, 0)
        let firstCookies = try await cookies(first.httpCookieStore)
        let saved = try XCTUnwrap(firstCookies.first)
        XCTAssertEqual(saved.domain, ".cookie-fixture.invalid")
        XCTAssertEqual(saved.path, "/account")
        XCTAssertTrue(saved.isHTTPOnly)
        XCTAssertTrue(saved.isSecure)
        XCTAssertEqual(saved.sameSitePolicy?.rawValue, "strict")
        XCTAssertEqual(saved.expiresDate?.timeIntervalSince1970, TimeInterval(expiry))
        let unchanged = try await cookies(second.httpCookieStore)
        let privateCookies = try await cookies(temporary.httpCookieStore)
        XCTAssertTrue(unchanged.isEmpty)
        XCTAssertTrue(privateCookies.isEmpty)
        let replacement = try XCTUnwrap(ChromiumCookies.cookie(row, value: "replacement-must-not-win"))
        reply.report = nil
        let repeatJob = Task {
            reply.report = await ChromiumCookies.publish([replacement], validate: { true }, fetch: access.fetch, set: access.set)
        }
        defer { repeatJob.cancel() }
        try await wait("Existing native cookie preservation") { reply.report != nil }
        XCTAssertEqual(reply.report?.imported, 0)
        XCTAssertEqual(reply.report?.skipped, 1)
        let after = try await cookies(first.httpCookieStore)
        XCTAssertEqual(after.first?.value, "synthetic-session")
    }
}
