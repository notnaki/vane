import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class FavouritePreviewSizingTests: XCTestCase {
    private func size(_ state: FavouritePreviewState, service: FavouritePreviewService) -> NSSize {
        _ = NSApplication.shared
        let context = FavouritePreviewContext(profileID: UUID(), url: URL(string: "https://\(service.host)/")!)!
        let host = NSHostingView(rootView: FavouritePreviewCard(context: context, state: state, open: { _ in }, dismiss: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
    func testLoadingNoticesAndResultsKeepTheSameCompactShellAcrossServices() {
        let items = (1...5).map { FavouritePreviewItem(title: "Fixture pull request \($0)", subtitle: "fixture/repo", url: URL(string: "https://github.com/fixture/repo/pull/\($0)")!) }
        let states: [FavouritePreviewState] = [.loading, .unavailable, .signedOut,
            .ready(.init(account: "fixture", items: [])), .ready(.init(account: "fixture", items: Array(items.prefix(1)))),
            .ready(.init(account: "fixture", items: items)), .stale(.init(account: "fixture", items: items))]
        let loading = size(.loading, service: .gmail)
        XCTAssertLessThan(loading.width, 260)
        XCTAssertLessThanOrEqual(loading.height, 280)
        for service in [FavouritePreviewService.gmail, .github] {
            for state in states { XCTAssertEqual(size(state, service: service), loading) }
        }
    }
    func testLongResultsKeepTheSameScrollableShell() {
        let items = (1...5).map { index in
            var item = FavouritePreviewItem(title: String(repeating: "Long pull request title ", count: 8), subtitle: "fixture/repository", url: URL(string: "https://github.com/fixture/repository/pull/\(index)")!)
            item.status = "Review required · All required checks are still pending"
            return item
        }
        XCTAssertEqual(size(.stale(.init(account: "fixture", items: items)), service: .github), size(.loading, service: .gmail))
    }
}
