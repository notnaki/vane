import AppKit
import WebKit
import XCTest
import ObjectiveC
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
        let web = tab.web
        let original = try XCTUnwrap(class_getInstanceMethod(WKWebView.self,
            NSSelectorFromString("findString:withConfiguration:completionHandler:")))
        let held = try XCTUnwrap(class_getInstanceMethod(WKWebView.self,
            #selector(WKWebView.feel08_findString(_:withConfiguration:completionHandler:))))
        Feel08FindCompletion.web = web
        method_exchangeImplementations(original, held)
        defer {
            Feel08FindCompletion.release?()
            Feel08FindCompletion.release = nil
            Feel08FindCompletion.matchFound = nil
            Feel08FindCompletion.web = nil
            method_exchangeImplementations(original, held)
        }
        let search = Task { await find.run("needle", in: tab, fresh: true) }
        try await compatibilityWait { Feel08FindCompletion.release != nil }
        XCTAssertEqual(Feel08FindCompletion.matchFound, true, "The held reply must be a real successful WebKit search")
        // WebKit has performed the real search, but Find has not received its reply.
        // Replace at the same URL before delivering that reply, independent of timing.
        web.loadSimulatedRequest(URLRequest(url: web.url!), responseHTML: "<title>Replacement</title><p>other text</p>")
        try await compatibilityWait { !web.isLoading && web.title == "Replacement" }
        let release = try XCTUnwrap(Feel08FindCompletion.release)
        Feel08FindCompletion.release = nil
        release()
        await search.value
        XCTAssertEqual(find.count, 0)
        XCTAssertEqual(find.index, 0)
    }
}

// Only this XCTest installs the hook, restoring it before the next test. The
// original WebKit method and all its side effects run; only reply delivery waits.
@MainActor private enum Feel08FindCompletion {
    static weak var web: WKWebView?
    static var release: (() -> Void)?
    static var matchFound: Bool?
}

extension WKWebView {
    @objc(feel08_findString:withConfiguration:completionHandler:)
    fileprivate dynamic func feel08_findString(_ text: String, withConfiguration configuration: WKFindConfiguration?,
                                               completionHandler: @escaping @MainActor (WKFindResult) -> Void) {
        feel08_findString(text, withConfiguration: configuration) { result in
            if self === Feel08FindCompletion.web {
                Feel08FindCompletion.matchFound = result.matchFound
                Feel08FindCompletion.release = { completionHandler(result) }
            } else {
                completionHandler(result)
            }
        }
    }
}
