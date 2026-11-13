import AppKit
import XCTest
@testable import vane

@MainActor final class SidebarMaterializationTests: XCTestCase {
    func testAnOldCompletionCannotReleaseTheReplacementCover() {
        let state = SidebarMaterialization()
        let old = UUID(), replacement = UUID(), space = UUID()
        let first = state.acquire(owner: old, spaceID: space, favoritesHeight: 40, minimumRowsExtent: 200)
        let second = state.acquire(owner: replacement, spaceID: space, favoritesHeight: 50, minimumRowsExtent: 300)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(state.release(owner: old))
        XCTAssertTrue(state.isDeferred)
        XCTAssertTrue(state.belongs(to: replacement, generation: second))
        XCTAssertFalse(state.belongs(to: old, generation: first))
        XCTAssertTrue(state.release(owner: replacement))
        XCTAssertFalse(state.isDeferred)
    }

    func testRetargetingTheSameCoverInvalidatesTheOldRenderedGeneration() {
        let state = SidebarMaterialization(), owner = UUID()
        let first = state.acquire(owner: owner, spaceID: UUID(), favoritesHeight: 0, minimumRowsExtent: 100)
        XCTAssertFalse(state.didRender(first), "A held placeholder cannot acknowledge real content")
        XCTAssertTrue(state.release(owner: owner))
        XCTAssertTrue(state.didRender(first))
        let next = state.acquire(owner: owner, spaceID: UUID(), favoritesHeight: 0, minimumRowsExtent: 100)
        XCTAssertNotEqual(first, next)
        XCTAssertNil(state.renderedID)
        state.release(owner: owner)
        XCTAssertFalse(state.didRender(first), "A delayed old anchor must not acknowledge the replacement")
        XCTAssertTrue(state.didRender(next))
    }

    func testRepeatedTrackingKeepsItsLeaseAndCachedDocumentExtent() {
        let state = SidebarMaterialization(), owner = UUID(), space = UUID()
        state.rememberRowsExtent(1400)
        let first = state.acquire(owner: owner, spaceID: space, favoritesHeight: 72, minimumRowsExtent: 700)
        state.rememberRowsExtent(30)
        let tracked = state.acquire(owner: owner, spaceID: space, favoritesHeight: 0, minimumRowsExtent: 0)
        XCTAssertEqual(first, tracked)
        XCTAssertEqual(state.favoritesHeight, 72)
        XCTAssertEqual(state.rowsExtent, 1400, "Covered placeholders must not collapse the retained scroll extent")
        state.release(owner: owner)
        let next = state.acquire(owner: UUID(), spaceID: space, favoritesHeight: 72, minimumRowsExtent: 700)
        XCTAssertNotEqual(next, first)
        XCTAssertEqual(state.rowsExtent, 1400, "Placeholder geometry must not overwrite the real cached extent")
    }

    func testUnregisteredPlaceholderCannotBecomeReadyUntilItsExactScopeRenders() {
        let coordinator = SidebarNativeReadinessCoordinator()
        let owner = NSObject()
        let space = UUID()
        let old = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space)
        let next = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space,
                                               materializationID: UUID())
        coordinator.beginMaterialization(next)
        XCTAssertFalse(coordinator.isReady(next, allowingUnregistered: true))
        coordinator.endMaterialization(old)
        XCTAssertFalse(coordinator.isReady(next, allowingUnregistered: true), "Old-generation callbacks cannot lift this gate")
        coordinator.endMaterialization(next)
        XCTAssertTrue(coordinator.isReady(next, allowingUnregistered: true))
    }
}
