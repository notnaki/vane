import XCTest
import AppKit
import WebKit
@testable import vane

@MainActor final class EaselTests: XCTestCase {
    private func repository() -> EaselStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return EaselStore(profileID: UUID(), directory: root)
    }
    private func imageItem() throws -> EaselItem {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        return try EaselWindow.imageItem(image, source: "https://example.com")
    }
    func testFailedSaveReturnsFailureAndPreservesCommittedContent() throws {
        let repository = repository()
        let session = EaselSession(repository)
        session.create()
        XCTAssertTrue(session.add(EaselItem(kind: .note, text: "Saved")))
        try FileManager.default.removeItem(at: repository.directory)
        try Data().write(to: repository.directory)
        XCTAssertFalse(session.edit { $0.items[0].text = "Keep this draft" })
        XCTAssertEqual(session.board?.items.first?.text, "Saved")
        XCTAssertNotNil(session.message)
    }
    func testRemovedCapturesReleaseTheirLiveViewSlots() throws {
        let session = EaselSession(repository()); session.create()
        var items: [EaselItem] = []
        for _ in 0..<4 {
            let item = try imageItem(); items.append(item)
            XCTAssertTrue(session.add(item)); session.toggleLive(item.id)
        }
        XCTAssertEqual(session.liveItems.count, 4)
        XCTAssertTrue(session.edit { $0.items.removeAll() })
        XCTAssertTrue(session.liveItems.isEmpty)
        let next = try imageItem(); XCTAssertTrue(session.add(next)); session.toggleLive(next.id)
        XCTAssertEqual(session.liveItems, [next.id])
        session.undo()
        XCTAssertTrue(session.liveItems.isEmpty)
    }
    func testNewItemsFollowTheVisibleCanvasAndStayWithinItsBounds() throws {
        let session = EaselSession(repository()); session.create()
        session.insertionPoint = CGPoint(x: 2500, y: 1800)
        XCTAssertTrue(session.add(EaselItem(kind: .note, text: "Here")))
        XCTAssertEqual(session.board?.items.first?.x, 2500)
        XCTAssertEqual(session.board?.items.first?.y, 1800)
        session.insertionPoint = CGPoint(x: 9000, y: 9000)
        XCTAssertTrue(session.add(EaselItem(kind: .note)))
        XCTAssertEqual(session.board?.items.last?.x, 5720)
        XCTAssertEqual(session.board?.items.last?.y, 3800)
    }
    func testLiveSourceChangesReloadButOrdinaryRerendersKeepNavigation() {
        TestEnvironment.prepare()
        let original = URL(string: "https://example.com/old")!
        let updated = URL(string: "https://example.com/new")!
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        delegate.source = original
        delegate.upgradedHosts.insert("example.com")
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        defer { web.stopLoading() }
        EaselLiveView.update(web, source: updated, delegate: delegate)
        XCTAssertEqual(delegate.source, updated)
        XCTAssertTrue(delegate.upgradedHosts.isEmpty)
        delegate.upgradedHosts.insert("keep-state")
        EaselLiveView.update(web, source: updated, delegate: delegate)
        XCTAssertEqual(delegate.upgradedHosts, ["keep-state"])
    }
    func testLiveNavigationHonorsHTTPSPolicyAndPreventsDowngradeLoops() {
        let suite = "vane.easel.https-tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let previous = HTTPSOnly.defaults; HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; UserDefaults.dropScratchSuite(suite) }
        let delegate = EaselLiveView.Delegate(profileID: UUID())
        let plain = URL(string: "http://example.com/a")!
        XCTAssertEqual(delegate.policy(url: plain, mainFrame: true), .upgrade(URL(string: "https://example.com/a")!))
        XCTAssertEqual(delegate.policy(url: plain, mainFrame: true), .cancel)
        delegate.finished(url: URL(string: "https://example.com/a")!)
        XCTAssertEqual(delegate.policy(url: URL(string: "http://example.com/next")!, mainFrame: true),
                       .upgrade(URL(string: "https://example.com/next")!))
        XCTAssertEqual(delegate.policy(url: URL(string: "http://localhost:8080")!, mainFrame: true), .allow)
        XCTAssertEqual(delegate.policy(url: URL(string: "javascript:alert(1)")!, mainFrame: true), .cancel)
        HTTPSOnly.allow(host: "allowed.example", profileID: delegate.profileID)
        XCTAssertEqual(delegate.policy(url: URL(string: "http://allowed.example")!, mainFrame: true), .allow)
    }
    func testPNGExportIncludesItemsAtTheFarCanvasEdge() throws {
        let board = EaselBoard(items: [EaselItem(kind: .note, text: "Edge", x: 5400, y: 3400)])
        let png = try EaselWindow.png(for: board, profileID: UUID())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(bitmap.pixelsWide, 4096)
        let scale = 4096.0 / 5720.0
        let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(5500 * scale), y: Int(3520 * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(pixel.redComponent, 0.95)
        XCTAssertLessThan(pixel.blueComponent, 0.8, "The far-edge note must be rendered, not clipped to empty paper")
    }

}
