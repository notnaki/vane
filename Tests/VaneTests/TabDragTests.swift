import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor final class TabDragTests: XCTestCase {
    func testWholeRowChoosesTheNearestGapWithoutSplitting() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<4).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let original = store.tabs.map(\.id)
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        drag.tab = original[0]
        drag.at = Landing.Spot(kind: .today, index: 0)
        var side: Landing.Band?
        let marker = SidebarDropMarker()
        let drop = TabDrop(store: store, target: store.tabs[2], into: .today,
                           axis: .vertical, extent: 220,
                           marker: marker, markerTarget: store.tabs[2].id.uuidString,
                           side: Binding(get: { side }, set: { side = $0 }), row: 2, rows: 4)
        for y in [CGFloat(0), Look.rowHeight * 0.3, Look.rowHeight * 0.49] {
            drop.trackHover(at: CGPoint(x: 100, y: y))
            XCTAssertEqual(side, .before)
        }
        for y in [Look.rowHeight * 0.5, Look.rowHeight * 0.7, Look.rowHeight] {
            drop.trackHover(at: CGPoint(x: 100, y: y))
            XCTAssertEqual(side, .after)
        }
        let padded = TabDrop(store: store, target: store.tabs[2], into: .today,
                             axis: .vertical, extent: 220, verticalInset: Look.rowGap / 2,
                             side: Binding(get: { side }, set: { side = $0 }), row: 2, rows: 4)
        padded.trackHover(at: CGPoint(x: 100, y: 0))
        XCTAssertEqual(side, .before)
        padded.trackHover(at: CGPoint(x: 100, y: Look.rowHeight + Look.rowGap))
        XCTAssertEqual(side, .after)
        let midpoint = Look.rowGap / 2 + Look.rowHeight / 2
        padded.trackHover(at: CGPoint(x: 100, y: midpoint - 0.1))
        XCTAssertEqual(side, .before)
        padded.trackHover(at: CGPoint(x: 100, y: midpoint))
        XCTAssertEqual(side, .after)
        padded.trackHover(at: CGPoint(x: 100, y: midpoint), splitting: true)
        XCTAssertEqual(side, .onto)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertEqual(marker.target, store.tabs[2].id.uuidString)
        marker.remember(CGRect(x: 8, y: 121, width: 220, height: 2))
        XCTAssertTrue(marker.visible(session: drag.session, active: drag.active))
        XCTAssertTrue(drop.performDrop(at: CGPoint(x: 100, y: Look.rowHeight * 0.6)))
        XCTAssertFalse(marker.visible(session: drag.session, active: drag.active))
        XCTAssertEqual(store.tabs.map(\.id), [original[1], original[2], original[0], original[3]])
        XCTAssertTrue(store.splits.isEmpty)

        drag.tab = original[0]
        drag.at = Landing.Spot(kind: .today, index: 2)
        let splitTarget = store.tabs[3]
        let splitDrop = TabDrop(store: store, target: splitTarget, into: .today,
                                axis: .vertical, extent: 220,
                                side: Binding(get: { side }, set: { side = $0 }), row: 3, rows: 4)
        let middle = CGPoint(x: 100, y: Look.rowHeight / 2)
        let beforeSplit = store.tabs.map(\.id)
        splitDrop.trackHover(at: middle, splitting: true)
        XCTAssertEqual(side, .onto)
        XCTAssertEqual(store.tabs.map(\.id), beforeSplit)
        XCTAssertTrue(store.splits.isEmpty)
        XCTAssertTrue(splitDrop.performDrop(at: middle, splitting: true))
        XCTAssertEqual(store.split(containing: original[0])?.tabs.count, 2)
        XCTAssertTrue(store.split(containing: original[0])?.contains(splitTarget.id) == true)
    }

    func testSectionEndsAcceptTabsAlreadyInThatSection() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<3).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let original = store.tabs.map(\.id)
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        var side: Landing.Band?
        let binding = Binding<Landing.Band?>(get: { side }, set: { side = $0 })
        let head = TabDrop(store: store, target: nil, into: .today,
                           axis: .horizontal, extent: 0, side: binding)
        drag.tab = original[2]
        drag.at = Landing.Spot(kind: .today, index: 2)
        head.trackHover(at: .zero)
        XCTAssertNotNil(side)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertTrue(head.performDrop(at: .zero))
        XCTAssertEqual(store.tabs.map(\.id), [original[2], original[0], original[1]])

        store.tabs.forEach { $0.kind = .pinned }
        store.syncShapes()
        let pinnedOrder = store.tabs.map(\.id)
        let tail = TabDrop(store: store, target: nil, into: .pinned,
                           axis: .horizontal, extent: 0, side: binding)
        drag.tab = original[2]
        drag.at = Landing.Spot(kind: .pinned, index: 0)
        tail.trackHover(at: .zero)
        XCTAssertNotNil(side)
        XCTAssertEqual(store.tabs.map(\.id), pinnedOrder)
        XCTAssertTrue(tail.performDrop(at: .zero))
        XCTAssertEqual(store.tabs.map(\.id), original)
    }

    func testReorderingASplitMovesEveryPaneOnRelease() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<3).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let original = store.tabs.map(\.id)
        store.splits = [Split(tabs: [original[0], original[1]])!]
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        drag.tab = original[0]
        drag.at = Landing.Spot(kind: .today, index: 0)
        var side: Landing.Band?
        let drop = TabDrop(store: store, target: store.tabs[2], into: .today,
                           axis: .vertical, extent: 220,
                           side: Binding(get: { side }, set: { side = $0 }), row: 1, rows: 2)
        let below = CGPoint(x: 100, y: Look.rowHeight - 1)
        drop.trackHover(at: below)
        XCTAssertEqual(side, .after)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertTrue(drop.performDrop(at: below))
        XCTAssertEqual(store.tabs.map(\.id), [original[2], original[0], original[1]])
        XCTAssertEqual(store.splits.first?.tabs, [original[0], original[1]])
        XCTAssertEqual(store.leadPane(store.splits[0]), original[0])

        let split = store.splits[0]
        drag.tab = original[0]
        drag.at = Landing.Spot(kind: .today, index: 1)
        let pinned = TabDrop(store: store, target: nil, into: .pinned,
                             axis: .horizontal, extent: 0,
                             side: Binding(get: { side }, set: { side = $0 }))
        let point = CGPoint(x: 100, y: 1)
        pinned.trackHover(at: point)
        XCTAssertEqual(store.tabs.filter { $0.kind == .pinned }.count, 0)
        XCTAssertTrue(pinned.performDrop(at: point))
        XCTAssertEqual(store.tabs.filter { $0.kind == .pinned }.map(\.id),
                       [original[0], original[1]])
        XCTAssertEqual(store.splits[0], split)

        let folder = store.pins.newFolder(named: "Nested pane", next: original[1].uuidString)!
        store.pins.move(original[1].uuidString, into: folder.id)
        store.applyOrder(.pinned)
        drag.tab = original[0]
        drag.at = Landing.Spot(kind: .pinned, index: 0)
        pinned.trackHover(at: point)
        XCTAssertNotNil(side)
        XCTAssertEqual(store.pins.folder(holding: original[1].uuidString)?.id, folder.id)
        XCTAssertTrue(pinned.performDrop(at: point))
        XCTAssertNil(store.pins.folder(holding: original[1].uuidString))
        XCTAssertEqual(store.splits[0], split)
    }

    func testAdjacentGapCanCollectANoncontiguousSelection() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<4).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let original = store.tabs.map(\.id)
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        drag.tab = original[0]
        drag.tabs = [original[0], original[2]]
        drag.at = Landing.Spot(kind: .today, index: 0)
        var side: Landing.Band?
        let drop = TabDrop(store: store, target: store.tabs[1], into: .today,
                           axis: .vertical, extent: 220,
                           side: Binding(get: { side }, set: { side = $0 }), row: 1, rows: 4)
        let above = CGPoint(x: 100, y: 1)
        drop.trackHover(at: above)
        XCTAssertEqual(side, .before)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertTrue(drop.performDrop(at: above))
        XCTAssertEqual(store.tabs.map(\.id), [original[0], original[2], original[1], original[3]])

        let grouped = store.tabs.map(\.id)
        drag.tab = original[0]
        drag.tabs = [original[0], original[2]]
        drag.at = Landing.Spot(kind: .today, index: 0)
        let selectedTarget = TabDrop(store: store, target: store.tabs[1], into: .today,
                                     axis: .vertical, extent: 220,
                                     side: Binding(get: { side }, set: { side = $0 }), row: 1, rows: 4)
        selectedTarget.trackHover(at: CGPoint(x: 100, y: Look.rowHeight / 2))
        XCTAssertEqual(side, .after)
        XCTAssertTrue(selectedTarget.performDrop(at: above))
        XCTAssertEqual(store.tabs.map(\.id), grouped)
        XCTAssertTrue(store.splits.isEmpty)
    }

    func testAdjacentRootGapCanMoveLastChildOutOfAFolder() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<2).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.syncShapes()
        let source = store.tabs[0]
        let target = store.tabs[1]
        let folder = store.todayShape.newFolder(named: "Folder", next: source.id.uuidString)!
        store.todayShape.move(source.id.uuidString, into: folder.id)
        store.applyOrder(.today)
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        drag.tab = source.id
        drag.at = Landing.Spot(kind: .today, index: 1)
        var side: Landing.Band?
        let drop = TabDrop(store: store, target: target, into: .today,
                           axis: .vertical, extent: 220,
                           side: Binding(get: { side }, set: { side = $0 }), row: 2, rows: 3)
        let above = CGPoint(x: 100, y: 1)
        drop.trackHover(at: above)
        XCTAssertEqual(side, .before)
        XCTAssertEqual(store.todayShape.folder(holding: source.id.uuidString)?.id, folder.id)
        XCTAssertTrue(drop.performDrop(at: above))
        XCTAssertNil(store.todayShape.folder(holding: source.id.uuidString))
        XCTAssertEqual(store.tabs.map(\.id), [source.id, target.id])
    }

    func testReleaseCommitsThePreviewedGapAndCrossSectionMove() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<4).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.tabs[3].kind = .pinned
        store.syncShapes()
        let original = store.tabs.map(\.id)
        let source = store.tabs[0]
        let drag = Dragging.shared
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        var side: Landing.Band?
        let binding = Binding<Landing.Band?>(get: { side }, set: { side = $0 })
        let drop = TabDrop(store: store, target: store.tabs[2], into: .today,
                           axis: .vertical, extent: 220, side: binding, row: 2, rows: 3)
        drag.tab = source.id
        drag.at = Landing.Spot(kind: .today, index: 0)
        let below = CGPoint(x: 100, y: Look.rowHeight - 1)
        drop.trackHover(at: below)
        XCTAssertEqual(side, .after)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertTrue(drop.performDrop(at: below))
        XCTAssertEqual(store.tabs.filter { $0.kind == .today }.map(\.id),
                       [original[1], original[2], original[0]])
        XCTAssertFalse(drag.active)
        XCTAssertNil(side)

        let crossSection = TabDrop(store: store, target: store.tabs.first { $0.kind == .pinned },
                                   into: .pinned, axis: .vertical, extent: 220,
                                   side: binding, row: 0, rows: 1)
        drag.tab = source.id
        drag.at = Landing.Spot(kind: .today, index: 2)
        let above = CGPoint(x: 100, y: 1)
        crossSection.trackHover(at: above)
        XCTAssertEqual(source.kind, .today)
        XCTAssertTrue(crossSection.performDrop(at: above))
        XCTAssertEqual(source.kind, .pinned)
        XCTAssertEqual(store.tabs.filter { $0.kind == .pinned }.map(\.id),
                       [original[0], original[3]])
        XCTAssertFalse(drag.active)
        XCTAssertNil(side)
    }

    func testHoverShowsInsertionWithoutReorderingOrChangingSection() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let store = TabStore(isPrivate: true)
        store.tabs = (0..<5).map { _ in Tab(isPrivate: true, profileID: store.profileID) }
        store.tabs[4].kind = .pinned
        store.syncShapes()
        let original = store.tabs.map(\.id)
        let today = store.todayShape
        let pins = store.pins
        let source = store.tabs[0]
        let drag = Dragging.shared
        drag.tab = source.id
        drag.at = Landing.Spot(kind: .today, index: 0)
        defer {
            drag.end()
            store.tabs.forEach { $0.tearDown() }
            TabStore.all.removeAll { $0 === store }
        }
        var publications = 0
        let subscription = store.$tabs.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        var side: Landing.Band?
        let binding = Binding<Landing.Band?>(get: { side }, set: { side = $0 })
        let destination = store.tabs[3]
        let drop = TabDrop(store: store, target: destination, into: .today,
                           axis: .vertical, extent: 220, side: binding, row: 3, rows: 4)

        drop.trackHover(at: CGPoint(x: 100, y: Look.rowHeight - 1))
        XCTAssertEqual(side, .after)
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertEqual(store.todayShape, today)
        XCTAssertEqual(drag.at, Landing.Spot(kind: .today, index: 0))

        let crossSection = TabDrop(store: store, target: store.tabs.first { $0.kind == .pinned },
                                   into: .pinned, axis: .vertical, extent: 220,
                                   side: binding, row: 0, rows: 1)
        crossSection.trackHover(at: CGPoint(x: 100, y: 1))
        XCTAssertEqual(side, .before)
        XCTAssertEqual(source.kind, .today)
        XCTAssertEqual(store.pins, pins)
        XCTAssertEqual(publications, 0)

        drag.cancel()
        XCTAssertEqual(store.tabs.map(\.id), original)
        XCTAssertFalse(drag.active)
    }
}
