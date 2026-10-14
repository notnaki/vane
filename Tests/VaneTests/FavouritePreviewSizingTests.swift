import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FavouritePreviewSizingTests: XCTestCase {
    private func height(_ state: FavouritePreviewState) -> CGFloat {
        _ = NSApplication.shared
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://github.com/")!)!
        let host = NSHostingView(rootView: FavouritePreviewCard(context: context, state: state, open: { _ in }, dismiss: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
    func testNoticesAndEmptyResultsDoNotReserveAnEmptyList() {
        for state: FavouritePreviewState in [.loading, .unavailable, .signedOut, .ready(.init(account: "fixture", items: []))] {
            XCTAssertLessThan(height(state), 240, "Short notices must fit their content")
        }
    }
    func testSingleResultIsSmallerThanFullList() {
        let items = (1...5).map { FavouritePreviewItem(title: "Fixture pull request \($0)", subtitle: "fixture/repo", url: URL(string: "https://github.com/fixture/repo/pull/\($0)")!) }
        let single = height(.ready(.init(account: "fixture", items: Array(items.prefix(1)))))
        let full = height(.ready(.init(account: "fixture", items: items)))
        XCTAssertLessThan(single, full - 80)
        XCTAssertLessThan(full, 430)
    }
    func testLongResultsStayInsideScrollableCard() {
        let items = (1...5).map { index in
            var item = FavouritePreviewItem(title: String(repeating: "Long pull request title ", count: 8), subtitle: "fixture/repository", url: URL(string: "https://github.com/fixture/repository/pull/\(index)")!)
            item.status = "Review required · All required checks are still pending"
            return item
        }
        let expanded = height(.stale(.init(account: "fixture", items: items)))
        XCTAssertLessThan(expanded, 430)
        XCTAssertGreaterThan(expanded, 300, "Long content must get a bounded scroll area, not a clipped short notice")
    }

}
