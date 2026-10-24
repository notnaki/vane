import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class SavedReaderTests: XCTestCase {
    func testNativeFileFailureIncludesBoundedUnderlyingErrnoAndPresentationURL() {
        let directory = URL(fileURLWithPath: "/tmp/vane-saved-reader-diagnostic")
        let file = directory.appendingPathComponent("article.html")
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let network = NSError(domain: "kCFErrorDomainCFNetwork", code: -3001, userInfo: [NSUnderlyingErrorKey: posix])
        let error = NSError(domain: NSURLErrorDomain, code: -3001, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open file", NSUnderlyingErrorKey: network,
            NSURLErrorFailingURLErrorKey: file,
        ])
        let report = SavedReaderNavigation.failureDescription(error, presentation: directory)
        XCTAssertTrue(report.hasPrefix("domain=NSURLErrorDomain, code=-3001, message=Cannot open file"))
        XCTAssertTrue(report.contains("underlying[0]={domain=kCFErrorDomainCFNetwork, code=-3001}"))
        XCTAssertTrue(report.contains("underlying[1]={domain=NSPOSIXErrorDomain, code=13}"))
        XCTAssertTrue(report.contains("failingURL=" + file.absoluteString))
    }

    func testNativeFileFailureStopsAfterTwoUnderlyingErrors() {
        var error = NSError(domain: "OUTSIDE-DEPTH-BOUND", code: 99)
        for depth in (0..<3).reversed() {
            error = NSError(domain: "level-\(depth)", code: depth, userInfo: [NSUnderlyingErrorKey: error])
        }
        let report = SavedReaderNavigation.failureDescription(error, presentation: URL(fileURLWithPath: "/tmp/fixture"))
        XCTAssertTrue(report.contains("underlying[0]={domain=level-1, code=1}"))
        XCTAssertTrue(report.contains("underlying[1]={domain=level-2, code=2}"))
        XCTAssertFalse(report.contains("OUTSIDE-DEPTH-BOUND"))
        XCTAssertFalse(report.contains("underlying[2]"))
    }

    func testNativeFileFailureOmitsUnrelatedPathAndAcceptsOwnedFilePath() {
        let directory = URL(fileURLWithPath: "/tmp/vane-saved-reader-diagnostic")
        let outside = "/tmp/OTHER-PRIVATE-PATH/article.html"
        let error = NSError(domain: NSURLErrorDomain, code: -3001, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open file", NSURLErrorFailingURLStringErrorKey: "file://" + outside,
            NSFilePathErrorKey: outside,
        ])
        let report = SavedReaderNavigation.failureDescription(error, presentation: directory)
        XCTAssertFalse(report.contains("OTHER-PRIVATE-PATH"))
        let file = directory.appendingPathComponent("images/fixture.png")
        let owned = NSError(domain: NSURLErrorDomain, code: -3001, userInfo: [
            NSLocalizedDescriptionKey: "Cannot open file", NSFilePathErrorKey: file.path,
        ])
        XCTAssertTrue(SavedReaderNavigation.failureDescription(owned, presentation: directory).contains("failingURL=" + file.absoluteString))
    }

    @MainActor private final class ImageProbe {
        private(set) var pending = false
        private(set) var width: Int?
        private(set) var snapshot = "not sampled"
        private(set) var error: String?
        private var active = true

        func stop() { active = false }

        func sample(_ web: WKWebView) {
            guard active, !pending else { return }
            pending = true
            web.evaluateJavaScript("""
                JSON.stringify((() => {
                    const image = document.images[0], rect = image?.getBoundingClientRect();
                    return {url: location.href, ready: document.readyState, imageCount: document.images.length,
                        naturalWidth: image?.naturalWidth, complete: image?.complete, loading: image?.loading,
                        src: image?.getAttribute('src'), currentSrc: image?.currentSrc,
                        rect: rect && {x:rect.x,y:rect.y,width:rect.width,height:rect.height},
                        viewport: {width:innerWidth,height:innerHeight}};
                })())
                """) { [weak self] value, error in
                guard let self, self.active else { return }
                self.pending = false
                if let error { self.error = String(describing: error); return }
                guard let text = value as? String, let data = text.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.error = "Image probe returned an unexpected value: \(String(describing: value))"
                    return
                }
                self.snapshot = String(text.prefix(4_096))
                self.width = object["naturalWidth"] as? Int
                self.error = nil
            }
        }
    }

    private struct ImageFixtureFailure: Error, CustomStringConvertible {
        let description: String
    }

    private func waitForLocalImage(_ web: WKWebView, image: URL, sessionState: () -> String,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        let probe = ImageProbe()
        defer { probe.stop() }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            if !web.isLoading, probe.width == 1 {
                print("Saved reader image ready: bounds=\(web.bounds), policy=\(NSApplication.shared.activationPolicy().rawValue), " +
                      "windowVisible=\(web.window?.isVisible ?? false), occlusion=\(web.window?.occlusionState.rawValue ?? 0), image=\(probe.snapshot)")
                return
            }
            if ContinuousClock.now >= deadline {
                let state = "url=\(web.url?.absoluteString ?? "nil"), loading=\(web.isLoading), progress=\(web.estimatedProgress), " +
                    "bounds=\(web.bounds), policy=\(NSApplication.shared.activationPolicy().rawValue), " +
                    "expectedImage=\(image.absoluteString), fileExists=\(FileManager.default.fileExists(atPath: image.path)), " +
                    "imageProbePending=\(probe.pending), image=\(probe.snapshot), javascriptError=\(probe.error ?? "none"), " +
                    "session=\(sessionState())"
                let failure = "\(file):\(line): Saved reader local image did not decode within 10 seconds. \(state)"
                NativeFixtureDiagnostics.emit(failure + "; collecting native diagnostics")
                let native = await NativeFixtureDiagnostics.failureReport(for: web)
                NativeFixtureDiagnostics.emit(failure + "; " + native)
                throw ImageFixtureFailure(description: failure + "; " + native)
            }
            if !web.isLoading { probe.sample(web) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

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
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        NSApplication.shared.setActivationPolicy(.prohibited)
        defer { NSApplication.shared.setActivationPolicy(policy) }
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
        let initial = try XCTUnwrap(SavedReaderWindow.loadSnapshot(articleID: article.id, profileID: article.profileID))
        XCTAssertTrue(web === initial.web, "The displayed view must be the saved-reader session's actual WebKit view")
        let image = initial.document.deletingLastPathComponent().appendingPathComponent("images/" + raster.resource.name)
        NativeFixtureDiagnostics.emit("saved reader loading resources: " + NativeFixtureDiagnostics.resourceSnapshot(for: web))
        try await waitForLocalImage(web, image: image, sessionState: {
            guard let state = SavedReaderWindow.loadSnapshot(articleID: article.id, profileID: article.profileID) else {
                return "session missing"
            }
            return "selectedViewMatches=\(state.web === web), expectedDocument=\(state.document.absoluteString), " +
                "documentExists=\(FileManager.default.fileExists(atPath: state.document.path)), " +
                "state=\(state.state), policy=\(state.policy), navigationFailure=\(state.failure ?? "none")"
        })
        XCTAssertEqual(web.url, initial.document)
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
