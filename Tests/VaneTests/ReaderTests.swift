import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class ReaderTests: XCTestCase {
    private let prose = String(repeating: "Readable prose, with detail and evidence for the reader. ", count: 24)
    private func fixture(_ html: String) async throws -> WKWebView {
        TestEnvironment.prepare()
        WebKitStartup.prepare()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://reader.test/news/story")!),
                                 responseHTML: "<!doctype html><html><body>" + html + "</body></html>")
        let deadline = Date().addingTimeInterval(10)
        while web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(web.isLoading)
        addTeardownBlock { @MainActor in web.stopLoading() }
        return web
    }
    private func extraction(_ html: String) async throws -> Reader.Extraction {
        let web = try await fixture(html)
        let extracted = await Reader.extract(from: web)
        let result = try XCTUnwrap(extracted)
        let probeJSON = try await web.evaluateJavaScript(Reader.extractJS(probe: true)) as! String
        let probe = try JSONSerialization.jsonObject(with: Data(probeJSON.utf8)) as! [String: Int]
        XCTAssertEqual(probe["words"], result.words)
        return result
    }
    func testSavedReadingMeasureAndSpacingReachDocumentWithClickableSource() {
        TestEnvironment.prepare()
        let keys = ["readerLineSpacing", "readerWidth"]
        let old = keys.map { UserDefaults.vane.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { UserDefaults.vane.set(value, forKey: key) } }
        UserDefaults.vane.set(1.9, forKey: keys[0]); UserDefaults.vane.set(82, forKey: keys[1])
        let html = Reader.html(for: Reader.Extraction(title: "Article"), url: URL(string: "https://reader.test/news/story?a=1&b=2"))
        XCTAssertTrue(html.contains("--r-spacing: 1.9")); XCTAssertTrue(html.contains("--r-width: 82ch"))
        XCTAssertTrue(html.contains("href=\"https://reader.test/news/story?a=1&amp;b=2\""))
    }
    func testPreferenceBoundsAndPersistence() {
        TestEnvironment.prepare()
        let keys = ["readerFontSize", "readerSerif", "readerLineSpacing", "readerWidth"]
        let old = keys.map { UserDefaults.vane.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { UserDefaults.vane.set(value, forKey: key) } }
        for key in keys { UserDefaults.vane.removeObject(forKey: key) }
        XCTAssertEqual(Reader.lineSpacing, 1.65); XCTAssertEqual(Reader.readingWidth, 68)
        Reader.setLineSpacing(1.9, in: nil); Reader.setReadingWidth(82, in: nil)
        XCTAssertEqual(UserDefaults.vane.double(forKey: keys[2]), 1.9)
        XCTAssertEqual(UserDefaults.vane.integer(forKey: keys[3]), 82)
        Reader.setLineSpacing(999, in: nil); Reader.setReadingWidth(-3, in: nil)
        XCTAssertEqual(Reader.lineSpacing, 2.1); XCTAssertEqual(Reader.readingWidth, 44)
        Reader.setLineSpacing(.nan, in: nil); XCTAssertEqual(Reader.lineSpacing, 1.65)
    }
    func testLivePreferencesUpdateReaderAndRespectMotionPolicy() async throws {
        TestEnvironment.prepare(); WebKitStartup.prepare()
        let keys = ["readerFontSize", "readerSerif", "readerLineSpacing", "readerWidth"]
        let old = keys.map { UserDefaults.vane.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { UserDefaults.vane.set(value, forKey: key) } }
        let tab = Tab(isPrivate: true)
        defer { if Reader.isOn(tab) { Reader.exit(tab) }; tab.tearDown() }
        tab.web.loadSimulatedRequest(URLRequest(url: URL(string: "https://reader.test/article")!), responseHTML: "<!doctype html><article><p>\(prose)</p></article>")
        let deadline = Date().addingTimeInterval(10)
        while tab.web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        Reader.enter(tab)
        while !Reader.isOn(tab), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(Reader.isOn(tab))
        Reader.adjustFontSize(2, in: tab); Reader.setLineSpacing(1.9, in: tab); Reader.setReadingWidth(82, in: tab)
        let values = try await tab.web.evaluateJavaScript("['--r-size','--r-spacing','--r-width'].map(k=>document.documentElement.style.getPropertyValue(k))") as? [String]
        XCTAssertEqual(values, ["\(Reader.fontSize)px", "1.9", "82ch"])
        let transition = try await tab.web.evaluateJavaScript("getComputedStyle(document.body).transitionDuration") as? String
        if Motion.reduced { XCTAssertEqual(transition, "0s") }
        else { XCTAssertTrue(transition?.contains("0.12s") == true, "Transition: \(transition ?? "nil")") }
        let oldMode = BatterySaver.shared.mode
        defer { BatterySaver.shared.setMode(oldMode) }
        BatterySaver.shared.setMode(.alwaysOn)
        Reader.setLineSpacing(1.4, in: tab)
        let reducedDuration = try await tab.web.evaluateJavaScript("getComputedStyle(document.body).transitionDuration") as? String
        XCTAssertEqual(reducedDuration, "0s")
    }
    func testDocumentBasePreservesRelativeArticleLinksAndImages() async throws {
        let result = try await extraction("<base href='https://cdn.reader.test/articles/'><article><p>\(prose)<a href='next'>Next article</a></p><img data-src='photo.jpg' width='600'></article>")
        let html = Reader.render(result.nodes, base: URL(string: "https://reader.test/news/story"))
        XCTAssertTrue(html.contains("https://cdn.reader.test/articles/next"))
        XCTAssertTrue(html.contains("https://cdn.reader.test/articles/photo.jpg"))
    }
    func testPublicDifficultPagesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["VANE_READER_LIVE_PAGES"] == "1" else {
            throw XCTSkip("Public network pages are opt-in; deterministic fixtures run by default")
        }
        TestEnvironment.prepare(); WebKitStartup.prepare()
        for address in ["https://paulgraham.com/greatwork.html", "https://en.wikipedia.org/wiki/Claude_Shannon", "https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Closures"] {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
            defer { web.stopLoading() }
            web.load(URLRequest(url: URL(string: address)!))
            let deadline = Date().addingTimeInterval(30)
            while web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertFalse(web.isLoading, address)
            let extracted = await Reader.extract(from: web)
            let result = try XCTUnwrap(extracted, address)
            print("Reader public page: \(address), title=\(result.title), words=\(result.words)")
            XCTAssertTrue(Reader.isEnough(words: result.words), address)
            XCTAssertFalse(result.title.isEmpty, address)
        }
    }
    func testSemanticMainInsideSidebarLayoutIsNotDiscarded() async throws {
        let result = try await extraction("<div class='layout__2-sidebars-inline'><aside><p>SIDEBAR \(prose)</p></aside><main id='content'><section class='content-section'><p>GUIDE \(prose)</p></section><section class='content-section'><p>EXAMPLE \(prose)</p></section></main></div>")
        let text = Reader.plainText(result.nodes)
        XCTAssertTrue(text.contains("GUIDE")); XCTAssertTrue(text.contains("EXAMPLE")); XCTAssertFalse(text.contains("SIDEBAR"))
    }
    func testNavigationDuringReaderEntryDoesNotReplaceDestination() async throws {
        TestEnvironment.prepare(); WebKitStartup.prepare()
        let tab = Tab(isPrivate: true)
        defer { if Reader.isOn(tab) { Reader.exit(tab) }; tab.tearDown() }
        let source = URL(string: "https://reader.test/source")!
        let target = URL(string: "https://reader.test/destination")!
        tab.web.loadSimulatedRequest(URLRequest(url: source), responseHTML: "<!doctype html><article><p>Source \(prose)</p></article>")
        var deadline = Date().addingTimeInterval(10)
        while tab.web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        Reader.enter(tab)
        tab.web.loadSimulatedRequest(URLRequest(url: target), responseHTML: "<!doctype html><article><p>Destination \(prose)</p></article>")
        deadline = Date().addingTimeInterval(10)
        while tab.web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(Reader.isOn(tab))
        let rewritten = try await tab.web.evaluateJavaScript("!!document.querySelector('.src')") as? Bool
        XCTAssertEqual(rewritten, false)
    }
    func testLayoutClassDoesNotDiscardSemanticArticleProse() async throws {
        let result = try await extraction("<article><div class='scroll-content'><p>SCROLL \(prose)</p></div></article>")
        XCTAssertTrue(Reader.plainText(result.nodes).contains("SCROLL"))
    }
    func testSyntaxHighlightedCodeKeepsWhitespaceOnlyNewlineNodes() async throws {
        let result = try await extraction("<article><p>\(prose)</p><pre><code><span>alpha</span>\n<span>  beta</span>\n<span>    gamma</span></code></pre></article>")
        XCTAssertTrue(Reader.render(result.nodes, base: nil).contains("alpha\n  beta\n    gamma"))
    }
    func testSameURLDocumentNavigationClearsReaderState() async throws {
        TestEnvironment.prepare(); WebKitStartup.prepare()
        let tab = Tab(isPrivate: true)
        defer { if Reader.isOn(tab) { Reader.exit(tab) }; tab.tearDown() }
        let url = URL(string: "https://reader.test/article")!
        let html = "<!doctype html><article><p>\(prose)</p></article>"
        tab.web.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        var deadline = Date().addingTimeInterval(10)
        while tab.web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        Reader.enter(tab)
        while !Reader.isOn(tab), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(Reader.isOn(tab))
        tab.web.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        deadline = Date().addingTimeInterval(10)
        while tab.web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(Reader.isOn(tab))
    }
    func testSplitArticleKeepsSiblingSectionsAndRejectsLongFurniture() async throws {
        let result = try await extraction("<main><div class='article-body'><p>FIRST \(prose)</p></div><div class='article-body'><h2>Continuation</h2><p>LAST \(prose)</p></div><div class='related'><p>RELATED \(prose)</p></div></main>")
        let text = Reader.plainText(result.nodes)
        XCTAssertTrue(text.contains("FIRST")); XCTAssertTrue(text.contains("LAST")); XCTAssertFalse(text.contains("RELATED"))
    }
    func testLegacyTableLayoutRetainsEssayButNotNavigation() async throws {
        let result = try await extraction("<table><tr><td><nav>MENU</nav></td><td><font>ESSAY \(prose)<br><br>ENDING \(prose)</font></td></tr></table>")
        let text = Reader.plainText(result.nodes)
        XCTAssertTrue(text.contains("ESSAY")); XCTAssertTrue(text.contains("ENDING")); XCTAssertFalse(text.contains("MENU"))
        XCTAssertTrue(Reader.isEnough(words: result.words))
    }
    func testArticleRetainsDataTableAndPreformattedCodeWithoutHiddenText() async throws {
        let result = try await extraction("<article><h1>Technical article</h1><p>\(prose)</p><table><caption>Results</caption><tr><th>Model</th><th>Score</th></tr><tr><td>A</td><td>42</td></tr></table><pre><code>one\n  two\n    three</code></pre><div hidden>HIDDEN \(prose)</div><p style='display:none'>SECRET \(prose)</p></article>")
        let html = Reader.render(result.nodes, base: URL(string: "https://reader.test"))
        XCTAssertTrue(html.contains("<table>")); XCTAssertTrue(html.contains("<th>Score</th>")); XCTAssertTrue(html.contains("one\n  two\n    three"))
        XCTAssertFalse(html.contains("HIDDEN")); XCTAssertFalse(html.contains("SECRET"))
    }
    func testLazyFigureUsesRealImageAndKeepsCaptionAndLinks() async throws {
        let result = try await extraction("<article><p>\(prose)</p><figure><img src='placeholder.gif' data-src='/full.jpg' width='600'><figcaption>Caption <a href='../credit'>credit</a></figcaption></figure></article>")
        let html = Reader.render(result.nodes, base: URL(string: "https://reader.test/news/story"))
        XCTAssertTrue(html.contains("https://reader.test/full.jpg")); XCTAssertTrue(html.contains("<figcaption>")); XCTAssertTrue(html.contains("https://reader.test/credit"))
    }
}
