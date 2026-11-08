import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class ToastLayoutTests: XCTestCase {
    private func render(_ message: String, action: String? = "Undo", width: CGFloat, sticky: Bool = false, dark: Bool = true, wraps: Bool = false) throws -> NSBitmapImageRep {
        TestEnvironment.prepare()
        let toast = Toasts.Toast(text: message, action: action.map { ($0, {}) }, sticky: sticky, wraps: wraps)
        let renderer = ImageRenderer(content: ToastPill(toast: toast, tint: .green)
            .environment(\.colorScheme, dark ? .dark : .light))
        renderer.proposedSize = ProposedViewSize(width: width - Look.inset * 2, height: nil)
        return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
    }

    func testShortUndoToastStaysOneRowAtDefaultSidebarWidth() throws {
        for width in [SidebarWidth.standard, 249, 250, SidebarWidth.maximum] {
            let image = try render("Unpinned", width: width)
            XCTAssertLessThanOrEqual(image.pixelsHigh, Int(Look.toastHeight),
                "A short message and Undo fit beside each other at \(width)pt")
            XCTAssertLessThanOrEqual(image.pixelsWide, Int(width - Look.inset * 2))
        }
    }

    func testLongArchiveTitleKeepsUndoOnOneRow() throws {
        for width in [SidebarWidth.minimum, SidebarWidth.standard, 249, SidebarWidth.maximum] {
            let image = try render("Archived CIALFO – University Applications, Made Easy", width: width)
            XCTAssertLessThanOrEqual(image.pixelsHigh, 32,
                "Long page titles should truncate rather than move Undo and dismiss below the message")
            XCTAssertLessThanOrEqual(image.pixelsWide, Int(width - Look.inset * 2))
        }
    }

    func testShortUpdatePromptsStayOneRow() throws {
        for width in [220, SidebarWidth.standard, 249, SidebarWidth.maximum] {
            for phase in [Updater.Phase.available("v0.0.23"), .available("v0.23.123"), .ready, .failed(nil)] {
                let message = Updater.text(for: phase)
                let action = try XCTUnwrap(Updater.action(for: phase)).title
                let image = try render(message, action: action, width: width, sticky: true)
                XCTAssertLessThanOrEqual(image.pixelsHigh, 32,
                    "\(message) and \(action) should share one row at \(width)pt")
                XCTAssertLessThanOrEqual(image.pixelsWide, Int(width - Look.inset * 2))
            }
        }
    }

    func testLongUpdateOfferWrapsWithinNarrowSidebar() throws {
        let phase = Updater.Phase.available("v0.0.23-beta.123")
        let image = try render(Updater.text(for: phase),
            action: try XCTUnwrap(Updater.action(for: phase)).title,
            width: SidebarWidth.minimum, sticky: true)
        XCTAssertLessThanOrEqual(image.pixelsWide, Int(SidebarWidth.minimum - Look.inset * 2))
        XCTAssertGreaterThan(image.pixelsHigh, Int(Look.toastHeight))
        XCTAssertLessThanOrEqual(image.pixelsHigh, 48,
            "The update message can wrap, but its controls should stay beside it")
    }

    func testLongActionAndMessageStayWithinNarrowSidebar() throws {
        let image = try render("Couldn't move Vane to Applications",
            action: "Choose another folder", width: SidebarWidth.minimum)
        XCTAssertLessThanOrEqual(image.pixelsWide, Int(SidebarWidth.minimum - Look.inset * 2))
        XCTAssertGreaterThan(image.pixelsHigh, Int(Look.toastHeight))
    }

    func testMessageWithoutActionTruncatesWithinNarrowSidebar() throws {
        let image = try render("Archived a very long page title that needs to wrap",
            action: nil, width: SidebarWidth.minimum)
        XCTAssertLessThanOrEqual(image.pixelsWide, Int(SidebarWidth.minimum - Look.inset * 2))
        XCTAssertLessThanOrEqual(image.pixelsHigh, 32)
    }
    func testOfflineUpdateNoticesFitBothThemes() throws {
        let notices: [(String, String, Bool)] = [
            ("You’re offline", "Retry", false),
            ("Network lost", "Retry", false),
            ("Timed out", "Retry", false),
            ("You’re offline", "Retry", true),
            ("Network lost", "Retry", true),
            ("Timed out", "Retry", true),
        ]
        for dark in [false, true] {
            for width in [SidebarWidth.minimum, SidebarWidth.standard] {
                for (index, notice) in notices.enumerated() {
                    let image = try render(notice.0, action: notice.1, width: width,
                                           sticky: notice.2, dark: dark, wraps: true)
                    XCTAssertLessThanOrEqual(image.pixelsWide, Int(width - Look.inset * 2))
                    XCTAssertLessThanOrEqual(image.pixelsHigh, 56)
                    if let directory = ProcessInfo.processInfo.environment["VANE_OFFLINE_UPDATE_SNAPSHOTS"] {
                        let root = URL(fileURLWithPath: directory)
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        try XCTUnwrap(image.representation(using: .png, properties: [:]))
                            .write(to: root.appendingPathComponent("\(index)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

}
