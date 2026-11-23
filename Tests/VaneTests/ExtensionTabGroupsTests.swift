import AppKit
import WebKit
import XCTest
@testable import vane

/// `chrome.tabGroups`, `tabs.group` and `tabs.ungroup` are Vane's own, over Today's
/// folders: a script in the extension's worker and pages, and requests the host intercepts.
@MainActor final class ExtensionTabGroupsTests: XCTestCase {
    private var profile = UUID()
    private var folder: URL!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("extension-tab-groups-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Group Fixture","version":"1.0","permissions":["tabGroups"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        try Data().write(to: folder.appendingPathComponent("worker.js"))
        try Data("<title>Fixture page</title>".utf8).write(to: folder.appendingPathComponent("page.html"))
    }

    override func tearDown() async throws {
        ExtensionHost.forget(profile)
        for store in TabStore.all.filter({ $0.profileID == profile || $0.isPrivate }) {
            store.window = nil
            store.everyTab.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        windows.forEach { $0.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: folder)
        try await NativeFixtureProfileCleanup.release([profile])
    }

    private func wait(_ description: String, until ready: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(try await ready()) {
            guard ContinuousClock.now < deadline else { throw ExtensionHost.Failure("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func run(_ script: String, in page: WKWebView) async throws -> String? {
        try await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? String
    }

    /// A browser window as the host counts one: a store with a window, not parked.
    private func browser(private isPrivate: Bool = false) -> TabStore {
        let store = TabStore(isPrivate: isPrivate, profileID: profile, session: [])
        let window = NSWindow(contentRect: NSRect(x: 120, y: 150, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        store.window = window
        windows.append(window)
        return store
    }

    private func page(_ context: WKWebExtensionContext) async throws -> WKWebView {
        let page = WKWebView(frame: .zero, configuration: try XCTUnwrap(context.webViewConfiguration))
        page.load(URLRequest(url: context.baseURL.appendingPathComponent("page.html")))
        try await wait("extension page") { !page.isLoading && page.title == "Fixture page" }
        return page
    }

    func testBridgeRequestsBelongToTheOwningExtensionOnly() throws {
        let base = URL(string: "webkit-extension://abc/")!
        let request = try XCTUnwrap(ExtensionDebuggerAPI.Request(
            URL(string: "webkit-extension://abc/__vane_tab_groups__?op=update&groupId=3&title=Two+words"), base: base,
            path: ExtensionTabGroupsAPI.bridgePath))
        XCTAssertEqual(request.operation, "update")
        XCTAssertEqual(request.values["title"], "Two words")
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "webkit-extension://abc/__vane_tab_groups__?op=get"), base: base),
                     "Not the debugger's")
        XCTAssertNil(ExtensionDebuggerAPI.Request(URL(string: "webkit-extension://other/__vane_tab_groups__?op=get"), base: base,
                                                  path: ExtensionTabGroupsAPI.bridgePath))
        XCTAssertTrue(ExtensionTabGroupsAPI.declared(["permissions": ["tabGroups"]]))
        XCTAssertFalse(ExtensionTabGroupsAPI.declared(["optional_permissions": ["tabGroups"]]))
        // Saved before groups existed, a folder still decodes, as the user's own.
        let old = try JSONDecoder().decode(Folder.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old","icon":"folder","collapsed":false}"#.utf8))
        XCTAssertNil(old.extensionOwner)
        XCTAssertNil(old.groupColor)
    }

    func testAnExtensionGroupsTodayTabsIntoItsOwnFolders() async throws {
        let store = browser()
        let a = store.newBlankTab(), b = store.newBlankTab(), c = store.newBlankTab(), d = store.newBlankTab()
        let pinned = store.newBlankTab(as: .pinned)
        // The user's own folder, holding `c`.
        let mine = try XCTUnwrap(store.newFolder(from: c.id, in: \.todayShape))
        store.renamingFolder = nil
        store.todayShape.edit(folder: mine.id) { $0.name = "Mine" }

        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        XCTAssertEqual((host.entries.first?.compatibility ?? []).filter { $0.hasPrefix("tabGroups") }.count, 1)
        host.sync()
        let page = try await page(context)
        defer { page.stopLoading() }

        // Tab ids by Vane tab, through the index WebKit reports.
        _ = try await run("""
            window.events = [];
            for (const name of ['Created', 'Updated', 'Removed', 'Moved'])
              chrome.tabGroups['on' + name].addListener(group => events.push(name + ':' + group.id + ':' + group.title));
            window.ids = (await chrome.tabs.query({})).sort((x, y) => x.index - y.index).map(tab => tab.id);
            window.failure = promise => promise.then(() => 'resolved', error => error.message);
            return 'ready';
            """, in: page)
        func id(_ tab: Tab) throws -> String {
            String(try XCTUnwrap(store.accessibleTabs.firstIndex { $0 === tab }))
        }
        let (ia, ib, ic, id_, ip) = (try id(a), try id(b), try id(c), try id(d), try id(pinned))

        // Grouping makes a folder the extension owns, beside the tab, holding both tabs.
        let made = try await run("return String(await chrome.tabs.group({tabIds: [ids[\(ia)], ids[\(ib)]]}))", in: page)
        let number = try XCTUnwrap(made.flatMap(Int.init))
        let owned = try XCTUnwrap(store.todayShape.entries.compactMap(\.folder).first { $0.extensionOwner != nil })
        XCTAssertEqual(host.tabGroups.number(for: owned.id), number)
        XCTAssertEqual(store.todayShape.tabs(in: owned.id), [a.id.uuidString, b.id.uuidString])
        XCTAssertEqual(store.todayShape.folder(holding: c.id.uuidString)?.id, mine.id, "The user's folder is untouched")
        XCTAssertEqual(store.tabs.count, 5, "Bridge requests never become tabs")

        // Update and read back, in Chrome's shapes.
        let updated = try await run("""
            const group = await chrome.tabGroups.update(\(number), {title: 'Claude', color: chrome.tabGroups.Color.ORANGE, collapsed: true});
            const windowId = (await chrome.tabs.get(ids[\(ia)])).windowId;
            const got = await chrome.tabGroups.get(\(number));
            return JSON.stringify([group.title, group.color, group.collapsed, group.windowId === windowId, got.title, got.shared]);
            """, in: page)
        XCTAssertEqual(updated, #"["Claude","orange",true,true,"Claude",false]"#)
        XCTAssertEqual(store.todayShape.folder(owned.id)?.name, "Claude")
        XCTAssertEqual(store.todayShape.folder(owned.id)?.collapsed, true)
        XCTAssertEqual(store.todayShape.folder(owned.id)?.groupColor, "orange")

        // Tabs carry their group; queries filter on it; the user's folder is a group too.
        let membership = try await run("""
            const inGroup = (await chrome.tabs.query({groupId: \(number)})).map(tab => tab.id).sort((x, y) => x - y);
            const loose = (await chrome.tabs.query({groupId: chrome.tabGroups.TAB_GROUP_ID_NONE})).map(tab => tab.id);
            const all = await chrome.tabGroups.query({});
            const titled = await chrome.tabGroups.query({title: 'Cla*', color: 'orange'});
            return JSON.stringify([(await chrome.tabs.get(ids[\(ia)])).groupId === \(number),
              JSON.stringify(inGroup) === JSON.stringify([ids[\(ia)], ids[\(ib)]].sort((x, y) => x - y)),
              loose.includes(ids[\(id_)]) && loose.includes(ids[\(ip)]) && !loose.includes(ids[\(ic)]),
              all.map(group => group.title).sort(), titled.length]);
            """, in: page)
        XCTAssertEqual(membership, #"[true,true,true,["Claude","Mine"],1]"#)

        // The user's folder and the pinned row stay the user's.
        let refused = try await run("""
            const mine = (await chrome.tabs.get(ids[\(ic)])).groupId;
            return [await failure(chrome.tabGroups.update(mine, {title: 'Taken'})),
                    await failure(chrome.tabs.group({tabIds: ids[\(ic)]})),
                    await failure(chrome.tabs.group({tabIds: ids[\(id_)], groupId: mine})),
                    await failure(chrome.tabs.ungroup(ids[\(ic)])),
                    await failure(chrome.tabs.group({tabIds: ids[\(ip)]})),
                    await failure(chrome.tabGroups.update(\(number), {color: 'beige'})),
                    await failure(chrome.tabGroups.get(9999))].join('\\n');
            """, in: page)
        let user = "“Mine” is a folder the user made. Extensions may change only the folders extensions made."
        XCTAssertEqual(refused?.components(separatedBy: "\n"), [
            user, user, user, user,
            "Vane groups only Today tabs. Pinned tabs and Favourites stay where the user put them.",
            "Invalid color: beige.", "No group with id: 9999."])
        XCTAssertEqual(store.todayShape.folder(mine.id)?.name, "Mine")
        XCTAssertEqual(store.todayShape.tabs(in: mine.id), [c.id.uuidString])
        XCTAssertEqual(pinned.kind, .pinned)

        // Adding to the group, moving it to the end of Today, then emptying it.
        let moved = try await run("""
            await chrome.tabs.group({tabIds: ids[\(id_)], groupId: \(number)});
            const group = await chrome.tabGroups.move(\(number), {index: -1});
            return String(group.id);
            """, in: page)
        XCTAssertEqual(moved, String(number))
        XCTAssertEqual(store.todayShape.tabs(in: owned.id).count, 3)
        XCTAssertEqual(store.tabs.last?.kind, .today)
        XCTAssertTrue(store.todayShape.tabs(in: owned.id).contains(try XCTUnwrap(store.tabs.last).id.uuidString),
                      "The group's tabs are last in the strip")
        let emptied = try await run("""
            await chrome.tabs.ungroup([ids[\(ia)], ids[\(ib)]]);
            const left = await chrome.tabGroups.get(\(number)).then(() => 'kept', () => 'gone');
            await chrome.tabs.ungroup(ids[\(id_)]);
            return left + '|' + await failure(chrome.tabGroups.get(\(number)));
            """, in: page)
        XCTAssertEqual(emptied, "kept|No group with id: \(number).")
        XCTAssertNil(store.todayShape.folder(owned.id), "An extension's empty folder goes, as an empty group does")
        XCTAssertEqual(store.todayShape.folder(mine.id)?.name, "Mine", "The user's folder stays")
        XCTAssertEqual(store.tabs.count, 5)

        try await wait("events") {
            (try await run("return events.join(',')", in: page))?.contains("Removed:\(number)") == true
        }
        let events = try await run("return events.join(',')", in: page)
        XCTAssertEqual(events, "Created:\(number):Group Fixture,Updated:\(number):Claude,Moved:\(number):Claude,Removed:\(number):Claude")

        // A tab of a private window is not this profile's to group.
        let privateStore = browser(private: true)
        let secret = privateStore.newBlankTab()
        XCTAssertFalse(context.hasAccessToPrivateData)
        XCTAssertThrowsError(try host.tabGroups.groupable(host.adapter(for: secret, in: privateStore), for: context))
        XCTAssertTrue(privateStore.todayShape.entries.compactMap(\.folder).isEmpty)
    }

    func testAnExtensionWithoutThePermissionHasNoTabGroups() async throws {
        try Data(#"{"manifest_version":3,"name":"Group Fixture","version":"1.0","optional_permissions":["tabGroups"],"background":{"service_worker":"worker.js"}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        let store = browser()
        _ = store.newBlankTab()
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        host.sync()
        let page = try await page(context)
        defer { page.stopLoading() }
        let denied = try await run("""
            return typeof chrome.tabGroups + '|' + typeof chrome.tabs.group + '|' + await chrome.tabs.create({url: chrome.runtime.getURL('/__vane_tab_groups__?op=get&groupId=1')})
                .then(() => 'answered', error => error.message);
            """, in: page)
        XCTAssertEqual(denied, "undefined|undefined|Invalid call to tabs.create(). This extension has not requested the tabGroups permission.")
        XCTAssertEqual(store.tabs.count, 1)
    }
}
