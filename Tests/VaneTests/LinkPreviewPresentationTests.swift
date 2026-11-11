import AppKit
import SwiftUI
import Vision
import XCTest
@testable import vane

@MainActor final class LinkPreviewPresentationTests: XCTestCase {
    func testPreviewBelongsOnlyToItsRequestingTabEvenForTheSameURL() {
        TestEnvironment.prepare()
        let previews = Previews(), first = vane.Tab(isPrivate: true), second = vane.Tab(isPrivate: true)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        defer {
            previews.cancel(); first.tearDown(); second.tearDown()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
        }
        let url = URL(string: "https://example.com/article")!
        previews.request(url, from: first)
        var preview = Previews.Preview(url: url)
        preview.summary = "The first page's summary."
        previews.publish(preview, for: previews.begin())
        XCTAssertEqual(previews.preview(for: first)?.summary, "The first page's summary.")
        XCTAssertNil(previews.preview(for: second))
        let rect = CGRect(x: 60, y: 80, width: 100, height: 24)
        previews.request(url, from: second, rect: rect)
        XCTAssertNil(previews.preview(for: first))
        XCTAssertEqual(previews.preview(for: second)?.summary, "")
        XCTAssertEqual(previews.linkRect, rect)
        previews.cancel(from: first)
        XCTAssertNotNil(previews.preview(for: second), "A late mouseout from another tab must not dismiss this preview")
        previews.cancel(from: second.id)
        XCTAssertNil(previews.preview(for: second))
    }

    func testCardStaysInsideThePaneAndFlipsAboveBottomLinks() {
        XCTAssertEqual(LinkPreviewLayout.frame(link: .init(x: 50, y: 60, width: 140, height: 20),
            viewport: .init(width: 800, height: 600)), .init(x: 50, y: 88, width: 320, height: 350))
        XCTAssertEqual(LinkPreviewLayout.frame(link: .init(x: 760, y: 570, width: 30, height: 20),
            viewport: .init(width: 800, height: 600)), .init(x: 472, y: 212, width: 320, height: 350))
        XCTAssertEqual(LinkPreviewLayout.frame(link: .init(x: 190, y: 200, width: 20, height: 20),
            viewport: .init(width: 200, height: 240)), .init(x: 8, y: 8, width: 184, height: 224))
    }

    func testLinkCoordinatesRespectPageZoomAndRejectInvalidGeometry() {
        var body: [String: Any] = ["x": 10.0, "y": 20.0, "w": 100.0, "h": 24.0]
        XCTAssertEqual(Previews.rect(from: body, pageZoom: 1.5), .init(x: 15, y: 30, width: 150, height: 36))
        XCTAssertNil(Previews.rect(from: body, pageZoom: 0))
        body["x"] = Double.nan
        XCTAssertNil(Previews.rect(from: body, pageZoom: 1))
        body["x"] = 10.0; body["w"] = -1.0
        XCTAssertNil(Previews.rect(from: body, pageZoom: 1))
    }

    func testPageMountDisplaysSummaryUpdatesAndRetractsOnPointerExit() async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do { try await checkPagePresentation() } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        NSApp.setActivationPolicy(policy)
        do { try await compatibilityWait { NSApp.activationPolicy() == policy } }
        catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func checkPagePresentation() async throws {
        let store = TabStore(isPrivate: true, session: [])
        let tab = store.newBlankTab()
        let web = tab.web
        store.palette = nil
        let previews = Previews.shared
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true
        BatterySaver.shared.setMode(.off)
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 700, height: 600),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        store.window = window
        let host = NSHostingView(rootView: TabPage(tab: tab).environmentObject(store)
            .transaction { $0.disablesAnimations = true })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            previews.cancel(); Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
            window.orderOut(nil); window.contentView = nil; window.close()
            store.window = nil; store.dropStashes()
            tab.tearDown(); TabStore.all.removeAll { $0 === store }
            SharedTabs.release(store.tabs)
        }
        web.loadHTMLString("<body style='background:white'>Current article</body>", baseURL: nil)
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return NativeFixtureMountAdmission.surfaceReady(host, in: window)
                && window.isKeyWindow && tab.existingWeb?.window === window && !tab.web.isLoading
        }

        previews.request(URL(string: "http://127.0.0.1:9/preview")!, from: tab)
        let request = previews.begin()
        var preview = Previews.Preview(url: URL(string: "https://example.com/article")!, title: "Destination article")
        preview.summary = "Oranges grow in warm climates."
        preview.loading = false
        previews.publish(preview, for: request)
        try await assertRendered("Oranges grow in warm climates", in: host)

        preview.summary = "Oranges grow in warm climates. Harvest begins in winter."
        previews.publish(preview, for: request)
        try await assertRendered("Harvest begins in winter", in: host)
        let hit = host.hitTest(NSPoint(x: 80, y: host.bounds.height - 180))
        XCTAssertTrue(hit === tab.web || hit?.isDescendant(of: tab.web) == true,
                      "The card must let clicks reach the source page")
        previews.cancel()
        try await assertRendered("Oranges grow in warm climates", in: host, present: false)
    }

    private func assertRendered(_ text: String, in host: NSView, present: Bool = true) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var found = !present
        repeat {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            let strings = try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }.value
            found = strings.joined(separator: " ").contains(text)
            if found, present, let path = ProcessInfo.processInfo.environment["VANE_LINK_PREVIEW_CAPTURE"],
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path))
            }
            if found == present { break }
            try await Task.sleep(for: .milliseconds(30))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(found, present, "The actual page mount must \(present ? "show" : "retract") the preview text: \(text)")
    }
}
