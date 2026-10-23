import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class DownloadTabWebKitTests: XCTestCase {
    var server: NavigationHTTPFixture!
    var store: TabStore!
    var opener: Tab!
    var child: Tab?
    var manager: Downloads!
    var root: URL!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        server = try NavigationHTTPFixture()
        try await compatibilityWait { self.server.port != nil }
        server.attachmentPaths.insert("/download")
        server.pages["/download"] = "download fixture bytes"
        server.redirects["/redirect"] = try server.url("/download")
        store = TabStore(isPrivate: false, urls: [], profileID: UUID(), session: [])
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        opener = Tab(popup: config, isPrivate: false, profileID: store.profileID)
        store.adoptBeside(opener, opener: nil, focus: true)
        let route = try XCTUnwrap(opener.onPopup)
        opener.onPopup = { [unowned self] config, placement, features in
            let web = route(config, placement, features)
            self.child = web?.uiDelegate as? Tab
            return web
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-download-tab-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager = Downloads.manager(for: store.profileID)
        manager.destinationDirectory = root
    }

    override func tearDown() async throws {
        manager.items.filter { $0.status.isLive }.forEach { manager.cancel($0) }
        Downloads.forget(store.profileID)
        child?.tearDown()
        store.everyTab.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        server.stop()
        try? FileManager.default.removeItem(at: root)
        child = nil; opener = nil; store = nil; server = nil; manager = nil
    }

    func loadOpener(_ html: String) async throws {
        server.pages["/opener"] = "<title>Download source</title>\(html)"
        opener.go(try server.url("/opener"))
        try await compatibilityWait { self.opener.title == "Download source" && !self.opener.loading }
    }

    func waitForDownload() async throws {
        try await compatibilityWait { self.manager.items.first?.status == .done }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.url)), Data("download fixture bytes".utf8))
    }

    func assertDownloadTabCloses(path: String) async throws {
        try await loadOpener("<a href='\(path)' target='_blank'>Download</a>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('a').click(); void 0")
        try await compatibilityWait { self.child != nil }
        let child = try XCTUnwrap(child)
        try await waitForDownload()
        try await compatibilityWait { !self.store.tabs.contains { $0.id == child.id } }
        XCTAssertNil(child.existingWeb)
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        XCTAssertEqual(store.current, opener.id)
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
    }

    func testBlankTargetDownloadClosesTabAndCompletesTransfer() async throws {
        try await assertDownloadTabCloses(path: "/download")
    }

    func testRedirectedBlankTargetDownloadClosesTabAndCompletesTransfer() async throws {
        try await assertDownloadTabCloses(path: "/redirect")
    }

    func testBlankScriptWindowNavigatedToDownloadCloses() async throws {
        try await loadOpener("<button onclick=\"window.child=window.open('about:blank'); child.location='/download'\">Download</button>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('button').click(); void 0")
        try await compatibilityWait { self.child != nil }
        let child = try XCTUnwrap(child)
        try await waitForDownload()
        try await compatibilityWait { !self.store.tabs.contains { $0.id == child.id } }
        XCTAssertEqual(store.current, opener.id)
    }

    func testBackgroundDownloadTabClosesWithoutChangingSelection() async throws {
        try await loadOpener("")
        opener.onOpenBeside?(try server.url("/download"), false)
        let child = try XCTUnwrap(store.tabs.last)
        XCTAssertNotEqual(child.id, opener.id)
        XCTAssertEqual(store.current, opener.id)
        try await waitForDownload()
        try await compatibilityWait { !self.store.tabs.contains { $0.id == child.id } }
        XCTAssertEqual(store.current, opener.id)
    }

    func testDownloadFromExistingDocumentKeepsItsTab() async throws {
        try await loadOpener("<a href='/download'>Download</a>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('a').click(); void 0")
        try await waitForDownload()
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
        XCTAssertEqual(store.current, opener.id)
        XCTAssertEqual(opener.web.url, try server.url("/opener"))
        XCTAssertNotNil(opener.existingWeb)
    }

    func testDownloadFromWrittenBlankDocumentKeepsItsTab() async throws {
        try await loadOpener("<button onclick=\"window.child=window.open('about:blank'); child.document.write('<p>Export options</p>'); child.document.close()\">Export</button>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('button').click(); void 0")
        try await compatibilityWait { self.child != nil }
        let child = try XCTUnwrap(child)
        _ = try await child.web.evaluateJavaScript("location.href='/download'; void 0")
        try await waitForDownload()
        XCTAssertEqual(store.tabs.map(\.id), [opener.id, child.id])
        XCTAssertNotNil(child.existingWeb)
    }

    func testTransferContinuesAfterItsBlankTabCloses() async throws {
        let binary = try DownloadHTTPFixture()
        defer { binary.stop() }
        try await compatibilityWait { binary.port != nil }
        binary.held = true
        try await loadOpener("<a href='\(try binary.url().absoluteString)' target='_blank'>Download</a>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('a').click(); void 0")
        try await compatibilityWait { self.child != nil }
        let child = try XCTUnwrap(child)
        try await compatibilityWait { self.manager.items.first?.received ?? 0 > 0 }
        try await compatibilityWait { !self.store.tabs.contains { $0.id == child.id } }
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.status, .running)
        XCTAssertNil(child.existingWeb)
        binary.held = false
        try await compatibilityWait { item.status == .done }
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(item.url)), binary.bytes)
    }

    func testDelayedDownloadClosesItsTabAfterSwitchingSpaces() async throws {
        let first = Space(name: "Downloads", profileID: store.profileID)
        let second = Space(name: "Reading", profileID: store.profileID)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([first, second], for: store.profileID))
        store.switchTo(space: first)
        server.heldPaths.insert("/download")
        try await loadOpener("<a href='/download' target='_blank'>Download</a>")
        _ = try await opener.web.evaluateJavaScript("document.querySelector('a').click(); void 0")
        try await compatibilityWait { self.child != nil && self.server.requests.contains { $0.hasPrefix("GET /download ") } }
        let child = try XCTUnwrap(child)
        store.switchTo(space: second)
        XCTAssertEqual(store.stashes[first.id]?.tabs.map(\.id), [opener.id, child.id])
        server.heldPaths.remove("/download")
        try await waitForDownload()
        try await compatibilityWait { !self.store.everyTab.contains { $0.id == child.id } }
        XCTAssertEqual(store.currentSpaceID, second.id)
        XCTAssertNil(store.current)
        store.switchTo(space: first)
        XCTAssertEqual(store.tabs.map(\.id), [opener.id])
    }

    func testEmptyBlankDocumentWithBackHistoryKeepsItsTab() async throws {
        try await loadOpener("")
        let web = opener.web
        opener.go(URL(string: "about:blank")!)
        try await compatibilityWait { web.backForwardList.currentItem?.url.absoluteString == "about:blank" && !self.opener.loading }
        XCTAssertFalse(web.backForwardList.backList.isEmpty)
        opener.go(try server.url("/download"))
        try await waitForDownload()
        // Allow the asynchronous blank-document check and deferred close to settle.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.tabs.contains { $0.id == opener.id })
        XCTAssertTrue(opener.existingWeb === web)
        XCTAssertTrue(web.canGoBack)
    }

    func testEmptyBlankDocumentWithForwardHistoryKeepsItsTab() async throws {
        let tab = store.newBlankTab()
        let web = tab.web
        tab.go(URL(string: "about:blank")!)
        try await compatibilityWait { web.backForwardList.currentItem?.url.absoluteString == "about:blank" && !tab.loading }
        tab.go(try server.url("/history"))
        try await compatibilityWait { tab.title == "Page /history" && !tab.loading }
        tab.back()
        try await compatibilityWait { web.backForwardList.currentItem?.url.absoluteString == "about:blank" && !tab.loading }
        XCTAssertFalse(web.backForwardList.forwardList.isEmpty)
        tab.go(try server.url("/download"))
        try await waitForDownload()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(store.tabs.contains { $0.id == tab.id })
        XCTAssertTrue(tab.existingWeb === web)
        XCTAssertTrue(web.canGoForward)
    }
}
