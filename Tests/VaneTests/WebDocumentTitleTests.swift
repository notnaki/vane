import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WebDocumentTitleTests: XCTestCase {
    private var server: NavigationHTTPFixture?
    private var tab: Tab?
    private var profiles: Set<UUID> = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let fixture = try NavigationHTTPFixture()
        server = fixture
        try await compatibilityWait { fixture.port != nil }
        let profile = UUID()
        profiles.insert(profile)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        tab = Tab(popup: configuration, isPrivate: false, profileID: profile)
        tab?.web.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
    }

    override func tearDown() async throws {
        tab?.tearDown()
        tab = nil
        server?.stop()
        server = nil
        let released = profiles
        profiles.removeAll()
        try await NativeFixtureProfileCleanup.release(released)
    }

    private func pdf(at path: String, name: String) throws {
        let server = try XCTUnwrap(server)
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>",
            "<< /Length 0 >>\nstream\nendstream"
        ]
        var document = "%PDF-1.4\n"
        var offsets = [Int]()
        for (index, object) in objects.enumerated() {
            offsets.append(document.utf8.count)
            document += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = document.utf8.count
        document += "xref\n0 5\n0000000000 65535 f \n"
        for offset in offsets { document += String(format: "%010ld 00000 n \n", offset) }
        document += "trailer\n<< /Root 1 0 R /Size 5 >>\nstartxref\n\(xref)\n%%EOF\n"
        server.pages[path] = document
        server.contentTypes[path] = "application/pdf"
        server.responseHeaders[path] = ["Content-Disposition": "inline; filename=\"\(name)\""]
    }

    private func load(_ path: String) async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        let url = try server.url(path)
        _ = try XCTUnwrap(tab.web.load(URLRequest(url: url)))
        try await compatibilityWait { tab.web.url == url && !tab.web.isLoading && !tab.loading }
    }

    func testWebPDFUsesItsResponseFilenameWithoutAPageTitle() async throws {
        try pdf(at: "/download", name: "1706.03762v7.pdf")
        try await load("/download")
        XCTAssertEqual(tab?.title, "1706.03762v7.pdf")
    }

    func testSameURLReloadCannotKeepAnEarlierPDFResponseFilename() async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        try pdf(at: "/download", name: "earlier.pdf")
        try await load("/download")
        XCTAssertEqual(tab.title, "earlier.pdf")
        server.pages["/download"] = "<p>A different, untitled HTML document</p>"
        server.contentTypes["/download"] = "text/html; charset=utf-8"
        server.responseHeaders["/download"] = [:]
        let earlierRequests = server.requests.filter { $0.hasPrefix("GET /download ") }.count
        _ = try XCTUnwrap(tab.web.reload())
        try await compatibilityWait {
            server.requests.filter { $0.hasPrefix("GET /download ") }.count > earlierRequests
                && !tab.web.isLoading && !tab.loading
        }
        let contentType = try await tab.web.evaluateJavaScript("document.contentType") as? String
        XCTAssertEqual(contentType, "text/html")
        XCTAssertEqual(tab.title, "127.0.0.1")
        _ = try await tab.web.evaluateJavaScript("document.title = 'Readable document'")
        try await compatibilityWait { tab.title == "Readable document" }
        _ = try await tab.web.evaluateJavaScript("document.title = ''")
        try await compatibilityWait { tab.title == "127.0.0.1" }
        XCTAssertEqual(tab.title, "127.0.0.1")
    }

    func testSubframePDFCannotNameItsUntitledMainDocument() async throws {
        let server = try XCTUnwrap(server)
        try pdf(at: "/child", name: "child-only.pdf")
        server.pages["/untitled"] = "<iframe src='/child'></iframe>"
        try await load("/untitled")
        try await compatibilityWait { server.requests.contains { $0.hasPrefix("GET /child ") } }
        XCTAssertEqual(tab?.title, "127.0.0.1")
    }
}
