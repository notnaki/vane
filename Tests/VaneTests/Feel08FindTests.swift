import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class Feel08FindTests: XCTestCase {
    private func fixture() async throws -> (Tab, Find) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let tab = Tab(isPrivate: true, profileID: UUID())
        addTeardownBlock { @MainActor in tab.tearDown() }
        tab.web.loadSimulatedRequest(URLRequest(url: URL(string: "https://feel08.example.test/")!),
            responseHTML: "<body><p>needle needle</p></body>")
        try await compatibilityWait { !tab.web.isLoading }
        return (tab, Find())
    }

    func testCancelledTypingDoesNotSelectOrPublishMatches() async throws {
        let (tab, find) = try await fixture()
        let search = Task { await find.run("needle", in: tab, fresh: true) }
        search.cancel()
        await search.value
        XCTAssertEqual(find.count, 0)
        let selected = try await tab.web.evaluateJavaScript("getSelection().toString()") as? String
        XCTAssertEqual(selected, "")
    }

    func testFreshTypingBurstSelectsOnlyLatestQuery() async throws {
        let (tab, find) = try await fixture()
        _ = try await tab.web.evaluateJavaScript("window.__selections=[]; document.addEventListener('selectionchange',()=>__selections.push(getSelection().toString()))")
        let tasks = ["n", "ne", "nee", "need", "needl", "needle"].map { text in
            Task { await find.run(text, in: tab, fresh: true) }
        }
        for task in tasks { await task.value }
        let selections = try await tab.web.evaluateJavaScript("__selections") as? [String]
        XCTAssertTrue(try XCTUnwrap(selections).allSatisfy { $0.isEmpty || $0 == "needle" },
                      "Obsolete typing must not scroll/select intermediate queries")
        XCTAssertEqual(find.query, "needle")
        XCTAssertEqual(find.count, 2)
    }

    func testSameURLReplacementRejectsOldFindResult() async throws {
        let (tab, find) = try await fixture()
        let search = Task { await find.run("needle", in: tab, fresh: true) }
        await Task.yield()
        // Replace the document at the same URL; URL equality alone is insufficient.
        let web = tab.web
        web.loadSimulatedRequest(URLRequest(url: web.url!), responseHTML: "<title>Replacement</title><p>other text</p>")
        await search.value
        try await compatibilityWait { !web.isLoading && web.title == "Replacement" }
        XCTAssertEqual(find.count, 0)
        XCTAssertEqual(find.index, 0)
    }
}
