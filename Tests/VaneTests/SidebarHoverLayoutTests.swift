import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarHoverLayoutTests: XCTestCase {
    func testHoverKeepsLongTabTitleAndSubtitleInPlace() throws {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        let tab = Tab(isPrivate: true, profileID: store.profileID)
        tab.park(url: URL(string: "about:blank")!,
                 Parked(title: "prepare Closet Dashboard with a very long title", needsRecovery: true))
        let saver = BatterySaver.shared
        let previousMode = saver.mode
        defer {
            saver.setMode(previousMode)
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }

        // Compare only the title area of a selected row, whose fill does not change on
        // hover. Revealing the trailing button must not move or retruncate this text.
        for mode: BatterySaver.Mode in [.off, .alwaysOn] {
            saver.setMode(mode)
            func titlePixels(held: Bool) throws -> Data {
                let renderer = ImageRenderer(content:
                    SidebarTabSurface(store: store, tab: tab, held: held,
                        returnHovering: .constant(false),
                        pr: GitHub.Row(author: "notnaki", state: .open),
                        action: {}, previewSelected: true)
                    .frame(width: 250, height: Look.rowHeight)
                    .transaction { $0.disablesAnimations = true })
                let image = try XCTUnwrap(renderer.cgImage)
                let context = try XCTUnwrap(CGContext(data: nil, width: 180,
                    height: image.height, bitsPerComponent: 8, bytesPerRow: 180 * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0,
                    width: image.width, height: image.height))
                return Data(bytes: try XCTUnwrap(context.data),
                            count: context.bytesPerRow * context.height)
            }
            XCTAssertTrue(try titlePixels(held: false) == titlePixels(held: true),
                           "Hover must keep the title stable (\(mode))")
        }
    }
}
