import AppKit
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

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out waiting for the upload picker")
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
