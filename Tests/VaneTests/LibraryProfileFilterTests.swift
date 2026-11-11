import AppKit
import XCTest
@testable import vane

@MainActor final class LibraryProfileFilterTests: XCTestCase {
    func testFilterPanelDismissesForSearchAndFreshVisitResetsProfileChoices() {
        TestEnvironment.prepare()
        _ = NSApplication.shared
        let library = Library.shared
        let previous = (library.section, library.profileFilters, library.filterSection, library.query, library.littleArcOnly, library.completedOnly)
        let store = TabStore(profileID: UUID(), session: [])
        defer {
            Library.open(previous.0, in: store)
            library.profileFilters = previous.1
            library.filterSection = previous.2
            library.query = previous.3; library.littleArcOnly = previous.4; library.completedOnly = previous.5
            store.libraryOpen = false
            store.dropStashes()
            TabStore.all.removeAll { $0 === store }
            Store.forget(store.profileID)
        }
        Library.open(.downloads, in: store)
        library.profileFilters[.downloads] = [UUID()]
        library.filterSection = .downloads
        library.focusSearch()
        XCTAssertNil(library.filterSection, "Find must reveal the editor before requesting focus")
        XCTAssertFalse(library.profileFilters[.downloads, default: []].isEmpty)
        library.filterSection = .downloads
        Library.open(.archived, in: store)
        XCTAssertNil(library.filterSection, "Changing sections closes the previous filter panel")
        XCTAssertFalse(library.profileFilters[.downloads, default: []].isEmpty)
        store.libraryOpen = false
        Library.open(.downloads, in: store)
        XCTAssertTrue(library.profileFilters.isEmpty, "A fresh visit must start with all profiles")
    }

    func testDownloadProfilesIntersectSearchAndCompletion() throws {
        TestEnvironment.prepare()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = Downloads(profileID: UUID(), directory: directory, sandboxed: true)
        let work = Downloads(profileID: UUID(), directory: directory, sandboxed: true)
        let first = home.add(.init(name: "report.pdf", state: "done"))
        let second = work.add(.init(name: "report.pdf", state: "done"))
        work.add(.init(name: "report-draft.pdf", state: "running"))
        let presentation = Feel05DownloadPresentation(DownloadLibrary(managers: [home, work]))
        XCTAssertEqual(presentation.groups(query: "report", completedOnly: true, profileIDs: [work.profileID])
            .flatMap(\.items).map(\.id), [second.id])
        XCTAssertEqual(Set(presentation.groups(query: "report.pdf", completedOnly: true,
                                              profileIDs: [home.profileID, work.profileID]).flatMap(\.items).map(\.id)),
                       [first.id, second.id])
        XCTAssertEqual(presentation.groups(query: "", completedOnly: false).flatMap(\.items).count, 3)
        XCTAssertTrue(presentation.groups(query: "missing", completedOnly: false,
                                          profileIDs: [work.profileID]).isEmpty)
    }

    func testArchiveCacheIncludesProfileSelectionAndKeepsOtherFilters() async {
        let home = Profile(name: "Home"), work = Profile(name: "Work")
        let entry = Archive.Entry(url: "https://same.invalid", title: "Report", at: .now, littleArc: true)
        let rows = [ArchiveLibrary.Entry(profile: home, entry: entry),
                    ArchiveLibrary.Entry(profile: work, entry: entry)]
        let search = Feel05ArchiveSearch()
        let first = await search.groups(rows, revision: 1, query: "report", littleOnly: true, profileIDs: [home.id])
        let second = await search.groups(rows, revision: 1, query: "report", littleOnly: true, profileIDs: [work.id])
        let all = await search.groups(rows, revision: 1, query: "report", littleOnly: true)
        XCTAssertEqual(first.flatMap(\.items).map(\.profile.id), [home.id])
        XCTAssertEqual(second.flatMap(\.items).map(\.profile.id), [work.id])
        XCTAssertEqual(all.flatMap(\.items).count, 2)
        let absent = await search.groups(rows, revision: 1, query: "missing", littleOnly: true, profileIDs: [home.id])
        XCTAssertTrue(absent.isEmpty)
    }

    func testReadingProfilesIntersectReadStateAndSearch() {
        var article = makeReadingArticle(text: "A nebula")
        article.isRead = true
        let home = UUID(), work = UUID()
        let rows = [ReadingQueueItem(profileID: home, profileName: "Home", article: article),
                    ReadingQueueItem(profileID: work, profileName: "Work", article: article)]
        XCTAssertEqual(ReadingQueueSearch.results(items: rows, query: "nebula", filter: .read,
                                                  profileIDs: [work]).map(\.profileID), [work])
        XCTAssertTrue(ReadingQueueSearch.results(items: rows, query: "nebula", filter: .unread,
                                                 profileIDs: [work]).isEmpty)
        XCTAssertEqual(ReadingQueueSearch.results(items: rows, query: "", filter: .all).count, 2)
    }
}
