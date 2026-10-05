import AppKit
import SwiftUI
import XCTest
@testable import vane

final class ChromeMenuTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 264, height: 165)

    func testMenuStaysInsideTheWindowWhenTheSidebarIsNarrowerThanTheMenu() {
        let window = CGRect(x: 200, y: 180, width: 800, height: 600)
        let anchor = CGRect(x: 390, y: 200, width: 28, height: 28)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: window,
                                           screen: screen, above: true)
        XCTAssertTrue(window.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.minX, window.minX + 8)
    }

    func testTallAndWideMenuShrinksToTheWindowAndItsVisibleScreenIntersection() {
        let window = CGRect(x: -100, y: 50, width: 320, height: 300)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: 170, y: 70, width: 28, height: 28),
            size: CGSize(width: 264, height: 2400), window: window, screen: screen, above: true)
        XCTAssertTrue(window.contains(frame))
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.width, 204)
        XCTAssertEqual(frame.height, 284)
    }

    func testHeaderPickerStaysInsideAWindowOnASecondaryScreen() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let window = CGRect(x: -1250, y: 200, width: 800, height: 600)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: -1220, y: 750, width: 180, height: 28),
            size: size, window: window, screen: screen, above: false)
        XCTAssertTrue(window.insetBy(dx: 8, dy: 8).contains(frame))
    }

    func testFastTypingFindsTheWholePrefixInsteadOfTheLastLetter() {
        var search = ChromeMenuTypeahead()
        let titles = ["Work", "Web", "Entertainment"]
        let first = search.match("w", at: 1, titles: titles, current: nil)
        XCTAssertEqual(first, 0)
        XCTAssertEqual(search.match("e", at: 1.1, titles: titles, current: first), 1)
    }

    func testRepeatedLettersCycleAndAPauseStartsANewPrefix() {
        var search = ChromeMenuTypeahead()
        let titles = ["Work", "Web", "Entertainment"]
        XCTAssertEqual(search.match("w", at: 1, titles: titles, current: nil), 0)
        XCTAssertEqual(search.match("W", at: 1.1, titles: titles, current: 0), 1)
        XCTAssertEqual(search.match("e", at: 2.5, titles: titles, current: 1), 2)
    }

    func testTypeaheadDistinguishesCreationActionsWithTheSameFirstWord() {
        var search = ChromeMenuTypeahead()
        let titles = ["New Space", "New Folder", "New Tab"]
        var selection: Int?
        for (index, char) in "new f".enumerated() {
            selection = search.match(String(char), at: Double(index) / 10, titles: titles, current: selection)
        }
        XCTAssertEqual(selection, 1)
    }

    func testFooterMenuOpensAboveTheTrigger() {
        let anchor = CGRect(x: 190, y: 30, width: 28, height: 28)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: true)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.minX, 8, "A narrow sidebar must not put the menu off screen")
    }

    func testHeaderMenuFlipsWhenThereIsNoRoomBelow() {
        let anchor = CGRect(x: 500, y: 60, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: false)
        XCTAssertGreaterThan(frame.minY, anchor.maxY)
        XCTAssertEqual(frame.maxX, anchor.maxX)
    }

    func testLargeSpaceListFitsOnASmallScreenWithANegativeOrigin() {
        let screen = CGRect(x: -1024, y: -100, width: 1024, height: 768)
        let frame = ChromeMenuLayout.frame(anchor: CGRect(x: -10, y: 620, width: 20, height: 20),
            size: CGSize(width: 264, height: 2400), window: screen, screen: screen, above: true)
        XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame))
        XCTAssertEqual(frame.height, 752)
    }

    func testMenuFlipsDownAtTheTopScreenEdge() {
        let anchor = CGRect(x: 1400, y: 850, width: 30, height: 30)
        let frame = ChromeMenuLayout.frame(anchor: anchor, size: size, window: screen, screen: screen, above: true)
        XCTAssertLessThan(frame.maxY, anchor.minY)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX - 8)
    }
}

@MainActor final class ChromeMenuPresentationTests: XCTestCase {
    private func fixture() -> (NSWindow, ChromeMenuAnchor) {
        _ = NSApplication.shared
        let anchor = ChromeMenuAnchor()
        let window = MenuEventWindow(contentRect: CGRect(x: 200, y: 200, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ChromeMenuAnchorView(anchor: anchor))
        window.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            ChromeMenu.shared.dismiss()
            window.close()
        }
        return (window, anchor)
    }

    func testPressingTheSameMenuAnchorAgainClosesItsMenu() {
        let (_, anchor) = fixture()
        let items = [ChromeMenuItem(title: "New Tab", symbol: "plus.square") {}]
        anchor.show(items, above: true, title: "Create")
        XCTAssertTrue(anchor.isPresented)
        XCTAssertTrue(NSApp.windows.contains { $0.title == "Create" && $0.isVisible })
        anchor.show(items, above: true, title: "Create")
        XCTAssertFalse(NSApp.windows.contains { $0.title == "Create" && $0.isVisible },
                       "The close button must dismiss rather than replace the open menu")
        XCTAssertFalse(anchor.isPresented)
    }

    func testClickingTheCloseTriggerIsConsumedBeforeItsButtonCanReopenTheMenu() throws {
        let (window, anchor) = fixture()
        anchor.show([ChromeMenuItem(title: "New Tab", symbol: "plus.square") {}], title: "Create")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: 400, y: 300), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        NSApp.sendEvent(event)
        XCTAssertFalse(anchor.isPresented)
        XCTAssertEqual((window as? MenuEventWindow)?.mouseDownCount, 0,
                       "Dismissal must consume mouse-down so the underlying button cannot fire on mouse-up")
    }

    func testEscapeClearsTheTriggersOpenState() throws {
        let (_, anchor) = fixture()
        anchor.show([ChromeMenuItem(title: "New Tab", symbol: "plus.square") {}], title: "Create")
        let panel = try XCTUnwrap(NSApp.windows.first { $0.title == "Create" && $0.isVisible })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(event)
        XCTAssertFalse(anchor.isPresented)
        XCTAssertFalse(panel.isVisible)
    }

    func testOpeningAnotherMenuClearsThePreviousTriggersOpenState() {
        let (_, first) = fixture()
        let (_, second) = fixture()
        let items = [ChromeMenuItem(title: "New Tab", symbol: "plus.square") {}]
        first.show(items, title: "Create")
        second.show(items, title: "Spaces")
        XCTAssertFalse(first.isPresented)
        XCTAssertTrue(second.isPresented)
        ChromeMenu.shared.dismiss()
        XCTAssertFalse(second.isPresented)
    }
}

private final class MenuEventWindow: NSWindow {
    var mouseDownCount = 0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { mouseDownCount += 1 }
        super.sendEvent(event)
    }
}
