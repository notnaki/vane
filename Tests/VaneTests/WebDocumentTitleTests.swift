import AppKit
import Combine
import WebKit
import XCTest
@testable import vane

@MainActor final class WebDocumentTitleTests: XCTestCase {
    private var server: NavigationHTTPFixture?
    private var tab: Tab?
    private var profiles: Set<UUID> = []
    private var cancellationDiagnostic: PDFCancellationDiagnostic?

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
        defer {
            cancellationDiagnostic?.flush()
            cancellationDiagnostic = nil
        }
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

    func testFailedProvisionalNavigationKeepsTheCommittedPDFFilename() async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        let web = tab.web
        let diagnostic = PDFCancellationDiagnostic()
        cancellationDiagnostic = diagnostic
        let previousObserver = tab.navigationStageObserver
        tab.navigationStageObserver = { [weak tab, weak web] event in
            previousObserver?(event)
            guard let tab, let web else { return }
            diagnostic.record("delegate stage=\(event.stage) identity=\(String(describing: event.identity)) detail=\(event.detail)", tab: tab, web: web)
        }
        let webObservation = web.observe(\.isLoading, options: [.new]) { [weak tab] page, change in
            MainActor.assumeIsolated {
                guard let tab else { return }
                diagnostic.record("web-loading-kvo new=\(String(describing: change.newValue))", tab: tab, web: page)
            }
        }
        let modelObservation = tab.$loading.sink { [weak tab, weak web] next in
            MainActor.assumeIsolated {
                guard let tab, let web else { return }
                diagnostic.record("model-loading-publication next=\(next)", tab: tab, web: web)
            }
        }
        defer {
            diagnostic.record("test-body-exit requests=\(server.requests.map { $0.components(separatedBy: "\r\n").first ?? "" })", tab: tab, web: web)
            tab.navigationStageObserver = previousObserver
            webObservation.invalidate()
            modelObservation.cancel()
        }
        diagnostic.record("before-pdf-load", tab: tab, web: web)
        try pdf(at: "/download", name: "committed.pdf")
        try await load("/download")
        diagnostic.record("pdf-load-completed", tab: tab, web: web)
        let committed = try server.url("/download")
        server.heldPaths.insert("/pending")
        // Keep only the primitive identity: retaining this navigation across stop
        // would change the lifetime of the weak retired-navigation ownership set.
        let pendingID = ObjectIdentifier(try XCTUnwrap(tab.web.load(URLRequest(url: server.url("/pending")))))
        diagnostic.record("pending-command-returned identity=\(pendingID)", tab: tab, web: web)
        try await compatibilityWait { server.requests.contains { $0.hasPrefix("GET /pending ") } }
        diagnostic.record("pending-request-observed identity=\(pendingID)", tab: tab, web: web)
        XCTAssertEqual(tab.title, "committed.pdf")
        diagnostic.record("before-stop identity=\(pendingID)", tab: tab, web: web)
        tab.stop()
        diagnostic.record("after-stop identity=\(pendingID)", tab: tab, web: web)
        do {
            try await compatibilityWait { !tab.web.isLoading && !tab.loading }
            diagnostic.record("stop-outcome-completed identity=\(pendingID)", tab: tab, web: web)
        } catch {
            diagnostic.record("stop-outcome-deadline identity=\(pendingID)", tab: tab, web: web)
            throw error
        }
        XCTAssertEqual(tab.currentURL, committed)
        XCTAssertEqual(tab.title, "committed.pdf")
    }

    func testRedirectUsesTheFinalPDFResponseFilename() async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        try pdf(at: "/download", name: "final-response.pdf")
        let final = try server.url("/download")
        server.redirects["/redirect"] = final
        _ = try XCTUnwrap(tab.web.load(URLRequest(url: server.url("/redirect"))))
        try await compatibilityWait { tab.currentURL == final && !tab.web.isLoading && !tab.loading }
        XCTAssertEqual(tab.title, "final-response.pdf")
    }

    func testSameURLPDFReloadUsesTheReplacementResponseFilename() async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        try pdf(at: "/download", name: "first.pdf")
        try await load("/download")
        try pdf(at: "/download", name: "replacement.pdf")
        let earlierRequests = server.requests.filter { $0.hasPrefix("GET /download ") }.count
        _ = try XCTUnwrap(tab.web.reload())
        try await compatibilityWait {
            server.requests.filter { $0.hasPrefix("GET /download ") }.count > earlierRequests
                && !tab.web.isLoading && !tab.loading
        }
        XCTAssertEqual(tab.title, "replacement.pdf")
    }

    func testPDFCommitReplacesThePreviousHTMLTitle() async throws {
        let server = try XCTUnwrap(server), tab = try XCTUnwrap(tab)
        server.pages["/previous"] = "<title>Previous document</title>"
        try await load("/previous")
        try pdf(at: "/download", name: "incoming.pdf")
        try await load("/download")
        XCTAssertEqual(tab.title, "incoming.pdf")
    }

    func testPDFFragmentStillUsesItsResponseFilename() async throws {
        try pdf(at: "/download", name: "fragment.pdf")
        try await load("/download#page=1")
        XCTAssertEqual(tab?.title, "fragment.pdf")
    }
}

@MainActor private final class PDFCancellationDiagnostic {
    private let start = ProcessInfo.processInfo.systemUptime
    private var records: [String] = []
    private var dropped = 0

    func record(_ label: String, tab: Tab, web: WKWebView) {
        if records.count == 96 { records.removeFirst(); dropped += 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let window = web.window
        records.append("PDF_STOP_DIAGNOSTIC t=\(elapsed) \(label) modelLoading=\(tab.loading) webLoading=\(web.isLoading) progress=\(web.estimatedProgress) title=\(tab.title) webURL=\(String(describing: web.url)) currentURL=\(String(describing: tab.currentURL)) gestures=\(web.allowsBackForwardNavigationGestures) appRunning=\(NSApp.isRunning) appActive=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) window=\(String(describing: window?.windowNumber)) key=\(window?.isKeyWindow ?? false) visible=\(window?.isVisible ?? false) occlusion=\(window?.occlusionState.rawValue ?? 0) webHidden=\(web.isHiddenOrHasHiddenAncestor) webFrame=\(web.frame)")
    }

    func flush() {
        print("PDF_STOP_DIAGNOSTIC_BEGIN records=\(records.count) dropped=\(dropped)")
        records.forEach { print($0) }
        print("PDF_STOP_DIAGNOSTIC_END")
    }
}
