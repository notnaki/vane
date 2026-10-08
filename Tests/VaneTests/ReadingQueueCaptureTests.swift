import AppKit
import WebKit
import XCTest
@testable import vane

actor HeldReadingImages: ReadingQueueImageLoading {
    var started = false
    private var continuation: CheckedContinuation<ReadingQueueImageResult, Never>?
    func collect(urls: [URL]) async -> ReadingQueueImageResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(returning: .init()); continuation = nil }
}

actor CountingReadingImages: ReadingQueueImageLoading {
    var calls = 0
    func collect(urls: [URL]) async -> ReadingQueueImageResult { calls += 1; return .init() }
}

@MainActor final class ReadingQueueCaptureTests: XCTestCase {
    func testPrivateSaveHasNoRepositoryOrImageWork() async throws {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        defer { store.tabs.forEach { $0.tearDown() }; TabStore.all.removeAll { $0 === store } }
        let capture = ReadingQueueCapture()
        XCTAssertFalse(ReadingQueueCapture.canSave(tab: store.active, in: store))
        if let tab = store.active { await capture.save(tab: tab, in: store) }
        XCTAssertTrue(capture.capturing.isEmpty)
    }
    func testColdQueueReportsDuplicateAndPreservesSavedCopyWithoutImageWork() async throws {
        TestEnvironment.prepare(); NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try CompatibilityServer(); defer { server.stop() }
        server.pages["/article"] = "<title>Changed live title</title><article><p>" + String(repeating: "Readable live article words. ", count: 100) + "</p></article>"
        try await compatibilityWait { server.port != nil }
        let url = try server.url("/article"), store = TabStore(profileID: ProfileManager.defaultID)
        store.newTab(url); let tab = try XCTUnwrap(store.active)
        defer { store.tabs.forEach { $0.tearDown() }; TabStore.all.removeAll { $0 === store } }
        try await compatibilityWait { !tab.web.isLoading && tab.web.url == url }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var article = makeReadingArticle(); article.sourceURL = url.absoluteString
        article.title = "Original saved title"; article.isRead = true; article.capturedAt = Date(timeIntervalSince1970: 1_000)
        let folder = ReadingQueueFiles.articleURL(profileID: article.profileID, articleID: article.id, in: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ReadingArticleCodec.encode(article).write(to: folder.appendingPathComponent("article.json"))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let repository = try ReadingQueueStore(profileID: article.profileID, directory: root, scanCheckpoint: { gate.wait() })
        let loader = CountingReadingImages()
        XCTAssertTrue(repository.loading)
        var duplicate = false
        let pending = Task { try await ReadingQueueCapture.capture(tab: tab, in: store, repository: repository, images: loader, onAlreadySaved: { duplicate = true }) }
        await Task.yield(); gate.signal()
        let saved = try await pending.value, calls = await loader.calls
        XCTAssertTrue(duplicate); XCTAssertEqual(saved, article); XCTAssertEqual(calls, 0)
        XCTAssertEqual(repository.articles.count, 1)
    }
    func testSameURLDocumentChangeCancelsPublication() async throws {
        TestEnvironment.prepare()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let server = try CompatibilityServer()
        defer { server.stop() }
        server.pages["/article"] = "<title>Article</title><article><h1>Article</h1><p>" + String(repeating: "An offline article has readable words and thoughtful sentences. ", count: 100) + "</p></article>"
        try await compatibilityWait { server.port != nil }
        let store = TabStore(profileID: ProfileManager.defaultID)
        store.newTab(try server.url("/article"))
        let tab = try XCTUnwrap(store.active)
        defer { store.tabs.forEach { $0.tearDown() }; TabStore.all.removeAll { $0 === store } }
        try await compatibilityWait { !tab.web.isLoading && tab.web.url?.path == "/article" }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ReadingQueueStore(profileID: tab.profileID, directory: root)
        let loader = HeldReadingImages()
        let pending = Task { try await ReadingQueueCapture.capture(tab: tab, in: store, repository: repository, images: loader) }
        try await compatibilityWait { await loader.started }
        tab.readingDocumentGeneration = UUID()
        await loader.resume()
        do { _ = try await pending.value; XCTFail("A changed document must not save") }
        catch { XCTAssertTrue(error is ReadingQueueFailure) }
        XCTAssertTrue(repository.articles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}

final class ReadingQueueImageTests: XCTestCase {
    func testRejectsActiveAndOversizedRasterInputs() throws {
        XCTAssertNil(ReadingQueueImages.raster(Data("<svg onload='bad()'/>".utf8)))
        XCTAssertNil(ReadingQueueImages.raster(Data(repeating: 0, count: ReadingArticleCodec.imageLimit + 1)))
        XCTAssertFalse(ReadingQueueImages.allowedRedirect(URL(string: "file:///etc/passwd")!, count: 1))
        XCTAssertFalse(ReadingQueueImages.allowedRedirect(URL(string: "https://example.test")!, count: 6))
        XCTAssertTrue(ReadingQueueImages.allowedRedirect(URL(string: "https://example.test")!, count: 5))
    }
    func testRasterRoundTrip() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        XCTAssertEqual(raster.resource.pixelWidth, 1)
        XCTAssertEqual(raster.resource.pixelHeight, 1)
        XCTAssertEqual(ReadingArticleCodec.digest(raster.data), raster.resource.digest)
    }
}
