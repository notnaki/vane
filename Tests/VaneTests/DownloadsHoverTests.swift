import XCTest
import Combine
@testable import vane

@MainActor final class DownloadsHoverTests: XCTestCase {
    func testHistoryChangesPublishAfterWritesAndStayScopedToTheirStore() {
        let history = Store(path: ":memory:")
        let otherProfile = Store(path: ":memory:")
        var counts: [Int] = []
        let subscription = NotificationCenter.default.publisher(for: Store.historyChanged).sink { notification in
            MainActor.assumeIsolated {
                if notification.object as? Store === history { counts.append(history.history().count) }
            }
        }
        defer { subscription.cancel() }
        let url = URL(string: "https://example.com")!
        history.record(url, title: "Page")
        otherProfile.record(url, title: "Another profile")
        history.retitle(url, title: "New title")
        history.record([(url: url, title: "Imported page", at: .now)])
        history.clearHistory()
        XCTAssertEqual(counts, [1, 1, 2, 0])
    }

    func testDownloadsAndMediaFilterBeforeTakingFourNewestItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(profileID: UUID(), directory: directory, sandboxed: true)
        for name in ["old.png", "more.pdf", "four.png", "newest.pdf", "recent.png", "latest.png"] {
            downloads.add(Downloads.Record(name: name, state: "done"))
        }
        func names(_ category: LibraryHoverCategory) -> [String] {
            LibraryHoverItem.recent(category, downloads: downloads.items).compactMap {
                if case .download(let item) = $0 { item.name } else { nil }
            }
        }
        XCTAssertEqual(names(.downloads), ["four.png", "newest.pdf", "recent.png", "latest.png"])
        XCTAssertEqual(names(.media), ["old.png", "four.png", "recent.png", "latest.png"])
        XCTAssertEqual(names(.off), [])
        XCTAssertEqual(LibraryHoverItem.recent(.downloads, downloads: downloads.items,
                                              isPrivate: true).count, 4)
    }

    func testEaselPreviewPicksFourMostRecentlyEditedBoardsAndPlacesNewestLast() {
        let boards = [5, 1, 6, 2, 4, 3].map { age -> EaselBoard in
            var board = EaselBoard()
            board.title = "Board \(age)"
            board.modified = Date(timeIntervalSince1970: Double(age))
            return board
        }
        let items = LibraryHoverItem.recent(.easels, boards: boards)
        XCTAssertEqual(items.compactMap { if case .easel(let board) = $0 { board.title } else { nil } },
                       ["Board 3", "Board 4", "Board 5", "Board 6"])
    }

    func testPrivatePreviewCannotShowSavedHistorySpacesOrEasels() {
        let board = EaselBoard()
        let visit = Visit(id: 1, url: "https://example.com", title: "Saved page", at: .now)
        let space = Space(name: "Saved space", profileID: ProfileManager.defaultID)
        for category in [LibraryHoverCategory.history, .spaces, .easels] {
            XCTAssertTrue(LibraryHoverItem.recent(category, boards: [board], spaces: [space],
                                                 history: [visit], isPrivate: true).isEmpty)
        }
    }

    func testPassingOverButtonDoesNotOpenPreview() async throws {
        let hover = DownloadsHover()
        hover.setHovered(true, over: .button)
        hover.setHovered(false, over: .button)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(hover.isVisible)
    }

    func testMovingFromButtonIntoPreviewKeepsItOpen() async throws {
        let hover = DownloadsHover()
        hover.setHovered(true, over: .button)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(hover.isVisible)
        hover.setHovered(false, over: .button)
        hover.setHovered(true, over: .preview)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(hover.isVisible)
        hover.setHovered(false, over: .preview)
        // The close task can start later than this test's continuation on a busy runner.
        try await compatibilityWait { !hover.isVisible }
        XCTAssertFalse(hover.isVisible)
    }

    func testDismissCancelsPendingOpenAndAllowsNextHover() async throws {
        let hover = DownloadsHover()
        hover.setHovered(true, over: .button)
        hover.dismiss()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(hover.isVisible)
        hover.setHovered(true, over: .button)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(hover.isVisible)
        hover.dismiss()
        XCTAssertFalse(hover.isVisible)
    }
}
