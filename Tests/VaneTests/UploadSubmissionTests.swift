import AppKit
import WebKit
import XCTest
@testable import vane

/// Tests WebKit's selected-URL contract, bytes and submission. Native picker acceptance
/// is deliberately scored separately; this delegate supplies synthetic selections.
@MainActor final class UploadSubmissionTests: XCTestCase {
    private var tab: Tab!
    private var server: CompatibilityServer!
    private var directory: URL!
    private var selection: SyntheticUploadSelection!
    private var oldHTTPS = true

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        oldHTTPS = HTTPSOnly.enabled; HTTPSOnly.enabled = false
        tab = Tab(isPrivate: true)
        selection = SyntheticUploadSelection()
        tab.web.uiDelegate = selection
        server = try CompatibilityServer()
        try await compatibilityWait { self.server.port != nil }
        directory = Store.directory.appendingPathComponent("uploads-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        server.pages["/upload"] = "<title>Upload</title><form action='/receive' method='post' enctype='multipart/form-data'><input id='files' name='files' type='file' multiple><button>Send</button></form>"
    }

    override func tearDown() async throws {
        tab.tearDown(); server.stop()
        HTTPSOnly.enabled = oldHTTPS
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ path: String, _ bytes: Data) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private func load(_ path: String) async throws {
        tab.web.load(URLRequest(url: try server.url(path)))
        try await compatibilityWait { !self.tab.web.isLoading && self.tab.web.title == (path == "/upload" ? "Upload" : "Parent") }
    }

    func testMultipleFilesSubmitExactTextAndBinaryBytes() async throws {
        let text = Data("synthetic upload α\n".utf8), binary = Data([0, 255, 1, 128, 13, 10])
        selection.urls = [try file("note.txt", text), try file("bytes.bin", binary)]
        try await load("/upload")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('files').click()")
        try await compatibilityWait { self.selection.frame != nil }
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.getElementById('files').files.length") as? Int == 2 }
        _ = try await tab.web.evaluateJavaScript("document.querySelector('form').submit()")
        try await compatibilityWait { self.server.submissions.count == 1 && self.tab.web.title == "Upload received" }
        let body = try XCTUnwrap(server.submissions.first)
        XCTAssertNotNil(body.range(of: text)); XCTAssertNotNil(body.range(of: binary))
        let metadata = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(metadata.contains("filename=\"note.txt\""))
        XCTAssertTrue(metadata.contains("filename=\"bytes.bin\""))
        XCTAssertTrue(selection.multiple)
    }

    private func chooseDirectory() async throws {
        let first = Data("folder top level".utf8), nested = Data("folder nested file".utf8)
        _ = try file("tree/top.txt", first); _ = try file("tree/nested/child.txt", nested)
        selection.urls = [directory.appendingPathComponent("tree")]
        server.pages["/upload"] = server.pages["/upload"]!.replacingOccurrences(of: "multiple>", with: "multiple webkitdirectory>")
        try await load("/upload")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('files').click()")
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.getElementById('files').files.length") as? Int == 2 }
        let paths = try await tab.web.evaluateJavaScript("Array.from(document.getElementById('files').files, f=>f.webkitRelativePath).sort()") as? [String]
        XCTAssertEqual(paths, ["tree/nested/child.txt", "tree/top.txt"])
        XCTAssertTrue(selection.directories)
    }

    func testDirectorySelectionEnumeratesNestedRelativePathsAndReadsExactBytes() async throws {
        try await chooseDirectory()
        let contents = try await tab.web.callAsyncJavaScript("return await Promise.all(Array.from(document.getElementById('files').files, f=>f.text()));", arguments: [:], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(Set(try XCTUnwrap(contents)), ["folder top level", "folder nested file"])
    }

    func testDirectoryFormSubmissionKnownWebKitFailure() async throws {
        // Keep a failing end-to-end reproduction available without turning the current
        // engine defect into a passing compatibility claim or breaking ordinary CI.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_RUN_KNOWN_COMPAT_FAILURES"] == "1",
                          "Opt-in reproduction: macOS 27.0.1 rejects directory form file paths and resets the page; see REAL-SITE-COMPATIBILITY.md")
        try await chooseDirectory()
        _ = try await tab.web.evaluateJavaScript("document.querySelector('form').submit()")
        try await compatibilityWait { self.server.submissions.count == 1 }
        let body = try XCTUnwrap(server.submissions.first)
        XCTAssertNotNil(body.range(of: Data("folder top level".utf8)))
        XCTAssertNotNil(body.range(of: Data("folder nested file".utf8)))
    }

    func testCrossOriginFrameReceivesSelectedFileAndSubmits() async throws {
        let bytes = Data("cross origin synthetic content".utf8)
        selection.urls = [try file("framed.txt", bytes)]
        server.pages["/upload"]! += "<script>window.addEventListener('message',()=>document.getElementById('files').click());</script>"
        server.pages["/parent"] = "<title>Parent</title><iframe id='child' src='\(try server.url("/upload", host: "localhost"))'></iframe>"
        try await load("/parent")
        try await compatibilityWait {
            try await self.tab.web.evaluateJavaScript("document.getElementById('child').contentWindow.postMessage('choose','*'); true") as? Bool == true
                && self.selection.frame != nil
        }
        let frame = try XCTUnwrap(selection.frame)
        XCTAssertFalse(frame.isMainFrame)
        XCTAssertEqual(frame.securityOrigin.host, "localhost")
        let count = try await tab.web.callAsyncJavaScript("return document.getElementById('files').files.length;", arguments: [:], in: frame, contentWorld: .page)
        XCTAssertEqual(count as? Int, 1)
        _ = try await tab.web.callAsyncJavaScript("document.querySelector('form').submit(); return true;", arguments: [:], in: frame, contentWorld: .page)
        try await compatibilityWait { self.server.submissions.count == 1 }
        XCTAssertNotNil(server.submissions[0].range(of: bytes))
        XCTAssertEqual(tab.web.title, "Parent", "Upload navigates only the requesting frame")
    }
}

@MainActor private final class SyntheticUploadSelection: NSObject, WKUIDelegate {
    var urls: [URL] = []
    var frame: WKFrameInfo?
    var multiple = false, directories = false
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        self.frame = frame
        multiple = parameters.allowsMultipleSelection; directories = parameters.allowsDirectories
        completionHandler(urls)
    }
}
