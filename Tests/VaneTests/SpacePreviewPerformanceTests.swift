import XCTest
import SwiftUI
@testable import vane

@MainActor final class SpacePreviewPerformanceTests: XCTestCase {
    func testPreviewKeepsFolderShapeUntilNextGesture() throws {
        TestEnvironment.prepare()
        let profile = UUID(), space = Space(name: "Work", profileID: profile)
        let key = TabStore.shapeKey(space: space.id, profileID: profile)
        defer { UserDefaults.vane.removeObject(forKey: key) }
        var shape = Pins()
        _ = shape.newFolder(named: "Original folder")
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        _ = preview.rows
        shape = Pins()
        _ = shape.newFolder(named: "Updated folder")
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        XCTAssertEqual(preview.rows.pinned.map { preview.title(for: $0, saved: [:]) },
                       ["Original folder"], "A moving preview must not reread the folder file each frame")
        let next = SpacePreviewList(space: space, liveTabs: nil)
        XCTAssertEqual(next.rows.pinned.map { next.title(for: $0, saved: [:]) }, ["Updated folder"])
    }

    func testPreviewKeepsSavedTitlesUntilNextGesture() throws {
        TestEnvironment.prepare()
        let profile = UUID(), url = URL(string: "https://example.com/document")!
        let space = Space(name: "Work", profileID: profile, tabURLs: [url])
        let file = Suspension.SpaceState.url(for: profile, in: Store.directory)
        let tidying = TidyTitles.enabled
        TidyTitles.enabled = false
        defer {
            TidyTitles.enabled = tidying
            TidyTitles.forget(profile)
            try? FileManager.default.removeItem(at: file)
        }
        XCTAssertTrue(Suspension.SpaceState.save([url.absoluteString: Parked(title: "Original document")],
            space: space.id, profileID: profile, in: Store.directory))
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        let original = preview.rows.today.map { preview.title(for: $0) }
        XCTAssertTrue(Suspension.SpaceState.save([url.absoluteString: Parked(title: "Changed document")],
            space: space.id, profileID: profile, in: Store.directory))
        XCTAssertEqual(preview.rows.today.map { preview.title(for: $0) }, original, "Swipe frames must reuse captured saved metadata")
        let next = SpacePreviewList(space: space, liveTabs: nil)
        XCTAssertEqual(original, ["Original document"])
        XCTAssertEqual(next.rows.today.map { next.title(for: $0) }, ["Changed document"],
                       "A later swipe must show newly saved titles")
    }

    func testPreviewDrawsExpandedPinnedChildrenAndKeepsClosedChildrenHidden() throws {
        TestEnvironment.prepare()
        let profile = UUID(), a = URL(string: "https://a.example")!, b = URL(string: "https://b.example")!
        let open = Folder(name: "Open"), closed = Folder(name: "Closed", collapsed: true)
        let space = Space(name: "Work", profileID: profile, pinnedTabURLs: [a, b])
        let key = TabStore.shapeKey(space: space.id, profileID: profile)
        defer { UserDefaults.vane.removeObject(forKey: key) }
        let shape = Pins(entries: [.init(row: .folder(open)), .init(row: .tab(a.absoluteString), parent: open.id),
                                   .init(row: .folder(closed)), .init(row: .tab(b.absoluteString), parent: closed.id)])
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        XCTAssertEqual(preview.rows.pinned.map { preview.title(for: $0) }, ["Open", "a.example", "Closed"])
        XCTAssertEqual(preview.rows.pinned.map(\.depth), [0, 1, 0])
        var changed = shape
        changed.toggle(folder: open.id)
        UserDefaults.vane.set(try JSONEncoder().encode(changed), forKey: key)
        XCTAssertEqual(preview.rows.pinned.map { preview.title(for: $0) }, ["Open", "a.example", "Closed"])
        XCTAssertEqual(SpacePreviewList(space: space, liveTabs: nil).rows.pinned.count, 2)
    }

    func testPreviewDrawsTodayFoldersInsteadOfFlatteningTheirTabs() throws {
        TestEnvironment.prepare()
        let profile = UUID(), a = URL(string: "https://a.example")!, b = URL(string: "https://b.example")!
        let open = Folder(name: "Today open"), closed = Folder(name: "Today closed", collapsed: true)
        let space = Space(name: "Work", profileID: profile, tabURLs: [a, b])
        let key = TabStore.shapeKey(.today, space: space.id, profileID: profile)
        defer { UserDefaults.vane.removeObject(forKey: key) }
        let shape = Pins(entries: [.init(row: .folder(open)), .init(row: .tab(a.absoluteString), parent: open.id),
                                   .init(row: .folder(closed)), .init(row: .tab(b.absoluteString), parent: closed.id)])
        UserDefaults.vane.set(try JSONEncoder().encode(shape), forKey: key)
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        XCTAssertEqual(preview.rows.today.map { preview.title(for: $0) }, ["Today open", "a.example", "Today closed"])
        XCTAssertEqual(preview.rows.today.map(\.depth), [0, 1, 0])
    }

    func testPopulatedPreviewFrameCost() {
        TestEnvironment.prepare()
        let profile = UUID(), spaceID = UUID()
        let urls = (0..<120).map { URL(string: "https://example.com/document/\($0)")! }
        let space = Space(id: spaceID, name: "Populated", profileID: profile, tabURLs: urls)
        let file = Suspension.SpaceState.url(for: profile, in: Store.directory)
        defer { try? FileManager.default.removeItem(at: file) }
        let parked = Dictionary(uniqueKeysWithValues: urls.map {
            ($0.absoluteString, Parked(title: "Saved document", state: Data(repeating: 42, count: 16_384)))
        })
        XCTAssertTrue(Suspension.SpaceState.save(parked, space: spaceID, profileID: profile, in: Store.directory))
        let preview = SpacePreviewList(space: space, liveTabs: nil)
        let start = ContinuousClock.now
        for _ in 0..<120 { _ = preview.body }
        print("POPULATED_PREVIEW_120_FRAMES: \(start.duration(to: .now))")
        XCTAssertFalse(preview.rows.today.isEmpty)
    }

}
