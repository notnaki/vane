import AppKit
import XCTest
@testable import vane

@MainActor final class PopupNoticeTests: XCTestCase {
    private var store: TabStore!
    private var tabs: [Tab] = []
    private var savedDuration: Any?

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        savedDuration = UserDefaults.vane.object(forKey: "toastSeconds")
        Prefs.toastSeconds = 0.05
        store = TabStore(profileID: UUID(), session: [])
    }

    override func tearDown() async throws {
        for toast in Toasts.shared.showing { Toasts.shared.dismiss(toast) }
        UserDefaults.vane.set(savedDuration, forKey: "toastSeconds")
        for tab in tabs { tab.tearDown() }
        store.everyTab.forEach { $0.tearDown() }
        TabStore.all.removeAll { $0 === store }
        tabs = []; store = nil
    }

    private func tab() -> Tab {
        let tab = Tab(profileID: store.profileID)
        tabs.append(tab)
        store.wire(tab)
        return tab
    }

    private func block(_ tab: Tab, path: String) {
        let scope = SitePermissions.Scope(url: URL(string: "https://popup.example"), profileID: store.profileID)
        tab.onPopupBlocked?(URL(string: "https://popup.example/\(path)"), scope)
    }

    func testRepeatedPopupCannotReplaceHoveredOpenActionAfterNormalExpiry() async throws {
        let source = tab()
        var opened: URL?
        source.onOpenBeside = { url, _ in opened = url }
        block(source, path: "first")
        let first = try XCTUnwrap(Toasts.shared.current)
        Toasts.shared.hover(first, true)
        try await Task.sleep(for: .milliseconds(100))
        block(source, path: "second")
        XCTAssertEqual(Toasts.shared.current?.id, first.id)
        Toasts.shared.act(first)
        XCTAssertEqual(opened?.absoluteString, "https://popup.example/first")
    }

    func testAnotherTabCannotReplaceOutstandingPopupNotice() throws {
        block(tab(), path: "first")
        let first = try XCTUnwrap(Toasts.shared.current)
        block(tab(), path: "second")
        XCTAssertEqual(Toasts.shared.current?.id, first.id)
    }

    func testPopupCannotReplaceUserActionButUserActionCanReplacePopup() throws {
        let source = tab()
        block(source, path: "first")
        let popup = try XCTUnwrap(Toasts.shared.current)
        var undone = false
        Toasts.show("Archived page", action: ("Undo", { undone = true }), in: store)
        let undo = try XCTUnwrap(Toasts.shared.current)
        XCTAssertNotEqual(undo.id, popup.id)
        block(source, path: "second")
        XCTAssertEqual(Toasts.shared.current?.id, undo.id)
        Toasts.shared.act(undo)
        XCTAssertTrue(undone)
    }

    func testPopupCanNotifyAgainAfterPreviousNoticeExpires() async throws {
        let source = tab()
        block(source, path: "first")
        let first = try XCTUnwrap(Toasts.shared.current)
        try await compatibilityWait { Toasts.shared.current == nil }
        block(source, path: "second")
        XCTAssertNotEqual(try XCTUnwrap(Toasts.shared.current).id, first.id)
    }
}
