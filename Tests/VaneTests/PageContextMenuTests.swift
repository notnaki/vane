import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageContextMenuTests: XCTestCase {
    private var tab: Tab!
    private var web: LinkContextWebView!
    private var event: NSEvent!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        tab = Tab(popup: config, isPrivate: false, profileID: UUID())
        web = try XCTUnwrap(tab.web as? LinkContextWebView)
        event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }

    override func tearDown() async throws {
        let profile = tab.profileID
        tab.tearDown()
        web = nil
        tab = nil
        try await NativeFixtureProfileCleanup.release([profile])
    }

    private func withLoop(_ body: () async throws -> Void) async throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await body() } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("AppKit loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    private func nativeMenu(_ identifiers: [String]) -> NSMenu {
        let menu = NSMenu()
        for id in identifiers {
            let item = menu.addItem(withTitle: id, action: nil, keyEquivalent: "")
            item.identifier = .init("WKMenuItemIdentifier" + id)
        }
        return menu
    }

    func testPageMenuGroupsActionsAndKeepsNativeInspectAndExtensionCommands() {
        let menu = nativeMenu(["GoBack", "GoForward", "Reload", "InspectElement"])
        let inspect = menu.items.last!
        let extensionItem = menu.addItem(withTitle: "Extension command", action: nil, keyEquivalent: "")
        web.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }, [
            "Back", "Forward", "Reload", "—", "Save Page As…", "Print…", "Copy Page Address",
            "—", "Extension command", "—", "View Page Source", "Inspect"
        ])
        XCTAssertTrue(menu.items.contains { $0 === inspect })
        XCTAssertTrue(menu.items.contains { $0 === extensionItem })
        web.willOpenMenu(menu, with: event)
        XCTAssertEqual(menu.items.filter { $0.title == "Reload" }.count, 1)
    }

    func testPageMenuDoesNotInventInspectWhenWebKitOmitsIt() {
        let menu = nativeMenu([])
        web.willOpenMenu(menu, with: event)
        XCTAssertTrue(menu.items.contains { $0.title == "View Page Source" })
        XCTAssertFalse(menu.items.contains { $0.title == "Inspect" })
        XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true)
        XCTAssertFalse(menu.items.last?.isSeparatorItem ?? true)
    }

    func testImageSelectionEditingMediaAndLinkMenusKeepTheirNativeItems() {
        for id in ["CopyImage", "Copy", "Paste", "SpellingGuess", "ToggleMediaPlayState", "OpenLink"] {
            let menu = nativeMenu([id, "InspectElement"])
            let original = menu.items
            web.willOpenMenu(menu, with: event)
            XCTAssertEqual(menu.items, original, id)
            web.didCloseMenu(menu, with: event)
        }
    }

    func testUnavailableHistoryAndBlankPageActionsAreDisabled() throws {
        let menu = nativeMenu([])
        web.willOpenMenu(menu, with: event)
        menu.update()
        for title in ["Back", "Forward", "Save Page As…", "Copy Page Address"] {
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == title }).isEnabled, title)
        }
    }

    func testCopyAddressUsesClickedPageAndSurvivesMenuClosing() async throws {
        try await withLoop {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            defer { window.close() }
            try await LibraryFocusFixture.admitForeground(window)
            let url = URL(string: "https://example.test/clicked?q=one#two")!
            _ = web.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Clicked</title><p>Page</p>")
            try await compatibilityWait { self.web.url == url && !self.web.isLoading }
            let menu = nativeMenu([])
            web.willOpenMenu(menu, with: event)
            let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Page Address" })
            web.didCloseMenu(menu, with: event)
            _ = try XCTUnwrap(copy.target as? NSObject).perform(try XCTUnwrap(copy.action), with: copy)
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), url.absoluteString)
        }
    }

    func testRetiredPageMenuCannotActOnReplacementDocument() throws {
        let menu = nativeMenu([])
        web.willOpenMenu(menu, with: event)
        let reload = try XCTUnwrap(menu.items.first { $0.title == "Reload" })
        tab.tearDown()
        menu.update()
        XCTAssertFalse(reload.isEnabled)
        _ = try XCTUnwrap(reload.target as? NSObject).perform(try XCTUnwrap(reload.action), with: reload)
        XCTAssertNil(tab.existingWeb)
    }

    func testNavigationDoesNotRebindOpenMenuToTheNextDocument() async throws {
        try await withLoop {
            let url = URL(string: "https://example.test/original")!
            _ = web.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<p>Original page</p>")
            try await compatibilityWait { self.tab.currentURL == url && !self.web.isLoading }
            let menu = nativeMenu([])
            web.willOpenMenu(menu, with: event)
            menu.update()
            XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == "Reload" }).isEnabled)
            // Match didStartProvisionalNavigation's document invalidation followed by
            // the context bridge reset, which rebuilds the still-open native menu.
            tab.readingDocumentGeneration = UUID()
            web.navigationStarted()
            menu.update()
            for title in ["Reload", "Save Page As…", "Print…", "Copy Page Address", "View Page Source"] {
                XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.title == title }).isEnabled, title)
            }
        }
    }

    func testViewSourceUsesClickedTabWhenAnotherTabIsActive() async throws {
        try await withLoop {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let store = TabStore(urls: [], profileID: tab.profileID, session: [])
            let other = store.newBlankTab()
            store.tabs.append(tab)
            store.current = other.id
            store.window = window
            window.contentView = web
            defer {
                window.close()
                store.window = nil
                store.tabs.filter { $0 !== tab }.forEach { $0.tearDown() }
                store.tabs = []
                TabStore.all.removeAll { $0 === store }
            }
            let url = URL(string: "https://example.test/source")!
            _ = web.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<p>Clicked source marker</p>")
            try await LibraryFocusFixture.admitForeground(window)
            try await compatibilityWait {
                window.isVisible && self.web.window === window && self.web.url == url && !self.web.isLoading
            }
            let menu = nativeMenu([])
            web.willOpenMenu(menu, with: event)
            menu.update()
            let source = try XCTUnwrap(menu.items.first { $0.title == "View Page Source" })
            XCTAssertTrue(source.isEnabled)
            _ = try XCTUnwrap(source.target as? NSObject).perform(try XCTUnwrap(source.action), with: source)
            try await compatibilityWait { store.tabs.count == 3 && store.active?.web.isLoading == false }
            let content = try await store.active?.web.evaluateJavaScript("document.body.textContent") as? String
            XCTAssertTrue(content?.contains("Clicked source marker") == true)
            XCTAssertEqual(other.currentURL, nil, "The unrelated active tab must remain blank")
        }
    }
}
