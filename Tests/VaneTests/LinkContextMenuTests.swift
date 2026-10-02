import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class LinkContextMenuTests: XCTestCase {
    private func fixture() -> (LinkContextWebView, NSMenu, NSEvent) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let view = LinkContextWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.openBackground = { _ in }
        let menu = NSMenu()
        for (title, id) in [("Open Link", "OpenLink"), ("Open Link in New Window", "OpenLinkInNewWindow"),
                            ("Download Linked File", "DownloadLinkedFile"), ("Copy Link", "CopyLink")] {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.identifier = .init("WKMenuItemIdentifier" + id)
        }
        menu.addItem(.separator())
        let inspect = menu.addItem(withTitle: "Inspect Element", action: nil, keyEquivalent: "")
        inspect.identifier = .init("WKMenuItemIdentifierInspectElement")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      eventNumber: 1, clickCount: 1, pressure: 1)!
        return (view, menu, event)
    }

    func testNormalLinkMenuMatchesReferenceWithoutDuplicateWebKitActions() {
        let (view, menu, event) = fixture()
        view.contextLink = URL(string: "https://example.test/destination")!
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, [
            "Open Link in New Tab", "Open Link in New Window", "Open Link in Split View",
            "Open Link in Little Vane", "Open Link in Private Window", "—",
            "Save Link As…", "Copy Link Address", "—", "Inspect"
        ])
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.filter { $0.title == "Open Link in New Window" }.count, 1)
        XCTAssertEqual(menu.items.filter { $0.title == "Save Link As…" }.count, 1)
    }

    func testImageAndSelectedTextActionsSurviveLinkMenuUpdate() {
        let (view, menu, event) = fixture()
        let image = menu.addItem(withTitle: "Copy Image", action: nil, keyEquivalent: "")
        image.identifier = .init("WKMenuItemIdentifierCopyImage")
        let copy = menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        copy.identifier = .init("WKMenuItemIdentifierCopy")
        view.contextLink = URL(string: "https://example.test/image")!
        view.willOpenMenu(menu, with: event)
        XCTAssertTrue(menu.items.contains { $0 === image })
        XCTAssertTrue(menu.items.contains { $0 === copy })
    }

    func testNonLinkMenuIsUntouched() {
        let (view, menu, event) = fixture()
        let before = menu.items
        view.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items, before)
    }

    func testLateContextReplyRebuildsMenuAndClearingContextRestoresWebKitItems() {
        let (view, menu, event) = fixture()
        let original = menu.items.map(\.title)
        view.willOpenMenu(menu, with: event)
        view.contextLink = URL(string: "https://example.test/late")!
        XCTAssertEqual(menu.items.first?.title, "Open Link in New Tab")
        XCTAssertEqual(menu.items.filter { $0.title == "Copy Link Address" }.count, 1)
        view.contextLink = nil
        XCTAssertEqual(menu.items.map(\.title), original)
    }

    func testEveryOpeningActionKeepsItsCapturedURLAndSplitCannotExceedCapacity() throws {
        let (view, menu, event) = fixture()
        let clicked = URL(string: "https://example.test/clicked?q=one#two")!
        var opened: [(URL, LinkContextWebView.Destination)] = []
        view.openBackground = { opened.append(($0, .tab)) }
        view.openDestination = { opened.append(($0, $1)) }
        var splitAllowed = true
        view.canOpenSplit = { splitAllowed }
        view.contextLink = clicked
        view.willOpenMenu(menu, with: event)
        let openingItems = Array(menu.items.prefix(5))
        view.contextLink = URL(string: "https://example.test/later")!
        for item in openingItems { view.openLink(item) }
        XCTAssertEqual(opened.map(\.0), Array(repeating: clicked, count: 5))
        XCTAssertEqual(opened.map(\.1), [.tab, .window, .split, .little, .privateWindow])
        let split = try XCTUnwrap(openingItems.first { $0.title == "Open Link in Split View" })
        splitAllowed = false
        XCTAssertFalse(view.validateMenuItem(split))
        view.openLink(split)
        XCTAssertEqual(opened.count, 5, "A split that filled while the menu was open must not open another tab")
    }

    func testSaveActionUsesCapturedURLWithoutNavigating() throws {
        let (view, menu, event) = fixture()
        let clicked = URL(string: "https://example.test/report.pdf")!
        var saved: URL?
        var opened = false
        view.saveLink = { url, _ in saved = url }
        view.openBackground = { _ in opened = true }
        view.contextLink = clicked
        view.willOpenMenu(menu, with: event)
        let save = try XCTUnwrap(menu.items.first { $0.title == "Save Link As…" })
        view.contextLink = URL(string: "https://example.test/later")!
        _ = view.perform(try XCTUnwrap(save.action), with: save)
        XCTAssertEqual(saved, clicked)
        XCTAssertFalse(opened)
    }

    func testSaveMenuCapturesAnchorDownloadFilename() throws {
        let (view, menu, event) = fixture()
        view.rightMouseDown(with: event)
        view.receiveContextLink(["url": "https://example.test/export?id=123",
                                 "filename": "statement.csv", "at": Date().timeIntervalSince1970 * 1_000])
        view.willOpenMenu(menu, with: event)
        let save = try XCTUnwrap(menu.items.first { $0.title == "Save Link As…" })
        let request = save.representedObject as? [String: Any]
        XCTAssertEqual(request?["filename"] as? String, "statement.csv")
        var savedName: String?
        view.saveLink = { _, filename in savedName = filename }
        view.contextLink = URL(string: "https://example.test/later")!
        _ = view.perform(try XCTUnwrap(save.action), with: save)
        XCTAssertEqual(savedName, "statement.csv")
    }
    func testSaveFilenameKeepsExtensionAndHonorsServerFilename() {
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "statement.csv", server: "export", disposition: nil), "statement.csv")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "statement.csv", server: "server.csv", disposition: "attachment; filename=server.csv"), "server.csv")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "statement.csv", server: "server.csv", disposition: "attachment; filename*=UTF-8''server.csv"), "server.csv")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "statement.csv", server: "export", disposition: "attachment"), "statement.csv")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "", server: "report.txt", disposition: nil), "report.txt")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "../statement.csv", server: "export", disposition: nil), ".._statement.csv")
    }

}
