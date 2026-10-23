import AppKit
import ImageIO
import XCTest
@testable import vane

@MainActor final class NativePageInputBoundsTests: XCTestCase {
    func testPreviewMalformedEntitiesStayLiteralAndValidEntitiesDecode() {
        let malformed = String(repeating: "&", count: 40_000)
        XCTAssertEqual(Previews.unescape(malformed), malformed)
        XCTAssertEqual(Previews.unescape("A &amp; B &#x1F642; &#39; &unknown; &abcdefghijk;"),
                       "A & B 🙂 ' &unknown; &abcdefghijk;")
    }

    func testPreviewRejectsOversizedFragmentsBeforeParsingMetadata() {
        let html = "<title>Oversized</title>" + String(repeating: "x", count: Previews.maxMetadataBytes)
        XCTAssertEqual(Previews.meta(from: html), Previews.Meta())
        XCTAssertEqual(Previews.meta(from: "<title>Fallback</title><meta property='og:title' content='A &amp; B'>").title, "A & B")
    }

    func testMediaBoundsRawTextBeforeWhitespaceAndControlSanitization() {
        XCTAssertEqual(MediaTray.clean(String(repeating: " ", count: 100_000) + "late"), "")
        XCTAssertEqual(MediaTray.clean(String(repeating: "\u{202E}", count: 100_000) + "late"), "")
        XCTAssertNil(MediaTray.info(from: ["playing": true,
            "title": String(repeating: " ", count: MediaTray.maxRawTextBytes + 1)]))
        XCTAssertEqual(MediaTray.info(from: ["playing": true, "title": "  Track\nname  ", "artist": "Artist"])?.line,
                       "Track name — Artist")
        XCTAssertEqual(MediaTray.clean(String(repeating: "e\u{301}", count: 210)),
                       String(repeating: "e\u{301}", count: MediaTray.maxText))
    }

    func testFaviconDecodesOnlyBoundedPixelsFromLargeCompressedBitmap() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048,
            pixelsHigh: 2048, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertLessThan(data.count, 512_000)
        let image = try XCTUnwrap(Favicons.image(from: data))
        let decoded = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(decoded.width, 64)
        XCTAssertLessThanOrEqual(decoded.height, 64)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
    }

    func testSVGArtworkRasterizesIntoBoundedBitmapOnWorker() async throws {
        let data = Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='red'/></svg>".utf8)
        let decoded = await Task.detached { NativeSVGResult(image: Favicons.image(from: data)) }.value
        let image = try XCTUnwrap(decoded.image)
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(bitmap.width, 64)
        XCTAssertLessThanOrEqual(bitmap.height, 64)
        XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
        XCTAssertFalse(image.isTemplate)
        let pixels = NSBitmapImageRep(cgImage: bitmap)
        let center = try XCTUnwrap(pixels.colorAt(x: bitmap.width / 2, y: bitmap.height / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.9)
        XCTAssertLessThan(center.greenComponent, 0.1)
    }

    func testFaviconMemoryCacheEvictsLeastRecentlyUsedAndKeepsInstancesIndependent() throws {
        var cache = FaviconMemoryCache(capacity: 2)
        let a = NSImage(size: NSSize(width: 16, height: 16))
        let b = NSImage(size: NSSize(width: 16, height: 16))
        let c = NSImage(size: NSSize(width: 16, height: 16))
        cache.store(a, for: "a")
        cache.store(b, for: "b")
        XCTAssertTrue(cache.image(for: "a") === a)
        cache.store(c, for: "c")
        XCTAssertNil(cache.image(for: "b"))
        XCTAssertTrue(cache.image(for: "a") === a)
        XCTAssertTrue(cache.image(for: "c") === c)
        var other = FaviconMemoryCache(capacity: 2)
        XCTAssertNil(other.image(for: "a"))
    }
}

private struct NativeSVGResult: @unchecked Sendable { let image: NSImage? }

/// A synthetic response that keeps sending chunks until URLSession cancels the transfer.
/// The assertions count delivered chunks; they do not impose a machine-speed threshold.
private final class NativeIconTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var chunks = 0
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func beginChunk() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        chunks += 1
        return true
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return chunks }
}

private final class NativeIconURLProtocol: URLProtocol, @unchecked Sendable {
    static let transfer = NativeIconTransfer()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {
        if request.url?.path == "/chunked" { Self.transfer.cancel() }
    }
    override func startLoading() {
        let path = request.url!.path
        let headers = path == "/oversized-length" ? ["Content-Length": "99999999"] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "/small" {
            client?.urlProtocol(self, didLoad: Data([1, 2, 3]))
            client?.urlProtocolDidFinishLoading(self)
        } else if path == "/oversized-length" {
            client?.urlProtocolDidFinishLoading(self)
        } else {
            Task.detached { @Sendable [self] in
                for _ in 0..<128 {
                    guard Self.transfer.beginChunk() else { return }
                    client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 65_536))
                    try? await Task.sleep(for: .milliseconds(5))
                }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
}

extension NativePageInputBoundsTests {
    func testFaviconFetchAcceptsSmallDataAndRejectsAdvertisedAndStreamedOversize() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeIconURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let small = await Favicons.fetch(URL(string: "https://icons.invalid/small")!, session: session)
        XCTAssertEqual(small, Data([1, 2, 3]))
        let advertised = await Favicons.fetch(URL(string: "https://icons.invalid/oversized-length")!, session: session)
        XCTAssertNil(advertised)
        let streamed = await Favicons.fetch(URL(string: "https://icons.invalid/chunked")!, session: session)
        XCTAssertNil(streamed)
        XCTAssertLessThan(NativeIconURLProtocol.transfer.count, 128,
                          "An unknown-length response must stop transferring at the byte bound")
    }
}
