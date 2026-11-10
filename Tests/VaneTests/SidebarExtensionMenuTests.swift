import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

/// Synthetic extensions and unshown windows only. No key focus, event injection,
/// screenshots, personal profiles, or credentials are used by these fixtures.
@MainActor final class SidebarExtensionMenuTests: XCTestCase {
    private var profile = UUID()
    private var folder: URL!
    private var stores: [TabStore] = []
    private var windows: [NSWindow] = []
    private var pages: [WKWebView] = []
    private var profiles = Set<UUID>()

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profiles.insert(profile)
        folder = Store.directory.appendingPathComponent("sidebar-menus-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Sidebar Fixture","version":"1.0","description":"Synthetic sidebar menus","permissions":["tabs","contextMenus","activeTab"],"options_ui":{"page":"options.html"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Sidebar fixture</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    override func tearDown() async throws {
        pages.forEach { $0.stopLoading() }; pages.removeAll()
        profiles.forEach(ExtensionHost.forget)
        for store in stores {
            store.everyTab.forEach { $0.tearDown() }
            store.window = nil
            TabStore.all.removeAll { $0 === store }
        }
        windows.forEach { $0.contentView = nil; $0.close() }
        windows.removeAll(); stores.removeAll()
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        ExtensionConsent.remove(for: folder, profileID: profile)
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release(profiles)
    }

    private func browser(profile id: UUID? = nil) -> TabStore {
        let id = id ?? profile
        profiles.insert(id)
        let store = TabStore(profileID: id, session: [])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        stores.append(store); windows.append(window)
        return store
    }

    private func fixture(menuAPI: String = "contextMenus") async throws -> (ExtensionHost, WKWebExtensionContext, WKWebView) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        pages.append(page)
        page.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(10)
        while page.isLoading || page.title != "Sidebar fixture" {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Sidebar fixture did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await page.callAsyncJavaScript("""
            window.clicks=[];
            browser.\(menuAPI).onClicked.addListener((info,tab) => window.clicks.push({id:info.menuItemId,tab:tab.id}));
            await browser.\(menuAPI).create({id:'tab',title:'Sidebar command',contexts:['tab']});
            await browser.\(menuAPI).create({id:'page',title:'Page command',contexts:['page']});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        return (host, context, page)
    }

    private func find(_ title: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = find(title, in: submenu) { return found }
        }
        return nil
    }

    private func sidebarMenu(_ tab: vane.Tab, in store: TabStore) -> NSMenu {
        let menu = NSHostingMenu(rootView: TabMenu(store: store, tab: tab))
        menu.update()
        return menu
    }

    private func clicks(_ page: WKWebView, count: Int) async throws -> [[String: Any]] {
        let deadline = ContinuousClock.now + .seconds(2)
        while true {
            let result = try await page.evaluateJavaScript("window.clicks") as? [[String: Any]] ?? []
            if result.count >= count || ContinuousClock.now >= deadline { return result }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testSidebarMenuDispatchesClickedUnselectedTabAfterSelectionChanges() async throws {
        let (host, context, page) = try await fixture()
        let store = browser()
        let clicked = store.newBlankTab(), selected = store.newBlankTab(), later = store.newBlankTab()
        store.current = selected.id
        host.sync()
        let tabs = try await page.callAsyncJavaScript("return (await browser.tabs.query({})).map(t => ({id:t.id,index:t.index}));", arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        let expected = try XCTUnwrap(tabs?.first { ($0["index"] as? Int) == 0 }?["id"] as? Int)
        let menu = sidebarMenu(clicked, in: store)
        XCTAssertNotNil(find("Reload", in: menu), "Core tab commands must remain available")
        XCTAssertNil(find("Page command", in: menu), "Only tab-context extension items belong in the sidebar")
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu), "The real sidebar menu must include extension commands")
        XCTAssertFalse(context.hasActiveUserGesture(in: host.adapter(for: clicked, in: store)), "Opening a menu must not manufacture activeTab rights")
        store.current = later.id
        host.sync()
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["tab"] as? Int, expected)
        XCTAssertEqual(result.first?["id"] as? String, "tab")
        XCTAssertEqual(store.current, later.id, "A tab menu action must not activate its subject")
        XCTAssertFalse(context.hasActiveUserGesture(in: host.adapter(for: later, in: store)), "The menu must not grant a gesture to the newly selected tab")
    }

    func testRetainedSidebarActionRefusesClosedTab() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        _ = store.newBlankTab()
        host.sync()
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu))
        store.close(tab.id)
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertTrue(result.isEmpty, "A retained menu cannot dispatch for a closed tab")
    }

    func testRetainedSidebarActionRefusesUnloadedExtension() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu))
        try host.disable(folder.path)
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertTrue(result.isEmpty, "An unloaded context cannot receive retained commands")
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(tab, in: store)))
    }

    func testSidebarMenusKeepProfilesAndPrivateTabsIsolated() async throws {
        let (host, _, _) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        XCTAssertNotNil(find("Sidebar command", in: sidebarMenu(tab, in: store)))
        let other = browser(profile: UUID())
        let foreign = other.newBlankTab()
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(foreign, in: other)))
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(foreign, in: store)), "Mismatched row identity must be rejected")
        let privateTab = vane.Tab(isPrivate: true, profileID: profile)
        store.tabs.append(privateTab)
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(privateTab, in: store)), "Private tabs cannot borrow a normal store's contexts")
    }

    func testSidebarMenuPreservesNestedDisabledItemsAndRefreshesAtNextOpening() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        _ = try await page.callAsyncJavaScript("""
            await browser.contextMenus.removeAll();
            await browser.contextMenus.create({id:'parent',title:'Nested actions',contexts:['tab']});
            await browser.contextMenus.create({id:'nested',parentId:'parent',title:'Nested command',contexts:['tab']});
            await browser.contextMenus.create({id:'disabled',title:'Disabled command',contexts:['tab'],enabled:false});
            await browser.contextMenus.create({id:'hidden',title:'Hidden command',contexts:['tab'],visible:false});
            await browser.contextMenus.create({id:'empty',title:'Empty actions',contexts:['tab']});
            await browser.contextMenus.create({id:'hidden-child',parentId:'empty',title:'Hidden child',contexts:['tab'],visible:false});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let menu = sidebarMenu(tab, in: store)
        let (disabledMenu, disabledIndex) = try XCTUnwrap(find("Disabled command", in: menu))
        XCTAssertFalse(disabledMenu.item(at: disabledIndex)!.isEnabled)
        disabledMenu.performActionForItem(at: disabledIndex)
        XCTAssertNil(find("Hidden command", in: menu))
        XCTAssertNil(find("Empty actions", in: menu), "Submenus with only hidden children must be omitted")
        let (nestedMenu, nestedIndex) = try XCTUnwrap(find("Nested command", in: menu))
        nestedMenu.performActionForItem(at: nestedIndex)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.compactMap { $0["id"] as? String }, ["nested"])
        _ = try await page.callAsyncJavaScript("await browser.contextMenus.removeAll(); return true;",
            arguments: [:], in: nil, contentWorld: .page)
        let empty = sidebarMenu(tab, in: store)
        XCTAssertNil(find("Nested actions", in: empty))
        XCTAssertNotNil(find("Reload", in: empty))
        XCTAssertFalse(empty.items.last?.isSeparatorItem ?? true, "No empty extension group or trailing separator")
    }


    func testSplitContainerMenuTargetsItsOwnActivePaneAfterSelectionChanges() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let first = store.newBlankTab(), active = store.newBlankTab(), unrelated = store.newBlankTab()
        let split = try XCTUnwrap(Split(tabs: [first.id, active.id])).focusing(active.id)
        store.splits = [split]
        store.current = unrelated.id
        host.sync()
        let tabs = try await page.callAsyncJavaScript("return (await browser.tabs.query({})).map(t => ({id:t.id,index:t.index}));",
            arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        let expected = try XCTUnwrap(tabs?.first { ($0["index"] as? Int) == 1 }?["id"] as? Int)
        let menu = NSHostingMenu(rootView: SplitMenu(store: store, split: split))
        menu.update()
        XCTAssertNotNil(find("Swap", in: menu))
        XCTAssertNotNil(find("Separate All Tabs", in: menu))
        XCTAssertNotNil(find("Close Split View", in: menu))
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu), "A split's menu must expose its active pane's extension commands")
        store.splits = [split.focusing(first.id)]
        store.current = first.id
        host.sync()
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.first?["tab"] as? Int, expected, "Changing the split's selection must not retarget an open menu")
    }

    func testNonTabAndParkedProfileRowsDoNotExposeExtensionCommands() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        let noTab = NSHostingMenu(rootView: SidebarExtensionMenu(store: store, tab: nil))
        noTab.update()
        XCTAssertTrue(noTab.items.isEmpty)
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu))
        store.profileVisible = false
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertTrue(result.isEmpty, "A menu from a hidden profile cannot retain authority")
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(tab, in: store)))
    }


    func testBulkSidebarMenuKeepsCoreCommandsAndTargetsOnlyClickedPane() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let lead = store.newBlankTab(), clicked = store.newBlankTab(), other = store.newBlankTab()
        store.splits = [try XCTUnwrap(Split(tabs: [lead.id, clicked.id]))]
        store.current = lead.id
        store.toggleSelection(other.id)
        host.sync()
        let tabs = try await page.callAsyncJavaScript("return (await browser.tabs.query({})).map(t => ({id:t.id,index:t.index}));",
            arguments: [:], in: nil, contentWorld: .page) as? [[String: Any]]
        let expected = try XCTUnwrap(tabs?.first { ($0["index"] as? Int) == 1 }?["id"] as? Int)
        let menu = NSHostingMenu(rootView: SidebarTabContextMenu(store: store, tab: clicked))
        menu.update()
        XCTAssertNotNil(find("Copy 2 Links", in: menu), "The selected rows keep their existing bulk commands")
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu), "Bulk menus must offer extension commands for the clicked pane")
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["tab"] as? Int, expected)
    }


    func testCheckedExtensionItemPreservesCheckStateAndNativeToggleDispatch() async throws {
        let (host, _, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        _ = try await page.callAsyncJavaScript("""
            await browser.contextMenus.removeAll();
            window.checked=[];
            browser.contextMenus.onClicked.addListener(info => window.checked.push(info.checked));
            await browser.contextMenus.create({id:'checked',title:'Checked command',type:'checkbox',checked:true,contexts:['tab']});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Checked command", in: menu))
        XCTAssertEqual(container.item(at: index)?.state, .on, "A checked SDK item must remain a checked menu action")
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.first?["id"] as? String, "checked")
        let checked = try await page.evaluateJavaScript("window.checked") as? [Bool]
        XCTAssertEqual(checked, [false], "WebKit, rather than a replacement browser action, must toggle the original item")
    }


    func testRetainedSidebarActionRefusesRevokedMenuPermission() async throws {
        let (host, context, page) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu))
        context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.Permission(rawValue: "contextMenus"))
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertTrue(result.isEmpty, "A retained item cannot outlive its API permission")
        XCTAssertNil(find("Sidebar command", in: sidebarMenu(tab, in: store)))
    }


    func testMixedKindSplitPaneKeepsBulkActionsForSelectedRowsSection() async throws {
        let (host, _, _) = try await fixture()
        let store = browser()
        let lead = store.newBlankTab(), favourite = store.newBlankTab(as: .favourite), other = store.newBlankTab()
        store.splits = [try XCTUnwrap(Split(tabs: [lead.id, favourite.id]))]
        store.current = lead.id
        store.toggleSelection(other.id)
        host.sync()
        let menu = NSHostingMenu(rootView: SidebarTabContextMenu(store: store, tab: favourite))
        menu.update()
        XCTAssertNotNil(find("Add 2 to Favourites", in: menu), "Bulk actions describe the selected Today rows even when the clicked pane is a favourite")
        XCTAssertNotNil(find("Archive 2 Tabs", in: menu))
        XCTAssertNotNil(find("Sidebar command", in: menu))
    }


    func testMenusPermissionAliasDispatchesThroughTheSameTabAdapter() async throws {
        let manifest = folder.appendingPathComponent("manifest.json")
        let source = try String(contentsOf: manifest, encoding: .utf8)
        try Data(source.replacingOccurrences(of: "contextMenus", with: "menus").utf8).write(to: manifest)
        let (host, _, page) = try await fixture(menuAPI: "menus")
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        let menu = sidebarMenu(tab, in: store)
        let (container, index) = try XCTUnwrap(find("Sidebar command", in: menu))
        container.performActionForItem(at: index)
        let result = try await clicks(page, count: 1)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["id"] as? String, "tab")
    }

}
