import Foundation
import JavaScriptCore
import XCTest
import WebKit
@testable import vane

@MainActor final class WebSecurityBoundaryTests: XCTestCase {
    func testDeveloperModeRequiresAParsedLoopbackAddress() {
        for host in ["127.attacker.example", "127.0.0.1.attacker.example", "127.999.1.1", "128.0.0.1"] {
            XCTAssertFalse(DeveloperMode.isLocal(URL(string: "https://\(host)/")), host)
        }
        for host in ["127.0.0.1", "127.255.2.3", "[::1]", "[0:0:0:0:0:0:0:1]", "localhost", "api.localhost"] {
            XCTAssertTrue(DeveloperMode.isLocal(URL(string: "http://\(host)/")), host)
        }
    }
    func testReaderEscapesMarkupScalarsWithCombiningMarks() {
        XCTAssertEqual(Reader.esc("&\u{301}<\u{301}>\u{301}\"\u{301}'\u{301}"),
                       "&amp;\u{301}&lt;\u{301}&gt;\u{301}&quot;\u{301}&#39;\u{301}")
        let alt = "\"\u{301} onerror=alert(1) data-tail=\""
        let markup = Reader.render([.init(e: "img", a: ["src": "https://reader.test/missing.png", "alt": alt])], base: nil)
        XCTAssertEqual(markup, "<img src=\"https://reader.test/missing.png\" alt=\"&quot;\u{301} onerror=alert(1) data-tail=&quot;\" loading=\"lazy\">")
    }

    func testDeveloperSecurityIndicatorUsesTrustAndLoadState() {
        let secure = SiteControlModel(host: "developer.test", scheme: "https")
        XCTAssertEqual(DeveloperMode.securityIndicator(secure).glyph, "lock")
        XCTAssertEqual(DeveloperMode.securityIndicator(secure).label, "Connection is secure")
        var certificate = secure; certificate.certificateTrusted = false
        var mixed = secure; mixed.secureContent = false
        var failed = secure; failed.navigationFailed = true
        for site in [certificate, mixed, failed, SiteControlModel()] {
            let indicator = DeveloperMode.securityIndicator(site)
            XCTAssertFalse(["lock", "lock.fill"].contains(indicator.glyph))
            XCTAssertNotEqual(indicator.label, "Connection is secure")
            XCTAssertEqual(indicator.glyph, site.glyph)
            XCTAssertEqual(indicator.label, site.connection)
        }
    }

    func testPreviewTransportPolicyUpgradesAndRejectsInsecureRedirects() throws {
        let suite = "vane-preview-security-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults
        HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        let profile = UUID(), other = UUID()
        let http = URL(string: "http://preview.test:80/article?q=private")!
        let https = URL(string: "https://preview.test/article?q=private")!
        XCTAssertEqual(Previews.requestURL(http, profileID: profile), https)
        XCTAssertFalse(Previews.allowsNavigation(http, profileID: profile), "A redirect to plaintext must stop without an interstitial")
        XCTAssertTrue(Previews.allowsNavigation(https, profileID: profile))
        XCTAssertEqual(Previews.httpsPolicy(https, profileID: profile), .errorOnFailure)
        HTTPSOnly.allow(host: "preview.test", profileID: profile)
        XCTAssertEqual(Previews.httpsPolicy(http, profileID: profile), .keepAsRequested)
        XCTAssertEqual(Previews.httpsPolicy(http, profileID: other), .errorOnFailure)
        XCTAssertEqual(Previews.requestURL(http, profileID: profile), http)
        XCTAssertTrue(Previews.allowsNavigation(http, profileID: profile))
        XCTAssertEqual(Previews.requestURL(http, profileID: other), https)
        XCTAssertFalse(Previews.allowsNavigation(http, profileID: other))
        let local = URL(string: "http://localhost:3000/article")!
        XCTAssertEqual(Previews.requestURL(local, profileID: other), local)
        XCTAssertTrue(Previews.allowsNavigation(local, profileID: other))
        XCTAssertEqual(Previews.httpsPolicy(local, profileID: other), .keepAsRequested)
        XCTAssertFalse(Previews.allowsNavigation(URL(string: "file:///tmp/preview")!, profileID: profile))
        HTTPSOnly.enabled = false
        XCTAssertEqual(Previews.httpsPolicy(https, profileID: other), .keepAsRequested)
        XCTAssertEqual(Previews.requestURL(http, profileID: other), http)
        XCTAssertTrue(Previews.allowsNavigation(http, profileID: other))
    }

    func testFindMeasurementDoesNotExposeQueryToPagePrototypes() async throws {
        TestEnvironment.prepare(); WebKitStartup.prepare()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        defer { web.stopLoading() }
        web.loadSimulatedRequest(URLRequest(url: URL(string: "https://find.test/")!), responseHTML: "<body>Sensitive-Needle Sensitive-Needle</body>")
        try await compatibilityWait {
            try await web.evaluateJavaScript("document.body?.textContent === 'Sensitive-Needle Sensitive-Needle'") as? Bool == true
        }
        _ = try await web.evaluateJavaScript("""
            window.capturedFindQueries = [];
            const original = String.prototype.toLowerCase;
            String.prototype.toLowerCase = function () {
                capturedFindQueries.push(String(this));
                return original.call(this);
            };
            true;
            """)
        let measured = await Find.measure("Sensitive-Needle", in: web)
        XCTAssertEqual(measured?.count, 2, "The real measurement must execute against this document")
        let captured = try await web.evaluateJavaScript("capturedFindQueries") as? [String]
        XCTAssertEqual(captured, [])
    }

}
