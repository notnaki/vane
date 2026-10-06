import XCTest
import Combine
@testable import vane

@MainActor final class DownloadLibraryTests: XCTestCase {
    func testCombinesSavedProfilesAndRoutesRemovalToTheOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileManager(directory: directory, sandboxed: true)
        let work = profiles.create(name: "Work")
        let personalDownloads = Downloads(profileID: ProfileManager.defaultID, directory: directory, sandboxed: true)
        let workDownloads = Downloads(profileID: work.id, directory: directory, sandboxed: true)
        personalDownloads.add(.init(name: "personal.pdf", state: "failed", completed: Date(timeIntervalSince1970: 10)))
        workDownloads.add(.init(name: "work.png", state: "failed", completed: Date(timeIntervalSince1970: 20)))
        let library = DownloadLibrary(profiles: profiles) { id in
            Downloads(profileID: id, directory: directory, sandboxed: true)
        }
        XCTAssertEqual(library.items.map(\.name), ["work.png", "personal.pdf"])
        let item = try XCTUnwrap(library.items.first)
        let owner = try XCTUnwrap(library.owner(of: item))
        XCTAssertEqual(owner.profileID, work.id)
        owner.forget(item)
        XCTAssertEqual(library.items.map(\.name), ["personal.pdf"])
        XCTAssertTrue(Downloads(profileID: work.id, directory: directory, sandboxed: true).items.isEmpty)
        XCTAssertEqual(Downloads(profileID: ProfileManager.defaultID, directory: directory, sandboxed: true).items.map(\.name), ["personal.pdf"])
    }

    func testClearKeepsPausedTransfersAcrossProfilesAndLeavesFilesAlone() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("image.png")
        try Data([1]).write(to: file)
        let first = Downloads(directory: directory, sandboxed: true)
        let second = Downloads(profileID: UUID(), directory: directory, sandboxed: true)
        first.add(.init(name: "image.png", destination: file, state: "done"))
        second.add(.init(name: "paused.zip", state: "paused"))
        let library = DownloadLibrary(managers: [first, second])
        library.clear()
        XCTAssertEqual(library.items.map(\.name), ["paused.zip"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testProfileChangesAndTransferChangesInvalidateTheCombinedList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profiles = ProfileManager(directory: directory, sandboxed: true)
        var managers: [UUID: Downloads] = [:]
        let library = DownloadLibrary(profiles: profiles) { id in
            if let hit = managers[id] { return hit }
            let manager = Downloads(profileID: id, directory: directory, sandboxed: true)
            managers[id] = manager
            return manager
        }
        let work = profiles.create(name: "Work")
        let manager = try XCTUnwrap(managers[work.id])
        let item = manager.add(.init(name: "live.png", state: "running"))
        XCTAssertTrue(library.items.contains { $0 === item })
        var changes = 0
        let observation = library.objectWillChange.sink { changes += 1 }
        item.status = .done
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(LibraryHoverItem.recent(.media, downloads: library.items).count, 1)
        XCTAssertTrue(profiles.delete(work.id))
        XCTAssertTrue(library.items.isEmpty)
        observation.cancel()
    }

    func testPrivateLibraryExcludesRegularDownloadsAndNeverPersistsItsRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let regular = Downloads(directory: directory, sandboxed: true)
        let incognito = Downloads(profileID: Profile.incognito.id, directory: directory, sandboxed: true)
        regular.add(.init(name: "regular.png", state: "failed"))
        incognito.add(.init(name: "private.png", state: "failed"))
        let library = DownloadLibrary(managers: [incognito])
        XCTAssertEqual(library.items.map(\.name), ["private.png"])
        XCTAssertNil(library.owner(of: regular.items[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Downloads.listURL(for: Profile.incognito.id, in: directory).path))
    }

    func testNewTransfersSortAheadOfOlderFilesAndKeepTheirStartDateAfterReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Downloads(directory: directory, sandboxed: true)
        let second = Downloads(profileID: UUID(), directory: directory, sandboxed: true)
        first.add(.init(name: "old.pdf", state: "failed", completed: Date(timeIntervalSince1970: 10)))
        let live = second.add(.init(name: "new.zip", state: "running"))
        XCTAssertEqual(DownloadLibrary(managers: [first, second]).items.map(\.name), ["new.zip", "old.pdf"])
        let restored = Downloads(profileID: second.profileID, directory: directory, sandboxed: true)
        XCTAssertEqual(restored.items.first?.started, live.started)
        XCTAssertEqual(DownloadLibrary(managers: [first, restored]).items.map(\.name), ["new.zip", "old.pdf"])
    }
}
