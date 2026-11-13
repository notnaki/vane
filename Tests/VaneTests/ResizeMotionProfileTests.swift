import AppKit
import WebKit
import XCTest

/// File/identity handshake only. The private document is never mounted or shown;
/// no sampler process, native application loop, or foreground action is started.
@MainActor final class ResizeMotionProfileTests: XCTestCase {
    func testUnshownOwnedDocumentWritesPrivateStableIdentityAndCompletedInterval() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        defer { web.stopLoading() }
        web.loadHTMLString("<title>Owned profile</title><body>fixture</body>", baseURL: nil)
        try await compatibilityWait { !web.isLoading && web.title == "Owned profile" }
        XCTAssertNil(web.window)
        XCTAssertNil(try ResizeMotionProfile.begin(environment: [:], web: web, sidebar: true))
        let path = NativeFixtureRetirement.canonical(FileManager.default.temporaryDirectory.path)
            + "/vane-profile-contract-" + UUID().uuidString
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let token = String(repeating: "a", count: 32)
        func write(_ name: String, _ value: [String: Any]) throws {
            let file = directory.appendingPathComponent(name)
            try JSONSerialization.data(withJSONObject: value).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        try write("contract.json", ["schema": 1, "token": token])
        let environment = ["VANE_RESIZE_PROFILE_DIR": path, "VANE_RESIZE_PROFILE_TOKEN": token]
        var wrongToken = environment
        wrongToken["VANE_RESIZE_PROFILE_TOKEN"] = String(repeating: "b", count: 32)
        XCTAssertThrowsError(try ResizeMotionProfile.begin(environment: wrongToken, web: web, sidebar: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready.json").path))
        let profile = try XCTUnwrap(ResizeMotionProfile.begin(environment: environment, web: web, sidebar: true))
        let readyURL = directory.appendingPathComponent("ready.json")
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: readyURL)) as? [String: Any])
        let ui = try XCTUnwrap(ready["ui"] as? [String: Any])
        let content = try XCTUnwrap(ready["content"] as? [String: Any])
        let owned = try XCTUnwrap(NativeFixtureDiagnostics.ownedContentIdentity(for: web))
        XCTAssertEqual(ui["pid"] as? Int32, getpid())
        XCTAssertEqual(content["pid"] as? Int32, owned.pid)
        XCTAssertEqual(content["start"] as? UInt64, owned.start)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: readyURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertNil(ready["began"])
        let began = CACurrentMediaTime()
        let ended = began + 0.01
        try write("release.json", ["schema": 1, "token": token, "status": 0])
        try await profile.finish(began: began, ended: ended, web: web)
        let finished = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("finished.json"))) as? [String: Any])
        XCTAssertEqual(finished["ownershipHeld"] as? Bool, true)
        XCTAssertEqual(finished["began"] as? Double, began)
        XCTAssertEqual(finished["ended"] as? Double, ended)
        XCTAssertNil(web.window)
    }
}
