import AppKit
import SwiftUI
import XCTest
@testable import vane

/// The scheduler is deliberately held by the test: shell identity/rest can arrive
/// while native population and its row-layout callbacks are still outstanding.
@MainActor final class SidebarNativeReadinessTests: XCTestCase {
    private func scope(_ owner: AnyObject, space: UUID = UUID(), surface: UUID? = nil) -> SidebarNativeReadinessScope {
        SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space, surfaceID: surface)
    }

    func testDelayedSectionsRequireEveryCurrentVisiblePopulation() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), pinned = NSObject(), today = NSObject()
        let destination = scope(owner)
        let first = gate.register(scope: destination, section: ObjectIdentifier(pinned), generation: 1, geometryRevision: 1)
        let second = gate.register(scope: destination, section: ObjectIdentifier(today), generation: 1, geometryRevision: 1)
        var readySignals = 0
        let observation = gate.observe(destination) { readySignals += 1 }
        defer { gate.removeObservation(observation) }
        XCTAssertFalse(gate.isReady(destination), "Identity/rest acknowledgement cannot stand in for native population")
        gate.complete(first)
        XCTAssertFalse(gate.isReady(destination))
        XCTAssertEqual(readySignals, 0)
        gate.complete(second)
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertEqual(readySignals, 1)
        gate.complete(second)
        XCTAssertEqual(readySignals, 1, "Repeated row layout must not publish per-pixel readiness")
    }

    func testExplicitExpectedSectionsBlockPartialRegistrationAndReplacementGaps() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), today = NSObject(), pinned = NSObject(), replacement = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"], "pinned": ["p"]])
        let todayTicket = gate.register(scope: destination, section: ObjectIdentifier(today),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(todayTicket)
        XCTAssertFalse(gate.isReady(destination), "First section cannot acknowledge a second section that has not configured")
        let pinnedTicket = gate.register(scope: destination, section: ObjectIdentifier(pinned),
            sectionKey: "pinned", rowIDs: ["p"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(pinnedTicket)
        XCTAssertTrue(gate.isReady(destination))
        var signals = 0
        let observation = gate.observe(destination) { signals += 1 }
        defer { gate.removeObservation(observation) }
        gate.unregister(pinnedTicket)
        XCTAssertFalse(gate.isReady(destination), "Unregistering an expected section is not completion")
        XCTAssertEqual(signals, 0)
        let newTicket = gate.register(scope: destination, section: ObjectIdentifier(replacement),
            sectionKey: "pinned", rowIDs: ["p"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(pinnedTicket)
        XCTAssertFalse(gate.isReady(destination), "A detached old owner's completion must not stand in for its replacement")
        gate.complete(newTicket)
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertEqual(signals, 1)
    }

    func testExpectedSectionEpochRejectsOldMembershipWithoutInvalidatingUnchangedPeer() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), today = NSObject(), pinned = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"], "pinned": ["p"]])
        let first = gate.register(scope: destination, section: ObjectIdentifier(today),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        let other = gate.register(scope: destination, section: ObjectIdentifier(pinned),
            sectionKey: "pinned", rowIDs: ["p"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(first)
        gate.complete(other)
        gate.expectPopulation(destination, sections: ["today": ["new"], "pinned": ["p"]])
        gate.complete(first)
        XCTAssertFalse(gate.isReady(destination))
        let current = gate.register(scope: destination, section: ObjectIdentifier(today),
            sectionKey: "today", rowIDs: ["new"], generation: 2, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination), "The unchanged Pinned section remains correctly committed")
    }

    func testLastShellOwnerWithdrawalRejectsLateCompletionAndDetach() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), shell = NSObject(), section = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"]])
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(shell))
        let old = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        var signals = 0
        let observation = gate.observe(destination) { signals += 1 }
        defer { gate.removeObservation(observation) }
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(shell))
        gate.complete(old)
        gate.unregister(old)
        XCTAssertFalse(gate.isReady(destination), "A removed shell remains unready after its old native callbacks")
        XCTAssertEqual(signals, 0, "Lifecycle withdrawal is not a successful visible population")
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 2, geometryRevision: 2),
            "A removed native owner cannot re-register without an active shell declaration")
        gate.expectPopulation(destination, sections: ["today": ["t"]])
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(shell))
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination))
        let current = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertEqual(signals, 1)
    }

    func testReleasingOldShellDoesNotWithdrawOverlappingReplacementOwner() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), oldShell = NSObject(), currentShell = NSObject(), section = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"]])
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(currentShell))
        let ticket = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.complete(ticket)
        XCTAssertTrue(gate.isReady(destination), "Only the final owning shell may withdraw a live scope")
    }

    func testNewBodyDeclarationSurvivesSameScopeShellReplacementGap() throws {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject(), section = NSObject()
        let destination = scope(owner)
        let sections = ["today": ["t"]]
        gate.expectPopulation(destination, sections: sections)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        let old = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(old)
        XCTAssertTrue(gate.isReady(destination))
        // The replacement body is evaluated before the old representable dismantles.
        gate.expectPopulation(destination, sections: sections)
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination), "Late completion cannot revive the withdrawn shell")
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell), sections: sections)
        let current = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1)
        XCTAssertNotNil(current, "The replacement must install its authoritative declaration before registering")
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination), "A replacement cannot inherit the old ready nonce")
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination))
    }

    func testReplacementOwnerRefreshesNonNilTicketInvalidatedByFinalWithdrawal() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject(), section = NSObject()
        let destination = scope(owner)
        let sections = ["today": ["t"]]
        gate.expectPopulation(destination, sections: sections)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        // A new native configure can run while the old shell still owns its declaration.
        let beforeWithdrawal = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 2, geometryRevision: 1, claimingCurrentSection: true)
        XCTAssertNotNil(beforeWithdrawal)
        gate.expectPopulation(destination, sections: sections)
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell), sections: sections)
        gate.complete(beforeWithdrawal)
        XCTAssertFalse(gate.isReady(destination), "A nonnil but withdrawn ticket cannot acknowledge the replacement")
        let refreshed = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 2, geometryRevision: 1)
        XCTAssertNotNil(refreshed)
        XCTAssertNotEqual(refreshed, beforeWithdrawal)
        let repeated = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 2, geometryRevision: 1)
        XCTAssertEqual(repeated, refreshed, "Unchanged geometry/layout retries reuse the current nonce")
        gate.complete(refreshed)
        XCTAssertTrue(gate.isReady(destination))
    }

    func testNativeLayoutRefreshesNonNilTicketWithdrawnAfterConfigure() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject()
        let destination = scope(owner)
        let sections: [String: [String]] = ["today": []]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let native = NativeCachedSidebarBatchesView<EmptyView>(frame: NSRect(x: 0, y: 0, width: 250, height: 0))
        scroll.documentView = native
        window.contentView = scroll
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = destination
        gate.expectPopulation(destination, sections: sections)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        native.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        native.layout()
        XCTAssertTrue(gate.isReady(destination))
        // The new body/configure arrives before final withdrawal, leaving a nonnil
        // native ticket which becomes invalid immediately after configure returns.
        gate.expectPopulation(destination, sections: sections)
        native.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell), sections: sections)
        defer {
            native.detach()
            gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(replacementShell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        XCTAssertFalse(gate.isReady(destination))
        native.layout()
        XCTAssertTrue(gate.isReady(destination), "A nonnil withdrawn native ticket must refresh before completion")
    }

    func testOwnWrongMembershipRevokesPreviouslyReadySemanticSection() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"]])
        let old = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        gate.complete(old)
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["other"], generation: 2, geometryRevision: 2,
            claimingCurrentSection: true))
        XCTAssertFalse(gate.isReady(destination), "Rejecting wrong membership must not leave the owner's previous ready ticket active")
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination))
    }

    func testPassiveOldSectionCannotDisplaceReplacementOrRegisterWrongMembership() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), oldSection = NSObject(), replacement = NSObject()
        let destination = scope(owner)
        gate.expectPopulation(destination, sections: ["today": ["t"]])
        let old = gate.register(scope: destination, section: ObjectIdentifier(oldSection),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1, claimingCurrentSection: true)
        let current = gate.register(scope: destination, section: ObjectIdentifier(replacement),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            claimingCurrentSection: true)
        XCTAssertNotNil(current)
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(oldSection),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 2))
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(oldSection),
            sectionKey: "today", rowIDs: ["removed"], generation: 2, geometryRevision: 2))
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination))
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination))
    }

    func testConfiguredBeforeAttachmentEmptyReplacementClaimsSectionWithoutPassiveStealing() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let owner = NSObject(), shell = NSObject()
        let destination = scope(owner)
        let sections: [String: [String]] = ["today": []]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        scroll.documentView = document
        window.contentView = scroll
        let oldNative = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        oldNative.geometryScheduler = { _ in }
        document.addSubview(oldNative)
        let replacement = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        replacement.geometryScheduler = { _ in }
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = destination
        gate.expectPopulation(destination, sections: sections)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(shell))
        defer {
            oldNative.detach()
            replacement.detach()
            gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(shell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        oldNative.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        oldNative.layout()
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertNil(replacement.window)
        replacement.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        document.addSubview(replacement)
        XCTAssertTrue(replacement.window === window)
        replacement.layout()
        XCTAssertTrue(gate.isReady(destination))
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(oldNative),
            sectionKey: "today", rowIDs: [], generation: 99, geometryRevision: 99),
            "The attached replacement, rather than its stale predecessor, must own the semantic section")
        oldNative.layout()
        XCTAssertTrue(gate.isReady(destination), "A passive old layout must not revoke a ready replacement")
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(oldNative),
            sectionKey: "today", rowIDs: [], generation: 100, geometryRevision: 100),
            "A passive old layout cannot reacquire ownership")
    }

    func testDetachedEmptyNativeSectionCannotAcknowledgeReactivatedScope() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject()
        let destination = scope(owner)
        let sections: [String: [String]] = ["today": []]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let native = NativeCachedSidebarBatchesView<EmptyView>(frame: NSRect(x: 0, y: 0, width: 250, height: 0))
        scroll.documentView = native
        window.contentView = scroll
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = destination
        gate.expectPopulation(destination, sections: sections)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        native.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        native.layout()
        XCTAssertTrue(gate.isReady(destination))
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        native.removeFromSuperview()
        XCTAssertNil(native.window)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell), sections: sections)
        defer {
            native.detach()
            gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(replacementShell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        native.layout() // Delayed old native layout callback after the new shell becomes active.
        XCTAssertFalse(gate.isReady(destination), "An empty row set still needs its current, attached native owner")
    }

    func testAttachedPredecessorCannotAcknowledgeReactivatedScopeBeforeReplacementConfigure() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject()
        let destination = scope(owner)
        let oldOwnerID = UUID(), replacementOwnerID = UUID()
        let sections: [String: [String]] = ["today": []]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        scroll.documentView = document
        window.contentView = scroll
        let predecessor = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        predecessor.geometryScheduler = { _ in }
        document.addSubview(predecessor)
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = destination
        environment.sidebarNativeReadinessOwnerID = oldOwnerID
        gate.expectPopulation(destination, sections: sections, populationOwnerID: oldOwnerID)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell), populationOwnerID: oldOwnerID)
        defer {
            predecessor.detach()
            gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(replacementShell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        predecessor.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        predecessor.layout()
        XCTAssertTrue(gate.isReady(destination))
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell), sections: sections, populationOwnerID: replacementOwnerID)
        XCTAssertTrue(predecessor.window === window, "The predecessor remains physically attached during the handoff gap")
        XCTAssertFalse(gate.isReady(destination))
        predecessor.layout()
        XCTAssertFalse(gate.isReady(destination), "An attached predecessor cannot acknowledge the replacement before it configures")
        // Neither a late authoritative configure nor reattachment grants the old
        // shell's captured owner ID authority over the replacement declaration.
        predecessor.configure(rows: [], modelIDs: [], environment: environment, readinessSection: "today") { _, _, _ in EmptyView() }
        predecessor.layout()
        XCTAssertFalse(gate.isReady(destination))
        predecessor.removeFromSuperview()
        document.addSubview(predecessor)
        predecessor.layout()
        XCTAssertFalse(gate.isReady(destination))
        let replacement = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        replacement.geometryScheduler = { _ in }
        var replacementEnvironment = environment
        replacementEnvironment.sidebarNativeReadinessOwnerID = replacementOwnerID
        replacement.configure(rows: [], modelIDs: [], environment: replacementEnvironment, readinessSection: "today") { _, _, _ in EmptyView() }
        document.addSubview(replacement)
        defer { replacement.detach() }
        replacement.layout()
        XCTAssertTrue(gate.isReady(destination))
        predecessor.layout()
        XCTAssertTrue(gate.isReady(destination), "The old owner cannot revoke the replacement's committed readiness")
    }

    func testNewOwnerConfiguredBeforeFinalWithdrawalRefreshesItsNonNilNativeTicket() {
        _ = NSApplication.shared
        let gate = SidebarNativeReadinessCoordinator.shared
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject()
        let destination = scope(owner)
        let oldOwnerID = UUID(), replacementOwnerID = UUID()
        let sections: [String: [String]] = ["today": []]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        scroll.documentView = document
        window.contentView = scroll
        let predecessor = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        let replacement = NativeCachedSidebarBatchesView<EmptyView>(frame: .zero)
        predecessor.geometryScheduler = { _ in }
        replacement.geometryScheduler = { _ in }
        document.addSubview(predecessor)
        document.addSubview(replacement)
        var oldEnvironment = EnvironmentValues()
        oldEnvironment.sidebarNativeReadinessScope = destination
        oldEnvironment.sidebarNativeReadinessOwnerID = oldOwnerID
        var replacementEnvironment = oldEnvironment
        replacementEnvironment.sidebarNativeReadinessOwnerID = replacementOwnerID
        gate.expectPopulation(destination, sections: sections, populationOwnerID: oldOwnerID)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell), populationOwnerID: oldOwnerID)
        defer {
            predecessor.detach()
            replacement.detach()
            gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(replacementShell))
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        predecessor.configure(rows: [], modelIDs: [], environment: oldEnvironment, readinessSection: "today") { _, _, _ in EmptyView() }
        predecessor.layout()
        XCTAssertTrue(gate.isReady(destination))
        gate.expectPopulation(destination, sections: sections, populationOwnerID: replacementOwnerID)
        XCTAssertFalse(gate.isReady(destination), "Identical row IDs cannot inherit another shell lifetime's completion")
        replacement.configure(rows: [], modelIDs: [], environment: replacementEnvironment, readinessSection: "today") { _, _, _ in EmptyView() }
        replacement.layout()
        XCTAssertTrue(gate.isReady(destination), "The replacement now holds a current nonnil ticket before withdrawal")
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell),
            sections: sections, populationOwnerID: replacementOwnerID)
        XCTAssertFalse(gate.isReady(destination))
        predecessor.layout()
        XCTAssertFalse(gate.isReady(destination))
        replacement.layout()
        XCTAssertTrue(gate.isReady(destination), "The replacement refreshes its nonnil withdrawn ticket using its captured current owner ID")
    }

    func testChangedShellOwnerRotatesIdenticalMembershipAndRejectsOldAuthority() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        let destination = scope(owner)
        let oldOwnerID = UUID(), replacementOwnerID = UUID()
        let sections = ["today": ["t"]]
        gate.expectPopulation(destination, sections: sections, populationOwnerID: oldOwnerID)
        let old = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            claimingCurrentSection: true, populationOwnerID: oldOwnerID)
        gate.complete(old)
        XCTAssertTrue(gate.isReady(destination))
        gate.expectPopulation(destination, sections: sections, populationOwnerID: replacementOwnerID)
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination))
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            claimingCurrentSection: true, populationOwnerID: oldOwnerID))
        let current = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            claimingCurrentSection: true, populationOwnerID: replacementOwnerID)
        XCTAssertNotNil(current)
        XCTAssertNotEqual(old, current)
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination))
        // Even reuse of the same native section ObjectIdentifier does not let an
        // old shell's callback revoke a current different owner's registration.
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 2,
            claimingCurrentSection: true, populationOwnerID: oldOwnerID))
        XCTAssertTrue(gate.isReady(destination))
    }

    func testOldAnchorRefreshCannotOverwriteNewBodyOwnerOrAcquireItsLease() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), oldShell = NSObject(), replacementShell = NSObject(), section = NSObject()
        let destination = scope(owner)
        let oldOwnerID = UUID(), replacementOwnerID = UUID()
        let sections = ["today": ["t"]]
        gate.expectPopulation(destination, sections: sections, populationOwnerID: oldOwnerID)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell),
            sections: sections, populationOwnerID: oldOwnerID)
        // The replacement body's declaration precedes a delayed update of the old anchor.
        gate.expectPopulation(destination, sections: sections, populationOwnerID: replacementOwnerID)
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(replacementShell),
            sections: sections, populationOwnerID: replacementOwnerID)
        let current = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            claimingCurrentSection: true, populationOwnerID: replacementOwnerID)
        gate.complete(current)
        XCTAssertTrue(gate.isReady(destination))
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(oldShell))
        gate.retainPopulationExpectation(destination, owner: ObjectIdentifier(oldShell),
            sections: sections, populationOwnerID: oldOwnerID)
        let refreshed = gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            populationOwnerID: replacementOwnerID)
        XCTAssertEqual(refreshed, current, "The stale anchor must leave the new body's epoch and current ticket intact")
        XCTAssertTrue(gate.isReady(destination))
        gate.releasePopulationExpectation(destination, owner: ObjectIdentifier(replacementShell))
        XCTAssertFalse(gate.isReady(destination), "A rejected old anchor refresh must not insert ownership of the new lifetime")
        XCTAssertNil(gate.register(scope: destination, section: ObjectIdentifier(section),
            sectionKey: "today", rowIDs: ["t"], generation: 1, geometryRevision: 1,
            populationOwnerID: replacementOwnerID))
    }

    func testNewStructureAndGeometrySynchronouslyRevokeCompletedPopulation() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        let destination = scope(owner)
        let old = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        gate.complete(old)
        let newStructure = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 2, geometryRevision: 1)
        XCTAssertFalse(gate.isReady(destination))
        gate.complete(old)
        XCTAssertFalse(gate.isReady(destination), "A delayed old-generation layout cannot release the new cover")
        gate.complete(newStructure)
        let newViewport = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 2, geometryRevision: 2)
        XCTAssertFalse(gate.isReady(destination), "Nonzero scroll/resize requires current visible rows")
        gate.complete(newStructure)
        XCTAssertFalse(gate.isReady(destination))
        gate.complete(newViewport)
        XCTAssertTrue(gate.isReady(destination))
    }

    func testDetachAndRapidReverseRejectLateCallbacksEvenForReusedGeneration() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        let destination = scope(owner)
        let old = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        gate.unregister(old)
        let replacement = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        gate.complete(old)
        gate.unregister(old)
        XCTAssertFalse(gate.isReady(destination), "Old detach/completion must not modify a replacement registration")
        gate.complete(replacement)
        XCTAssertTrue(gate.isReady(destination))
    }

    func testPreviewAndColdCachedProfilePopulationsAreIndependent() {
        let gate = SidebarNativeReadinessCoordinator()
        let coldStore = NSObject(), cachedStore = NSObject(), section = NSObject()
        let space = UUID()
        let live = scope(coldStore, space: space)
        let preview = scope(coldStore, space: space, surface: UUID())
        let cached = scope(cachedStore, space: space)
        let liveTicket = gate.register(scope: live, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        let previewTicket = gate.register(scope: preview, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        let cachedTicket = gate.register(scope: cached, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        gate.complete(liveTicket)
        XCTAssertFalse(gate.isReady(preview), "Live readiness must not make a prepared preview claimable")
        XCTAssertFalse(gate.isReady(cached), "A different TabStore restoring the same Space needs its own rows")
        gate.complete(previewTicket)
        XCTAssertTrue(gate.isReady(preview))
        XCTAssertFalse(gate.isReady(cached))
        gate.complete(cachedTicket)
        XCTAssertTrue(gate.isReady(cached))
    }

    func testEmptyAndCreateSpaceStillRequireExplicitCompletion() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        for _ in 0..<2 {
            let empty = scope(owner)
            let ticket = gate.register(scope: empty, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
            XCTAssertFalse(gate.isReady(empty))
            gate.complete(ticket)
            XCTAssertTrue(gate.isReady(empty))
            gate.unregister(ticket)
        }
    }

    private func slideFixture(mount: Bool = true) throws -> (TabStore, Space, NSWindow, NSView, ProfileSpaceSlide) {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        try XCTSkipIf(Motion.spaceReduced, "Native animated cover handoff requires motion")
        let profile = ProfileManager.shared.create(name: "Native readiness fixture").id
        let origin = Space(name: "Origin", profileID: profile)
        let target = Space(name: "Destination", profileID: profile)
        XCTAssertTrue(ProfileManager.shared.saveSpaces([origin, target], for: profile))
        let store = TabStore(profileID: profile, space: origin, session: [])
        store.palette = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        store.window = window
        let slide = ProfileSpaceSlide(frame: container.bounds,
            outgoing: store.swipePreview(in: origin), incoming: store.swipePreview(in: target),
            drag: -80, direction: 1, source: store, includesFavorites: false, travelWidth: 250)
        if mount { container.addSubview(slide) }
        addTeardownBlock { @MainActor in
            slide.cancel()
            window.orderOut(nil)
            window.contentView = nil
            store.window = nil
            store.dropStashes()
            let tabs = store.tabs
            TabStore.all.removeAll { $0 === store }
            SharedTabs.release(tabs)
            Store.forget(profile)
            ProfileManager.shared.delete(profile)
            try? FileManager.default.removeItem(at: ProfileManager.spacesURL(for: profile, in: Store.directory))
        }
        return (store, target, window, container, slide)
    }

    func testIdentityRestAcknowledgementCannotRetireCoverBeforeNativeRowsCommit() throws {
        let (store, target, _, container, slide) = try slideFixture()
        let section = NSObject()
        let destination = scope(store, space: target.id)
        let ticket = SidebarNativeReadinessCoordinator.shared.register(scope: destination,
            section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        defer { SidebarNativeReadinessCoordinator.shared.unregister(ticket) }
        slide.start(duration: 60) { store.switchTo(space: target) }
        slide.finish()
        slide.sidebarDidUpdate(store, renderedSpaceID: target.id, atRest: true)
        XCTAssertTrue(slide.superview === container, "The shell ack precedes delayed population")
        SidebarNativeReadinessCoordinator.shared.complete(ticket)
        XCTAssertNil(slide.superview, "Committed visible rows complete the already-acknowledged handoff immediately")
    }

    func testNativeReadinessBeforeIdentityAckRetiresInTheAcknowledgingTransaction() throws {
        let (store, target, _, container, slide) = try slideFixture()
        let section = NSObject()
        let destination = scope(store, space: target.id)
        let ticket = SidebarNativeReadinessCoordinator.shared.register(scope: destination,
            section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        defer { SidebarNativeReadinessCoordinator.shared.unregister(ticket) }
        slide.start(duration: 60) { store.switchTo(space: target) }
        slide.finish()
        SidebarNativeReadinessCoordinator.shared.complete(ticket)
        XCTAssertTrue(slide.superview === container)
        slide.sidebarDidUpdate(store, renderedSpaceID: target.id, atRest: true)
        XCTAssertNil(slide.superview, "Already-ready population must not add a display frame of doubled ink")
    }

    func testUnlaidOutPreparedPreviewIsNotClaimable() throws {
        let flag = "VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let (_, _, _, _, slide) = try slideFixture(mount: false)
        XCTAssertFalse(slide.preparedPopulationReady, "Allocating preview hosts does not establish row layout")
    }

    private func shiftedLazyLayouts() -> [SidebarPreviewPopulationCoverage.RowLayout] {
        (144...153).map { index in
            .init(index: index, frame: CGRect(x: 0, y: CGFloat(index) * 41 + 5, width: 300, height: 36), committed: true)
        }
    }
    private func lazyCoverage(_ rows: [SidebarPreviewPopulationCoverage.RowLayout]) -> Bool {
        SidebarPreviewPopulationCoverage.covers(visible: CGRect(x: 0, y: 5933, width: 300, height: 359),
            sectionBounds: CGRect(x: 0, y: 0, width: 300, height: 8200), rowCount: 200, rows: rows)
    }

    func testLazyActualCommittedFramesCoverViewportDespiteTrailingGapEstimate() {
        XCTAssertTrue(lazyCoverage(shiftedLazyLayouts()))
    }

    func testLazyViewportRejectsMissingFirstMiddleAndLastActualRow() {
        for missing in [144, 148, 153] {
            XCTAssertFalse(lazyCoverage(shiftedLazyLayouts().filter { $0.index != missing }), "Missing row \(missing) leaves a visible hole")
        }
    }

    func testLazyViewportRejectsStaleWindowOrBoundsCommitAndIncorrectFrame() {
        var rows = shiftedLazyLayouts()
        let previous = rows[4]
        rows[4] = .init(index: previous.index, frame: previous.frame, committed: false)
        XCTAssertFalse(lazyCoverage(rows), "A moved-window or changed-bounds anchor has not committed its current layout")
        rows = shiftedLazyLayouts()
        rows[4] = .init(index: previous.index, frame: previous.frame.offsetBy(dx: 0, dy: 6), committed: true)
        XCTAssertFalse(lazyCoverage(rows), "A six-point extra gap must not pass as ordinary row spacing")
        rows = shiftedLazyLayouts()
        rows[4] = .init(index: previous.index, frame: CGRect(x: 0, y: previous.frame.minY, width: 280, height: 36), committed: true)
        XCTAssertFalse(lazyCoverage(rows), "A stale width must not acknowledge the current viewport")
        rows = shiftedLazyLayouts().map { .init(index: $0.index - 144, frame: $0.frame, committed: true) }
        XCTAssertFalse(lazyCoverage(rows), "Old top-row identities cannot acknowledge far viewport frames")
    }

    func testLazyPreparedPreviewRechecksPopulationAfterFarScrollAtClaim() async throws {
        let flag = "VANE_EXPERIMENT_NATIVE_ROW_BATCH_CACHE"
        let previous = ProcessInfo.processInfo.environment[flag]
        setenv(flag, "1", 1)
        defer {
            if let previous { setenv(flag, previous, 1) } else { unsetenv(flag) }
        }
        let (store, target, window, container, _) = try slideFixture(mount: false)
        let origin = Space(name: "Lazy preview", profileID: store.profileID,
            tabURLs: (0..<200).map { URL(string: "https://example.com/lazy-preview-\($0)")! })
        let outgoing = SpacePreviewList(space: origin, liveTabs: nil)
        XCTAssertFalse(outgoing.eagerlyMountsVisibleRows, "This regression must exercise the >128-row lazy path")
        let slide = ProfileSpaceSlide(frame: container.bounds, outgoing: outgoing,
            incoming: store.swipePreview(in: target), drag: 0, direction: 1,
            source: store, includesFavorites: false, travelWidth: 300)
        slide.isHidden = true
        container.addSubview(slide)
        window.orderFront(nil)
        slide.prepare()
        defer { slide.discardPreparation() }
        try await compatibilityWait { slide.preparedPopulationReady }
        let scroll = try XCTUnwrap(SidebarSectionsViewport.scrollView(in: slide.outgoing))
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 1)
        // No intervening layout/run-loop turn: a cached top viewport cannot
        // acknowledge newly visible lazy rows merely because its clip scrolled.
        let claimed = slide.updatePreparedScrollOffset(6000)
        let readyAtClaim = slide.preparedPopulationReady
        XCTAssertFalse(claimed && !readyAtClaim,
            "Claim must fall back whenever the new far viewport has not committed its actual row layouts")
        XCTAssertEqual(scroll.documentVisibleRect.minY, 6000, accuracy: 1)
        try await compatibilityWait { slide.preparedPopulationReady }
        XCTAssertTrue(slide.updatePreparedScrollOffset(6000), "Once far visible rows commit, the same prepared surface is safe")
    }

    private struct ReadinessControl: NSViewRepresentable {
        let index: Int
        func makeNSView(context: Context) -> NSButton { NSButton(title: "Destination row \(index)", target: nil, action: nil) }
        func updateNSView(_ view: NSButton, context: Context) { view.title = "Destination row \(index)" }
    }

    func testActualNativePopulationSchedulerHoldsCoverUntilVisibleRowLayoutsCommit() async throws {
        let (store, target, window, container, slide) = try slideFixture()
        let destination = scope(store, space: target.id)
        let rows = (0..<100).map { index in
            SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Destination \(index)"))), depth: 0), tab: nil)
        }
        let native = NativeCachedSidebarBatchesView<ReadinessControl>(frame: NSRect(x: 0, y: 0, width: 250, height: 4095))
        var scheduled: [@MainActor () -> Void] = []
        native.geometryScheduler = { scheduled.append($0) }
        var environment = EnvironmentValues()
        environment.sidebarNativeReadinessScope = destination
        native.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment) { _, index, _ in
            ReadinessControl(index: index)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 300))
        scroll.documentView = native
        container.addSubview(scroll, positioned: .below, relativeTo: slide)
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded() // Initial fixture setup only; subsequent population uses natural layout.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 164))
        scroll.reflectScrolledClipView(scroll.contentView)
        defer { native.detach() }
        XCTAssertFalse(scheduled.isEmpty)
        XCTAssertEqual(native.attachedLogicalRows, 0, "The injected scheduler must actually delay native population")
        slide.start(duration: 60) { store.switchTo(space: target) }
        slide.finish()
        slide.sidebarDidUpdate(store, renderedSpaceID: target.id, atRest: true)
        XCTAssertFalse(SidebarNativeReadinessCoordinator.shared.isReady(destination))
        XCTAssertTrue(slide.superview === container, "Shell identity/rest arrives before actual native row population")
        let pending = scheduled
        scheduled.removeAll()
        pending.forEach { $0() }
        try await compatibilityWait {
            let work = scheduled
            scheduled.removeAll()
            work.forEach { $0() }
            return SidebarNativeReadinessCoordinator.shared.isReady(destination)
        }
        XCTAssertNil(slide.superview)
        XCTAssertGreaterThan(native.attachedLogicalRows, 0)
        func buttons(_ root: NSView) -> [NSButton] {
            ((root as? NSButton).map { [$0] } ?? []) + root.subviews.flatMap(buttons)
        }
        let titles = Set(buttons(native).map(\.title))
        for index in 4...11 { XCTAssertTrue(titles.contains("Destination row \(index)"), "Visible destination row \(index) must exist before cover retirement") }
        XCTAssertEqual(scroll.contentView.bounds.minY, 164, accuracy: 0.5)
    }

    func testCancelledReadinessSubscriptionCannotRetireReplacementCover() {
        let gate = SidebarNativeReadinessCoordinator()
        let owner = NSObject(), section = NSObject()
        let destination = scope(owner)
        let ticket = gate.register(scope: destination, section: ObjectIdentifier(section), generation: 1, geometryRevision: 1)
        var retirements = 0
        let observation = gate.observe(destination) { retirements += 1 }
        gate.removeObservation(observation)
        gate.complete(ticket)
        XCTAssertEqual(retirements, 0)
    }
}
