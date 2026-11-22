import AppKit
import XCTest
@testable import vane

/// In full screen AppKit keeps a window's toolbar on screen as an opaque strip over the top
/// of its content, one that takes the clicks meant for what is under it. Both kinds of
/// browser window have to answer AppKit's question with "hide it with the menu bar".
@MainActor final class FullScreenTitlebarTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        WebKitStartup.prepare()
    }

    override func tearDown() async throws {
        for window in windows {
            window.close()
            window.contentView = nil
        }
        windows = []
    }

    private func assertHidesTitlebar(_ store: TabStore, file: StaticString = #filePath, line: UInt = #line) throws {
        let window = try XCTUnwrap(store.window, file: file, line: line)
        windows.append(window)
        let proposed: NSApplication.PresentationOptions = [.fullScreen, .autoHideMenuBar, .autoHideDock]
        let answer = try XCTUnwrap(
            window.delegate?.window?(window, willUseFullScreenPresentationOptions: proposed),
            "the window's delegate leaves full screen's presentation to AppKit", file: file, line: line)
        XCTAssertEqual(answer, proposed.union(.autoHideToolbar), file: file, line: line)
    }

    func testBrowserWindowHidesItsTitlebarInFullScreen() throws {
        try assertHidesTitlebar(Windows.open(isPrivate: true, focus: false, session: []))
    }

    func testLittleVaneHidesItsTitlebarInFullScreen() throws {
        try assertHidesTitlebar(LittleArc.open(nil, isPrivate: true))
    }
}
