import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FavouritePreviewKeyboardTests: XCTestCase {
    func testOptionDownOnFocusedFavouriteInvokesPreviewWithArrowHardwareFlags() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        var previews = 0
        let view = Text("Fixture favourite").frame(width: 180, height: 70)
            .vaneKeyboardAction(requestFocus: .constant(true), previewAction: { previews += 1 }) {}
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option, .function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
            charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        NSApp.sendEvent(event)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(previews, 1)
    }
    func testKeyboardPanelBecomesKeyWhileHoverPanelPreservesOwnerFocus() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor
        owner.makeKeyAndOrderFront(nil)
        defer { anchor.hide(); owner.contentView = nil; owner.close() }
        anchor.configure(visible: true, keyboard: false, content: AnyView(Text("Fixture card").frame(width: 370, height: 180)), dismiss: {})
        try await Task.sleep(for: .milliseconds(100))
        let hoverPanel = try XCTUnwrap(owner.childWindows?.first)
        XCTAssertFalse(hoverPanel.isKeyWindow)
        anchor.hide()
        anchor.configure(visible: true, keyboard: true, content: AnyView(Text("Fixture card").frame(width: 370, height: 180)), dismiss: {})
        try await Task.sleep(for: .milliseconds(100))
        let keyPanel = try XCTUnwrap(owner.childWindows?.first)
        XCTAssertTrue(keyPanel.isKeyWindow)
        XCTAssertTrue(keyPanel.parent === owner)
        anchor.hide()
        XCTAssertTrue(owner.childWindows?.isEmpty ?? true)
    }

    func testKeyboardOpeningFocusesOpenSiteAndPromotionDoesNotRecreatePanel() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor
        owner.makeKeyAndOrderFront(nil)
        defer { anchor.hide(); owner.contentView = nil; owner.close() }
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/0/")!)!
        var opened: [URL] = []
        func content(_ keyboard: Bool) -> AnyView {
            AnyView(FavouritePreviewCard(context: context, state: .signedOut, open: { opened.append($0) }, dismiss: {}, keyboardOpened: keyboard))
        }
        anchor.configure(visible: true, keyboard: false, content: content(false), dismiss: {})
        let hoverPanel = try XCTUnwrap(owner.childWindows?.first)
        anchor.configure(visible: true, keyboard: true, content: content(true), dismiss: {})
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(hoverPanel === owner.childWindows?.first)
        XCTAssertTrue(hoverPanel.isKeyWindow, "Keyboard opening must promote an existing hover card")
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: hoverPanel.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(opened, [context.siteURL], "Return must activate the initially focused Open Site button")
    }

    func testInboxReferenceCardFitsBoundedNativePanel() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                             styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor
        owner.makeKeyAndOrderFront(nil)
        defer { anchor.hide(); owner.contentView = nil; owner.close() }
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/0/")!)!
        let items = [
            FavouritePreviewItem(title: "Design review is ready", subtitle: "Alex", url: URL(string: "https://mail.google.com/mail/u/0/#inbox/abc1")!, unread: true, timeLabel: "7m", snippet: "The latest changes are ready for your feedback before the next review."),
            FavouritePreviewItem(title: "Your receipt for Sunday’s trip", subtitle: "Receipts", url: URL(string: "https://mail.google.com/mail/u/0/#inbox/abc2")!, timeLabel: "18h", snippet: "Thanks for travelling with us. Here is a summary of your trip."),
            FavouritePreviewItem(title: "Your weekly activity summary", subtitle: "Weekly updates", url: URL(string: "https://mail.google.com/mail/u/0/#inbox/abc3")!, timeLabel: "2d", snippet: "See what happened this week across your projects and repositories.")
        ]
        let card = FavouritePreviewCard(context: context, state: .ready(.init(account: "fixture@example.test", items: items)), open: { _ in }, dismiss: {})
            .environment(\.colorScheme, .dark)
        anchor.configure(visible: true, keyboard: false, content: AnyView(card), dismiss: {})
        try await Task.sleep(for: .milliseconds(250))
        let panel = try XCTUnwrap(owner.childWindows?.first)
        XCTAssertEqual(panel.frame.width, 240)
        XCTAssertLessThanOrEqual(panel.frame.height, 280)
        let content = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/vane-favourite-inbox-fixture.png"))
    }

    func testKeyboardOpeningInboxFocusesFirstMessage() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let anchor = FavouritePreviewPanel.Anchor(frame: NSRect(x: 0, y: 0, width: 70, height: 50))
        owner.contentView = anchor
        owner.makeKeyAndOrderFront(nil)
        defer { anchor.hide(); owner.contentView = nil; owner.close() }
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://mail.google.com/mail/u/0/")!)!
        let item = FavouritePreviewItem(title: "Fixture subject", subtitle: "Fixture Sender", url: URL(string: "https://mail.google.com/mail/u/0/#inbox/abc1")!)
        var opened: [URL] = []
        let card = FavouritePreviewCard(context: context, state: .ready(.init(account: "fixture@example.test", items: [item])), open: { opened.append($0) }, dismiss: {}, keyboardOpened: true)
        anchor.configure(visible: true, keyboard: true, content: AnyView(card), dismiss: {})
        try await Task.sleep(for: .milliseconds(300))
        let panel = try XCTUnwrap(owner.childWindows?.first)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.sendEvent(enter)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(opened, [item.url])
    }

}
