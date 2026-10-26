import Foundation
import XCTest
@testable import vane

final class FileTitleTests: XCTestCase {
    func testUntitledRemoteDocumentUsesItsURLFilename() {
        XCTAssertEqual(Files.title(page: nil, url: URL(string: "https://example.com/report.pdf?token=private")), "report.pdf")
    }

    func testUntitledRemotePageUsesOnlyItsHost() {
        XCTAssertEqual(Files.title(page: "", url: URL(string: "https://example.com/download?token=private")), "example.com")
    }

    func testWhitespaceOnlyTitleUsesDocumentFallback() {
        XCTAssertEqual(Files.title(page: " \n ", url: URL(string: "https://example.com/report.pdf")), "report.pdf")
    }

    func testMeaningfulPageTitleStillWins() {
        XCTAssertEqual(Files.title(page: "Research notes", url: URL(string: "https://example.com/report.pdf")), "Research notes")
    }

    func testLocalFileAndBlankTabKeepTheirFallbacks() {
        XCTAssertEqual(Files.title(page: "", url: URL(fileURLWithPath: "/tmp/report.pdf")), "report.pdf")
        XCTAssertEqual(Files.title(page: nil, url: nil), "New Tab")
        XCTAssertEqual(Files.title(page: "", url: URL(string: "about:blank")), "New Tab")
    }
}
