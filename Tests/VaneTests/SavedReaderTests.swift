import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SavedReaderTests: XCTestCase {
    func testEscapingLabelAndNoNetworkImages() {
        TestEnvironment.prepare()
        let article = makeReadingArticle(text: "<script>window.bad=true</script>")
        let html = SavedReaderDocument.html(article: article)
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("Saved copy"))
        XCTAssertTrue(html.contains("Content-Security-Policy"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("src=\"https://"))
    }
    func testNavigationRejectsSiblingAndUnrequestedLivePage() {
        let directory = URL(fileURLWithPath: "/tmp/article")
        XCTAssertTrue(SavedReaderNavigation.allowed(url: directory.appendingPathComponent("article.html"), articleDirectory: directory, userInitiated: false))
        XCTAssertFalse(SavedReaderNavigation.allowed(url: URL(fileURLWithPath: "/tmp/article-other/article.html"), articleDirectory: directory, userInitiated: false))
        XCTAssertFalse(SavedReaderNavigation.allowed(url: URL(string: "https://tracker.test/pixel")!, articleDirectory: directory, userInitiated: false))
    }
    func testCurrentPreferencesDoNotChangeSnapshot() throws {
        TestEnvironment.prepare()
        let article = makeReadingArticle()
        let data = try ReadingArticleCodec.encode(article), old = Reader.fontSize
        let oldSpacing = Reader.lineSpacing, oldWidth = Reader.readingWidth
        defer { Reader.fontSize = old; Reader.lineSpacing = oldSpacing; Reader.readingWidth = oldWidth }
        Reader.fontSize = 27; Reader.lineSpacing = 1.9; Reader.readingWidth = 80
        XCTAssertTrue(SavedReaderDocument.html(article: article).contains("--r-size: 27px"))
        XCTAssertTrue(SavedReaderDocument.html(article: article).contains("--r-spacing: 1.9"))
        XCTAssertTrue(SavedReaderDocument.html(article: article).contains("--r-width: 80ch"))
        XCTAssertEqual(try ReadingArticleCodec.encode(article), data)
        XCTAssertFalse(article.isRead)
    }
    func testLiveSourceReopensClosedProfileWindow() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared, previous = ProfileManager.shared.active
        let profile = manager.create(name: "Saved source closure")
        let original = Windows.open(profile: profile, focus: false)
        let oldWindow = try XCTUnwrap(original.window)
        var newWindow: NSWindow?
        defer { newWindow?.close(); oldWindow.close(); _ = manager.delete(profile.id); manager.active = previous }
        oldWindow.close()
        XCTAssertFalse(TabStore.all.contains { $0 === original })
        let url = URL(string: "https://example.test/closed-origin")!
        let reopened = try XCTUnwrap(SavedReaderLivePage.open(url, profileID: profile.id))
        newWindow = reopened.window
        XCTAssertEqual(reopened.profileID, profile.id)
        XCTAssertFalse(reopened.isPrivate); XCTAssertFalse(reopened.isParked)
        XCTAssertNotNil(newWindow); XCTAssertTrue(newWindow?.isVisible == true)
        XCTAssertFalse(newWindow === oldWindow)
        XCTAssertEqual(reopened.active?.address, url.absoluteString)
    }
    func testLiveSourceRevealsParkedProfileInsteadOfCreatingHiddenTab() throws {
        TestEnvironment.prepare()
        let manager = ProfileManager.shared, previous = ProfileManager.shared.active
        let first = manager.create(name: "Saved first"), second = manager.create(name: "Saved second")
        let a = manager.createSpace(name: "Article", in: first.id), b = manager.createSpace(name: "Other", in: second.id)
        let origin = Windows.open(profile: first, space: a, focus: false)
        let window = try XCTUnwrap(origin.window)
        defer { window.close(); _ = manager.delete(first.id); _ = manager.delete(second.id); manager.active = previous }
        let other = try XCTUnwrap(Windows.hop(origin, to: b))
        XCTAssertTrue(origin.isParked); XCTAssertNil(origin.window)
        let url = URL(string: "https://example.test/parked-origin")!
        let shown = try XCTUnwrap(SavedReaderLivePage.open(url, profileID: first.id))
        XCTAssertTrue(shown === origin); XCTAssertTrue(shown.window === window)
        XCTAssertFalse(shown.isParked); XCTAssertTrue(other.isParked)
        XCTAssertEqual(shown.active?.address, url.absoluteString)
        XCTAssertTrue(window.isVisible)
    }
    func testSavedWindowOpensFromAnotherProfileRendersLocalImageAndClosesOnRemoval() async throws {
        TestEnvironment.prepare(); NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ReadingQueueStore.shared(profileID: ProfileManager.defaultID, directory: root)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        var article = makeReadingArticle(); article.title = "Saved fixture \(UUID())"
        article.resources = [raster.resource]
        article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name, "alt": "Offline image"]))
        try await repository.publish(.init(article: article, images: [raster.resource.name: raster.data]))
        let origin = TabStore(profileID: UUID())
        XCTAssertNotEqual(origin.profileID, repository.profileID)
        defer { origin.tabs.forEach { $0.tearDown() }; TabStore.all.removeAll { $0 === origin }; SavedReaderWindow.forget(profileID: article.profileID) }
        SavedReaderWindow.show(articleID: article.id, repository: repository, origin: origin)
        try await compatibilityWait { NSApp.windows.contains { $0.title == "Saved copy — \(article.title)" } }
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Saved copy — \(article.title)" })
        func findWeb(_ view: NSView) -> WKWebView? { if let web = view as? WKWebView { return web }; return view.subviews.compactMap(findWeb).first }
        try await compatibilityWait { window.contentView?.layoutSubtreeIfNeeded(); return window.contentView.flatMap(findWeb) != nil }
        let web = try XCTUnwrap(window.contentView.flatMap(findWeb))
        try await compatibilityWait {
            if web.isLoading { return false }
            let width = try? await web.evaluateJavaScript("document.images[0]?.naturalWidth")
            return width as? Int == 1
        }
        let raw = try await web.evaluateJavaScript("document.body.innerText")
        let text = try XCTUnwrap(raw as? String)
        XCTAssertTrue(text.contains("Saved copy")); XCTAssertTrue(text.contains("nebula"))
        XCTAssertFalse(repository.articles[0].isRead)
        let directory = try XCTUnwrap(web.url?.deletingLastPathComponent())
        try await repository.remove(article.id)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
