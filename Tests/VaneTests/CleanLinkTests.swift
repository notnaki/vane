import AppKit
import XCTest
@testable import vane

final class CleanLinkTests: XCTestCase {
    func testRemovesTrackingWhilePreservingPageParametersAndFragment() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/article?id=42&utm_source=newsletter&fbclid=click&q=swift#section"))
        XCTAssertEqual(CleanLink.string(for: url), "https://example.com/article?id=42&q=swift#section")
    }

    func testTrackingNamesAreCaseInsensitiveAndPercentDecoded() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/?UTM_campaign=sale&%66bclid=click&gclid=one&gclid=two&msclkid=three&mc_cid=four&mc_eid=five"))
        XCTAssertEqual(CleanLink.string(for: url), "https://example.com/")
    }

    func testPreservesRawEncodingOrderRepeatedAndEmptyValues() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a%2Fb?q=a+b&q=a%20b&flag&empty=&redirect=https%3A%2F%2Fother.test%2F%3Futm_source%3Dkeep&utm_medium=email#utm_source=keep"))
        XCTAssertEqual(CleanLink.string(for: url), "https://example.com/a%2Fb?q=a+b&q=a%20b&flag&empty=&redirect=https%3A%2F%2Fother.test%2F%3Futm_source%3Dkeep#utm_source=keep")
    }

    func testDoesNotGuessAtFunctionalParameters() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/?ref=book&source=search&feature=share&si=token&id=42&campaign=event"))
        XCTAssertEqual(CleanLink.string(for: url), url.absoluteString)
    }

    func testLeavesCleanAndNonWebURLsUnchanged() throws {
        for value in ["https://example.com/path#section", "https://example.com/?", "file:///tmp/page?utm_source=keep", "custom://host?fbclid=keep"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(CleanLink.string(for: url), value)
        }
    }

    @MainActor func testCopyWritesOnlyCleanURLToPasteboard() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous contents", forType: .string)
        CleanLink.copy(try XCTUnwrap(URL(string: "https://example.com/?id=42&utm_source=email")), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/?id=42")
    }
}
