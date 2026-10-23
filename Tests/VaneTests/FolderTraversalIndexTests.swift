import XCTest
@testable import vane

final class FolderTraversalIndexTests: XCTestCase {
    func testLargeShallowShapeUsesIndexedAncestry() {
        let folders = (0..<10_000).map { Folder(name: "Folder \($0)") }
        var shape = Pins()
        for folder in folders {
            shape.entries.append(.init(row: .folder(folder)))
            shape.entries.append(.init(row: .tab(folder.id.uuidString + "-tab"), parent: folder.id))
        }
        let rows = shape.visible
        XCTAssertEqual(rows.count, 20_000)
        XCTAssertEqual(rows.map(\.depth), (0..<10_000).flatMap { _ in [0, 1] })
    }

    func testCollapsedLiveArrivalsAndLockedDescendantsRetainVisibilityRules() {
        var folder = Folder(name: "Live")
        folder.collapsed = true
        // Lock behavior is independent of a live source's provider-specific payload.
        folder.requiresAuthentication = true
        var shape = Pins()
        shape.entries = [.init(row: .folder(folder)), .init(row: .tab("hidden"), parent: folder.id), .init(row: .tab("outside"))]
        XCTAssertEqual(shape.visible.map(\.id), [folder.id.uuidString, "outside"])
        let index = Pins.TraversalIndex(shape.entries)
        XCTAssertEqual(index.lockedRows(in: shape.entries, unlocked: []), [folder.id.uuidString, "hidden"])
        XCTAssertTrue(index.lockedRows(in: shape.entries, unlocked: [folder.id]).isEmpty)
    }

    func testCyclesAndMissingParentsTerminateAndKeepProtectedRowsLocked() {
        var a = Folder(name: "A"), b = Folder(name: "B")
        b.requiresAuthentication = true
        a.collapsed = true
        var shape = Pins()
        shape.entries = [.init(row: .folder(a), parent: b.id), .init(row: .folder(b), parent: a.id),
                         .init(row: .tab("inside"), parent: a.id), .init(row: .tab("orphan"), parent: UUID())]
        let index = Pins.TraversalIndex(shape.entries)
        XCTAssertTrue(index.lockedRows(in: shape.entries, unlocked: []).contains("inside"))
        XCTAssertTrue(shape.visible.contains { $0.id == "orphan" && $0.depth == 0 })
        XCTAssertLessThanOrEqual(shape.visible.count, shape.entries.count)
    }
}
