import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class FindWebKitTests: XCTestCase {
    private func fixture() async throws -> (TabStore, Tab, Find) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID())
        let tab = store.newBlankTab(focus: false)
        store.current = tab.id
        store.findOpen = true
        tab.web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        tab.web.loadHTMLString("<body style='background:white;color:black;font:32px sans-serif'>needle needle</body>", baseURL: nil)
        try await compatibilityWait { !tab.web.isLoading }
        addTeardownBlock { @MainActor in
            store.dropStashes()
            SharedTabs.release(store.tabs)
            TabStore.all.removeAll { $0 === store }
        }
        return (store, tab, Find.session(for: store))
    }

    func testClosingFindInvalidatesSearchInFlightAndKeepsQuery() async throws {
        let (store, tab, find) = try await fixture()
        let searching = Task { await find.run("needle", in: tab, fresh: true) }
        // run suspends for WebKit after remembering the query, before publishing results.
        await Task.yield()
        XCTAssertEqual(find.query, "needle")
        store.findOpen = false
        await searching.value
        XCTAssertEqual(find.query, "needle", "Command-G should still resume the query")
        XCTAssertEqual(find.count, 0, "A completed search must not revive dismissed results")
        XCTAssertEqual(find.index, 0)
        let selection = try await tab.web.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(selection, "")
    }

    private func coloredPixels(in web: WKWebView) async throws -> Int {
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(x: 0, y: 0, width: 400, height: 80)
        let image = try await web.takeSnapshot(configuration: config)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.saturationComponent > 0.3, color.brightnessComponent > 0.4 {
                    count += 1
                }
            }
        }
        return count
    }

    func testClosingFindRemovesWebKitHighlight() async throws {
        let (store, tab, find) = try await fixture()
        await find.run("needle", in: tab, fresh: true)
        let highlighted = try await coloredPixels(in: tab.web)
        if #available(macOS 27, *) {
            XCTAssertGreaterThan(highlighted, 0, "The fixture must render a Find highlight")
        }
        store.findOpen = false
        // The JavaScript round trip also waits for the earlier native cleanup message.
        let selection = try await tab.web.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(selection, "")
        let cleared = try await coloredPixels(in: tab.web)
        XCTAssertEqual(cleared, 0, "Find's native text marker must disappear with the bar")
    }

    func testClearingQueryRemovesSelectionAndAllowsSearchingAgain() async throws {
        let (_, tab, find) = try await fixture()
        await find.run("needle", in: tab, fresh: true)
        XCTAssertEqual(find.count, 2)
        await find.run("", in: tab, fresh: true)
        let selection = try await tab.web.evaluateJavaScript("window.getSelection().toString()") as? String
        XCTAssertEqual(selection, "")
        XCTAssertEqual(find.count, 0)
        await find.run("needle", in: tab, fresh: true)
        XCTAssertEqual(find.count, 2)
        XCTAssertEqual(find.index, 1)
    }

    func testClosingFindClearsSelectionInsideFrame() async throws {
        let (store, tab, find) = try await fixture()
        tab.web.loadHTMLString("<iframe srcdoc='<p>frame-needle</p>'></iframe>", baseURL: nil)
        let selection = "document.querySelector('iframe').contentWindow.getSelection().toString()"
        try await compatibilityWait {
            try await tab.web.evaluateJavaScript(
                "document.querySelector('iframe')?.contentDocument?.body?.textContent") as? String == "frame-needle"
        }
        await find.run("frame-needle", in: tab, fresh: true)
        let selected = try await tab.web.evaluateJavaScript(selection) as? String
        XCTAssertEqual(selected, "frame-needle")
        store.findOpen = false
        let cleared = try await tab.web.evaluateJavaScript(selection) as? String
        XCTAssertEqual(cleared, "", "Closing Find must clear the selected match in a child frame")
    }
}
