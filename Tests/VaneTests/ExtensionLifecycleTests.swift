import AppKit
import WebKit
import XCTest
@testable import vane

/// XCTest's command-line host cannot acquire WindowServer key focus. Only that native
/// focus bit is controlled here; NSEvent matching, profile routing, text responders,
/// controller dispatch, and JavaScript listeners all run through production APIs.
@MainActor private final class ExtensionKeyboardWindow: NSWindow {
    var keyboardFocused = false
    override var isKeyWindow: Bool { keyboardFocused }
}

@MainActor final class ExtensionLifecycleTests: XCTestCase {
    private var profile: UUID!
    private var folder: URL!
    private var views: [WKWebView] = []
    private var stores: [TabStore] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        profile = UUID()
        folder = Store.directory.appendingPathComponent("lifecycle-extension-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Lifecycle Fixture","version":"1.0","description":"Runtime integration fixture","permissions":["tabs"],"options_ui":{"page":"options.html"},"commands":{"fixture":{"suggested_key":{"mac":"Command+Shift+Y"},"description":"Fixture command"}}}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("<title>Lifecycle fixture</title>".utf8).write(to: folder.appendingPathComponent("options.html"))
    }

    override func tearDown() async throws {
        views.forEach { $0.stopLoading() }; views.removeAll()
        ExtensionHost.forget(profile)
        windows.forEach { $0.orderOut(nil); $0.contentView = nil }
        for store in stores {
            if store.profileID != profile { ExtensionHost.forget(store.profileID) }
            store.window = nil
            TabStore.all.removeAll { $0 === store }
            store.everyTab.forEach { $0.tearDown() }
        }
        stores.removeAll(); windows.removeAll()
        ScopedPaths.remove(path: folder.path, from: ExtensionHost.key(for: profile))
        ExtensionConsent.remove(for: folder, profileID: profile)
        try? FileManager.default.removeItem(at: folder)
    }

    private func fixture() async throws -> (ExtensionHost, WKWebExtensionContext, WKWebView) {
        let host = ExtensionHost.host(for: profile)
        _ = try await host.load(folder, installing: true) { _ in true }
        let context = try XCTUnwrap(host.installed.first)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: try XCTUnwrap(context.webViewConfiguration))
        views.append(web)
        web.load(URLRequest(url: try XCTUnwrap(context.optionsPageURL)))
        let deadline = ContinuousClock.now + .seconds(10)
        while web.isLoading || web.title != "Lifecycle fixture" {
            if ContinuousClock.now >= deadline { throw ExtensionHost.Failure("Timed out loading lifecycle fixture") }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("window.events = []; for (const type of ['onMoved','onHighlighted','onRemoved','onActivated']) browser.tabs[type].addListener((...args) => window.events.push({type,args}));")
        return (host, context, web)
    }

    private func browser() -> TabStore {
        let store = TabStore(profileID: profile, session: [])
        let window = ExtensionKeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentLayoutRect)
        store.window = window
        stores.append(store); windows.append(window)
        return store
    }

    private func events(_ web: WKWebView) async throws -> [[String: Any]] {
        try await Task.sleep(for: .milliseconds(150))
        return try await web.evaluateJavaScript("window.events") as? [[String: Any]] ?? []
    }

    func testReorderSelectionAndWindowCloseReachJavaScriptListeners() async throws {
        let (host, _, web) = try await fixture()
        let store = browser()
        let first = store.newBlankTab(), second = store.newBlankTab()
        host.sync()
        _ = try await events(web)
        _ = try await web.evaluateJavaScript("window.events=[]")
        store.tabs = [second, first]
        store.current = first.id
        host.sync()
        let changes = try await events(web)
        XCTAssertTrue(changes.contains { $0["type"] as? String == "onMoved" }, "Reordering must emit tabs.onMoved")
        XCTAssertTrue(changes.contains { $0["type"] as? String == "onHighlighted" }, "Changing active selection must emit tabs.onHighlighted")
        _ = try await web.evaluateJavaScript("window.events=[]")
        TabStore.all.removeAll { $0 === store }
        host.sync()
        let removed = try await events(web).filter { $0["type"] as? String == "onRemoved" }
        XCTAssertEqual(removed.count, 2)
        for event in removed {
            let args = try XCTUnwrap(event["args"] as? [Any])
            XCTAssertEqual((args.last as? [String: Any])?["isWindowClosing"] as? Bool, true)
        }
    }

    func testCommandEventReachesOnlyEnabledOriginatingProfileIncludingTextEntry() async throws {
        let (host, context, web) = try await fixture()
        let store = browser()
        _ = store.newBlankTab()
        let window = try XCTUnwrap(store.window)
        window.makeKeyAndOrderFront(nil)
        (window as? ExtensionKeyboardWindow)?.keyboardFocused = true
        _ = try await web.evaluateJavaScript("window.commands=[]; browser.commands.onCommand.addListener(name => window.commands.push(name));")
        let command = try XCTUnwrap(context.commands.first { $0.id == "fixture" })
        XCTAssertEqual(command.activationKey?.lowercased(), "y")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
        XCTAssertTrue(ExtensionCommands.handle(event), "A registered extension shortcut must execute")
        try await Task.sleep(for: .milliseconds(100))
        let received = try await web.evaluateJavaScript("window.commands") as? [String]
        XCTAssertEqual(received, ["fixture"])
        let editor = NSTextView(frame: .zero)
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        XCTAssertTrue(ExtensionCommands.handle(event), "Modified extension commands must work in native login fields")
        try await Task.sleep(for: .milliseconds(100))
        let editorReceived = try await web.evaluateJavaScript("window.commands") as? [String]
        XCTAssertEqual(editorReceived, ["fixture", "fixture"])
        window.makeFirstResponder(window.contentView)
        let other = ExtensionKeyboardWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        windows.append(other)
        let otherEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: other.windowNumber, context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
        XCTAssertFalse(ExtensionCommands.handle(otherEvent), "A non-browser window cannot trigger commands in another window")
        (window as? ExtensionKeyboardWindow)?.keyboardFocused = false
        other.makeKeyAndOrderFront(nil)
        other.keyboardFocused = true
        XCTAssertFalse(ExtensionCommands.handle(event), "An event from an inactive browser must not act on the focused window")
        let otherStore = TabStore(profileID: UUID(), session: [])
        otherStore.window = other
        _ = otherStore.newBlankTab()
        stores.append(otherStore)
        XCTAssertFalse(ExtensionCommands.handle(otherEvent), "A browser in another profile must not dispatch this profile’s extension command")
        other.keyboardFocused = false
        window.makeKeyAndOrderFront(nil)
        (window as? ExtensionKeyboardWindow)?.keyboardFocused = true
        try host.disable(folder.path)
        XCTAssertFalse(ExtensionCommands.handle(event), "Disabled contexts cannot receive commands")
    }

    func testCommandConflictDisclosureAndWebsiteEditorSupport() async throws {
        let (_, context, _) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        let window = try XCTUnwrap(store.window)
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tab.web)
        (window as? ExtensionKeyboardWindow)?.keyboardFocused = true
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "Y", charactersIgnoringModifiers: "Y", isARepeat: false, keyCode: 16))
        tab.editableFrames = ["focused-frame"]
        XCTAssertTrue(ExtensionCommands.handle(event), "Modified extension commands must work in webpage login fields")
        tab.editableFrames = []
        let command = try XCTUnwrap(context.commands.first { $0.id == "fixture" })
        command.activationKey = "t"
        command.modifierFlags = [.command]
        let description = try XCTUnwrap(ExtensionCommands.descriptors(for: context).first { $0.id == "fixture" })
        XCTAssertEqual(description.shortcut, "⌘T")
        XCTAssertTrue(description.conflict?.contains("New Tab") == true)
        let browserEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertFalse(ExtensionCommands.handle(browserEvent), "Vane shortcut reservation applies even if its action is unavailable")
        command.activationKey = "c"
        let copy = try XCTUnwrap(ExtensionCommands.descriptors(for: context).first { $0.id == "fixture" })
        XCTAssertTrue(copy.conflict?.contains("Copy") == true, "Native editing chords stay reserved independently of menu construction")
        let copyEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        tab.editableFrames = ["focused-frame"]
        XCTAssertFalse(ExtensionCommands.handle(copyEvent))
    }

    func testOptionShortcutUsesWebKitMatchingWhileProtectingTextEntry() async throws {
        let (_, context, web) = try await fixture()
        let store = browser()
        _ = store.newBlankTab()
        let window = try XCTUnwrap(store.window as? ExtensionKeyboardWindow)
        window.keyboardFocused = true
        let command = try XCTUnwrap(context.commands.first { $0.id == "fixture" })
        command.activationKey = "k"
        command.modifierFlags = [.option, .shift]
        _ = try await web.evaluateJavaScript("window.commands=[]; browser.commands.onCommand.addListener(name => window.commands.push(name));")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "K", charactersIgnoringModifiers: "K", isARepeat: false, keyCode: 40))
        XCTAssertNotNil(context.command(for: event), "The public WebKit matcher accepts this shortcut")
        XCTAssertTrue(ExtensionCommands.handle(event))
        try await Task.sleep(for: .milliseconds(100))
        let received = try await web.evaluateJavaScript("window.commands") as? [String]
        XCTAssertEqual(received, ["fixture"])
        let field = NSTextView(frame: .zero)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertFalse(ExtensionCommands.handle(event))
    }

    func testNativeTabMenuItemsDispatchToExtensionAndDisappearWhenDisabled() async throws {
        let manifest = #"{"manifest_version":3,"name":"Lifecycle Fixture","version":"1.0","description":"Native menu fixture","permissions":["tabs","contextMenus"],"options_ui":{"page":"options.html"}}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        let (host, context, web) = try await fixture()
        let store = browser()
        let tab = store.newBlankTab()
        host.sync()
        let exposed = try await web.evaluateJavaScript("typeof browser.contextMenus") as? String
        XCTAssertEqual(exposed, "object", "Public WebKit page menus must not be hidden by Vane")
        guard exposed == "object" else { return }
        _ = try await web.callAsyncJavaScript("""
            window.clicks=[];
            browser.contextMenus.onClicked.addListener(info => window.clicks.push(info.menuItemId));
            await browser.contextMenus.create({id:'page-fixture',title:'Fixture page command',contexts:['page']});
            await browser.contextMenus.create({id:'tab-fixture',title:'Fixture tab command',contexts:['tab']});
            return true;
            """, arguments: [:], in: nil, contentWorld: .page)
        let items = context.menuItems(for: host.adapter(for: tab, in: store))
        func find(_ items: [NSMenuItem]) -> (NSMenu, Int)? {
            for item in items {
                if let menu = item.submenu {
                    if let index = menu.items.firstIndex(where: { $0.title == "Fixture tab command" }) { return (menu, index) }
                    if let nested = find(menu.items) { return nested }
                }
            }
            return nil
        }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        let action = menu.items.firstIndex { $0.title == "Fixture tab command" }.map { (menu, $0) } ?? find(items)
        let (container, index) = try XCTUnwrap(action, "WebKit must produce the native tab item")
        container.performActionForItem(at: index)
        try await Task.sleep(for: .milliseconds(100))
        let clicked = try await web.evaluateJavaScript("window.clicks") as? [String]
        XCTAssertEqual(clicked, ["tab-fixture"])
        try host.disable(folder.path)
        XCTAssertTrue(context.menuItems(for: host.adapter(for: tab, in: store)).isEmpty)
    }

    func testSidebarMultiselectionIsExposedToExtensions() async throws {
        let (host, context, _) = try await fixture()
        let store = browser()
        let first = store.newBlankTab(), second = store.newBlankTab()
        store.current = first.id
        store.toggleSelection(second.id)
        XCTAssertTrue(host.adapter(for: first, in: store).isSelected(for: context))
        XCTAssertTrue(host.adapter(for: second, in: store).isSelected(for: context), "Sidebar selection must match browser.tabs highlighted queries")
    }

    func testExtensionSelectionUsesSidebarMultiselectionWithoutActivatingAnotherTab() async throws {
        let (host, context, _) = try await fixture()
        let store = browser()
        let first = store.newBlankTab(), second = store.newBlankTab()
        store.current = first.id
        let adapter = host.adapter(for: second, in: store)
        try await adapter.setSelected(true, for: context)
        XCTAssertEqual(store.current, first.id, "Highlighting a tab is separate from activating it")
        XCTAssertTrue(store.selection.contains(second.id))
        XCTAssertTrue(host.adapter(for: first, in: store).isSelected(for: context))
        try await adapter.setSelected(false, for: context)
        XCTAssertFalse(store.selection.contains(second.id))
        XCTAssertTrue(host.adapter(for: first, in: store).isSelected(for: context))
    }

    func testMovingTabPreservesAdapterIdentityAndRebindsItsWindow() async throws {
        let (host, context, _) = try await fixture()
        let source = browser(), destination = browser()
        let tab = source.newBlankTab()
        host.sync()
        let before = host.adapter(for: tab, in: source)
        source.tabs.removeAll { $0 === tab }
        destination.tabs.append(tab)
        destination.current = tab.id
        host.sync()
        let after = host.adapter(for: tab, in: destination)
        XCTAssertTrue(before === after, "Moving must preserve the WebKit tab identity")
        XCTAssertTrue((after.window(for: context) as? ExtWindow)?.store === destination)
        XCTAssertEqual(after.indexInWindow(for: context), 0)
        TabStore.all.removeAll { $0 === destination }
        host.sync()
        XCTAssertNil(after.window(for: context), "A retained adapter must not expose a closed browser")
        XCTAssertNil(after.url(for: context))
    }

    func testOptionsActionReusesWindowAndDisabledContextCannotOpenIt() async throws {
        let (host, context, _) = try await fixture()
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        let first = try XCTUnwrap(NSApp.windows.first { $0.title == "Lifecycle Fixture" && $0.isVisible })
        try await host.webExtensionController(host.controller, openOptionsPageFor: context)
        XCTAssertEqual(NSApp.windows.filter { $0.title == "Lifecycle Fixture" && $0.isVisible }.count, 1)
        try host.disable(folder.path)
        XCTAssertFalse(first.isVisible)
        do {
            try await host.webExtensionController(host.controller, openOptionsPageFor: context)
            XCTFail("Disabled options contexts must reject requests")
        } catch { }
    }
}
