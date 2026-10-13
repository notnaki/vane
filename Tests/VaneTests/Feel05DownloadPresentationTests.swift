import Combine
import XCTest
@testable import vane

@MainActor final class Feel05DownloadPresentationTests: XCTestCase {
    func testProgressDoesNotRebuildMembershipButCompletionRenameAndRemovalDo() async throws {
        TestEnvironment.prepare()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloads = Downloads(directory: dir, sandboxed: true)
        let item = downloads.add(.init(name: "live.png", state: "running"))
        let source = DownloadLibrary(managers: [downloads])
        let presentation = Feel05DownloadPresentation(source)
        var changes = 0
        let observation = presentation.objectWillChange.sink { changes += 1 }
        item.fraction = 0.5
        item.received = 1_000
        // Drain queued aggregate notifications without a machine-sensitive latency assertion.
        await drain()
        XCTAssertEqual(changes, 0, "Transfer bytes must update rows without rebuilding sections")
        item.status = .done
        try await waitUntil { presentation.rows.first?.done == true }
        XCTAssertEqual(changes, 1, "Only completion, not transfer bytes, should rebuild section membership")
        XCTAssertEqual(presentation.media(query: "live").map(\.id), [item.id])
        item.name = "renamed.pdf"
        try await waitUntil { presentation.rows.first?.name == "renamed.pdf" }
        XCTAssertTrue(presentation.media(query: "").isEmpty)
        XCTAssertTrue(presentation.groups(query: "live", completedOnly: false).isEmpty)
        XCTAssertEqual(presentation.groups(query: "renamed", completedOnly: true).flatMap(\.items).count, 1)
        downloads.forget(item)
        try await waitUntil { presentation.rows.isEmpty }
        XCTAssertTrue(presentation.rows.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testMissingCompletedDownloadKeepsItsHistoricalGroupAndIdentity() async throws {
        TestEnvironment.prepare()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("old.pdf")
        try Data([1]).write(to: file)
        let completed = Date.now.addingTimeInterval(-10 * 86_400)
        let downloads = Downloads(directory: dir, sandboxed: true)
        let item = downloads.add(.init(name: "old.pdf", destination: file, state: "done", completed: completed))
        let presentation = Feel05DownloadPresentation(DownloadLibrary(managers: [downloads]))
        let before = presentation.groups(query: "", completedOnly: false)
        XCTAssertEqual(before.first?.title, Library.bucket(completed))
        try FileManager.default.removeItem(at: file)
        downloads.refreshMissing()
        try await waitUntil { presentation.rows.first?.done == false }
        XCTAssertEqual(item.status, .missing)
        let after = presentation.groups(query: "", completedOnly: false)
        XCTAssertEqual(after.first?.title, before.first?.title)
        XCTAssertEqual(after.flatMap(\.items).map(\.id), [item.id])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Deferred presentation update did not arrive")
    }

    private func drain() async {
        // Yield past progress notifications; completion is checked against actual state above.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
