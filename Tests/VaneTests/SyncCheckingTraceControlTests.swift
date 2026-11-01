import AppKit
import XCTest

@MainActor final class SyncCheckingTraceControlTests: XCTestCase {
    func testRealSynchronousCheckerPassesThroughTrace() async throws {
        TestEnvironment.prepare()
        let policy = NSApplication.shared.activationPolicy()
        defer { NSApplication.shared.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let results = checker.check("fixture", range: NSRange(location: 0, length: 7),
            types: NSTextCheckingResult.CheckingType.orthography.rawValue, options: [:],
            inSpellDocumentWithTag: tag, orthography: nil, wordCount: nil)
        XCTAssertNotNil(results)
        _ = checker.checkSpelling(of: "fixture", startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: tag, wordCount: nil)
        try await loop.close()
    }
}
