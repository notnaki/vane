import AppKit
import WebKit
import XCTest
@testable import vane

/// Unshown private documents only: no focus, native loop, input, or capture.
@MainActor final class PageResizeStyleTests: XCTestCase {
    func testAttachingALoadedPageWarmsWithoutChangingTheDocument() async throws {
        for mountAfter in [false, true] {
            let web = try await page(variables: 160)
            let before = try await read(web, fingerprint)
            let host = WebHost(mountAfter ? nil : web)
            let window = ResizeStyleModelWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            if mountAfter { host.show(web) }
            defer { window.contentView = nil; host.removePage(); window.close() }
            _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
            let warmed = try await read(web, "String(Boolean(globalThis.__vaneResizeStyle))", world: PageResizeStyle.world)
            let sheets = try await read(web, "String(document.adoptedStyleSheets.length)")
            let after = try await read(web, fingerprint)
            XCTAssertEqual(warmed, "true")
            XCTAssertEqual(sheets, "2", "Warmup keeps the author sheet and one bounded invisible helper")
            XCTAssertEqual(after, before)
        }
    }

    func testHintPreservesAuthorStylesAttributesAndEveryElementsGeometry() async throws {
        let web = try await page(variables: 160)
        defer { web.stopLoading() }
        let before = try await read(web, fingerprint)
        for _ in 0..<4 {
            PageResizeStyle.prepare(web)
            _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
            let after = try await read(web, fingerprint)
            XCTAssertEqual(after, before)
            XCTAssertEqual(web.pageZoom, 1)
            XCTAssertNil(web.window)
        }
    }

    func testFinishRemovesOnlyTheBrowserPropertiesAndReusesOneStylesheet() async throws {
        let web = try await page(variables: 160)
        defer { web.stopLoading() }
        let before = try await read(web, fingerprint)
        for _ in 0..<3 {
            PageResizeStyle.prepare(web)
            _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
            PageResizeStyle.finish(web)
            _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
            let remaining = try await read(web, "JSON.stringify([...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')))")
            XCTAssertEqual(remaining, "[]")
            let count = try await read(web, "String(document.adoptedStyleSheets.length)")
            XCTAssertEqual(count, "2", "One author sheet and at most one reusable browser sheet")
            let after = try await read(web, fingerprint)
            XCTAssertEqual(after, before)
        }
    }

    func testLightweightPagesDoNotGetAnExtraStylesheet() async throws {
        let web = try await page(variables: 2)
        defer { web.stopLoading() }
        PageResizeStyle.prepare(web)
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let count = try await read(web, "String(document.adoptedStyleSheets.length)")
        XCTAssertEqual(count, "1")
    }

    func testCoalescedPreparationsKeepBrowserStorageBounded() async throws {
        let web = try await page(variables: 160)
        defer { web.stopLoading() }
        for _ in 0..<150 { PageResizeStyle.prepare(web) }
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let count = try await read(web, "String([...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')).length)")
        XCTAssertGreaterThan(Int(count) ?? 0, 0)
        XCTAssertLessThanOrEqual(Int(count) ?? .max, 128)
        PageResizeStyle.finish(web)
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let cleaned = try await read(web, "String([...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')).length)")
        XCTAssertEqual(cleaned, "0")
    }

