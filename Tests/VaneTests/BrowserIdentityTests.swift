import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class BrowserIdentityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestEnvironment.prepare()
    }

    private func withUserAgent(_ value: String?, run: () async throws -> Void) async throws {
        let previous = UserDefaults.vane.object(forKey: "userAgent")
        UserDefaults.vane.set(value, forKey: "userAgent")
        defer { UserDefaults.vane.set(previous, forKey: "userAgent") }
        try await run()
    }

    private func canvasDensity(zoom: Double) async throws -> [String: Double] {
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true)
        let web = tab.web
        web.frame = NSRect(x: 0, y: 0, width: 816, height: 1056)
        web.pageZoom = zoom
        // Google Docs' kix_core (2026-10-08) uses outerWidth / innerWidth
        // for Safari < 26.4, and native devicePixelRatio for newer Safari.
        // WKWebView reports outerWidth=0: the legacy path snaps to 0.25.
        web.loadHTMLString(#"""
        <canvas id="page" style="width:816px;height:1056px"></canvas>
        <script>
        const version = navigator.userAgent.match(/Version\/(\d+)\.(\d+)/);
        const legacy = version && (+version[1] < 26 || (+version[1] === 26 && +version[2] < 4));
        let density = devicePixelRatio;
        if (legacy) {
          const levels = [.25,.33296337402885684,.5,.6659,.75,.9,1,1.1,1.25,1.5,1.75,2,2.5,3,4,5];
          const ratio = innerWidth > 0 ? outerWidth / innerWidth : 1;
          density *= levels.reduce((best, n) => Math.abs(n-ratio) < Math.abs(best-ratio) ? n : best);
        }
        page.width = Math.ceil(816 * density);
        page.height = Math.ceil(1056 * density);
        window.result = {width:page.width,height:page.height,dpr:devicePixelRatio,outer:outerWidth};
        </script>
        """#, baseURL: URL(string: "https://canvas.test"))
        defer { web.stopLoading(); tab.tearDown() }
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline {
            if let result = try? await web.evaluateJavaScript("window.result"),
               let values = result as? [String: Double] { return values }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "BrowserIdentityTests", code: 1)
    }

    func testDefaultIdentityKeepsCanvasAtNativeDensity() async throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("Native zoom-aware DPR requires WebKit 26.4") }
        try await withUserAgent(nil) {
            for zoom in [1.0, 1.5] {
                let values = try await canvasDensity(zoom: zoom)
                XCTAssertEqual(values["outer"], 0, "Fixture must exercise WKWebView's zero outer width")
                let dpr = try XCTUnwrap(values["dpr"])
                XCTAssertEqual(values["width"], ceil(816 * dpr))
                XCTAssertEqual(values["height"], ceil(1056 * dpr))
            }
        }
    }

    func testSavedOldDefaultDoesNotRestoreLowResolutionCanvas() async throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("Native zoom-aware DPR requires WebKit 26.4") }
        let old = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        try await withUserAgent(old) {
            let values = try await canvasDensity(zoom: 1)
            let dpr = try XCTUnwrap(values["dpr"])
            XCTAssertEqual(values["width"], ceil(816 * dpr))
            XCTAssertEqual(values["height"], ceil(1056 * dpr))
        }
    }

    func testExplicitAlternateIdentitiesArePreserved() async throws {
        for choice in Settings.userAgents.dropFirst() {
            try await withUserAgent(choice.value) {
                let tab = Tab(isPrivate: true)
                defer { tab.tearDown() }
                XCTAssertEqual(tab.web.customUserAgent, choice.value)
            }
        }
    }

    func testSafariUpdateCanLeadTheOperatingSystemVersion() {
        let system = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        XCTAssertEqual(BrowserIdentity.safariVersion(installed: "26.4", system: system), "26.4")
        XCTAssertEqual(BrowserIdentity.safariVersion(installed: "27.0.1", system: system), "27.0.1")
    }

    func testMissingOrInvalidSafariMetadataFallsBackToSystemVersion() {
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 1, patchVersion: 2)
        for installed in [nil, "", "27..1", "27.beta", "18.0", "27.-1"] as [String?] {
            XCTAssertEqual(BrowserIdentity.safariVersion(installed: installed, system: system), "27.1")
        }
    }

    func testChoosingDefaultPersistsAnAutomaticIdentity() async throws {
        try await withUserAgent(Settings.userAgents[1].value) {
            Settings.userAgent = safariUA
            XCTAssertEqual(UserDefaults.vane.string(forKey: "userAgent"), "")
            XCTAssertEqual(Settings.userAgent, safariUA)
            let values = try await canvasDensity(zoom: 1)
            let dpr = try XCTUnwrap(values["dpr"])
            guard #available(macOS 26.4, *) else { return }
            XCTAssertEqual(values["width"], ceil(816 * dpr))
        }
    }
}
