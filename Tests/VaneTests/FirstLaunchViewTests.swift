import AppKit
import SwiftUI
import Vision
import XCTest
@testable import vane

@MainActor final class FirstLaunchViewTests: XCTestCase {
    func testSetupStartsWithoutChromeAndCompletesOnlyOnAnExplicitFinish() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { retire(store) }
        var completions = 0
        let setup = FirstLaunchSetup(store: store, finish: { completions += 1 })
        XCTAssertFalse(setup.showsSetupControls)
        setup.advance()
        XCTAssertTrue(setup.showsSetupControls)
        XCTAssertEqual(setup.step, .tabs)
        setup.back()
        XCTAssertFalse(setup.showsSetupControls)
        for _ in 1..<WelcomeStep.allCases.count { setup.advance() }
        XCTAssertEqual(setup.step, .ready)
        XCTAssertEqual(completions, 0)
        setup.advance()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(store.tabs.isEmpty)
    }

    func testChoicesAndTheProductionThemeEditorPersistSettings() {
        TestEnvironment.prepare()
        let store = makeStore()
        defer { retire(store) }
        let engine = Search.current
        defer { Search.current = engine }
        var completions = 0
        let setup = FirstLaunchSetup(store: store, finish: { completions += 1 })
        setup.chooseColor("#7AA982")
        XCTAssertEqual(store.currentSpace?.colorHex, "#7AA982")
        XCTAssertEqual(ProfileManager.shared.spaces(for: store.profileID).first { $0.id == store.currentSpaceID }?.colorHex, "#7AA982")
        setup.chooseEngine(Search.builtIn.first { $0.id == "duckduckgo" }!)
        XCTAssertEqual(Search.current.id, "duckduckgo")
        var edited = try! XCTUnwrap(store.currentSpace)
        Spaces.setPalette([ThemeColor(red: 0.2, green: 0.4, blue: 0.8), ThemeColor(red: 0.7, green: 0.3, blue: 0.6)], on: &edited)
        edited.tint = 0.7
        edited.grain = 0.3
        setup.applySpace(edited)
        XCTAssertEqual(Spaces.palette(of: store.currentSpace!).count, 2)
        XCTAssertEqual(store.currentSpace?.tint, 0.7)
        XCTAssertEqual(store.currentSpace?.grain, 0.3)
        XCTAssertEqual(completions, 0)
    }

    func testGuidedPreviewScalesUniformlyInsteadOfFlatteningTheBrowser() {
        for bounds in [CGSize(width: 720, height: 450), CGSize(width: 560, height: 350),
                       CGSize(width: 752, height: 190), CGSize(width: 1000, height: 700)] {
            let scale = WelcomePreviewLayout.scale(in: bounds)
            let drawn = CGSize(width: WelcomePreviewLayout.canvas.width * scale,
                               height: WelcomePreviewLayout.canvas.height * scale)
            XCTAssertEqual(drawn.width / drawn.height, 1.6, accuracy: 0.0001)
            XCTAssertLessThanOrEqual(drawn.width - bounds.width, 1e-9)
            XCTAssertLessThanOrEqual(drawn.height - bounds.height, 1e-9)
        }
    }

    func testDrawnBrowserFollowsUncommittedColorStrengthAndGrain() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        let store = makeStore()
        let host = NSHostingView(rootView: WelcomeBrowserPreview(sample: .constant(WelcomeBrowserSample()),
            query: .constant("architecture"), store: store, tint: .green,
            palette: WelcomePalette(dark: true), showsSplit: false, showsSearch: false,
            engine: "Google", reduced: true).transaction { $0.disablesAnimations = true })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 880, height: 550),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        var failure: (any Error)?
        do {
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(host.window === window)
            func pixels() throws -> Data {
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.cgImage)
                let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 30, y: 360, width: 150, height: 100)))
                return try XCTUnwrap(NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]))
            }
            await Task.yield()
            let before = try pixels()
            var live = try XCTUnwrap(store.currentSpace)
            Spaces.setPalette([ThemeColor(red: 0.9, green: 0.15, blue: 0.2)], on: &live)
            store.previewSpace = live
            await Task.yield()
            let color = try pixels()
            XCTAssertNotEqual(before, color, "A held color drag must repaint the drawn sidebar before saving")
            live.tint = 0.05
            store.previewSpace = live
            await Task.yield()
            let strength = try pixels()
            XCTAssertNotEqual(color, strength, "The strength slider must repaint before release")
            live.grain = 1
            store.previewSpace = live
            await Task.yield()
            XCTAssertNotEqual(strength, try pixels(), "The grain dial must repaint before release")
        } catch { failure = error }
        window.contentView = nil; window.close(); retire(store)
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    func testNativeStepsRenderAtMinimumAndLargeWindowSizes() async throws {
        TestEnvironment.prepare()
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .regular)
        var failure: (any Error)?
        do { try await renderSteps() } catch { failure = error }
        do { try await loop.close() } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }

    private func renderSteps() async throws {
        let store = makeStore()
        defer { retire(store) }
        let setup = FirstLaunchSetup(store: store, importHome: Store.directory.appendingPathComponent("no-browser-fixture"), finish: {})
        let host = NSHostingView(rootView: FirstLaunchView(setup: setup)
            .transaction { $0.disablesAnimations = true; $0.animation = nil })
        host.sizingOptions = []
        let window = OnboardingViewportWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Native subviews must belong to the entire admitted viewport. A1200×800
        // hosting view inside an800×500 owner lets SwiftUI cull off-owner controls.
        // This fixture-only window admits exact sizes without the screen's height cap.
        let viewport = NSView()
        window.contentView = viewport
        viewport.addSubview(host)
        host.autoresizingMask = []
        defer { window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(host.window === window)
        for dark in [true, false] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for size in [NSSize(width: 800, height: 500), NSSize(width: 1200, height: 800)] {
                window.setContentSize(size)
                XCTAssertEqual(viewport.bounds.size, size)
                guard viewport.bounds.size == size else { return }
                host.setFrameOrigin(.zero)
                host.setFrameSize(size)
                while setup.step != .welcome { setup.back() }
                for index in 0..<WelcomeStep.allCases.count {
                    await Task.yield()
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.frame.size, size)
                    XCTAssertEqual(host.visibleRect.size, size, "The actual native owner must admit the complete render viewport")
                    guard host.visibleRect.size == size else { return }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try XCTUnwrap(bitmap.cgImage)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                    if index == 0 {
                        XCTAssertTrue(visible.contains("make yourself at home"), visible)
                        XCTAssertFalse(visible.contains("skip setup"), visible)
                        XCTAssertFalse(visible.contains("your tabs, your ideas"), visible)
                        XCTAssertFalse(visible.contains("few small choices"), visible)
                    } else {
                        // Full-page OCR can merge the small top-right action with unrelated
                        // app artwork; inspect the header's own region for this assertion.
                        let header = VNRecognizeTextRequest()
                        // Vision's accurate detector misses the small muted label in
                        // preserved dark800 captures. The fast detector reads those same
                        // pixels; retain the region and exact required-content assertion.
                        header.recognitionLevel = .fast
                        header.recognitionLanguages = ["en-US"]
                        header.regionOfInterest = CGRect(x: 0.65, y: 0.84, width: 0.35, height: 0.16)
                        try VNImageRequestHandler(cgImage: image).perform([header])
                        let headerText = (header.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                        XCTAssertTrue(headerText.contains("skip setup"),
                                      "\(dark ? "dark" : "light") \(Int(size.width))×\(Int(size.height)) \(setup.step): \(headerText)")
                        // Large sample-page text can crowd small controls out of full-page
                        // OCR. Read the actual persistent footer, as we do for its header.
                        let footer = VNRecognizeTextRequest()
                        footer.recognitionLevel = .accurate
                        footer.recognitionLanguages = ["en-US"]
                        footer.regionOfInterest = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.16)
                        try VNImageRequestHandler(cgImage: image).perform([footer])
                        let footerText = (footer.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
                        XCTAssertTrue(footerText.contains(setup.step == .bringBrowser ? "start fresh" : setup.step == .ready ? "start browsing" : "continue"), footerText)
                        if setup.step == .ai {
                            XCTAssertTrue(visible.contains("a little help, when you want it"), visible)
                            XCTAssertTrue(visible.contains("stays off until you turn it on"), visible)
                        }
                    }
                    if let directory = ProcessInfo.processInfo.environment["VANE_ONBOARDING_CAPTURE_DIR"] {
                        let file = URL(fileURLWithPath: directory).appendingPathComponent("\(dark ? "dark" : "light")-\(Int(size.width))-\(index).png")
                        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
                    }
                    if index < WelcomeStep.allCases.count - 1 { setup.advance() }
                }
            }
        }
        // Split View is an interactive state with less room than the resting preview.
        for dark in [true, false] {
            let split = NSHostingView(rootView: WelcomeBrowserPreview(
                sample: .constant(WelcomeBrowserSample(split: true)), query: .constant("architecture"),
                store: store, tint: .green, palette: WelcomePalette(dark: dark), showsSplit: true,
                showsSearch: false, engine: "Google", reduced: true))
            split.sizingOptions = []
            window.contentView = split
            window.setContentSize(NSSize(width: 752, height: 190))
            await Task.yield()
            split.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(split.bitmapImageRepForCachingDisplay(in: split.bounds))
            split.cacheDisplay(in: split.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["VANE_ONBOARDING_CAPTURE_DIR"] {
                let file = URL(fileURLWithPath: directory).appendingPathComponent("\(dark ? "dark" : "light")-split-minimum.png")
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
            }
        }
    }

    private func makeStore() -> TabStore {
        TabStore(space: Spaces.resolve(nil, for: ProfileManager.shared.active), session: [])
    }
    private func retire(_ store: TabStore) {
        TabStore.all.removeAll { $0 === store }
        SharedTabs.release(store.tabs)
    }
}

/// Does not alter the app's windows; only this fixed-viewport render fixture may
/// extend beyond a small runner's screen while retaining its complete native owner.
private final class OnboardingViewportWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
