import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class FavouritePreviewDOMTests: XCTestCase {
    private func extract(_ html: String, service: FavouritePreviewService, url: String) async throws -> FavouritePreviewResult {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700), configuration: config)
        let window = PreviewHostWindow(content: web)
        defer { web.stopLoading(); window.contentView = nil; window.close() }
        web.loadHTMLString(html, baseURL: URL(string: url)!)
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let adapter = DOMFavouritePreviewAdapter(service: service)
        let value = try await web.evaluateJavaScript(adapter.script)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value))
        return adapter.parse(try JSONDecoder().decode(FavouritePreviewExtraction.self, from: data))
    }

    func testExtractsMoreRowsForScrollingWithBoundedPayload() async throws {
        let rows = (1...60).map { "<div class='js-issue-row'><a class='Link--primary' href='/fixture/repo/pull/\($0)'>PR \($0)</a></div>" }.joined()
        let result = try await extract("<meta name='user-login' content='fixture-user'>" + rows,
            service: .github, url: "https://github.com/pulls?q=is:open%20involves:@me")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected scrollable PRs") }
        XCTAssertEqual(snapshot.items.count, 50)
        XCTAssertEqual(snapshot.items.last?.title, "PR 50")
    }

    func testGitHubVisibleRowsAndStatus() async throws {
        let result = try await extract("""
        <meta name="user-login" content="fixture-user">
        <div class="js-issue-row"><a class="Link--primary" href="/fixture/repo/pull/42">Fixture PR</a>
        <span aria-label="Review required"></span><span title="All checks passed"></span></div>
        """, service: .github, url: "https://github.com/pulls?q=is:open%20is:pr%20involves:@me")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected extracted PR") }
        XCTAssertEqual(snapshot.items.first?.title, "Fixture PR")
        XCTAssertEqual(snapshot.items.first?.status, "Review required · All checks passed")
        XCTAssertEqual(snapshot.account, "fixture-user")
    }


    func testCurrentGitHubSearchRowsAndChecksBadge() async throws {
        let result = try await extract("""
        <meta name="user-login" content="fixture-user">
        <main><ul role="list"><li><h3><a data-testid="listitem-title-link" href="/fixture/repo/pull/43">Current fixture PR</a></h3>
        <button data-testid="checks-status-badge-button" aria-label="0 of 1 successful checks">0/1</button></li></ul></main>
        """, service: .github, url: "https://github.com/pulls/search?q=is:open%20is:pr%20involves:@me")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected current GitHub list") }
        XCTAssertEqual(snapshot.items.first?.title, "Current fixture PR")
        XCTAssertEqual(snapshot.items.first?.status, "0 of 1 successful checks")
    }

    func testGitHubAcceptsOpenStateQuerySpelling() async throws {
        let result = try await extract("""
        <meta name="user-login" content="fixture-user">
        <main><ul><li><a data-testid="listitem-title-link" href="/fixture/repo/pull/44">Open PR</a></li></ul></main>
        """, service: .github, url: "https://github.com/pulls?q=state:open%20is:pr%20involves:@me")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected open-state query to extract PRs") }
        XCTAssertEqual(snapshot.items.first?.title, "Open PR")
    }

    func testGmailExtractsOnlySubjectSenderUnreadAndThreadRoute() async throws {
        let result = try await extract("""
        <header><a aria-label="Google Account: Fixture (fixture@example.test)" href="https://accounts.google.com/SignOutOptions"></a></header>
        <main role="main"><table><tr class="zA zE"><td class="yW"><span email="sender@example.test" name="Fixture Sender">Sender</span></td>
        <td><span class="bog" data-legacy-thread-id="abc123">Fixture subject</span><span class="y2"> - Visible inbox snippet</span><span>Body must not be extracted</span></td><td class="xW"><span title="Fixture date">7m</span></td></tr></table></main>
        """, service: .gmail, url: "https://mail.google.com/mail/u/2/#inbox")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected extracted message") }
        XCTAssertEqual(snapshot.items.first?.url.absoluteString, "https://mail.google.com/mail/u/2/#inbox/abc123")
        XCTAssertEqual(snapshot.items.first?.title, "Fixture subject")
        XCTAssertEqual(snapshot.items.first?.subtitle, "Fixture Sender")
        XCTAssertTrue(snapshot.items.first?.unread == true)
        XCTAssertEqual(snapshot.items.first?.timeLabel, "7m")
        XCTAssertEqual(snapshot.items.first?.snippet, "Visible inbox snippet")
    }


    func testListTimestampsUseCompactAgeLabelsFromVisibleDateFields() async throws {
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-(19 * 3600 + 60)))
        let result = try await extract("""
        <header><a aria-label="Google Account: Fixture (fixture@example.test)" href="https://accounts.google.com/SignOutOptions"></a></header>
        <main role="main"><table><tr class="zA"><td class="yW"><span email="sender@example.test">Sender</span></td>
        <td><span class="bog" data-legacy-thread-id="abc123">Subject</span></td><td class="xW"><span title="\(date)">Oct 13</span></td></tr></table></main>
        """, service: .gmail, url: "https://mail.google.com/mail/u/0/#inbox")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected list fields") }
        XCTAssertEqual(snapshot.items.first?.timeLabel, "19h")
    }

    func testVerifiedEmptyAndChangedMarkupDiffer() async throws {
        let identity = "<header><a aria-label='Google Account: Fixture (fixture@example.test)' href='https://accounts.google.com/SignOutOptions'></a></header>"
        let empty = try await extract(identity + "<main role='main'><table><tr><td>Your inbox is empty.</td></tr></table></main>", service: .gmail, url: "https://mail.google.com/mail/u/0/#inbox")
        guard case .ready(let snapshot) = empty else { return XCTFail("Expected verified empty") }
        XCTAssertTrue(snapshot.items.isEmpty)
        let unknown = try await extract(identity + "<main role='main'>New layout</main>", service: .gmail, url: "https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(unknown, .unavailable)
        let signedOut = try await extract("<form action='/session'><input type='password'></form>", service: .github, url: "https://github.com/login")
        XCTAssertEqual(signedOut, .signedOut)
    }

    func testCalendarRequiresStructuredTimeAndActualLinks() async throws {
        let identity = "<header><a aria-label='Google Account: Fixture (fixture@example.test)' href='https://accounts.google.com/SignOutOptions'></a></header>"
        let html = identity + """
        <main role="main"><article data-eventid="fixture"><a href="https://calendar.google.com/calendar/event?eid=fixture">Fixture event</a>
        <time datetime="2099-12-01T10:00:00Z">10am</time><a href="https://meet.google.com/abc-defg-hij">Join</a></article></main>
        """
        let result = try await extract(html, service: .calendar, url: "https://calendar.google.com/calendar/u/0/r/agenda")
        guard case .ready(let snapshot) = result else { return XCTFail("Expected structured event") }
        XCTAssertNotNil(snapshot.items.first?.startsAt)
        XCTAssertEqual(snapshot.items.first?.meetingURL?.host, "meet.google.com")
        let changed = try await extract(identity + "<main role='main'><button data-eventid='fixture'>Unstructured event</button></main>", service: .calendar, url: "https://calendar.google.com/calendar/u/0/r/agenda")
        XCTAssertEqual(changed, .unavailable)
    }
}
