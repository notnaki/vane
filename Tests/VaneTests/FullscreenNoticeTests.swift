import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class FullscreenNoticeTests: XCTestCase {
    private func withPage(_ body: (Tab, NSWindow) async throws -> Void) async rethrows {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let mode = BatterySaver.shared.mode
        BatterySaver.shared.setMode(.alwaysOn)
        let tab = Tab(isPrivate: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        defer {
            FullscreenNotice.hide()
            tab.tearDown()
            window.contentView = nil
            window.close()
            BatterySaver.shared.setMode(mode)
        }
        try await body(tab, window)
    }

    private func reportFullscreenChange(_ web: WKWebView) {
        web.willChangeValue(forKey: "fullscreenState")
        web.didChangeValue(forKey: "fullscreenState")
    }

    private func notice() -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first {
            $0.isVisible && $0.ignoresMouseEvents &&
            ($0.contentView?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
                .localizedCaseInsensitiveContains("full screen") == true)
        }
    }

    func testNoticeIdentifiesBrowsingContextWithoutAttributingEmbeddedFullscreen() async throws {
        try await withPage { tab, _ in
            let keyWindow = NSApp.keyWindow
            FullscreenNotice.show(pageURL: URL(string: "https://user:password@www.example.com:8443/private?token=secret#fragment"), over: tab.web)
            let panel = try XCTUnwrap(notice())
            let label = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertTrue(label.stringValue.contains("Browsing https://www.example.com:8443"))
            XCTAssertFalse(label.stringValue.contains("is full screen"))
            XCTAssertFalse(label.stringValue.contains("password"))
            XCTAssertFalse(label.stringValue.contains("private"))
            XCTAssertFalse(label.stringValue.contains("secret"))
            XCTAssertTrue(NSApp.keyWindow === keyWindow)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertEqual(panel.alphaValue, 1, "Battery Saver must show the notice immediately")
        }
    }

    func testClosingOwnerDismissesNoticeBeforeTimeout() async throws {
        try await withPage { tab, _ in
            FullscreenNotice.show(pageURL: URL(string: "https://example.com"), over: tab.web)
            let panel = try XCTUnwrap(notice())
            tab.tearDown()
            XCTAssertFalse(panel.isVisible, "Closing the page must remove its notice synchronously")
        }
    }

    func testUnrelatedTabFullscreenUpdateCannotDismissOwnerNotice() async throws {
        try await withPage { tab, _ in
            let other = Tab(isPrivate: true)
            defer { other.tearDown() }
            let otherWeb = other.web
            FullscreenNotice.show(pageURL: URL(string: "https://example.com"), over: tab.web)
            let panel = try XCTUnwrap(notice())
            // KVO may arrive from any attached tab, including an exit in another window.
            reportFullscreenChange(otherWeb)
            XCTAssertTrue(panel.isVisible)
            other.tearDown()
            XCTAssertTrue(panel.isVisible)
        }
    }

    func testClosingOwnerWindowDismissesNoticeImmediately() async throws {
        try await withPage { tab, window in
            FullscreenNotice.show(pageURL: URL(string: "https://example.com"), over: tab.web)
            let panel = try XCTUnwrap(notice())
            window.close()
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testSwitchingTabsDismissesOnlyPreviousOwnersNotice() async throws {
        try await withPage { tab, _ in
            let store = TabStore(isPrivate: true)
            let other = Tab(isPrivate: true)
            defer {
                other.tearDown()
                store.dropStashes()
                TabStore.all.removeAll { $0 === store }
            }
            store.tabs = [tab, other]
            store.current = tab.id
            FullscreenNotice.show(pageURL: URL(string: "https://example.com"), over: tab.web)
            let panel = try XCTUnwrap(notice())
            store.current = other.id
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testOwnerExitDismissesNoticeAndUnrelatedOwnerCannotHideIt() async throws {
        try await withPage { tab, _ in
            let other = Tab(isPrivate: true)
            defer { other.tearDown() }
            FullscreenNotice.show(pageURL: URL(string: "https://first.example"), over: tab.web)
            let first = try XCTUnwrap(notice())
            reportFullscreenChange(tab.web)
            XCTAssertFalse(first.isVisible)

            FullscreenNotice.show(pageURL: URL(string: "https://second.example"), over: tab.web)
            let replacement = try XCTUnwrap(notice())
            FullscreenNotice.hide(over: other.web, immediately: true)
            XCTAssertTrue(replacement.isVisible)
        }
    }

    func testWindowAndAppDeactivationDismissNoticeWithoutChangingFocus() async throws {
        try await withPage { tab, window in
            let keyWindow = NSApp.keyWindow
            FullscreenNotice.show(pageURL: URL(string: "http://example.com:8080"), over: tab.web)
            let first = try XCTUnwrap(notice())
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertFalse(first.isVisible)
            FullscreenNotice.show(pageURL: URL(string: "http://example.com:8080"), over: tab.web)
            let second = try XCTUnwrap(notice())
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            XCTAssertFalse(second.isVisible)
            XCTAssertTrue(NSApp.keyWindow === keyWindow)
        }
    }

    func testOpaqueAndLocalDocumentsNeverExposeURLContents() async throws {
        try await withPage { tab, _ in
            for url in [URL(string: "data:text/html,secret"), URL(fileURLWithPath: "/private/secret.html"), nil] {
                FullscreenNotice.show(pageURL: url, over: tab.web)
                let panel = try XCTUnwrap(notice())
                let label = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
                XCTAssertFalse(label.stringValue.contains("secret"))
                XCTAssertFalse(label.stringValue.contains("is full screen"))
            }
        }
    }

    func testReplacementSurvivesOldOwnersCleanupAndDeadlineThenExpires() async throws {
        try await withPage { tab, window in
            let other = Tab(isPrivate: true)
            let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                       styleMask: .borderless, backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            otherWindow.contentView = other.web
            defer {
                other.tearDown()
                otherWindow.contentView = nil
                otherWindow.close()
            }
            FullscreenNotice.show(pageURL: URL(string: "https://first.example"), over: tab.web)
            let first = try XCTUnwrap(notice())
            try await Task.sleep(for: .seconds(2))
            FullscreenNotice.show(pageURL: URL(string: "https://second.example"), over: other.web)
            let second = try XCTUnwrap(notice())
            XCTAssertFalse(first.isVisible)
            XCTAssertTrue(second !== first)
            tab.tearDown()
            window.close()
            XCTAssertTrue(second.isVisible, "The old owner's teardown and close must not hide its replacement")
            try await Task.sleep(for: .milliseconds(1700))
            XCTAssertTrue(second.isVisible, "The old deadline must not dismiss the replacement")
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(second.isVisible, "The replacement must expire at its own deadline")
        }
    }

    func testDetachedPageCannotDisplayNoticeOnMainScreen() async {
        await withPage { _, _ in
            let detached = WKWebView()
            FullscreenNotice.show(pageURL: URL(string: "https://hidden.example"), over: detached)
            XCTAssertNil(notice())
        }
    }

    func testLongOriginStaysInsideScreenWithoutTruncation() async throws {
        try await withPage { tab, window in
            let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
            let origin = "https://" + Array(repeating: String(repeating: "w", count: 60), count: 4).joined(separator: ".") + ":8443"
            FullscreenNotice.show(pageURL: URL(string: origin), over: tab.web)
            let panel = try XCTUnwrap(notice())
            let label = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertTrue(screen.frame.contains(panel.frame))
            XCTAssertTrue(label.stringValue.contains(origin))
            XCTAssertFalse(label.cell?.lineBreakMode == .byTruncatingTail)
            XCTAssertGreaterThan(label.frame.height, label.font!.pointSize * 2,
                                 "Long origins must wrap instead of hiding part of their identity")
        }
    }
}
