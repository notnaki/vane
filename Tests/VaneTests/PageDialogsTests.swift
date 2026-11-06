import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class PageDialogsTests: XCTestCase {
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
        tab.web.loadHTMLString("<title>Dialog fixture</title>", baseURL: URL(string: "https://dialog.example"))
        try await wait { self.tab.web.title == "Dialog fixture" && !self.tab.web.isLoading }
    }

    override func tearDown() async throws {
        PageDialogs.cancel(tabID: tab.id)
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
        XCTAssertTrue(condition(), "Timed out waiting for the dialog fixture", file: file, line: line)
        if !condition() { throw NSError(domain: "DialogFixtureTimeout", code: 1) }
    }

    /// Runs script that opens a dialog, and hands back its sheet with the script's result pending.
    private func open(_ script: String) async throws -> (NSWindow, Task<String?, Error>) {
        let web = tab.web
        let result = Task { @MainActor in try await web.evaluateJavaScript("String(\(script))") as? String }
        try await wait { self.window.attachedSheet != nil }
        return (try XCTUnwrap(window.attachedSheet), result)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    private func button(_ title: String, in sheet: NSWindow) throws -> NSButton {
        try XCTUnwrap(views(NSButton.self, in: try XCTUnwrap(sheet.contentView)).first { $0.title == title })
    }

    private func checkbox(in sheet: NSWindow) -> NSButton? {
        sheet.contentView.flatMap { content in
            views(NSButton.self, in: content).first { $0.title.hasPrefix("Don’t let this site") && !$0.isHidden }
        }
    }

    func testConfirmReportsTheButtonChosenAndNamesTheSite() async throws {
        var (sheet, result) = try await open("confirm('Delete revision?')")
        let labels = views(NSTextField.self, in: try XCTUnwrap(sheet.contentView)).map(\.stringValue)
        XCTAssertTrue(labels.contains("dialog.example says"))
        XCTAssertTrue(labels.contains("Delete revision?"))
        try button("OK", in: sheet).performClick(nil)
        let accepted = try await result.value
        XCTAssertEqual(accepted, "true")

        (sheet, result) = try await open("confirm('Delete revision?')")
        try button("Cancel", in: sheet).performClick(nil)
        let refused = try await result.value
        XCTAssertEqual(refused, "false")
        try await wait { self.window.attachedSheet == nil }
    }

    func testAlertWaitsForTheUserWithOnlyOneButton() async throws {
        let (sheet, result) = try await open("(alert('Saved'), 'continued')")
        XCTAssertFalse(views(NSButton.self, in: try XCTUnwrap(sheet.contentView)).contains { $0.title == "Cancel" })
        try button("OK", in: sheet).performClick(nil)
        let value = try await result.value
        XCTAssertEqual(value, "continued")
    }

    func testPromptReturnsTypedTextOrNull() async throws {
        var (sheet, result) = try await open("prompt('Name?', 'Vane')")
        let field = try XCTUnwrap(views(NSTextField.self, in: try XCTUnwrap(sheet.contentView)).first(where: \.isEditable))
        XCTAssertEqual(field.stringValue, "Vane")
        field.stringValue = "Typed"
        try button("OK", in: sheet).performClick(nil)
        let typed = try await result.value
        XCTAssertEqual(typed, "Typed")

        (sheet, result) = try await open("prompt('Name?', 'Vane')")
        try button("Cancel", in: sheet).performClick(nil)
        let refused = try await result.value
        XCTAssertEqual(refused, "null")
    }

    func testHiddenTabGetsAnAnswerWithoutASheet() async throws {
        tab.web.isHidden = true
        let answer = try await tab.web.evaluateJavaScript("confirm('Hidden')")
        XCTAssertEqual(answer as? Bool, false)
        XCTAssertNil(window.attachedSheet)
    }

    func testCancellingEndsTheSheetAndResolvesThePageOnce() async throws {
        let (_, result) = try await open("confirm('Navigating')")
        PageDialogs.cancel(tabID: tab.id)
        PageDialogs.cancel(tabID: tab.id)
        let answer = try await result.value
        XCTAssertEqual(answer, "false")
        try await wait { self.window.attachedSheet == nil }
    }

    func testRepeatedDialogsCanBeSilencedForTheSite() async throws {
        var (sheet, result) = try await open("alert('First')")
        XCTAssertNil(checkbox(in: sheet))
        try button("OK", in: sheet).performClick(nil)
        _ = try await result.value
        try await wait { self.window.attachedSheet == nil }

        (sheet, result) = try await open("alert('Second')")
        try XCTUnwrap(checkbox(in: sheet)).performClick(nil)
        try button("OK", in: sheet).performClick(nil)
        _ = try await result.value
        try await wait { self.window.attachedSheet == nil }

        let silenced = try await tab.web.evaluateJavaScript("confirm('Third')")
        XCTAssertEqual(silenced as? Bool, false)
        XCTAssertNil(window.attachedSheet)
    }

    func testSuppressionIsOfferedOnlyForQuickRepeatsOfTheSameSite() {
        var policy = PageDialogPolicy()
        let start = ContinuousClock.now
        XCTAssertFalse(policy.offersSuppression("a.example", now: start))
        policy.dismissed("a.example", suppress: false, now: start)
        XCTAssertTrue(policy.offersSuppression("a.example", now: start + .seconds(1)))
        XCTAssertFalse(policy.offersSuppression("a.example", now: start + .seconds(60)))
        XCTAssertFalse(policy.offersSuppression("b.example", now: start + .seconds(1)))
    }

    func testClippingKeepsShortMessagesAndBoundsLongOnes() {
        XCTAssertEqual(PageDialogs.clipped("Delete?\nThis can't be undone."), "Delete?\nThis can't be undone.")
        XCTAssertLessThan(PageDialogs.clipped(String(repeating: "x", count: 100_000)).count, 2000)
        let lines = PageDialogs.clipped(String(repeating: "\n", count: 10_000))
        XCTAssertLessThan(lines.split(separator: "\n", omittingEmptySubsequences: false).count, 100)
        XCTAssertTrue(lines.hasSuffix("…"))
    }
}
