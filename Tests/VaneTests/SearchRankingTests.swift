import XCTest
import SwiftUI
@testable import vane

@MainActor final class SearchRankingTests: XCTestCase {
    private func fixture() throws -> Store {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Store(path: directory.appendingPathComponent("history.db").path)
    }

    func testExactTitleBeatsPopularSubstringAndBookmark() throws {
        let store = try fixture()
        let exact = URL(string: "https://rare.example")!
        store.record(exact, title: "Swift")
        for _ in 0..<20 { store.record(URL(string: "https://popular.example")!, title: "Learn Swift today") }
        store.toggleBookmark(URL(string: "https://bookmark.example")!, title: "Swift resources")
        XCTAssertEqual(store.suggest("Swift").first?.url, exact.absoluteString)
        XCTAssertEqual(store.history(matching: "Swift", limit: 1).first?.url, exact.absoluteString)
    }

    func testFuzzyMatchingFindsOldPageOutsideRecentHistoryCap() throws {
        let store = try fixture()
        let exact = URL(string: "https://github.com/project")!
        store.record([(exact, "GitHub Project", Date(timeIntervalSince1970: 1))])
        store.record((0..<600).map { (URL(string: "https://unrelated.example/\($0)")!, "Unrelated", Date.now) })
        XCTAssertEqual(store.suggest("ghp").map(\.url), [exact.absoluteString])
        XCTAssertEqual(store.history(matching: "ghp", limit: 1).first?.url, exact.absoluteString)
    }

    func testExactAndContinuousMatchesBeatScatteredLetters() {
        XCTAssertGreaterThan(Palette.score("abc", "abc")!, Palette.score("abc", "a b c a b c")!)
        XCTAssertGreaterThan(Palette.score("abc", "xabc")!, Palette.score("abc", "a b c")!)
        // The first 'a' is a distraction; use the later continuous alignment.
        XCTAssertGreaterThan(Palette.score("abc", "a---abc")!, Palette.score("abc", "a---b---c")!)
        XCTAssertNotNil(Palette.score("cafe", "Café"))
    }

    func testBookmarkIdentitySurvivesHistoryWinningItsTitleMatch() throws {
        let store = try fixture()
        let page = URL(string: "https://saved.example")!
        store.record(page, title: "Exact")
        store.toggleBookmark(page, title: "Reference")
        store.toggleBookmark(URL(string: "https://other.example")!, title: "Exact")
        let first = try XCTUnwrap(store.suggest("Exact", limit: 1).first)
        XCTAssertEqual(first.url, page.absoluteString)
        XCTAssertTrue(first.bookmarked, "A saved page must not gain a history-only forget action")
    }

