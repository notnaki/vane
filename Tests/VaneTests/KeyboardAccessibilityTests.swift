import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import vane

@MainActor final class KeyboardAccessibilityTests: XCTestCase {
    private func fixture(isPrivate: Bool = true) -> (TabStore, NSWindow, WKWebView) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: isPrivate, profileID: UUID())
        let tab = store.newBlankTab(focus: false)
        store.current = tab.id
        store.palette = nil
        let web = tab.web
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            store.window = nil
            window.close()
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return (store, window, web)
    }

    private func key(_ text: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: text, charactersIgnoringModifiers: text,
                        isARepeat: false, keyCode: code)!
    }

    func testWebsitePriorityDoesNotRunBrowserThroughMenuFallback() throws {
        let (store, window, web) = fixture()
        let oldMenu = NSApp.mainMenu
        let oldActions = Keybindings.actions
        defer { NSApp.mainMenu = oldMenu; Keybindings.actions = oldActions }
        try XCTUnwrap(Keybindings.withScratchDefaults("keyboard-menu") {
            Keybindings.setPriority(.page, for: .toggleSidebar)
            rebuild()
            window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(web))
            XCTAssertTrue(window.firstResponder === web)
            let event = key("s", code: 1, in: window)
            let before = store.sidebarShown
            XCTAssertFalse(Keybindings.handle(event))
            XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: event),
                           "The main menu must also leave the website's shortcut alone")
            XCTAssertEqual(store.sidebarShown, before)
            // Explicit menu activation remains available regardless of website priority.
            let viewMenu = NSApp.mainMenu!.items.first { $0.title == "View" }!.submenu!
            let index = viewMenu.items.firstIndex { $0.title == "Toggle Sidebar" }!
            viewMenu.performActionForItem(at: index)
            XCTAssertEqual(store.sidebarShown, !before)
        })
    }

    func testWebsitePriorityStillRunsWhileBrowserFieldHasFocus() throws {
        let (_, window, _) = fixture()
        let field = NSTextField(string: "hello")
        window.contentView = field
        window.makeFirstResponder(field)
        let oldActions = Keybindings.actions
        defer { Keybindings.actions = oldActions }
        try XCTUnwrap(Keybindings.withScratchDefaults("keyboard-chrome") {
            Keybindings.setPriority(.page, for: .find)
            var fired = false
            Keybindings.actions[.find] = { fired = true }
            XCTAssertTrue(Keybindings.handle(key("f", code: 3, in: window)))
            XCTAssertTrue(fired)
        })
    }

    func testDeferredPageFocusDoesNotTakeFocusFromNewPalette() async throws {
        let (store, window, web) = fixture()
        window.makeFirstResponder(nil)
        store.focusPage()
        store.palette = .all
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(window.firstResponder === web,
                       "A queued dismissal must not steal focus while a new overlay mounts")
    }

    func testPageFocusWaitsForPageToMountAfterDismissal() async throws {
        let (store, window, web) = fixture()
        window.contentView = NSView()
        window.makeFirstResponder(nil)
        store.focusPage()
        try await Task.sleep(for: .milliseconds(60))
        window.contentView = web
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.firstResponder === web)
    }

    func testOpeningFindAgainReturnsFocusToExistingFindField() async throws {
        let (store, window, web) = fixture()
        let host = NSHostingView(rootView: FindBar(tab: store.active!).environmentObject(store))
        let container = NSView(frame: window.contentView!.frame)
        container.addSubview(web)
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 80)
        container.addSubview(host)
        window.contentView = container
        store.openFind()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(web)
        XCTAssertTrue(window.firstResponder === web)
        store.openFind()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder is NSTextView,
                      "Command-F must refocus a find field that is already open")
    }

    func testSidebarRowCanBeFocusedAndActivatedWithoutPointer() async throws {
        _ = NSApplication.shared
        var presses = 0
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarRow(icon: "globe", title: "Example",
                                                      selected: false) { presses += 1 })
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(nil)
        window.selectNextKeyView(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(window.firstResponder === window, "Tab must reach the sidebar row")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: " ", charactersIgnoringModifiers: " ",
                                    isARepeat: false, keyCode: 49)!
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(presses, 1, "Space activates the focused row")
    }


    func testOptionLetterShortcutLeavesTextEditingWithTheField() throws {
        let (_, window, _) = fixture()
        let field = NSTextField(string: "hello")
        window.contentView = field
        window.makeFirstResponder(field)
        let oldActions = Keybindings.actions
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu; Keybindings.actions = oldActions }
        try XCTUnwrap(Keybindings.withScratchDefaults("keyboard-option") {
            rebuild()
            var fired = false
            Keybindings.actions[.toggleDeveloperMode] = { fired = true }
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "∂", charactersIgnoringModifiers: "d",
                                        isARepeat: false, keyCode: 2)!
            XCTAssertFalse(Keybindings.handle(event), "Option-D must still type in a text field")
            XCTAssertFalse(fired)
            XCTAssertFalse(NSApp.mainMenu!.performKeyEquivalent(with: event),
                           "The menu fallback must preserve Option typing too")
        })
    }

    func testShadowRootEditorKeepsCommandArrowForItsCaret() async throws {
        let (store, window, web) = fixture()
        web.loadHTMLString("<div id='editor'></div>", baseURL: nil)
        let deadline = Date.now.addingTimeInterval(5)
        while web.isLoading, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(web.isLoading)
        _ = try await web.evaluateJavaScript("""
            const root = document.getElementById('editor').attachShadow({mode: 'open'});
            root.innerHTML = '<input value="typing">';
            root.querySelector('input').focus();
            """)
        window.makeFirstResponder(web)
        try await Task.sleep(for: .milliseconds(150))
        let oldActions = Keybindings.actions
        defer { Keybindings.actions = oldActions }
        var navigated = false
        Keybindings.actions[.back] = { navigated = true }
        let event = key("\u{F702}", code: 123, in: window)
        XCTAssertFalse(Keybindings.handle(event), "Command-Left belongs to the editor's caret")
        XCTAssertFalse(navigated)
        XCTAssertTrue(store.active!.editableFocused)
    }


    func testFirstSearchResultReceivesFocusWhenTabIsCreatedOnNextTurn() async throws {
        let (store, window, web) = fixture()
        let selected = store.current
        store.current = nil
        window.makeFirstResponder(nil)
        store.focusPage()
        DispatchQueue.main.async { store.current = selected }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.firstResponder === web,
                      "Opening the first search result must leave the page ready for the keyboard")
    }


    func testF6MovesBetweenPageAndBrowserControls() async throws {
        let (store, window, web) = fixture()
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let oldMenu = NSApp.mainMenu
        let oldActions = Keybindings.actions
        defer { NSApp.mainMenu = oldMenu; Keybindings.actions = oldActions }
        rebuild()
        let host = NSHostingView(rootView: AddressPill(tab: store.active).environmentObject(store))
        let container = NSView(frame: window.contentView!.frame)
        host.frame = NSRect(x: 0, y: 520, width: 250, height: 80)
        web.frame = NSRect(x: 250, y: 0, width: 550, height: 600)
        container.addSubview(host)
        container.addSubview(web)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(web)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                    characters: "\u{F709}", charactersIgnoringModifiers: "\u{F709}",
                                    isARepeat: false, keyCode: 97)!
        XCTAssertEqual(Keybindings.command(for: Keybinding(event: event)!), .nextFocusArea)
        XCTAssertNotNil(Keybindings.actions[.nextFocusArea])
        store.focusNextArea()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(window.firstResponder === web)
        XCTAssertFalse(window.firstResponder === window)
        store.focusNextArea()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.firstResponder === web)
        XCTAssertNil(store.palette)
    }

    func testPaletteDismissalReturnsFocusWhenFindRemainsOpen() async throws {
        let (store, window, web) = fixture()
        store.openFind()
        store.palette = .all
        // The palette removes its field on Escape while the existing Find bar stays mounted.
        window.makeFirstResponder(nil)
        store.palette = nil
        store.focusPage()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.findOpen)
        XCTAssertTrue(window.firstResponder === web)
    }

    func testF6LeavesTheLocalEaselForBrowserControls() async throws {
        let (store, window, _) = fixture(isPrivate: false)
        let tab = try XCTUnwrap(store.openEasel(create: true))
        let session = try XCTUnwrap(tab.easelSession)
        let page = EaselHostingView(rootView: EaselWorkspace(session: session, browser: store))
        let chrome = NSHostingView(rootView: AddressPill(tab: tab).environmentObject(store))
        let container = NSView(frame: window.contentView!.frame)
        page.frame = NSRect(x: 250, y: 0, width: 550, height: 600)
        chrome.frame = NSRect(x: 0, y: 520, width: 250, height: 80)
        container.addSubview(chrome)
        container.addSubview(page)
        window.contentView = container
        chrome.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(window.makeFirstResponder(page))
        store.focusNextArea()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(window.firstResponder === page, "F6 must leave the canvas for the address pill")
        XCTAssertFalse(window.firstResponder === window)
        store.focusNextArea()
        XCTAssertTrue(window.firstResponder === page)
    }

    func testSearchResultHandsFocusFromOldPageToNewTab() async throws {
        let (store, window, oldPage) = fixture()
        window.makeFirstResponder(oldPage)
        let next = store.newBlankTab()
        let newPage = next.web
        store.focusPage(from: oldPage)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            window.contentView = newPage
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.firstResponder === newPage,
                      "Submitting another tab must not strand the keyboard on the old page")
    }

    func testPageFocusWaitsForDismissedFieldToLeaveTheWindow() async throws {
        let (store, window, web) = fixture()
        let field = NSTextField(string: "search")
        let container = NSView(frame: window.contentView!.frame)
        container.addSubview(web)
        field.frame = NSRect(x: 0, y: 0, width: 250, height: 30)
        container.addSubview(field)
        window.contentView = container
        window.makeFirstResponder(field)
        store.focusPage()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
            field.removeFromSuperview()
            window.makeFirstResponder(nil)
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(window.firstResponder === web,
                      "Dismissal can leave its field editor mounted until the transition finishes")
    }

}
