import Foundation
import CoreGraphics
import ImageIO
import WebKit
import XCTest
@testable import vane

/// A protocol boundary recorder; delivery and cancellation are exercised by the real handler.
@MainActor final class SavedReaderTaskRecorder: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    var response: URLResponse?
    var bytes = Data()
    var error: Error?
    var onEvent: ((String) -> Void)?
    init(_ request: URLRequest) { self.request = request; super.init() }
    func didReceive(_ response: URLResponse) { self.response = response; record("response") }
    func didReceive(_ data: Data) { bytes.append(data); record("data") }
    func didFinish() { record("finish") }
    func didFailWithError(_ error: Error) { self.error = error; record("failure") }
    private func record(_ event: String) { events.append(event); onEvent?(event) }
}

@MainActor final class SavedReaderTransportTests: XCTestCase {
    private func fixture(text: String = "Offline nebula") throws -> (SavedReaderContent, ReadingQueueImages.Raster) {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let raster = try XCTUnwrap(ReadingQueueImages.raster(png))
        var article = makeReadingArticle(text: text)
        article.resources = [raster.resource]
        article.nodes.append(.init(e: "img", a: ["src": "images/" + raster.resource.name]))
        let candidate = ReadingQueueCandidate(article: article, images: [raster.resource.name: raster.data])
        return (try SavedReaderContent(candidate: candidate, html: SavedReaderDocument.html(article: article)), raster)
    }

    func testDeliversOnlyOwnedImmutableDocumentAndImageBytes() throws {
        let (content, raster) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        let document = SavedReaderTaskRecorder(URLRequest(url: content.document))
        handler.start(document)
        XCTAssertEqual(document.events, ["response", "data", "finish"])
        XCTAssertEqual(document.response?.mimeType, "text/html")
        XCTAssertEqual(document.response?.textEncodingName, "utf-8")
        XCTAssertTrue(String(decoding: document.bytes, as: UTF8.self).contains("Offline nebula"))
        let image = SavedReaderTaskRecorder(URLRequest(url: content.document.deletingLastPathComponent().appendingPathComponent("images/" + raster.resource.name)))
        handler.start(image)
        XCTAssertEqual(image.events, ["response", "data", "finish"])
        XCTAssertEqual(image.bytes, raster.data)
        XCTAssertEqual(image.response?.mimeType, "image/png")
    }

    func testUnknownTraversalAndForeignOriginsNeverReceiveBytes() throws {
        let (content, raster) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        let origin = "vane-saved-reader://" + (try XCTUnwrap(content.document.host))
        let denied = [
            origin + "/missing.html", origin + "/images/unknown.png", origin + "/images/../article.html",
            origin + "/%2e%2e/article.html", origin + "/images%2f" + raster.resource.name,
            origin + "/images/%2e%2e/article.html", origin + "/images%5c" + raster.resource.name,
            origin + "/article.html?query=1", origin + ":443/article.html",
            "vane-saved-reader://user@" + (content.document.host ?? "") + "/article.html",
            "vane-saved-reader://foreign/article.html", "https://" + (content.document.host ?? "") + "/article.html",
            "file:///tmp/article.html",
        ]
        for raw in denied {
            let task = SavedReaderTaskRecorder(URLRequest(url: try XCTUnwrap(URL(string: raw))))
            handler.start(task)
            XCTAssertEqual(task.events, ["failure"], raw)
            XCTAssertTrue(task.bytes.isEmpty, raw)
        }
    }

    func testNonGETMethodsCannotReadTheInventory() throws {
        let (content, _) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        for method in ["POST", "PUT", "DELETE", "HEAD"] {
            var request = URLRequest(url: content.document); request.httpMethod = method
            let task = SavedReaderTaskRecorder(request)
            handler.start(task)
            XCTAssertEqual(task.events, ["failure"])
            XCTAssertTrue(task.bytes.isEmpty)
        }
    }

