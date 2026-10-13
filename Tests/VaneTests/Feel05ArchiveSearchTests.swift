import AppKit
import XCTest
@testable import vane

@MainActor final class Feel05ArchiveSearchTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    func testLargeCollectionSearchAndMutationDoNotReuseOldCache() async {
        let profile = Profile(name: "Café Work")
        let entries = (0..<10_000).map { index in
            ArchiveLibrary.Entry(profile: profile, entry: .init(
                url: "https://fixture.invalid/\(index)", title: "Entry \(index)",
                at: Date(timeIntervalSince1970: Double(index)), littleArc: index.isMultiple(of: 2)))
        }
        let search = Feel05ArchiveSearch()
        let all = await search.groups(entries, revision: 1, query: "cafe", littleOnly: false)
        XCTAssertEqual(all.flatMap(\.items).count, entries.count)
        let little = await search.groups(entries, revision: 1, query: "", littleOnly: true)
        XCTAssertEqual(little.flatMap(\.items).count, 5_000)
        let exact = await search.groups(entries, revision: 1, query: "Entry 9999", littleOnly: false)
        XCTAssertEqual(exact.flatMap(\.items).map(\.id), [entries.last!.id])
        let changed = await search.groups(Array(entries.dropLast()), revision: 2,
                                          query: "Entry 9999", littleOnly: false)
        XCTAssertTrue(changed.isEmpty, "A mutation invalidates prepared search results")
        let empty = await search.groups(entries, revision: 3, query: "absent", littleOnly: false)
        XCTAssertTrue(empty.isEmpty)
    }

    func testCancelledPreparationAndProfileOwnedIdentity() async {
        let work = Profile(name: "Work"), home = Profile(name: "Home")
        let entry = Archive.Entry(url: "https://same.invalid", title: "Same", at: .now)
        let rows = [ArchiveLibrary.Entry(profile: work, entry: entry),
                    ArchiveLibrary.Entry(profile: home, entry: entry)]
        let search = Feel05ArchiveSearch()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await search.groups(rows, revision: 1, query: "", littleOnly: false)
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled.isEmpty)
        let fresh = await search.groups(rows, revision: 1, query: "", littleOnly: false)
        XCTAssertEqual(Set(fresh.flatMap(\.items).map(\.id)).count, 2)
        let isolated = Feel05ArchiveSearch()
        let privateRows = await isolated.groups([], revision: 1, query: "", littleOnly: false)
        XCTAssertTrue(privateRows.isEmpty)
    }
}
