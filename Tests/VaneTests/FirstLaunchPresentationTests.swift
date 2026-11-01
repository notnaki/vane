import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FirstLaunchPresentationTests: XCTestCase {
    func testWelcomeFillsHostWindowWithoutChangingSystemPresentation() async throws {
        let policy = NSApplication.shared.activationPolicy()
        try await checkWelcomeFillsHostWindowWithoutChangingSystemPresentation()
        XCTAssertEqual(NSApplication.shared.activationPolicy(), policy,
                       "The welcome fixture must restore its caller's activation policy")
    }

    private func checkWelcomeFillsHostWindowWithoutChangingSystemPresentation() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do {
            let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
                                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let browser = NSView()
            let field = NSTextField(string: "Browser remains underneath")
            browser.addSubview(field)
            host.contentView = browser
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
            host.makeFirstResponder(field)
            let responder = host.firstResponder
            let frame = host.frame
            presentation.show()
            XCTAssertEqual(NSApp.presentationOptions, original)
            XCTAssertEqual(host.frame, frame)
            XCTAssertFalse(host.styleMask.contains(.fullScreen))
            XCTAssertTrue(host.childWindows?.isEmpty ?? true)
            XCTAssertTrue(host.isKeyWindow)
            let welcome = try XCTUnwrap(host.contentView as? NSHostingView<AnyView>)
            XCTAssertTrue(welcome.window === host)
            XCTAssertNil(browser.window)
            XCTAssertEqual(welcome.frame.size, frame.size)
            XCTAssertFalse(host.firstResponder === responder)
            presentation.show()
            XCTAssertTrue(host.contentView === welcome)

            // The welcome follows window movement and resizing, not display geometry.
            host.setFrame(NSRect(x: 150, y: 160, width: 950, height: 700), display: true)
            host.layoutIfNeeded()
            XCTAssertEqual(welcome.frame.size, host.frame.size)
            XCTAssertEqual(NSApp.presentationOptions, original)
            presentation.close()
            XCTAssertNil(welcome.window)
            XCTAssertTrue(host.contentView === browser)
            XCTAssertEqual(browser.subviews, [field])
            XCTAssertTrue(host.firstResponder === responder)
            XCTAssertTrue(host.isVisible)
            XCTAssertEqual(NSApp.presentationOptions, original)
            // Repeated finish callbacks must not overwrite another owner's options.
            NSApp.presentationOptions = [.autoHideDock]
            presentation.close()
            XCTAssertEqual(NSApp.presentationOptions, [.autoHideDock])

            var closed = false
            let closing = FirstLaunchPresentation(host: host, content: AnyView(Text("Welcome")),
                                                 onHostClose: { closed = true })
            closing.show()
            host.close()
            XCTAssertTrue(closed)
            XCTAssertTrue(host.contentView === browser)
            XCTAssertEqual(NSApp.presentationOptions, [.autoHideDock])
        } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private enum XCTUnwrapFailure: Error { case notForeground }
}
