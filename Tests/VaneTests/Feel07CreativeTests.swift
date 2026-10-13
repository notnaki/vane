import AppKit
import WebKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class Feel07CreativeTests: XCTestCase {
    func testIdleResizePreservesExactStrokeCoordinates() {
        let item = EaselItem(kind: .drawing, points: [.init(x: 0.35, y: 0.7)], width: 280, height: 200)
        XCTAssertEqual(EaselItemLayout.resized(item, corner: .bottomTrailing, translation: .zero, zoom: 0.75), item)
    }

    func testImageReuseAndCropReplacement() throws {
        let original = try png(.red), cropped = try png(.blue)
        let decoded = Feel07EaselImage(data: original)
        let first = try XCTUnwrap(decoded.image)
        decoded.update(original)
        XCTAssertTrue(decoded.image === first)
        decoded.update(cropped)
        XCTAssertFalse(decoded.image === first)
        XCTAssertEqual(decoded.data, cropped)
        decoded.update(nil)
        XCTAssertNil(decoded.image)
    }

    func testPreparationRejectsChangedRevisionAndOtherRepository() async throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingQueueStore(profileID: UUID(), directory: root)
        var article = makeReadingArticle(); article.profileID = store.profileID
        try await store.publish(.init(article: article, images: [:]))
        let preparation = Feel07ArticlePreparation()
        await preparation.prepare(article.id, repository: store)
        XCTAssertEqual(preparation.take(article.id, repository: store)?.article, article)
        XCTAssertNil(preparation.take(article.id, repository: store), "Preparation is consumed once")
        await preparation.prepare(article.id, repository: store)
        try await store.setRead(true, id: article.id)
        XCTAssertNil(preparation.take(article.id, repository: store))
        await preparation.prepare(article.id, repository: store)
        let other = try ReadingQueueStore(profileID: store.profileID, directory: root.appendingPathComponent("other"))
        XCTAssertNil(preparation.take(article.id, repository: other))
        await preparation.prepare(article.id, repository: store)
        preparation.clear()
        XCTAssertNil(preparation.take(article.id, repository: store))
    }

    func testOpenDuringPreparationReusesTheInFlightRead() async throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingQueueStore(profileID: UUID(), directory: root)
        var article = makeReadingArticle(); article.profileID = store.profileID
        try await store.publish(.init(article: article, images: [:]))
        var resume: CheckedContinuation<Void, Never>?
        var reads = 0
        let preparation = Feel07ArticlePreparation { id, repository in
            reads += 1
            await withCheckedContinuation { resume = $0 }
            return try await repository.candidate(id)
        }
        let preparing = Task { await preparation.prepare(article.id, repository: store) }
        try await compatibilityWait { resume != nil }
        var openingStarted = false
        let opening = Task {
            openingStarted = true
            return await preparation.takeOrWait(article.id, repository: store)
        }
        try await compatibilityWait { openingStarted }
        preparing.cancel() // Leaving the queue must not cancel the explicit open's read.
        preparation.clear()
        resume?.resume(); resume = nil
        await preparing.value
        let opened = await opening.value
        XCTAssertEqual(opened?.article, article, "Opening must reuse the pending local read")
        XCTAssertEqual(reads, 1)
        XCTAssertNil(preparation.take(article.id, repository: store))
    }

    func testClearingPreparationCancelsItsUnconsumedRead() async throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingQueueStore(profileID: UUID(), directory: root)
        var article = makeReadingArticle(); article.profileID = store.profileID
        try await store.publish(.init(article: article, images: [:]))
        var resume: CheckedContinuation<Void, Never>?
        var cancelled = false
        let preparation = Feel07ArticlePreparation { id, repository in
            await withCheckedContinuation { resume = $0 }
            cancelled = Task.isCancelled
            return try await repository.candidate(id)
        }
        let preparing = Task { await preparation.prepare(article.id, repository: store) }
        try await compatibilityWait { resume != nil }
        preparation.clear()
        resume?.resume(); resume = nil
        await preparing.value
        XCTAssertTrue(cancelled, "Leaving an unopened queue cancels its speculative work")
        XCTAssertNil(preparation.take(article.id, repository: store))
    }

    func testPendingOpenRejectsARevisionChangedWhileWaiting() async throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReadingQueueStore(profileID: UUID(), directory: root)
        var article = makeReadingArticle(); article.profileID = store.profileID
        try await store.publish(.init(article: article, images: [:]))
        var resume: CheckedContinuation<Void, Never>?
        let preparation = Feel07ArticlePreparation { id, repository in
            await withCheckedContinuation { resume = $0 }
            return try await repository.candidate(id)
        }
        let preparing = Task { await preparation.prepare(article.id, repository: store) }
        try await compatibilityWait { resume != nil }
        var openingStarted = false
        let opening = Task {
            openingStarted = true
            return await preparation.takeOrWait(article.id, repository: store)
        }
        try await compatibilityWait { openingStarted }
        try await store.setRead(true, id: article.id)
        resume?.resume(); resume = nil
        await preparing.value
        let stale = await opening.value
        XCTAssertNil(stale, "A changed owner revision needs the ordinary fresh load")
    }

    func testSavedImagesReserveTheirValidatedGeometry() throws {
        TestEnvironment.prepare()
        var article = makeReadingArticle()
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png(.red)))
        article.resources = [raster.resource]
        article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name]))
        let html = SavedReaderDocument.html(article: article)
        XCTAssertTrue(html.contains("width=\"12\" height=\"8\""))
        XCTAssertEqual(article.nodes.last?.a?.count, 1, "Presentation must not mutate the saved payload")
    }

    func testResizePreviewAndCommitAgreeAtEveryZoomAndCorner() {
        let item = EaselItem(kind: .drawing, points: [.init(x: 20, y: 30)], x: 120, y: 140, width: 280, height: 200)
        for zoom in [0.25, 0.75, 1, 2] {
            for corner in EaselItemLayout.Corner.allCases {
                for delta in [CGSize(width: 71, height: -39), CGSize(width: -9000, height: 9000)] {
                    let preview = EaselItemLayout.resizeFrame(item, corner: corner, translation: delta, zoom: zoom)
                    let committed = EaselItemLayout.resized(item, corner: corner, translation: delta, zoom: zoom)
                    XCTAssertEqual(preview, CGRect(x: committed.x, y: committed.y, width: committed.width, height: committed.height))
                }
            }
        }
    }

    func testNativePointerKeepsRawDeltaAndCommitsOnlyOnRelease() throws {
        TestEnvironment.prepare()
        let pointer = EaselPointerView(frame: .init(x: 0, y: 0, width: 280, height: 200))
        var selected = 0
        var samples: [(CGSize, Bool)] = []
        pointer.select = { selected += 1 }
        pointer.drag = { delta, _, finished in samples.append((delta, finished)) }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: x, y: y), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        pointer.mouseDown(with: try event(.leftMouseDown, 100, 100))
        pointer.mouseDragged(with: try event(.leftMouseDragged, 101, 100))
        XCTAssertTrue(samples.isEmpty)
        pointer.mouseDragged(with: try event(.leftMouseDragged, 151, 73))
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].0, CGSize(width: 51, height: 27))
        XCTAssertFalse(samples[0].1)
        pointer.mouseUp(with: try event(.leftMouseUp, 155, 70))
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].0, CGSize(width: 55, height: 30))
        XCTAssertTrue(samples[1].1)
        XCTAssertEqual(selected, 1)
    }

    func testPreferencesPreserveDOMSelectionScrollAndRespectBatterySaver() async throws {
        TestEnvironment.prepare(); WebKitStartup.prepare()
        let oldMode = BatterySaver.shared.mode, oldSize = Reader.fontSize
        defer { BatterySaver.shared.setMode(oldMode); Reader.fontSize = oldSize }
        BatterySaver.shared.setMode(.alwaysOn)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
        defer { web.stopLoading() }
        let text = String(repeating: "Keep reading and selecting this text. ", count: 300)
        web.loadHTMLString(Reader.html(for: .init(title: "Continuity", nodes: [.init(e: "p", c: [.init(x: text)])]), url: nil), baseURL: nil)
        try await compatibilityWait { !web.isLoading }
        _ = try await web.evaluateJavaScript("""
            window.originalParagraph = document.querySelector('article p');
            const r = document.createRange(); r.setStart(originalParagraph.firstChild, 5); r.setEnd(originalParagraph.firstChild, 12);
            getSelection().removeAllRanges(); getSelection().addRange(r); window.scrollTo(0, 450);
            """)
        let before = try await web.evaluateJavaScript("[getSelection().toString(), String(scrollY)]") as? [String]
        Reader.fontSize = min(32, Reader.fontSize + 1)
        _ = try await web.evaluateJavaScript(Reader.preferenceScript)
        let after = try await web.evaluateJavaScript("[getSelection().toString(), String(scrollY)]") as? [String]
        XCTAssertEqual(before, after)
        let same = try await web.evaluateJavaScript("originalParagraph === document.querySelector('article p')") as? Bool
        XCTAssertEqual(same, true)
        let transition = try await web.evaluateJavaScript("getComputedStyle(document.body).transitionDuration") as? String
        XCTAssertEqual(transition, "0s")
    }

    func testHostedCanvasRoutesDragToTheCardAndSavesOnce() async throws {
        TestEnvironment.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = EaselStore(profileID: UUID(), directory: root)
        let session = EaselSession(repository); session.create()
        let item = EaselItem(kind: .note, text: "Pointer fixture", x: 450, y: 200)
        XCTAssertTrue(session.add(item))
        let browser = TabStore(profileID: repository.profileID)
        defer { browser.tabs.forEach { $0.tearDown() }; TabStore.all.removeAll { $0 === browser } }
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: EaselWorkspace(session: session, browser: browser))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func find(_ view: NSView) -> EaselPointerView? {
            if let pointer = view as? EaselPointerView { return pointer }
            return view.subviews.compactMap(find).first
        }
        try await compatibilityWait { host.layoutSubtreeIfNeeded(); return find(host) != nil }
        let pointer = try XCTUnwrap(find(host))
        let center = pointer.convert(CGPoint(x: pointer.bounds.midX, y: pointer.bounds.midY), to: nil)
        let hit = window.contentView?.hitTest(center)
        XCTAssertTrue(hit === pointer, "The hosted canvas must hit the card pointer surface")
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: hit?.mouseDown(with: event)
            case .leftMouseDragged: hit?.mouseDragged(with: event)
            case .leftMouseUp: hit?.mouseUp(with: event)
            default: XCTFail("Unexpected fixture event")
            }
        }
        let original = try XCTUnwrap(session.board?.items.first)
        try send(.leftMouseDown, center)
        try send(.leftMouseDragged, CGPoint(x: center.x + 50, y: center.y - 30))
        XCTAssertEqual(session.board?.items.first, original, "Autosave waits for the release")
        try send(.leftMouseUp, CGPoint(x: center.x + 50, y: center.y - 30))
        try await compatibilityWait { session.board?.items.first?.x != original.x }
        XCTAssertEqual(session.board?.items.first?.x, original.x + 50)
        XCTAssertEqual(session.board?.items.first?.y, original.y + 30)
        session.undo()
        XCTAssertEqual(session.board?.items.first, original)
    }

    func testCachedImageStillRendersInPNGExport() throws {
        TestEnvironment.prepare()
        let image = try png(.red)
        let item = EaselItem(kind: .image, image: image, x: 100, y: 100, width: 240, height: 204)
        let data = try EaselWindow.png(for: .init(items: [item]), profileID: UUID())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let pixel = try XCTUnwrap(bitmap.colorAt(x: 200, y: 180)?.usingColorSpace(.deviceRGB))
        let source = try XCTUnwrap(NSBitmapImageRep(data: image)?.colorAt(x: 6, y: 4)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(pixel.redComponent, source.redComponent, accuracy: 0.02)
        XCTAssertEqual(pixel.greenComponent, source.greenComponent, accuracy: 0.02)
        XCTAssertEqual(pixel.blueComponent, source.blueComponent, accuracy: 0.02)
    }

    private func png(_ color: NSColor) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill(); NSBezierPath(rect: .init(x: 0, y: 0, width: 12, height: 8)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
