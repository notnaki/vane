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

}
