import AppKit
import Darwin
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
    private static let childMarker = "VANE_UPLOAD_SUBMISSION_TEST_CHILD"
    private static let selectorMarker = "VANE_UPLOAD_SUBMISSION_TEST_SELECTOR"
    private var isFreshHostChild: Bool {
        ProcessInfo.processInfo.environment[Self.childMarker] == "1"
    }

    override func setUp() async throws {
        TestEnvironment.prepare()
        guard isFreshHostChild else { return }
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
        guard isFreshHostChild else { return }
        tab?.tearDown(); server?.stop()
        HTTPSOnly.enabled = oldHTTPS
        if let directory { try? FileManager.default.removeItem(at: directory) }
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

    /// Long native suites can leave WebKit unable to read newly selected files even
    /// though fresh-host checks succeed. Preserve the actual File API and multipart
    /// assertions in an isolated host, with bounded cleanup of that exact child.
    private func runInFreshHost(_ function: String) async throws -> Bool {
        let marker = Self.childMarker
        let selector = "VaneTests.UploadSubmissionTests/" + function.replacingOccurrences(of: "()", with: "")
        if isFreshHostChild {
            XCTAssertEqual(ProcessInfo.processInfo.environment[Self.selectorMarker], selector,
                           "Fresh host must execute the requested upload assertion set")
            print("UPLOAD_SUBMISSION_TEST_CHILD_ASSERTIONS selector=\(selector)")
            return false
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-upload-submission-host-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("output.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        let bundle = Bundle(for: Self.self).bundleURL.path
        process.arguments = ["xctest", "-XCTest", selector, bundle]
        var environment = ProcessInfo.processInfo.environment
        environment[marker] = "1"
        environment[Self.selectorMarker] = selector
        process.environment = environment
        process.standardOutput = output; process.standardError = output
        try process.run()
        let pid = process.processIdentifier
        print("UPLOAD_SUBMISSION_TEST_PROCESS pid=\(pid) launched=\(Date.now) bundle=\(bundle) selector=\(selector)")

        func stopOwnedChild() async {
            await Task { @MainActor in
                // Process retains this launch's child identity until it is reaped.
                // Never signal a name or another test host.
                if process.isRunning { process.terminate() }
                var deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if process.isRunning { _ = kill(pid, SIGKILL) }
                deadline = ContinuousClock.now + .seconds(2)
                while process.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertFalse(process.isRunning, "Owned native test host did not exit: \(pid)")
            }.value
        }
        do {
            let deadline = ContinuousClock.now + .seconds(60)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                await stopOwnedChild()
                XCTFail("Native upload-submission check timed out: \(selector)")
            }
        } catch {
            await stopOwnedChild()
            throw error
        }
        let text = try String(contentsOf: log, encoding: .utf8)
        print(text)
        guard !process.isRunning else { return true }
        print("UPLOAD_SUBMISSION_TEST_PROCESS exited pid=\(pid) status=\(process.terminationStatus)")
        XCTAssertEqual(process.terminationReason, .exit, text)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("UPLOAD_SUBMISSION_TEST_CHILD_ASSERTIONS selector=\(selector)"),
                      "Child must enter the requested upload assertions: \(text)")
        XCTAssertTrue(text.contains("Executed 1 test, with 0 failures"), "Child must execute the selected assertion set: \(text)")
        return true
    }

    func testMultipleFilesSubmitExactTextAndBinaryBytes() async throws {
        if try await runInFreshHost(#function) { return }
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
        if try await runInFreshHost(#function) { return }
        try await chooseDirectory()
        let contents = try await tab.web.callAsyncJavaScript("return await Promise.all(Array.from(document.getElementById('files').files, f=>f.text()));", arguments: [:], in: nil, contentWorld: .page) as? [String]
        XCTAssertEqual(Set(try XCTUnwrap(contents)), ["folder top level", "folder nested file"])
    }

    func testDirectoryFormSubmissionKnownWebKitFailure() async throws {
        // Keep a failing end-to-end reproduction available without turning the current
        // engine defect into a passing compatibility claim or breaking ordinary CI.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VANE_RUN_KNOWN_COMPAT_FAILURES"] == "1",
                          "Opt-in reproduction: macOS 27.0.1 rejects directory form file paths and resets the page; see REAL-SITE-COMPATIBILITY.md")
        if try await runInFreshHost(#function) { return }
        try await chooseDirectory()
        _ = try await tab.web.evaluateJavaScript("document.querySelector('form').submit()")
        try await compatibilityWait { self.server.submissions.count == 1 }
        let body = try XCTUnwrap(server.submissions.first)
        XCTAssertNotNil(body.range(of: Data("folder top level".utf8)))
        XCTAssertNotNil(body.range(of: Data("folder nested file".utf8)))
    }

    // Characterize why returning child URLs through the public picker callback
    // cannot replace root selection: it changes the directory input's contract.
    func testChildFileURLsSubmitBytesButLoseDirectoryRelativePaths() async throws {
        if try await runInFreshHost(#function) { return }
        let top = Data("folder top level".utf8), child = Data([0, 255, 1, 128, 13, 10])
        selection.urls = [try file("tree/top.txt", top), try file("tree/nested/child.bin", child)]
        server.pages["/upload"] = server.pages["/upload"]!.replacingOccurrences(of: "multiple>", with: "multiple webkitdirectory>")
        try await load("/upload")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('files').click()")
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.getElementById('files').files.length") as? Int == 2 }
        let paths = try await tab.web.evaluateJavaScript("Array.from(document.getElementById('files').files, f=>f.webkitRelativePath)") as? [String]
        XCTAssertEqual(paths, ["", ""], "Child-only selection loses the folder hierarchy")
        _ = try await tab.web.evaluateJavaScript("document.querySelector('form').submit()")
        try await compatibilityWait { self.server.submissions.count == 1 }
        let body = try XCTUnwrap(server.submissions.first)
        XCTAssertNotNil(body.range(of: top)); XCTAssertNotNil(body.range(of: child))
        let metadata = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(metadata.contains("filename=\"top.txt\""))
        XCTAssertTrue(metadata.contains("filename=\"child.bin\""))
        XCTAssertFalse(metadata.contains("filename=\"tree/"))
    }

    func testRootAndChildFileURLsDuplicateDirectoryEntries() async throws {
        if try await runInFreshHost(#function) { return }
        _ = try file("tree/top.txt", Data("top".utf8))
        _ = try file("tree/nested/child.txt", Data("child".utf8))
        selection.urls = [directory.appendingPathComponent("tree"),
                          directory.appendingPathComponent("tree/top.txt"),
                          directory.appendingPathComponent("tree/nested/child.txt")]
        server.pages["/upload"] = server.pages["/upload"]!.replacingOccurrences(of: "multiple>", with: "multiple webkitdirectory>")
        try await load("/upload")
        _ = try await tab.web.evaluateJavaScript("document.getElementById('files').click()")
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.getElementById('files').files.length") as? Int == 4 }
        let paths = try await tab.web.evaluateJavaScript("Array.from(document.getElementById('files').files, f=>f.webkitRelativePath).sort()") as? [String]
        XCTAssertEqual(paths, ["", "", "tree/nested/child.txt", "tree/top.txt"],
                       "Granting children alongside the root adds unwanted duplicate entries")
    }

    func testCrossOriginFrameReceivesSelectedFileAndSubmits() async throws {
        if try await runInFreshHost(#function) { return }
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
        try await compatibilityWait {
            try await self.tab.web.callAsyncJavaScript("return document.getElementById('files').files.length;",
                                                       arguments: [:], in: frame, contentWorld: .page) as? Int == 1
        }
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
