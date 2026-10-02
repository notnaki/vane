import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageCaptureTests: XCTestCase {
    func testSelectionWorksInEveryDragDirectionAndClipsToPage() {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
        XCTAssertEqual(PageCapture.rectangle(from: .init(x: 180, y: 140),
            to: .init(x: 20, y: 30), in: bounds), CGRect(x: 20, y: 30, width: 160, height: 110))
        XCTAssertEqual(PageCapture.rectangle(from: .init(x: 20, y: 30),
            to: .init(x: 180, y: 140), in: bounds), CGRect(x: 20, y: 30, width: 160, height: 110))
        XCTAssertEqual(PageCapture.rectangle(from: .init(x: 400, y: 200),
            to: .init(x: 700, y: 450), in: bounds), CGRect(x: 400, y: 200, width: 100, height: 100))
        XCTAssertNil(PageCapture.rectangle(from: .zero, to: .init(x: 1, y: 100), in: bounds))
        XCTAssertNil(PageCapture.rectangle(from: .zero, to: .init(x: CGFloat.nan, y: 100), in: bounds))
        XCTAssertNil(PageCapture.rectangle(from: .init(x: 600, y: 20),
            to: .init(x: 650, y: 100), in: bounds))
    }

    func testCaptureIsDiscoverableAndHasArcsShortcut() {
        let command = Command(rawValue: "capturePage")
        XCTAssertNotNil(command)
        XCTAssertEqual(command?.defaultBinding, Keybinding("@", .command))
        XCTAssertTrue(PaletteCommand.registered.contains { $0.rawValue == "capturePage" })
        let row = SiteControlModel(host: "example.com", scheme: "https").rows.first {
            $0.title == "Capture a Portion of This Page"
        }
        XCTAssertEqual(row?.glyph, "camera.viewfinder")
        XCTAssertEqual(row?.control, .action)
    }

    private final class ShortcutTarget: NSObject {
        var fired = false
        @objc func capture(_ sender: Any?) { fired = true }
    }

    func testCaptureShortcutMatchesTheShiftedKeyboardEventAndNativeMenu() throws {
        let command = try XCTUnwrap(Command(rawValue: "capturePage"))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil,
            characters: "@", charactersIgnoringModifiers: "@", isARepeat: false, keyCode: 19))
        XCTAssertEqual(Keybinding(event: event), command.defaultBinding)
        let target = ShortcutTarget()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let item = NSMenuItem(title: command.title, action: #selector(ShortcutTarget.capture(_:)),
                              keyEquivalent: command.defaultBinding.menuKeyEquivalent)
        item.keyEquivalentModifierMask = command.defaultBinding.menuModifierMask
        item.target = target
        menu.addItem(item)
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertTrue(target.fired)
    }

    func testElementSelectionUsesVisibleCoordinatesAtPageZoom() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.loadHTMLString("""
        <style>body{margin:0;height:2000px}#card{position:absolute;left:20px;top:400px;width:100px;height:80px;background:red}</style>
        <div id='card'><span>Capture me</span></div>
        """, baseURL: nil)
        let deadline = Date.now.addingTimeInterval(10)
        while web.isLoading && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        web.pageZoom = 1.5
        _ = try await web.evaluateJavaScript("window.scrollTo(0, 350)")
        try await Task.sleep(for: .milliseconds(100))
        let geometry = try await web.evaluateJavaScript("JSON.stringify(document.getElementById('card').getBoundingClientRect().toJSON())") as! String
        let values = try JSONSerialization.jsonObject(with: Data(geometry.utf8)) as! [String: Double]
        let expected = CGRect(x: values["x"]! * 1.5, y: values["y"]! * 1.5,
                              width: 150, height: 120).intersection(web.bounds)
        let actual = await PageCapture.element(at: CGPoint(x: expected.midX, y: expected.midY), in: web)
        XCTAssertEqual(actual, expected)
        web.stopLoading()
    }

    private func visiblePage() async throws -> (TabStore, Tab, NSWindow) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true, session: [])
        let tab = Tab(isPrivate: true, profileID: store.profileID)
        store.tabs = [tab]
        store.current = tab.id
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
        tab.web.loadHTMLString("""
        <style>body{margin:0;height:2000px;background:blue}#card{position:absolute;left:20px;top:400px;width:100px;height:80px;background:red}</style>
        <div id='card'></div>
        """, baseURL: URL(string: "https://capture.test"))
        let deadline = Date.now.addingTimeInterval(10)
        while tab.web.isLoading && Date.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(tab.web.isLoading)
        addTeardownBlock { @MainActor in
            window.close()
            tab.web.stopLoading()
            TabStore.all.removeAll { $0 === store }
        }
        return (store, tab, window)
    }

    func testSnapshotCropsScrolledZoomedPageToActualPixels() async throws {
        let (_, tab, window) = try await visiblePage()
        tab.web.pageZoom = 1.5
        _ = try await tab.web.evaluateJavaScript("window.scrollTo(0,350)")
        try await Task.sleep(for: .milliseconds(150))
        let selected = await PageCapture.element(at: CGPoint(x: 80, y: 130), in: tab.web)
        let rect = try XCTUnwrap(selected)
        let image = try await PageCapture.snapshot(rect, in: tab.web)
        XCTAssertEqual(image.size.width, rect.width, accuracy: 1)
        XCTAssertEqual(image.size.height, rect.height, accuracy: 1)
        let data = try XCTUnwrap(PageCapture.png(image))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(CGFloat(bitmap.pixelsWide) / rect.width, window.backingScaleFactor, accuracy: 0.01)
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertLessThan(color.blueComponent, 0.1, "Snapshot must crop the red element, excluding the blue page")
    }

    func testCaptureCancelsOnEscapeTabSwitchAndNavigation() async throws {
        let (store, tab, window) = try await visiblePage()
        let initial = tab.web.subviews.count
        PageCapture.start(tab)
        XCTAssertEqual(tab.web.subviews.count, initial + 1)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.firstResponder?.keyDown(with: escape)
        XCTAssertEqual(tab.web.subviews.count, initial)
        PageCapture.start(tab)
        store.current = nil
        XCTAssertEqual(tab.web.subviews.count, initial)
        store.current = tab.id
        PageCapture.start(tab)
        tab.web.loadHTMLString("<p>A different page</p>", baseURL: URL(string: "https://other.test"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(tab.web.subviews.count, initial)
    }

    func testReturnCapturesPageAndOpensOutputPreview() async throws {
        let (_, tab, window) = try await visiblePage()
        let initial = tab.web.subviews.count
        PageCapture.start(tab)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.firstResponder?.keyDown(with: enter)
        let deadline = Date.now.addingTimeInterval(10)
        while window.attachedSheet == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let preview = try XCTUnwrap(window.attachedSheet)
        XCTAssertEqual(preview.title, "Page Capture")
        XCTAssertEqual(tab.web.subviews.count, initial, "The selection overlay must be removed before capture")
        window.endSheet(preview)
        preview.orderOut(nil)
    }

    func testCaptureModeDoesNotForwardPageScrollingKeys() async throws {
        let (_, tab, window) = try await visiblePage()
        PageCapture.start(tab)
        for (characters, code): (String, UInt16) in [("\u{F72D}", 121), (" ", 49)] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.firstResponder?.keyDown(with: event)
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try await tab.web.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(scroll, 0, "Capture mode must keep the viewport under the selection stable")
    }
}