    func testStrongTabsKeepTheirExistingKeyboardPriority() {
        XCTAssertTrue(Palette.strong("go", title: "Google", url: "https://google.com"))
        XCTAssertTrue(Palette.strong("go", title: "Search", url: "https://www.google.com"))
        XCTAssertTrue(Palette.strong("tur", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertFalse(Palette.strong("tu", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertFalse(Palette.strong("gpt", title: "Giant Purple Turtles", url: "https://example.com"))
        XCTAssertGreaterThan(Palette.score("doc", "mydoc doc")!, Palette.score("doc", "mydocdoc")!)
    }

    func testTypedURLCannotBeDisplacedByATabTitle() {
        for query in ["https://bank.example/login", "bank.example/login", "http://localhost:8080/login",
                      "[::1]:8080/login", "mailto:ada@example.com"] {
            XCTAssertFalse(Palette.strong(query, title: query, url: "https://attacker.example/"), query)
        }
        XCTAssertFalse(Palette.strong("https://bank.example/login", title: "Bank",
                                     url: "https://bank.example/login"),
                       "Even a real matching tab leaves explicit navigation first")
    }

    func testTabSubtitleShowsItsActualOriginWithoutCredentialsOrPageMetadata() {
        XCTAssertEqual(Palette.tabSubtitle(address: "https://user:pass@attacker.example:8443/login?q=bank#name",
                                           place: "Window 2"), "Window 2 — https://attacker.example:8443")
        XCTAssertEqual(Palette.tabSubtitle(address: "https://attacker.example/login", place: ""),
                       "https://attacker.example")
        XCTAssertEqual(Palette.tabSubtitle(address: "http://[::1]:8080/page", place: ""), "http://[::1]:8080")
        XCTAssertEqual(Palette.tabSubtitle(address: "about:blank", place: ""), "about:blank")
    }

    func testInlineCompletionFillsOnlyTheStartOfAVisitedHost() {
        let urls = ["https://docs.google.com/x", "https://www.deepseek.com/chat"]
        XCTAssertEqual(Palette.completeHost("d", urls: urls)?.text, "docs.google.com")
        XCTAssertEqual(Palette.completeHost("d", urls: urls)?.url.absoluteString, "https://docs.google.com/",
                       "Return opens the site's origin, not the visited page")
        let deep = Palette.completeHost("DE", urls: urls)
        XCTAssertEqual(deep?.text, "deepseek.com", "www. and case are ignored")
        XCTAssertEqual(deep?.url.absoluteString, "https://www.deepseek.com/", "…but the real host is kept")
        let local = Palette.completeHost("loc", urls: ["http://localhost:3000/path"])
        XCTAssertEqual(local?.text, "localhost:3000")
        XCTAssertEqual(local?.url.absoluteString, "http://localhost:3000/", "a port survives")
        XCTAssertEqual(Palette.completeHost("se", urls: ["http://server/wiki"])?.url.absoluteString,
                       "http://server/", "a single-label host opens rather than searches")
        XCTAssertNil(Palette.completeHost("fi", urls: ["file:///Users/me/notes.txt"]), "only web origins")
        XCTAssertNil(Palette.completeHost("seek", urls: urls), "the middle of a host is not its start")
        XCTAssertNil(Palette.completeHost("deepseek.com", urls: urls), "a fully typed host has no tail")
        XCTAssertNil(Palette.completeHost("de ep", urls: urls), "a space means a search")
        XCTAssertNil(Palette.completeHost("", urls: urls))
    }

    func testURLMatchesAndLiteralWildcardsStayPredictable() throws {
        let store = try fixture()
        let url = URL(string: "https://www.example.com/docs")!
        store.record(url, title: "Reference")
        store.toggleBookmark(URL(string: "https://other.example")!, title: "example.com/docs extras")
        XCTAssertEqual(store.suggest("example.com/docs").first?.url, url.absoluteString)
        XCTAssertEqual(store.suggest("www.example.com/docs").first?.url, url.absoluteString)
        XCTAssertEqual(store.suggest("https://www.example.com/docs").first?.url, url.absoluteString)
        XCTAssertFalse(Palette.strong("https://www.example.com/docs", title: "Reference", url: url.absoluteString))
        XCTAssertTrue(store.suggest("100%").isEmpty)
        store.record(URL(string: "https://cafe.example")!, title: "Café handbook")
        XCTAssertEqual(store.suggest("cafe handbook").first?.title, "Café handbook")
    }

    func testHeldResultsSurviveEitherSourceArrivingFirst() {
        struct Row: Equatable { let id: String; let completion: Bool }
        let oldHistory = Row(id: "url:old-page", completion: false)
        let oldPhrase = Row(id: "url:old-search", completion: true)
        let newHistory = Row(id: "url:new-page", completion: false)
        let newPhrase = Row(id: "url:new-search", completion: true)
        func shown(_ live: [Row], history: Bool = true, engine: Bool = true) -> [Row] {
            Palette.heldResults(live: live, held: [oldHistory, oldPhrase], historyPending: history,
                                enginePending: engine, isCompletion: \.completion, id: \.id)
        }
        XCTAssertEqual(shown([]), [oldHistory, oldPhrase], "nothing new yet: the last query's rows stay")
        XCTAssertEqual(shown([newPhrase], engine: false), [oldHistory, newPhrase],
                       "engine first: held history stays until the local lookup answers")
        XCTAssertEqual(shown([newHistory], history: false), [newHistory, oldPhrase],
                       "history first: held completions stay until the engine answers")
        XCTAssertEqual(shown([], history: false), [oldPhrase],
                       "history answered with nothing while the engine is slow: old history goes")
        XCTAssertEqual(shown([], history: true, engine: false), [oldHistory],
                       "the engine answered with nothing: old completions go")
        XCTAssertEqual(shown([newHistory, newPhrase], history: false, engine: false), [newHistory, newPhrase])
        XCTAssertEqual(shown([], history: false, engine: false), [], "both in and empty: shown as empty")
        let sameAsHistory = Row(id: newHistory.id, completion: true)
        XCTAssertEqual(Palette.heldResults(live: [newHistory], held: [sameAsHistory], historyPending: false,
                                           enginePending: true, isCompletion: \.completion, id: \.id),
                       [newHistory], "a held row is never shown twice")
    }

    func testHoverStaysOnItsSlotWhileResultsReorderUnderAStillPointer() {
        // Rows are rewritten in place: a reorder keeps the count, so the slot under the
        // pointer stays lit and now shows whatever result moved into it.
        XCTAssertEqual(Palette.litSlot(hover: 2, rowCount: 8), 2)
        XCTAssertNil(Palette.litSlot(hover: 5, rowCount: 3), "a slot the shorter list no longer has is not lit")
        XCTAssertNil(Palette.litSlot(hover: nil, rowCount: 8))
    }

    func testResultsFitAShortWindowAtTheHighestRowSetting() {
        // Field, divider and list padding: everything in the bar but its rows.
        let chrome = Look.barFieldHeight + 1 + (Look.barInset - Look.barRowGap + Look.barInset)
        let rows = Palette.fittingRows(12, windowHeight: 600, chrome: chrome)
        XCTAssertLessThan(rows, 12, "twelve rows do not fit a 600pt window")
        XCTAssertLessThanOrEqual(chrome + Palette.rowsHeight(rows) + Look.inset * 2, 600,
                                 "the whole bar, rows included, stays inside the window")
        XCTAssertEqual(Palette.fittingRows(12, windowHeight: 2000, chrome: chrome), 12,
                       "a tall window draws every row asked for")
        XCTAssertEqual(Palette.fittingRows(8, windowHeight: 100, chrome: chrome), 1, "never fewer than one")
        XCTAssertEqual(Palette.fittingRows(8, windowHeight: .infinity, chrome: chrome), 8,
                       "before the first layout the window's height is unknown")
    }

    func testFirstLetterCompletesAHistoryOnlySite() {
        // At one character history suggestions are empty and no tab matches; only the
        // first-letter lookup knows the site, and only for the letter it was made for.
        let lookup = (query: "d", urls: ["https://www.deepseek.com/chat"])
        let sources = Palette.completionSources(typed: "d", history: [], held: [],
                                                firstLetter: lookup, tabs: ["https://example.com/"])
        XCTAssertEqual(Palette.completeHost("d", urls: sources)?.text, "deepseek.com")
        XCTAssertTrue(Palette.completionSources(typed: "x", history: [], held: [],
                                                firstLetter: lookup, tabs: []).isEmpty,
                      "a lookup for another letter is not used")
        XCTAssertEqual(Palette.completionSources(typed: "d", history: ["https://docs.google.com/"],
                                                 held: [], firstLetter: lookup, tabs: []).first,
                       "https://docs.google.com/", "this query's own history ranks first")
    }

    func testAcceptedCompletionKeepsItsOriginUntilTheNextEdit() throws {
        let server = try XCTUnwrap(Palette.completeHost("se", urls: ["http://server/wiki"]))
        // → / End / ← / Home / a click commit "server" to the query while `server` is the
        // completion: Return must still open http://server/, not search for "server".
        let accepted = Palette.carriedCompletion(nil, completion: server, query: "server")
        XCTAssertEqual(accepted?.url.absoluteString, "http://server/")
        XCTAssertEqual(Palette.carriedCompletion(accepted, completion: nil, query: "server")?.url,
                       server.url, "still standing once the completion itself is gone")
        XCTAssertEqual(Palette.carriedCompletion(accepted, completion: nil, query: "SERVER")?.url,
                       server.url, "case typed before the tail does not matter")
        XCTAssertNil(Palette.carriedCompletion(accepted, completion: nil, query: "server/x"),
                     "the next edit lets it go")
        XCTAssertNil(Palette.carriedCompletion(nil, completion: server, query: "se"),
                     "a completion still showing is not yet accepted")
    }

    @MainActor
    func testMovingTheCaretOffAnInlineCompletionAcceptsIt() {
        var query = "se"
        let field = CommandField(text: Binding(get: { query }, set: { query = $0 }), prompt: "",
                                 selectAll: false, label: "", hint: "", onKey: { _ in false })
        let coordinator = field.makeCoordinator()
        let editor = NSTextView()
        editor.string = "server"
        func move(to range: NSRange) {
            coordinator.showsCompletion = true
            query = "se"
            editor.setSelectedRange(range)
            coordinator.selectionMoved(in: editor)
        }
        move(to: NSRange(location: 2, length: 4))
        XCTAssertEqual(query, "se", "the tail still selected is still a completion")
        move(to: NSRange(location: 6, length: 0))
        XCTAssertEqual(query, "server", "→ or End accepts the whole host")
        XCTAssertFalse(coordinator.showsCompletion)
        move(to: NSRange(location: 2, length: 0))
        XCTAssertEqual(query, "server", "← or a click accepts it too, so the next key edits what is shown")
        coordinator.showsCompletion = true
        query = "se"
        editor.string = "se"
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.selectionMoved(in: editor)
        XCTAssertEqual(query, "se", "deleting the tail is not an acceptance")
        XCTAssertTrue(coordinator.showsCompletion, "…it is left for the text-change path to dismiss")
    }

    func testCompletionFollowsTypingForwardIncludingOverTheSeededAddress() {
        XCTAssertTrue(Palette.typesForward(from: "de", to: "dee", seeded: nil))
        XCTAssertFalse(Palette.typesForward(from: "dee", to: "de", seeded: nil), "a delete turns it off")
        XCTAssertFalse(Palette.typesForward(from: "deep", to: "dexp", seeded: nil), "an edit in the middle too")
        let address = "https://github.com/notnaki/vane"
        XCTAssertTrue(Palette.typesForward(from: address, to: "g", seeded: address),
                      "the first character typed over ⌘L's selected address completes")
        XCTAssertFalse(Palette.typesForward(from: address, to: "", seeded: address), "clearing it does not")
        XCTAssertFalse(Palette.typesForward(from: "github.com/x", to: "g", seeded: address),
                       "only the address ⌘L opened with counts as a replacement")
    }
}