    func testOnlyDocumentAndItsFragmentCanNavigate() throws {
        let (content, raster) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        XCTAssertTrue(handler.allowsNavigation(content.document))
        XCTAssertTrue(handler.allowsNavigation(try XCTUnwrap(URL(string: content.document.absoluteString + "#paragraph"))))
        XCTAssertFalse(handler.allowsNavigation(content.document.deletingLastPathComponent().appendingPathComponent("images/" + raster.resource.name)))
        XCTAssertFalse(handler.allowsNavigation(try XCTUnwrap(URL(string: "https://example.test/article"))))
        let (other, _) = try fixture()
        XCTAssertNotEqual(other.document.host, content.document.host)
        XCTAssertFalse(handler.allowsNavigation(other.document))
    }

    func testStopDuringResponseOrDataPreventsEveryLaterCallback() throws {
        for stopAt in ["response", "data"] {
            let (content, _) = try fixture()
            let handler = SavedReaderSchemeHandler(content: content)
            let task = SavedReaderTaskRecorder(URLRequest(url: content.document))
            task.onEvent = { [weak task] event in
                if event == stopAt, let task { handler.stop(task) }
            }
            handler.start(task)
            XCTAssertEqual(task.events, stopAt == "response" ? ["response"] : ["response", "data"])
        }
    }

    func testRevokeDuringDeliveryCancelsOnceAndDeniesFreshRequests() throws {
        let (content, _) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        let task = SavedReaderTaskRecorder(URLRequest(url: content.document))
        task.onEvent = { event in if event == "response" { handler.revoke() } }
        handler.start(task)
        XCTAssertEqual(task.events, ["response", "failure"])
        XCTAssertTrue(task.bytes.isEmpty)
        handler.revoke()
        let later = SavedReaderTaskRecorder(URLRequest(url: content.document))
        handler.start(later)
        XCTAssertEqual(later.events, ["failure"])
        XCTAssertTrue(later.bytes.isEmpty)
        XCTAssertFalse(handler.allowsNavigation(content.document))
    }

    func testStopThenRevokeDoesNotCallbackStoppedTask() throws {
        let (content, _) = try fixture()
        let handler = SavedReaderSchemeHandler(content: content)
        let task = SavedReaderTaskRecorder(URLRequest(url: content.document))
        task.onEvent = { [weak task] event in
            if event == "response", let task { handler.stop(task); handler.revoke() }
        }
        handler.start(task)
        XCTAssertEqual(task.events, ["response"])
    }

    func testValidEscapedTextAndImagesPreserveExistingSnapshotAcceptance() throws {
        // One real, incompressible grayscale PNG, reused as four distinct saved images.
        // This avoids relying on decoders accepting padding after the PNG end marker.
        var pixels = Data(count: 2048 * 2048)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var state: UInt64 = 0x9e3779b97f4a7c15
            for index in buffer.indices {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                buffer[index] = UInt8(truncatingIfNeeded: state)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2048, height: 2048, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2048, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = output as Data
        XCTAssertLessThanOrEqual(bytes.count, ReadingArticleCodec.imageLimit)
        var article = makeReadingArticle(text: String(repeating: "&", count: 1024 * 1024))
        var images: [String: Data] = [:]
        for _ in 0..<4 {
            let name = UUID().uuidString.lowercased() + ".png"
            article.resources.append(.init(name: name, byteCount: bytes.count,
                digest: ReadingArticleCodec.digest(bytes), pixelWidth: 2048, pixelHeight: 2048))
            article.nodes.append(.init(e: "img", a: ["src": "images/" + name]))
            images[name] = bytes
        }
        let candidate = ReadingQueueCandidate(article: article, images: images)
        XCTAssertNoThrow(try ReadingArticleCodec.validate(candidate))
        let html = SavedReaderDocument.html(article: article)
        XCTAssertGreaterThan(html.utf8.count + 4 * bytes.count, ReadingArticleCodec.snapshotLimit)
        let content = try SavedReaderContent(candidate: candidate, html: html)
        let resource = try XCTUnwrap(content.resource(for: URLRequest(url: content.document)))
        XCTAssertTrue(String(decoding: resource.data, as: UTF8.self).contains("&amp;&amp;&amp;"))
    }

    func testRenderedHTMLHasAnIndependentBound() throws {
        let article = makeReadingArticle()
        let candidate = ReadingQueueCandidate(article: article, images: [:])
        XCTAssertThrowsError(try SavedReaderContent(candidate: candidate,
            html: String(repeating: "x", count: 6 * ReadingArticleCodec.recordLimit + 65_537)))
    }
}
