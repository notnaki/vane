import AppKit
import SwiftUI
import Vision
import XCTest
@testable import vane

@MainActor private final class LinkPreviewStreamFixture: ObservableObject {
    @Published var preview = Previews.Preview(url: URL(string: "https://example.com/article")!, title: "A growing preview")
}

private struct LinkPreviewStreamSurface: View {
    @ObservedObject var fixture: LinkPreviewStreamFixture
    var body: some View {
        LinkPreviewAnimatedCard(preview: fixture.preview, size: .init(width: 320, height: 350))
    }
}

@MainActor final class LinkPreviewPresentationTests: XCTestCase {
    func testLoadingCardDoesNotReserveABlankScreenshotOrDescription() {
        let preview = Previews.Preview(url: URL(string: "https://example.com/article")!, title: "example.com")
        let host = NSHostingView(rootView: LinkPreviewCard(preview: preview, size: .init(width: 320, height: 350)))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.height, 90, "Loading should be a compact status row, not a blank page-sized card")
    }

    func testCardPhasesStayCompactAndRenderInBothAppearances() throws {
        let url = URL(string: "https://example.com/article")!
        var loading = Previews.Preview(url: url, title: "example.com")
        loading.loading = true
        var metadata = Previews.Preview(url: url, title: "A useful article to read next")
        metadata.description = "A short description of the destination, available while its image finishes loading."
        var ready = metadata
        ready.loading = false
        let art = NSImage(size: NSSize(width: 1000, height: 700))
        art.lockFocus()
        NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 700).fill()
        NSColor.systemBlue.setFill(); NSRect(x: 32, y: 150, width: 936, height: 518).fill()
        art.unlockFocus()
        ready.image = art
        var unavailable = loading
        unavailable.loading = false
        for (name, preview) in [("loading", loading), ("metadata", metadata), ("ready", ready), ("unavailable", unavailable)] {
            for (theme, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
                let host = NSHostingView(rootView: LinkPreviewCard(preview: preview, size: .init(width: 320, height: 350))
                    .preferredColorScheme(scheme))
                host.setFrameSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.bounds.width, 320)
                XCTAssertLessThanOrEqual(host.bounds.height, preview.image == nil ? 160 : 280)
                if let directory = ProcessInfo.processInfo.environment["VANE_LINK_CARD_CAPTURES"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(theme).png"))
                }
            }
        }
    }

    func testShortTextDoesNotReserveSpaceForMissingLines() {
        var preview = Previews.Preview(url: URL(string: "https://example.com/article")!, title: "A short article")
        preview.description = "A short note."
        preview.loading = false
        let host = NSHostingView(rootView: LinkPreviewCard(preview: preview, size: .init(width: 320, height: 350)))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(host.fittingSize.height, 100, "The card should end after its actual text and padding")
    }

    func testMountedTypingExpandsThroughIntermediateTextHeights() async throws {
        TestEnvironment.prepare()
        guard !Motion.reduced else { throw XCTSkip("The active system motion policy requires immediate text") }
        // Measuring a visible card needs a running AppKit loop, not foreground
        // activation. Avoid a regular→prohibited policy handoff that can enqueue
        // application hiding after the next fixture has already mounted its window.
        let loop = try await NativeFixtureApplicationLoop.acquire()
        var failure: (any Error)?
        do { try await checkMountedTyping() } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func checkMountedTyping() async throws {
        let fixture = LinkPreviewStreamFixture()
        let host = NSHostingView(rootView: LinkPreviewStreamSurface(fixture: fixture))
        let window = NSWindow(contentRect: .init(x: 120, y: 120, width: 320, height: 350),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await compatibilityWait {
            host.layoutSubtreeIfNeeded()
            return NativeFixtureMountAdmission.surfaceReady(host, in: window) && window.isVisible && NSApp.isRunning
        }
        let initial = host.fittingSize.height
        var complete = fixture.preview
        complete.summary = "The card follows the words as they arrive. Each new line makes room for more of the answer, keeping the preview close to the link without reserving a large empty block below the text."
        complete.loading = false
        let completedHost = NSHostingView(rootView: LinkPreviewCard(preview: complete, size: .init(width: 320, height: 350)))
        completedHost.layoutSubtreeIfNeeded()
        let finalHeight = completedHost.fittingSize.height
        // Admission above concerns the surface, never the typing outcome. Observe from
        // the first update so this cannot pass by sampling only the completed answer.
        fixture.preview = complete
        let deadline = ContinuousClock.now + .seconds(3)
        var intermediate = Set<Int>()
        repeat {
            host.layoutSubtreeIfNeeded()
            let height = host.fittingSize.height
            if height > initial + 1, height < finalHeight - 1 {
                intermediate.insert(Int(height.rounded()))
                if let directory = ProcessInfo.processInfo.environment["VANE_LINK_CARD_CAPTURES"] {
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: directory).appendingPathComponent("typing-\(Int(height)).png"))
                }
            }
            if height >= finalHeight - 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTAssertGreaterThanOrEqual(intermediate.count, 2, "A mounted streaming card must grow as visible lines are typed")
        XCTAssertEqual(host.fittingSize.height, finalHeight, accuracy: 1, "The final card should fit its completed text")
    }

    func testChangedAISettingsRejectCachedSummaryOnRehover() {
        TestEnvironment.prepare()
        let previews = Previews(), tab = vane.Tab(isPrivate: true)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        let revision = UserDefaults.vane.integer(forKey: "aiSettingsRevision")
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        defer {
            previews.cancel(); tab.tearDown()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
            UserDefaults.vane.set(revision, forKey: "aiSettingsRevision")
        }
        let url = URL(string: "https://example.com/article")!
        previews.request(url, from: tab)
        var cached = Previews.Preview(url: url, title: "Cached article", image: NSImage())
        cached.summary = "Summary from the previous AI settings."
        previews.publish(cached, for: previews.begin())
        previews.cancel()
        previews.request(url, from: tab)
        XCTAssertEqual(previews.preview(for: tab)?.summary, cached.summary,
                       "Unchanged settings should retain the completed preview")
        previews.cancel()
        UserDefaults.vane.set(revision + 1, forKey: "aiSettingsRevision")
        previews.request(url, from: tab)
        XCTAssertEqual(previews.preview(for: tab)?.summary, "",
                       "Disabling or rerouting AI must not revive a previous summary")
        XCTAssertNil(previews.preview(for: tab)?.image, "Settings changes must revalidate the cached preview")
    }

    func testNavigationDismissesOnlyTheRequestingTabsPreview() throws {
        TestEnvironment.prepare()
        let previews = Previews.shared
        let source = vane.Tab(isPrivate: true), other = vane.Tab(isPrivate: true)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        defer {
            previews.cancel(); source.tearDown(); other.tearDown()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
        }
        let otherWeb = other.web
        let otherNavigation = try XCTUnwrap(otherWeb.loadHTMLString("<title>Other tab</title>", baseURL: nil))
        previews.request(URL(string: "https://example.com/article")!, from: source)
        other.webView(otherWeb, didStartProvisionalNavigation: otherNavigation)
        XCTAssertNotNil(previews.preview(for: source), "Another tab's navigation must preserve the hovered card")

        let sourceWeb = source.web
        let sourceNavigation = try XCTUnwrap(sourceWeb.loadHTMLString("<title>New source page</title>", baseURL: nil))
        source.webView(sourceWeb, didStartProvisionalNavigation: sourceNavigation)
        XCTAssertNil(previews.preview(for: source), "Leaving the source document must dismiss its card")
    }

    func testRejectedCachedSessionKeepsTheHoveredLinkPositionOnRetry() async throws {
        TestEnvironment.prepare()
        let profile = ProfileManager.shared.create(name: "Link preview geometry fixture")
        let previews = Previews(sessionObserverFactory: { _, _ in nil })
        let tab = vane.Tab(profileID: profile.id)
        let enabled = Previews.enabled, mode = BatterySaver.shared.mode
        Previews.enabled = true; BatterySaver.shared.setMode(.off)
        defer {
            previews.cancel(); tab.tearDown()
            Previews.enabled = enabled; BatterySaver.shared.setMode(mode)
            Store.forget(profile.id); _ = ProfileManager.shared.delete(profile.id)
        }
        let url = URL(string: "http://127.0.0.1:9/preview")!
        let cached = Previews.Preview(url: url, title: "Unverified cached session", image: NSImage())
        previews.publish(cached, for: previews.begin())
        let rect = CGRect(x: 240, y: 180, width: 120, height: 24)
        // The cached pixels have no verified session snapshot. The real cookie-store
        // read must reject them and restart the request, preserving the link anchor.
        previews.request(url, from: tab, rect: rect)
        try await compatibilityWait { previews.current?.title == "127.0.0.1" }
        XCTAssertNil(previews.current?.image, "The rejected cached pixels must not be presented")
        XCTAssertEqual(previews.linkRect, rect, "Session revalidation must not move the card to the pane origin")
    }

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
            viewport: .init(width: 800, height: 600)), .init(x: 50, y: 88, width: 320, height: 280))
        XCTAssertEqual(LinkPreviewLayout.frame(link: .init(x: 760, y: 570, width: 30, height: 20),
            viewport: .init(width: 800, height: 600)), .init(x: 472, y: 282, width: 320, height: 280))
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
        do {
            try await compatibilityWait {
                host.layoutSubtreeIfNeeded()
                return NativeFixtureMountAdmission.surfaceReady(host, in: window)
                    && window.isKeyWindow && tab.existingWeb?.window === window && !tab.web.isLoading
            }
        } catch {
            FileHandle.standardError.write(Data("LINK_PREVIEW_ADMISSION running=\(NSApp.isRunning) active=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) mounted=\(tab.existingWeb?.window === window) loading=\(tab.existingWeb?.isLoading ?? false) surface=\(NativeFixtureMountAdmission.surfaceReady(host, in: window))\n".utf8))
            throw error
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