    func testViewportRulesFollowWidthHeightAndUserZoomWithoutChangingLayout() async throws {
        let web = try await page(variables: 160)
        defer { web.stopLoading() }
        for zoom: CGFloat in [1, 1.5] {
            web.pageZoom = zoom
            for size in [NSSize(width: 1100, height: 500), NSSize(width: 800, height: 700), NSSize(width: 1250, height: 450)] {
                PageResizeStyle.prepare(web, nextSize: size)
                web.setFrameSize(size)
                try await compatibilityWait {
                    let width = try await web.evaluateJavaScript("innerWidth") as? NSNumber
                    return abs((width?.doubleValue ?? 0) - size.width / zoom) <= 1
                }
                let json = try await read(web, """
                JSON.stringify({width:innerWidth,height:innerHeight,
                  right:document.querySelector('aside').getBoundingClientRect().right,
                  wide:matchMedia('(min-width:1000px)').matches,
                  privateCount:[...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')).length})
                """)
                let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(values["right"] as? NSNumber).doubleValue, size.width / zoom, accuracy: 1)
                XCTAssertEqual(try XCTUnwrap(values["height"] as? NSNumber).doubleValue, size.height / zoom, accuracy: 1)
                XCTAssertEqual(values["wide"] as? Bool, size.width / zoom >= 1000)
                XCTAssertLessThanOrEqual(try XCTUnwrap(values["privateCount"] as? NSNumber).intValue, 128)
                XCTAssertEqual(web.pageZoom, zoom)
            }
        }
    }

    func testAuthorReplacingAdoptedSheetsKeepsItsNewSheetAndOneBrowserSheet() async throws {
        let web = try await page(variables: 160)
        defer { web.stopLoading() }
        PageResizeStyle.prepare(web)
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        _ = try await read(web, "document.adoptedStyleSheets=[globalThis.authorSheet];'replaced'")
        PageResizeStyle.prepare(web)
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let count = try await read(web, "String(document.adoptedStyleSheets.length)")
        let author = try await read(web, "String(document.adoptedStyleSheets.includes(globalThis.authorSheet))")
        XCTAssertEqual(count, "2")
        XCTAssertEqual(author, "true")
    }

    func testReleaseDuringQueuedPaintCleansTheFinalPagesHint() async throws {
        let web = try await page(variables: 160)
        let host = WebHost(web)
        let window = ResizeStyleModelWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paints: [@MainActor @Sendable () -> Void] = []
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paints.append(callback) }, deadline: { _ in }) { frame, display in
                window.setFrame(frame, display: display)
            }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 600), display: false))
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1100, height: 600), display: false))
        resize.endLiveResize()
        paints.removeFirst()()
        try await compatibilityWait { paints.count == 1 }
        paints.removeFirst()()
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let remaining = try await read(web, "JSON.stringify([...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')))")
        XCTAssertEqual(remaining, "[]")
        XCTAssertEqual(window.frame.width, 1100)
    }

    func testCancellationCleansTheHintAndLatePaintCannotRestoreIt() async throws {
        let web = try await page(variables: 160)
        let host = WebHost(web)
        let window = ResizeStyleModelWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; host.removePage(); window.close() }
        var paint: (@MainActor @Sendable () -> Void)?
        let resize = WindowResizePreparation(window: window,
            presenter: { _, callback in paint = callback }, deadline: { _ in }) { _, _ in XCTFail("Canceled paint committed") }
        XCTAssertTrue(resize.request(frame: NSRect(x: 0, y: 0, width: 1000, height: 600), display: false))
        resize.cancel()
        paint?()
        _ = try await read(web, "'ordered'", world: PageResizeStyle.world)
        let remaining = try await read(web, "JSON.stringify([...getComputedStyle(document.documentElement)].filter(x=>x.startsWith('--vane-resize-')))")
        XCTAssertEqual(remaining, "[]")
    }

    private func page(variables: Int) async throws -> WKWebView {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        let values = (0..<variables).map { "--site-\($0):\($0)px;" }.joined()
        web.loadHTMLString("""
        <html data-owner="site"><title>Resize style ready</title><style>
        :root{\(values)--site-color:rgb(23,50,77)}html[style]{filter:invert(1)}
        body{margin:0}main{width:100vw;color:var(--site-color)}
        aside{position:fixed;right:0;width:40px;height:20px;background:currentColor}
        </style><body><main>Normal scale content<aside></aside></main></body></html>
        """, baseURL: nil)
        try await compatibilityWait { !web.isLoading && web.title == "Resize style ready" }
        _ = try await read(web, """
        globalThis.authorSheet = new CSSStyleSheet();authorSheet.replaceSync('main{padding-top:7px}');
        document.adoptedStyleSheets=[authorSheet];'ready'
        """)
        return web
    }

    private var fingerprint: String {
        """
        JSON.stringify({attributes:[...document.documentElement.attributes].map(a=>[a.name,a.value]),
          author:document.adoptedStyleSheets.includes(globalThis.authorSheet),
          elements:[...document.querySelectorAll('*')].map(el=>{
            const r=el.getBoundingClientRect(),s=getComputedStyle(el);
            return [r.x,r.y,r.width,r.height,s.color,s.backgroundColor,s.fontSize,s.display,s.filter,s.transform];
          })})
        """
    }

    private func read(_ web: WKWebView, _ script: String, world: WKContentWorld = .page) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: world) { result in
                do {
                    guard let string = try result.get() as? String else { throw NSError(domain: "ResizeStyleRead", code: 1) }
                    continuation.resume(returning: string)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private final class ResizeStyleModelWindow: NSWindow {
    override var isVisible: Bool { true }
    override var inLiveResize: Bool { true }
}
