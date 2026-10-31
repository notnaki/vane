import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FirstLaunchPresentationTests: XCTestCase {
    func testWelcomeCoversHostScreenAndRestoresPresentationOnDismissal() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do {
            let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                                styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.makeKeyAndOrderFront(nil)
            let original = NSApp.presentationOptions
            let presentation = FirstLaunchPresentation(host: host, content: AnyView(Text("Welcome")))
            defer {
                presentation.close()
                NSApp.presentationOptions = original
                host.close()
            }
            NSApp.activate(ignoringOtherApps: true)
            let hostDeadline = Date().addingTimeInterval(2)
            while (!NSApp.isActive || !host.isKeyWindow) && Date() < hostDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(NSApp.isActive)
            XCTAssertTrue(host.isKeyWindow)
            guard NSApp.isActive, host.isKeyWindow else { throw XCTUnwrapFailure.notForeground }
            presentation.show()
            let welcome = try XCTUnwrap(presentation.window)
            let deadline = Date().addingTimeInterval(2)
            while (!welcome.isVisible || !welcome.isKeyWindow) && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(welcome.isVisible)
            XCTAssertTrue(welcome.isKeyWindow)
            XCTAssertEqual(welcome.parent, host)
            XCTAssertEqual(welcome.frame, try XCTUnwrap(host.screen).frame)
            XCTAssertTrue(welcome.canBecomeKey)
            XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideDock))
            XCTAssertTrue(NSApp.presentationOptions.contains(.autoHideMenuBar))
            presentation.close()
            XCTAssertFalse(welcome.isVisible)
            XCTAssertNil(welcome.parent)
            XCTAssertTrue(host.isVisible)
            XCTAssertEqual(NSApp.presentationOptions, original)
            // Repeated finish callbacks must not overwrite another owner's options.
            NSApp.presentationOptions = [.autoHideDock]
            presentation.close()
            XCTAssertEqual(NSApp.presentationOptions, [.autoHideDock])
        } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private enum XCTUnwrapFailure: Error { case notForeground }
}
