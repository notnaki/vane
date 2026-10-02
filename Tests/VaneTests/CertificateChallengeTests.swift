import AppKit
import Security
import WebKit
import XCTest
@testable import vane

/// Only the network challenge is supplied by the fixture. The trust evaluation,
/// navigation delegate, window sheet and rejection all run through production code.
@MainActor final class CertificateChallengeTests: XCTestCase {
    private final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        let trust: SecTrust
        override var serverTrust: SecTrust? { trust }
        override func copy(with zone: NSZone? = nil) -> Any { self }

        init(host: String, port: Int, trust: SecTrust) {
            self.trust = trust
            super.init(host: host, port: port, protocol: "https", realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }

        required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func selfSignedTrust(host: String) throws -> SecTrust {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pem = directory.appendingPathComponent("cert.pem")
        let der = directory.appendingPathComponent("cert.der")
        for arguments in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
             "-subj", "/CN=certificate-fixture.invalid", "-keyout",
             directory.appendingPathComponent("key.pem").path, "-out", pem.path],
            ["x509", "-in", pem.path, "-outform", "der", "-out", der.path]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(contentsOf: der) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString),
                                                    &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private func challenge(navigation: String?, host: String, port: Int = 443,
                           expectsPrompt: Bool) async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let tab = Tab(isPrivate: true, profileID: UUID())
        tab.certificateNavigationURL = navigation.flatMap(URL.init(string:))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.orderFront(nil)
        defer { tab.tearDown(); window.close() }

        let space = TrustSpace(host: host, port: port, trust: try selfSignedTrust(host: host))
        let request = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender())
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        let task = Task { result = await tab.webView(tab.web, respondTo: request) }
        let deadline = Date.now.addingTimeInterval(10)
        while result == nil && window.attachedSheet == nil && Date.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let prompted = window.attachedSheet != nil
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        // Invalid connections must finish rejected, even when there was no sheet.
        if result == nil && !prompted { task.cancel(); CertificateTrust.navigationStarted(in: tab) }
        await task.value
        XCTAssertEqual(prompted, expectsPrompt)
        XCTAssertEqual(result?.0, .cancelAuthenticationChallenge)
        XCTAssertNil(result?.1)
    }

    func testInvalidSentryConnectionIsRejectedWithoutSheetDuringNavigation() async throws {
        try await challenge(navigation: "https://app.kognity.com/study",
                            host: "o4506983207337984.ingest.us.sentry.io", expectsPrompt: false)
    }

    func testInvalidBackgroundConnectionAfterCommitIsRejectedWithoutSheet() async throws {
        try await challenge(navigation: nil, host: "example.com", expectsPrompt: false)
    }

    func testDirectInvalidPageStillOffersCertificateWarning() async throws {
        try await challenge(navigation: "https://example.com:8443/study", host: "example.com",
                            port: 8443, expectsPrompt: true)
    }
}
