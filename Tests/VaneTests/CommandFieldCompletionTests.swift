import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class CommandFieldCompletionTests: XCTestCase {
    private final class Input {
        var text: String
        var accepted: Palette.HostCompletion?
        init(_ text: String) { self.text = text }
    }

    private func fixture(_ prefix: String = "d", url: String = "https://deepseek.com/chat") throws
        -> (NSTextField, NSTextView, CommandField.Coordinator, Input, Palette.HostCompletion) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let input = Input(prefix)
        let completion = try XCTUnwrap(Palette.completeHost(prefix, urls: [url]))
        let field = CommandField(text: Binding(get: { input.text }, set: {
            input.accepted = Palette.carriedCompletion(input.accepted, completion: completion, query: $0)
            input.text = $0
        }), prompt: "Search", selectAll: false, label: "Search", hint: "", onKey: { _ in true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: field.frame(width: 350, height: 30))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        func nativeField(in view: NSView) -> CommandField.BarField? {
            if let field = view as? CommandField.BarField { return field }
            return view.subviews.lazy.compactMap { nativeField(in: $0) }.first
        }
        let native = try XCTUnwrap(nativeField(in: hosting))
        let coordinator = try XCTUnwrap(native.delegate as? CommandField.Coordinator)
        coordinator.take(native, selectAll: false)
        let editor = try XCTUnwrap(native.currentEditor() as? NSTextView)
        native.stringValue = completion.text
        editor.string = completion.text
        editor.setSelectedRange(NSRange(location: prefix.utf16.count,
            length: completion.text.utf16.count - prefix.utf16.count))
        coordinator.showsCompletion = true
        addTeardownBlock { @MainActor in
            coordinator.invalidate()
            native.delegate = nil
            window.contentView = nil
            window.close()
        }
        return (native, editor, coordinator, input, completion)
    }

    func testMovingLeftReconcilesTheDisplayedCompletionBeforeEditing() throws {
        let (_, editor, _, input, _) = try fixture()
        editor.moveLeft(nil)
        XCTAssertEqual(input.text, "deepseek.com")
        XCTAssertEqual(input.text, editor.string)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 0))
        editor.insertText("o", replacementRange: editor.selectedRange())
        XCTAssertEqual(input.text, "doeepseek.com")
    }

    func testHomeAndPointerSelectionReconcileTheDisplayedCompletion() throws {
        let (_, editor, _, input, _) = try fixture()
        editor.moveToBeginningOfLine(nil)
        XCTAssertEqual(input.text, "deepseek.com")
        XCTAssertEqual(input.text, editor.string)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        editor.insertText("o", replacementRange: editor.selectedRange())
        XCTAssertEqual(input.text, "odeepseek.com")

        let (_, clickedEditor, _, clickedInput, _) = try fixture()
        clickedEditor.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(clickedInput.text, "deepseek.com")
        XCTAssertEqual(clickedInput.text, clickedEditor.string)
        XCTAssertEqual(clickedEditor.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testAcceptingWithRightOrEndKeepsTheOriginalOrigin() throws {
        for selector in [#selector(NSResponder.moveRight(_:)),
                         #selector(NSResponder.moveToEndOfLine(_:))] {
            for url in ["http://server/wiki", "http://example.com/page", "http://localhost:3000/path"] {
                let prefix = url.contains("server") ? "se" : (url.contains("localhost") ? "loc" : "ex")
                let (_, editor, _, input, completion) = try fixture(prefix, url: url)
                _ = editor.perform(selector, with: nil)
                XCTAssertEqual(input.text, completion.text)
                let destination = input.accepted?.url
                    ?? Palette.completeHost(input.text, urls: [url])?.url
                    ?? Search.url(for: input.text)
                XCTAssertEqual(destination, completion.url,
                               "Accepting a display host must preserve its scheme and port")
            }
        }
    }

    /// The stand-in's symbol names AppKit's password AutoFill check, which is how the
    /// field knows who is asking for its neighbours.
    @inline(never) private func NSAutoFillHeuristicControllerStandIn(_ field: CommandField.BarField) -> (NSView?, NSView?) {
        (field.nextValidKeyView, field.previousValidKeyView)
    }

    func testOnlyTheAutoFillCheckIsToldAFieldHasNoNeighbours() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = CommandField.BarField(string: "")
        let after = NSTextField(string: ""), before = NSTextField(string: "")
        for (index, view) in [before, field, after].enumerated() {
            view.frame = NSRect(x: 20, y: 150 - 40 * index, width: 200, height: 24)
            window.contentView?.addSubview(view)
        }
        before.nextKeyView = field
        field.nextKeyView = after
        XCTAssertTrue(field.nextValidKeyView === after, "Tab still reaches the real next key view")
        XCTAssertTrue(field.previousValidKeyView === before, "Shift-Tab still reaches the real previous one")
        let answer = NSAutoFillHeuristicControllerStandIn(field)
        XCTAssertTrue(answer.0 === field && answer.1 === field,
                      "The AutoFill check must not search the window for key views")
    }
}
