import AppKit
import WebKit
import ObjectiveC
import XCTest
@testable import vane

@MainActor final class WebKeyboardFallbackTests: XCTestCase {
    func testPageKeysDoNotReachTheWindowsAlertFallback() throws {
        _ = NSApplication.shared
        let window = VaneWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let web = WKWebView()
        window.contentView = web
        XCTAssertTrue(window.makeFirstResponder(web))

        // Observe the superclass boundary without playing a system alert in the test.
        let method = try XCTUnwrap(class_getInstanceMethod(NSWindow.self, #selector(NSResponder.keyDown(with:))))
        var fallbacks = 0
        let block: @convention(block) (NSWindow, NSEvent) -> Void = { _, _ in fallbacks += 1 }
        let replacement = imp_implementationWithBlock(block)
        let original = method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "l", charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37))
        window.keyDown(with: event)
        XCTAssertEqual(fallbacks, 0, "A page key must end quietly after WebKit offers it back")

        let field = NSTextField()
        window.contentView = field
        XCTAssertTrue(window.makeFirstResponder(field))
        window.keyDown(with: event)
        XCTAssertEqual(fallbacks, 1, "Native controls retain AppKit's fallback")
    }
}
