import AppKit
import Combine
import SwiftUI
import XCTest
@testable import vane

@MainActor final class PaletteMetadataObservationTests: XCTestCase {
    private final class Tick: ObservableObject { @Published var value = 0 }
    private final class Calls {
        var values: [PaletteSpaceCatalog.Metadata] = []
        var bodies = 0
    }
    private struct Mounted: View {
        @ObservedObject var tick: Tick
        let catalog: PaletteSpaceCatalog
        let manager: ProfileManager
        let calls: Calls
        var body: some View {
            calls.bodies += 1
            return Text("Body \(tick.value)")
                .onReceive(catalog.metadataChanges(manager: manager)) { calls.values.append($0) }
        }
    }
    private func manager() throws -> ProfileManager {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("palette-observation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ProfileManager(directory: directory, sandboxed: true)
    }
    private func drain() async {
        // Multiple turns also expose an initial-emission/resubscription feedback loop.
        for _ in 0..<8 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    func testMountedSubscriptionIgnoresUnrelatedManagerActivityAndBodyUpdates() async throws {
        _ = NSApplication.shared
        let manager = try manager()
        let other = manager.create(name: "Other")
        let tick = Tick(), calls = Calls(), catalog = PaletteSpaceCatalog()
        let host = NSHostingView(rootView: Mounted(tick: tick, catalog: catalog, manager: manager, calls: calls))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        host.layoutSubtreeIfNeeded()
        await drain()
        XCTAssertEqual(calls.values.count, 1)
        let bodies = calls.bodies
        manager.active = other
        await drain()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(calls.bodies, bodies, "Changing the active profile must not invalidate palette metadata consumers")
        XCTAssertEqual(calls.values.count, 1)
        for value in 1...4 {
            tick.value = value
            host.layoutSubtreeIfNeeded()
            await drain()
        }
        XCTAssertGreaterThan(calls.bodies, bodies, "The fixture must really rebuild its body")
        XCTAssertEqual(calls.values.count, 1, "Rebuilding must not resubscribe and replay metadata")
        withExtendedLifetime(host) {}
    }
    func testMetadataBurstPublishesCompletedRenameAndRevisionOnceAndRefreshesSavedSpaces() async throws {
        let manager = try manager(), catalog = PaletteSpaceCatalog()
        var values: [PaletteSpaceCatalog.Metadata] = []
        let subscription = catalog.metadataChanges(manager: manager).sink { values.append($0) }
        await drain()
        values.removeAll()
        let own = manager.active.id
        manager.rename(own, to: "Renamed profile")
        var space = manager.createSpace(name: "Draft", in: own)
        space.name = "Saved Space"
        XCTAssertTrue(manager.updateSpace(space))
        XCTAssertTrue(values.isEmpty, "Published willSet must not synchronously expose incomplete manager state")
        await drain()
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.last?.profiles, manager.profiles)
        XCTAssertEqual(values.last?.revision, manager.spacesRevision)
        await catalog.prepare(manager: manager)?.value
        XCTAssertEqual(catalog.spaces(for: own, manager: manager), [space])
        manager.rename(own, to: "Renamed profile")
        await drain()
        XCTAssertEqual(values.count, 1, "An equal Published assignment must not refresh the palette")
        XCTAssertTrue(manager.deleteSpace(space.id, in: own))
        await drain()
        XCTAssertEqual(values.count, 2)
        await catalog.prepare(manager: manager)?.value
        XCTAssertTrue(catalog.spaces(for: own, manager: manager).isEmpty)
        let other = manager.create(name: "Removable profile")
        await drain()
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.last?.profiles, manager.profiles)
        XCTAssertTrue(manager.delete(other.id))
        await drain()
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values.last?.profiles, manager.profiles)
        withExtendedLifetime(subscription) {}
    }
}
