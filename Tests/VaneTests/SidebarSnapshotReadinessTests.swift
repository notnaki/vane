import AppKit
import SwiftUI
import XCTest
@testable import vane

@MainActor final class SidebarSnapshotReadinessTests: XCTestCase {
    func testVisibleSnapshotPlacementExcludesPointerAtEveryCorner() throws {
        let screen = NSRect(x: -1200, y: 100, width: 1000, height: 800)
        let size = NSSize(width: 250, height: 400)
        let points = [NSPoint(x: screen.minX + 20, y: screen.minY + 337),
                      NSPoint(x: screen.maxX - 20, y: screen.minY + 337),
                      NSPoint(x: screen.minX + 20, y: screen.maxY - 20),
                      NSPoint(x: screen.maxX - 20, y: screen.maxY - 20),
                      NSPoint(x: screen.midX, y: screen.midY)]
        for point in points {
            let frame = try XCTUnwrap(SidebarSnapshot.frame(avoiding: point, size: size, within: screen))
            XCTAssertTrue(screen.contains(frame), "The exact snapshot owner must stay on screen")
            XCTAssertFalse(frame.contains(point), "The live return control must not acquire physical-pointer hover")
            XCTAssertEqual(frame.size, size)
        }
    }

    func testVisibleSnapshotPlacementRejectsScreensWithoutAnUnhoveredPosition() {
        let screen = NSRect(x: 100, y: 100, width: 250, height: 400)
        XCTAssertNil(SidebarSnapshot.frame(avoiding: NSPoint(x: 120, y: 437), size: screen.size, within: screen))
        XCTAssertNil(SidebarSnapshot.frame(avoiding: .zero, size: NSSize(width: 251, height: 400), within: screen))
    }

    func testPointerIntrusionDiscardsThePreviousInteractivePresentation() async throws {
        TestEnvironment.prepare()
        let app = NSApplication.shared
        let policy = app.activationPolicy()
        defer { app.setActivationPolicy(policy) }
        let loop = try await NativeFixtureApplicationLoop.acquire(activationPolicy: .accessory)
        var failure: (any Error)?
        do {
            let state = SnapshotInteractiveState()
            var pointer = NSEvent.mouseLocation
            var previousHost: NSView?
            var phase = 0
            _ = try await SidebarSnapshot.imageWhenReady(SnapshotInteractiveSurface(state: state),
                                                         pointerLocation: { pointer }) { host in
                guard let probe = state.probe, probe.window === host.window, let setHovered = state.setHovered else { return false }
                if phase == 0 {
                    // Enter a real SwiftUI interaction state before introducing the
                    // pointer. The fixture never changes the user's system cursor.
                    setHovered(true)
                    phase = 1
                    return false
                }
                if phase == 1 {
                    guard probe.hovered, let window = host.window else { return false }
                    previousHost = host
                    pointer = NSPoint(x: window.frame.midX, y: window.frame.midY)
                    phase = 2
                    return false
                }
                XCTAssertFalse(host === previousHost, "Relocation must discard the old interaction and its animation graph")
                XCTAssertFalse(probe.hovered, "The replacement surface must start in its idle state")
                return true
            }
            XCTAssertEqual(phase, 2)
            XCTAssertNil(previousHost?.window, "The previous presentation owner must be detached before capture")
        } catch { failure = error }
        do { try await loop.close() }
        catch {
            if failure == nil { failure = error }
            else { XCTFail("Snapshot intrusion loop cleanup also failed: \(error)") }
        }
        if let failure { throw failure }
    }

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

@MainActor private final class SnapshotInteractiveState {
    weak var probe: SnapshotInteractiveProbe.Native?
    var setHovered: ((Bool) -> Void)?
}

private struct SnapshotInteractiveSurface: View {
    let state: SnapshotInteractiveState
    @State private var hovered = false
    var body: some View {
        Color(white: hovered ? 0.8 : 0.2)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .background(SnapshotInteractiveProbe(state: state, hovered: hovered))
            .onAppear { state.setHovered = { hovered = $0 } }
    }
}

private struct SnapshotInteractiveProbe: NSViewRepresentable {
    final class Native: NSView { var hovered = false }
    let state: SnapshotInteractiveState
    let hovered: Bool
    func makeNSView(context: Context) -> Native { Native() }
    func updateNSView(_ view: Native, context: Context) {
        state.probe = view
        view.hovered = hovered
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
