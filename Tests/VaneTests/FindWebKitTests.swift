import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class FindWebKitTests: XCTestCase {
    private func withFixture(_ body: @MainActor (TabStore, Tab, Find) async throws -> Void) async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        if policy == .prohibited { NativeFixturePolicyDiagnostics.setActivationPolicy(app, .accessory) }
        defer { NativeFixturePolicyDiagnostics.setActivationPolicy(app, policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire()
        WebKitStartup.prepare()
        let store = TabStore(isPrivate: true, profileID: UUID())
        let tab = store.newBlankTab(focus: false)
        store.current = tab.id
        store.findOpen = true
        tab.web.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: tab.web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        var failure: (any Error)?
        do {
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            try await compatibilityWait { app.isRunning && app.isActive && window.isKeyWindow
                && window.isVisible && !window.isMiniaturized
                && tab.web.window === window && window.contentView === tab.web && !tab.web.visibleRect.isEmpty }
            tab.web.loadHTMLString("<body style='background:white;color:black;font:32px sans-serif'>needle needle</body>", baseURL: nil)
            try await compatibilityWait {
                guard !tab.web.isLoading else { return false }
                return (try? await tab.web.evaluateJavaScript("document.readyState === 'complete' && document.body?.textContent === 'needle needle'")) as? Bool == true
            }
            try await body(store, tab, Find.session(for: store))
        } catch {
            failure = error
            fputs("Find fixture failure: active=\(app.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), occlusionDiagnostic=\(window.occlusionState.rawValue)\n", stderr)
        }
        tab.existingWeb?.stopLoading()
        window.contentView = nil
        window.close()
        store.dropStashes()
        SharedTabs.release(store.tabs)
        TabStore.all.removeAll { $0 === store }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Find fixture AppKit cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

    func testClosingFindInvalidatesSearchInFlightAndKeepsQuery() async throws {
        try await withFixture { store, tab, find in
            let boundary = HeldNativeFindSearch()
            find.nativeSearchBoundary = boundary.search
            async let searching: Void = boundary.run(find, in: tab)
            var failure: (any Error)?
            do {
                // Admit a real native result, held before Find.run can publish it.
                boundary.allowEntry()
                try await compatibilityWait { boundary.hasNativeResult }
                XCTAssertTrue(boundary.nativeEntered, "The in-flight fixture must enter the real native search before closing")
                XCTAssertTrue(boundary.nativeMatched, "The held completion must be a real matching WKWebView.find result")
                XCTAssertEqual(find.query, "needle")
                store.findOpen = false
                boundary.releaseResult()
            } catch { failure = error }
            boundary.releaseAll()
            find.nativeSearchBoundary = nil
            do { try await compatibilityWait { boundary.searchFinished } }
            catch {
                fputs("Find search join deadline failed: \(error)\n", stderr)
                if failure == nil { failure = error }
                else { XCTFail("Find search join also failed: \(error)") }
            }
            // Structured join precedes web/loop teardown even on an error. Do not
            // cancel the successful arm: cancellation would mask invalidation bugs.
            // A nonreturning SDK call remains a primary-driver watchdog failure.
            await searching
            if let failure { throw failure }
            XCTAssertEqual(find.query, "needle", "Command-G should still resume the query")
            XCTAssertEqual(find.count, 0, "A completed search must not revive dismissed results")
            XCTAssertEqual(find.index, 0)
            let selection = try await tab.web.evaluateJavaScript("window.getSelection().toString()") as? String
            XCTAssertEqual(selection, "")
        }
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
        try await withFixture { store, tab, find in
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
    }

    func testClearingQueryRemovesSelectionAndAllowsSearchingAgain() async throws {
        try await withFixture { _, tab, find in
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
    }

    func testClosingFindClearsSelectionInsideFrame() async throws {
        try await withFixture { store, tab, find in
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
}

/// Controls scheduling around the real SDK call, never synthesizing a search result.
@MainActor private final class HeldNativeFindSearch {
    private var entryAllowed = false
    private var resultAllowed = false
    private var entry: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<Void, Never>?
    private(set) var nativeEntered = false
    private(set) var nativeMatched = false
    var searchFinished = false
    var hasNativeResult: Bool { result != nil }

    func run(_ find: Find, in tab: Tab) async {
        defer { searchFinished = true }
        await find.run("needle", in: tab, fresh: true)
    }

    func search(_ tab: Tab, _ text: String, _ forward: Bool) async -> Bool {
        if !entryAllowed { await withCheckedContinuation { entry = $0 } }
        nativeEntered = true
        let matched = await tab.find(text, forward: forward)
        nativeMatched = matched
        if !resultAllowed { await withCheckedContinuation { result = $0 } }
        return matched
    }
    func allowEntry() { entryAllowed = true; entry?.resume(); entry = nil }
    func releaseResult() { resultAllowed = true; result?.resume(); result = nil }
    func releaseAll() { allowEntry(); releaseResult() }
}
