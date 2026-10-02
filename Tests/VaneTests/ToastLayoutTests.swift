import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class ToastLayoutTests: XCTestCase {
    private func render(_ message: String, action: String? = "Undo", width: CGFloat) throws -> NSBitmapImageRep {
        TestEnvironment.prepare()
        let toast = Toasts.Toast(text: message, action: action.map { ($0, {}) })
        let renderer = ImageRenderer(content: ToastPill(toast: toast, tint: .green)
            .environment(\.colorScheme, .dark))
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

    func testLongActionAndMessageStayWithinNarrowSidebar() throws {
        let image = try render("Couldn't move Vane to Applications",
            action: "Choose another folder", width: SidebarWidth.minimum)
        XCTAssertLessThanOrEqual(image.pixelsWide, Int(SidebarWidth.minimum - Look.inset * 2))
        XCTAssertGreaterThan(image.pixelsHigh, Int(Look.toastHeight))
    }

    func testMessageWithoutActionWrapsWithinNarrowSidebar() throws {
        let image = try render("Archived a very long page title that needs to wrap",
            action: nil, width: SidebarWidth.minimum)
        XCTAssertLessThanOrEqual(image.pixelsWide, Int(SidebarWidth.minimum - Look.inset * 2))
        XCTAssertLessThanOrEqual(image.pixelsHigh, Int(Look.toastHeight + 16))
    }
}
