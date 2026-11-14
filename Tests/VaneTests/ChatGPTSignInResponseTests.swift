import CryptoKit
import Foundation
import JavaScriptCore
import XCTest
@testable import vane

final class ChatGPTSignInResponseTests: XCTestCase {
    func testAcceptedCallbackClosesWithOnlyItsScriptAllowed() throws {
        let (headers, body) = try response(success: true)
        XCTAssertTrue(headers.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(headers.contains("Content-Type: text/html; charset=utf-8\r\n"))
        let start = try XCTUnwrap(body.range(of: "<script>"))
        let end = try XCTUnwrap(body.range(of: "</script>"))
        let script = String(body[start.upperBound..<end.lowerBound])
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        XCTAssertTrue(headers.contains("default-src 'none'; script-src 'sha256-\(hash)'"))
        XCTAssertFalse(headers.contains("'unsafe-inline'"))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("var closeCalls = 0; var window = {close: function() {closeCalls++;}};")
        context.evaluateScript(script)
        XCTAssertNil(context.exception)
        XCTAssertEqual(context.objectForKeyedSubscript("closeCalls")?.toInt32(), 1)
        XCTAssertTrue(body.contains("You can close this tab"), "Keep instructions when a browser refuses to close")
    }

    func testRejectedCallbackDoesNotCloseOrAllowScripts() throws {
        let (headers, body) = try response(success: false)
        XCTAssertTrue(headers.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
        XCTAssertTrue(headers.contains("Content-Security-Policy: default-src 'none'\r\n"))
        XCTAssertFalse(body.contains("<script>"))
        XCTAssertTrue(body.contains("could not be accepted"))
    }

    private func response(success: Bool) throws -> (String, String) {
        let wire = String(decoding: ChatGPTSignInResponse.data(success: success), as: UTF8.self)
        let separator = try XCTUnwrap(wire.range(of: "\r\n\r\n"))
        let headers = String(wire[..<separator.lowerBound]) + "\r\n"
        let body = String(wire[separator.upperBound...])
        XCTAssertTrue(headers.contains("Content-Length: \(body.utf8.count)\r\n"))
        XCTAssertTrue(headers.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(headers.contains("Connection: close\r\n"))
        return (headers, body)
    }
}
