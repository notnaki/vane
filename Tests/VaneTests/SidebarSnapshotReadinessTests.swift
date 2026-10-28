import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarSnapshotReadinessTests: XCTestCase {
    func testSnapshotDoesNotSampleBeforeItsCurrentNativeRowsCommit() throws {
        TestEnvironment.prepare()
        let owner = NSObject()
        let space = UUID()
        let scope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space, surfaceID: UUID())
        let retainedScope = SidebarNativeReadinessScope(storeID: ObjectIdentifier(owner), spaceID: space, surfaceID: UUID())
        let retainedSection = NSObject()
        let row = SidebarRows.Row(visible: Pins.Visible(entry: .init(row: .folder(Folder(name: "Deferred row"))), depth: 0), tab: nil)
        let population = SnapshotPopulation()
        let gate = SidebarNativeReadinessCoordinator.shared
        let retainedTicket = gate.register(scope: retainedScope, section: ObjectIdentifier(retainedSection),
                                           generation: 1, geometryRevision: 1)
        gate.complete(retainedTicket)
        XCTAssertTrue(gate.isReady(retainedScope), "A retained other surface starts fully ready")
        gate.expectPopulation(scope, sections: ["today": [row.id]])
        // Intentionally hold the real native geometry boundary beyond the former
        // 20ms sample. Releasing work is separate from observing row commitment.
        let release = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let work = population.pending
                population.pending.removeAll()
                work.forEach { $0() }
            }
        }
        defer {
            release.invalidate()
            population.native?.detach()
            gate.releasePopulationExpectation(scope, owner: ObjectIdentifier(owner))
            gate.unregister(retainedTicket)
        }
        gate.retainPopulationExpectation(scope, owner: ObjectIdentifier(owner))
        _ = try SidebarSnapshot.pixels(SpaceSectionsLayout {
            Text("Snapshot fixture")
        } rows: {
            DeferredSnapshotRows(population: population, scope: scope, rows: [row])
                .frame(height: Look.rowHeight)
        }, sidebarScope: scope, beforeCapture: { host in
            XCTAssertTrue(population.native?.window === host.window)
            XCTAssertTrue(gate.isReady(scope), "The exact current visible population must have committed before capture")
            XCTAssertTrue(gate.isReady(retainedScope), "The other ready surface cannot satisfy this viewport's admission")
        })
        XCTAssertEqual(population.native?.attachedLogicalRows, 1,
                       "A snapshot must include the current native row, not its empty shell")
    }
}

@MainActor private final class SnapshotPopulation {
    var pending: [@MainActor () -> Void] = []
    var native: NativeCachedSidebarBatchesView<Text>?
}

private struct DeferredSnapshotRows: NSViewRepresentable {
    let population: SnapshotPopulation
    let scope: SidebarNativeReadinessScope
    let rows: [SidebarRows.Row]

    func makeNSView(context: Context) -> NativeCachedSidebarBatchesView<Text> {
        let native = NativeCachedSidebarBatchesView<Text>(frame: .zero)
        native.geometryScheduler = { population.pending.append($0) }
        population.native = native
        return native
    }
    func updateNSView(_ native: NativeCachedSidebarBatchesView<Text>, context: Context) {
        var environment = context.environment
        environment.sidebarNativeReadinessScope = scope
        native.configure(rows: rows, modelIDs: Set(rows.map(\.id)), environment: environment,
                         readinessSection: "today") { _, _, _ in Text("Deferred row") }
    }
    static func dismantleNSView(_ native: NativeCachedSidebarBatchesView<Text>, coordinator: ()) { native.detach() }
}
