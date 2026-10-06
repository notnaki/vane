import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarChromeTests: XCTestCase {
    private func fixture() -> TabStore {
        TestEnvironment.prepare()
        let store = TabStore(isPrivate: true)
        store.sidebarShown = true
        let previousWidth = SidebarWidth.shared.width
        addTeardownBlock { @MainActor in
            SidebarWidth.shared.width = previousWidth
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
        }
        return store
    }

    private func headerHeight(width: CGFloat, store: TabStore) throws -> CGFloat {
        SidebarWidth.shared.width = width
        let renderer = ImageRenderer(content: TopRow().environmentObject(store)
            .transaction { $0.disablesAnimations = true })
        renderer.proposedSize = ProposedViewSize(width: width - Look.inset * 2, height: nil)
        return try XCTUnwrap(renderer.nsImage).size.height
    }

    func testHeaderKeepsOneRowOnceCompactControlsFit() throws {
        let store = fixture()
        for width: CGFloat in [188, 192, 219, 220, 227, 228, 300, 500] {
            XCTAssertEqual(try headerHeight(width: width, store: store), Look.topRow,
                           "Navigation must not wrap again when leaving compact mode at \(width)pt")
        }
        for width: CGFloat in [164, 180, 187] {
            XCTAssertEqual(try headerHeight(width: width, store: store), Look.topRow * 2)
        }
    }

    func testAddressEditorFollowsPillWhenHeaderWraps() async throws {
        let store = fixture()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PaletteView(mode: .address, dismiss: {})
            .environmentObject(store).transaction { $0.disablesAnimations = true })
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }

        func field(in view: NSView) -> CommandField.BarField? {
            if let field = view as? CommandField.BarField { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        func fieldTop() throws -> CGFloat {
            let field = try XCTUnwrap(field(in: hosting))
            let rect = field.convert(field.bounds, to: hosting)
            return hosting.isFlipped ? rect.minY : hosting.bounds.height - rect.maxY
        }

        SidebarWidth.shared.width = 228
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        let inlineTop = try fieldTop()
        let inlineHeight = try headerHeight(width: 228, store: store)
        SidebarWidth.shared.width = 164
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(try fieldTop() - inlineTop,
                       try headerHeight(width: 164, store: store) - inlineHeight, accuracy: 1,
                       "Address editing must move down by the same amount as the pill")
    }
}
