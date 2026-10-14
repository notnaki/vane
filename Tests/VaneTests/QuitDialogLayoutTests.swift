import AppKit
import XCTest
@testable import vane

@MainActor final class QuitDialogLayoutTests: XCTestCase {
    private func inspectDialog(_ action: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard QuitDialog.isUp else { return }
                defer { NSApp.stopModal() }
                action()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func testQuitOverlayCoversResizedWindowAndCancelRemovesIt() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = VaneWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 700),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let store = TabStore(isPrivate: true)
        store.window = window
        window.contentView = BrowserWindowHost(shown: ShownStore(store))
        defer {
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        window.setContentSize(NSSize(width: 1200, height: 800))
        window.orderFront(nil)
        defer { window.close() }
        let content = window.contentView!
        let container = content.superview!
        let timer = inspectDialog {
            let overlay = container.subviews.first { candidate in
                candidate.accessibilityRole() == .sheet && candidate.accessibilityLabel() == "Quit Vane?"
            }
            guard let overlay else { XCTFail("Missing quit overlay"); return }
            window.setContentSize(NSSize(width: 1000, height: 700))
            container.layoutSubtreeIfNeeded()
            overlay.layoutSubtreeIfNeeded()
            XCTAssertEqual(overlay.frame, container.bounds, "Quit scrim must cover the whole window")
            guard let card = overlay.subviews.first else { XCTFail("Missing card"); return }
            XCTAssertEqual(card.frame.midX, overlay.bounds.midX, accuracy: 1)
            XCTAssertEqual(card.frame.midY, overlay.bounds.midY, accuracy: 1)
        }
        defer { timer.invalidate() }
        XCTAssertEqual(QuitDialog.ask(over: window), .cancel)
        XCTAssertFalse(container.subviews.contains { $0.accessibilityRole() == .sheet })
    }

    func testQuitEscapeDoesNotClearSidebarSelection() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        store.palette = nil
        let selected = UUID()
        store.selection.toggle(selected, in: .init(kind: .today, ids: [selected]))
        window.orderFront(nil)
        defer {
            window.close()
            store.window = nil
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        let timer = inspectDialog {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)!
            window.sendEvent(event)
        }
        defer { timer.invalidate() }
        XCTAssertEqual(QuitDialog.ask(over: window), .cancel)
        XCTAssertTrue(store.selection.contains(selected), "Escape belongs to the quit dialog")
    }

    func testQuitWithoutKeyWindowStillOverlaysVisibleBrowser() {
        _ = NSApplication.shared
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        let container = window.contentView!.superview!
        let timer = inspectDialog {
            XCTAssertTrue(container.subviews.contains { candidate in
                candidate.accessibilityRole() == .sheet && candidate.accessibilityLabel() == "Quit Vane?"
            }, "A temporary gap in key-window ownership must not lose the browser overlay")
        }
        defer { timer.invalidate() }
        XCTAssertEqual(QuitDialog.ask(over: nil), .cancel)
        XCTAssertFalse(container.subviews.contains { $0.accessibilityRole() == .sheet })
    }

    func testHostSelectionUsesMenuOwnerAndSkipsInvisibleOrPreviewWindows() {
        _ = NSApplication.shared
        let browser = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        let menu = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let preview = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [browser, menu, preview] { window.isReleasedWhenClosed = false }
        defer { browser.removeChildWindow(menu); menu.close(); preview.close(); browser.close() }
        browser.orderFront(nil)
        preview.isExcludedFromWindowsMenu = true
        preview.orderFront(nil)
        browser.addChildWindow(menu, ordered: .above)
        XCTAssertTrue(QuitDialog.presentationHost(preferred: menu, main: nil, ordered: []) === browser)
        XCTAssertTrue(QuitDialog.presentationHost(preferred: preview, main: nil,
                                                  ordered: [preview, browser]) === browser)
        browser.orderOut(nil)
        XCTAssertNil(QuitDialog.presentationHost(preferred: menu, main: browser,
                                                 ordered: [menu, preview, browser]))
    }
}
