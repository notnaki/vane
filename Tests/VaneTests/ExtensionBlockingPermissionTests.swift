import WebKit
import XCTest
@testable import vane

@MainActor final class ExtensionBlockingPermissionTests: XCTestCase {
    private func extensionFixture(blocking: Bool) async throws -> WKWebExtension {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blocking-permission-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 2, "name": "uBlock Origin", "version": "1.0",
            "permissions": ["storage", "webRequest", "<all_urls>"] + (blocking ? ["webRequestBlocking"] : [])]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return try await WKWebExtension(resourceBaseURL: folder)
    }

    func testDisplayNameAndRequestObservationCannotAuthorizeNativeBlocking() async throws {
        let observer = try await extensionFixture(blocking: false)
        XCTAssertTrue(observer.requestedPermissions.contains(.init(rawValue: "webRequest")))
        XCTAssertFalse(ExtensionFilterBridge.recognizes(observer))
        let blocker = try await extensionFixture(blocking: true)
        XCTAssertTrue(ExtensionFilterBridge.recognizes(blocker))
    }
}
