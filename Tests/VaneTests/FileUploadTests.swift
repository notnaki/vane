import AppKit
import Network
import WebKit
import XCTest
@testable import vane

@MainActor final class FileUploadTests: XCTestCase {
    private var tab: Tab!
    private var window: NSWindow!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        tab = Tab(isPrivate: true)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.web
        window.makeKeyAndOrderFront(nil)
    }

    override func tearDown() async throws {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        tab.tearDown()
        window.close()
        tab = nil; window = nil
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the upload fixture", file: file, line: line)
        if !condition() { throw NSError(domain: "UploadFixtureTimeout", code: 1) }
    }

    private func loadInput(_ attributes: String = "") async throws {
        tab.web.loadHTMLString("<title>Upload fixture</title><input id='file' type='file' \(attributes)>",
                              baseURL: URL(string: "https://upload.example"))
        try await wait { self.tab.web.title == "Upload fixture" && !self.tab.web.isLoading }
    }

    private func openPicker() async throws -> NSOpenPanel {
        _ = try await tab.web.evaluateJavaScript("document.getElementById('file').click()")
        try await wait { self.window.attachedSheet != nil }
        return try XCTUnwrap(window.attachedSheet as? NSOpenPanel)
    }

    func testChooseFileOpensNativePickerAndCancelLeavesInputEmpty() async throws {
        try await loadInput()
        let panel = try await openPicker()
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        panel.cancel(nil)
        try await wait { self.window.attachedSheet == nil }
        let count = try await tab.web.evaluateJavaScript("document.getElementById('file').files.length")
        XCTAssertEqual(count as? Int, 0)
        // A cancelled callback must finish so that the input can open another picker.
        let reopened = try await openPicker()
        reopened.cancel(nil)
    }

    func testMultipleFileInputAllowsMultipleFiles() async throws {
        try await loadInput("multiple")
        let panel = try await openPicker()
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        panel.cancel(nil)
    }

    func testDirectoryInputChoosesFoldersIncludingPackages() async throws {
        try await loadInput("webkitdirectory multiple")
        let panel = try await openPicker()
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.treatsFilePackagesAsDirectories)
        panel.cancel(nil)
    }

    func testNavigationDismissesOldDocumentPicker() async throws {
        try await loadInput()
        _ = try await openPicker()
        tab.web.loadHTMLString("<title>Next document</title><input id='file' type='file'>", baseURL: nil)
        try await wait { self.window.attachedSheet == nil && self.tab.web.title == "Next document" }
        let panel = try await openPicker()
        panel.cancel(nil)
    }

    func testCommitDismissesPickerOpenedAfterProvisionalNavigation() async throws {
        let server = try SlowUploadServer()
        defer { server.stop() }
        try await wait { server.port != nil }
        let recorder = UploadRecorder(tab: tab)
        tab.web.uiDelegate = recorder
        try await loadInput()
        let port = try XCTUnwrap(server.port)
        let url = URL(string: "http://127.0.0.1:\(port)/next")!
        tab.web.load(URLRequest(url: url))
        try await wait { self.tab.loading && server.request != nil }
        // The old document is still interactive while the HTTP response is held.
        let panel = try await openPicker()
        server.respond()
        try await wait { self.tab.web.title == "Next document" }
        try await wait { self.window.attachedSheet == nil }
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(recorder.results.count, 1)
        let result = try XCTUnwrap(recorder.results.first)
        XCTAssertNil(result)
    }

    func testTabTeardownDismissesPicker() async throws {
        let recorder = UploadRecorder(tab: tab)
        tab.web.uiDelegate = recorder
        try await loadInput()
        _ = try await openPicker()
        tab.tearDown()
        try await wait { self.window.attachedSheet == nil && recorder.results.count == 1 }
        XCTAssertNil(recorder.results[0])
        // Allow the later AppKit completion to run; it must not answer WebKit twice.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.results.count, 1)
    }

    func testWindowCloseDismissesPicker() async throws {
        let recorder = UploadRecorder(tab: tab)
        tab.web.uiDelegate = recorder
        try await loadInput()
        let panel = try await openPicker()
        window.close()
        try await wait { !panel.isVisible && self.window.attachedSheet == nil && recorder.results.count == 1 }
        XCTAssertNil(recorder.results[0])
    }

    func testBusyAndDetachedRequestsCancelWithoutReplacingExistingPicker() async throws {
        let recorder = UploadRecorder(tab: tab)
        tab.web.uiDelegate = recorder
        try await loadInput()
        let panel = try await openPicker()
        let parameters = try XCTUnwrap(recorder.parameters)
        let frame = try XCTUnwrap(recorder.frame)
        var answers = 0
        tab.webView(tab.web, runOpenPanelWith: parameters, initiatedByFrame: frame) { urls in
            answers += 1
            XCTAssertNil(urls)
        }
        XCTAssertEqual(answers, 1)
        XCTAssertTrue(window.attachedSheet === panel)
        panel.cancel(nil)
        try await wait { self.window.attachedSheet == nil && recorder.results.count == 1 }
        tab.web.removeFromSuperview()
        tab.webView(tab.web, runOpenPanelWith: parameters, initiatedByFrame: frame) { urls in
            answers += 1
            XCTAssertNil(urls)
        }
        XCTAssertEqual(answers, 2)
        XCTAssertNil(window.attachedSheet)
    }
}

/// Hold the next page until the old document has opened its upload sheet.
@MainActor private final class SlowUploadServer {
    private let listener: NWListener
    var port: UInt16?
    var request: NWConnection?

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.port = self?.listener.port?.rawValue }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                Task { @MainActor in self?.request = connection }
            }
        }
        listener.start(queue: .main)
    }

    func respond() {
        let body = "<title>Next document</title><p>Navigation committed</p>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        request?.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
    }

    func stop() { listener.cancel(); request?.cancel() }
}

/// Record actual WebKit answers while forwarding its real parameters and frame to Tab.
@MainActor private final class UploadRecorder: NSObject, WKUIDelegate {
    weak var tab: Tab?
    var parameters: WKOpenPanelParameters?
    var frame: WKFrameInfo?
    var results: [[URL]?] = []
    init(tab: Tab) { self.tab = tab }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        self.parameters = parameters; self.frame = frame
        tab!.webView(webView, runOpenPanelWith: parameters, initiatedByFrame: frame) { urls in
            self.results.append(urls)
            completionHandler(urls)
        }
    }
}
