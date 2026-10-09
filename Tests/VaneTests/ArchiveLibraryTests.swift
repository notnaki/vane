import AppKit
import Combine
import XCTest
@testable import vane

@MainActor final class ArchiveLibraryTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare(); _ = NSApplication.shared }

    func testGlobalArchiveKeepsDuplicateSitesAndRoutesRemovalToTheirOwners() {
        let work = Profile(name: "Work"), home = Profile(name: "Home")
        let workArchive = Archive.shared(for: work.id), homeArchive = Archive.shared(for: home.id)
        defer { workArchive.clear(); homeArchive.clear() }
        let library = ArchiveLibrary(sources: [.init(profile: work, archive: workArchive), .init(profile: home, archive: homeArchive)])
        let url = URL(string: "https://example.test")!
        workArchive.add(url: url, title: "Work page")
        homeArchive.add(url: url, title: "Home page")
        XCTAssertEqual(library.entries.count, 2)
        XCTAssertEqual(Set(library.entries.map(\.id)).count, 2)
        let row = library.entries.first { $0.profile.id == home.id }!
        XCTAssertTrue(library.owner(of: row) === homeArchive)
        library.owner(of: row)?.remove(row.entry.id)
        XCTAssertEqual(library.entries.map(\.profile.id), [work.id])
        XCTAssertEqual(workArchive.entries.first?.title, "Work page")
        library.clear()
        XCTAssertTrue(workArchive.entries.isEmpty)
        XCTAssertTrue(homeArchive.entries.isEmpty)
    }

    func testArchiveForwardsLiveChangesAndPrivateLibraryStaysSeparate() {
        let profile = Profile(name: "Work")
        let archive = Archive.shared(for: profile.id)
        defer { archive.clear() }
        let library = ArchiveLibrary(sources: [.init(profile: profile, archive: archive)])
        var changes = 0
        let observation = library.objectWillChange.sink { changes += 1 }
        archive.add(url: URL(string: "https://new.test")!, title: "New")
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(library.entries.first?.entry.title, "New")
        XCTAssertFalse(ArchiveLibrary.library(for: Profile.incognito.id).entries.contains { $0.profile.id == profile.id })
        withExtendedLifetime(observation) {}
    }
}
