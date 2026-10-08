import AppKit
import PDFKit
import XCTest
@testable import vane

@MainActor final class PrintingCompatibilityTests: XCTestCase {
    private var tab: Tab!
    private var window: NSWindow!
    private var directory: URL!

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        tab = Tab(isPrivate: true)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = tab.web
        window.orderFront(nil)
        directory = Store.directory.appendingPathComponent("print-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        tab.tearDown(); window.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func load(_ html: String) async throws {
        tab.web.loadHTMLString(html, baseURL: nil)
        try await compatibilityWait { !self.tab.web.isLoading && self.tab.web.title == "Print fixture" }
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.readyState") as? String == "complete" }
    }

    private func pdf(first: Int? = nil, last: Int? = nil) async throws -> PDFDocument {
        let output = directory.appendingPathComponent("\(UUID()).pdf")
        let info = try XCTUnwrap(NSPrintInfo.shared.copy() as? NSPrintInfo)
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        if let first, let last {
            info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = first
            info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = last
        }
        // This is the same operation factory used by File > Print.
        let operation = PagePrinting.operation(for: tab.web, printInfo: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        let completed = expectation(description: "Native print operation completed")
        let observer = PrintCompletion { succeeded in
            XCTAssertTrue(succeeded)
            completed.fulfill()
        }
        // WebKit computes pagination via main-thread IPC and renders on a secondary
        // thread. A synchronous run without a panel starves pagination in XCTest.
        operation.runModal(for: window, delegate: observer,
                           didRun: #selector(PrintCompletion.finished(_:success:context:)), contextInfo: nil)
        await fulfillment(of: [completed], timeout: 20)
        withExtendedLifetime(observer) {}
        return try XCTUnwrap(PDFDocument(url: output))
    }

    private let pages = """
    <title>Print fixture</title>
    <style>
    @media screen { .print-only { display:none } }
    @media print { .screen-only { display:none } section { break-after:page } section:last-child { break-after:auto } }
    </style>
    <p class='screen-only'>SCREEN_ONLY_SENTINEL</p>
    <section><h1>PAGE_ONE_SENTINEL</h1><p class='print-only'>PRINT_ONLY_SENTINEL</p></section>
    <section><h1>PAGE_TWO_SENTINEL</h1></section>
    <section><h1>PAGE_THREE_SENTINEL</h1></section>
    """

    func testPrintCSSAndThreePageDocumentProduceNonblankPDF() async throws {
        try await load(pages)
        let document = try await pdf()
        XCTAssertEqual(document.pageCount, 3)
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("PRINT_ONLY_SENTINEL"))
        XCTAssertFalse(text.contains("SCREEN_ONLY_SENTINEL"))
        for (index, sentinel) in ["PAGE_ONE_SENTINEL", "PAGE_TWO_SENTINEL", "PAGE_THREE_SENTINEL"].enumerated() {
            XCTAssertTrue(document.page(at: index)?.string?.contains(sentinel) == true)
        }
    }

    func testPageRangeSavesOnlyRequestedPage() async throws {
        try await load(pages)
        let document = try await pdf(first: 2, last: 2)
        XCTAssertEqual(document.pageCount, 1)
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("PAGE_TWO_SENTINEL"))
        XCTAssertFalse(text.contains("PAGE_ONE_SENTINEL"))
        XCTAssertFalse(text.contains("PAGE_THREE_SENTINEL"))
    }

    func testEmbeddedDocumentTextIsIncludedInParentPrint() async throws {
        try await load("<title>Print fixture</title><h1>PARENT_SENTINEL</h1><iframe style='width:500px;height:300px' srcdoc='<h2>FRAME_SENTINEL</h2>'></iframe>")
        try await compatibilityWait { try await self.tab.web.evaluateJavaScript("document.querySelector('iframe').contentDocument.readyState") as? String == "complete" }
        let document = try await pdf()
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("PARENT_SENTINEL"))
        XCTAssertTrue(text.contains("FRAME_SENTINEL"))
    }
}

@MainActor private final class PrintCompletion: NSObject {
    let complete: (Bool) -> Void
    init(_ complete: @escaping (Bool) -> Void) { self.complete = complete }
    @objc nonisolated func finished(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.complete(success) }
    }
}
