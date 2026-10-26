import AppKit
import XCTest
@testable import vane

/// Only for state-machine tests whose NSView-only destination is deliberately
/// empty. Actual population correctness remains covered by mounted native tests.
@MainActor final class EmptyNativeSidebarPopulationFixture {
    private enum Failure: Error { case nonemptyFixture, registrationRejected }
    private let coordinator = SidebarNativeReadinessCoordinator.shared
    private let leaseOwner = NSObject()
    private let todayOwner = NSObject()
    private let pinnedOwner = NSObject()
    private let populationOwnerID = UUID()
    private let scope: SidebarNativeReadinessScope
    private var tickets: [SidebarNativeReadinessCoordinator.Ticket] = []
    private var closed = false

    init(store: TabStore, spaceID: UUID) throws {
        guard store.tabs.isEmpty, store.pins.entries.isEmpty, store.todayShape.entries.isEmpty else {
            throw Failure.nonemptyFixture
        }
        scope = SidebarNativeReadinessScope(store: store, spaceID: spaceID)
        let sections: [String: [String]] = ["today": [], "pinned": []]
        coordinator.expectPopulation(scope, sections: sections, populationOwnerID: populationOwnerID)
        coordinator.retainPopulationExpectation(scope, owner: ObjectIdentifier(leaseOwner),
            sections: sections, populationOwnerID: populationOwnerID)
        for (key, owner) in [("today", todayOwner), ("pinned", pinnedOwner)] {
            guard let ticket = coordinator.register(scope: scope, section: ObjectIdentifier(owner),
                sectionKey: key, rowIDs: [], generation: 1, geometryRevision: 1,
                claimingCurrentSection: true, populationOwnerID: populationOwnerID) else {
                close()
                throw Failure.registrationRejected
            }
            tickets.append(ticket)
        }
    }

    func complete() {
        tickets.forEach { coordinator.complete($0) }
        XCTAssertTrue(coordinator.isReady(scope), "The deliberately empty test destination must finish both sections")
    }

    func close() {
        guard !closed else { return }
        closed = true
        tickets.forEach { coordinator.unregister($0) }
        coordinator.releasePopulationExpectation(scope, owner: ObjectIdentifier(leaseOwner))
        tickets.removeAll()
    }
}
