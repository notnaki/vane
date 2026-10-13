import XCTest
import Combine
@testable import vane

@MainActor final class Feel06ManagementTests: XCTestCase {
    override func setUp() async throws { await MainActor.run { TestEnvironment.prepare() } }

    func testIdenticalProgressCallbacksDoNotInvalidateTheLibraryAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(directory: directory, sandboxed: true)
        let item = downloads.add(.init(name: "fixture.zip", state: "running"))
        let library = DownloadLibrary(managers: [downloads])
        var changes = 0
        let subscription = library.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        let progress = Progress(totalUnitCount: 1000)
        progress.completedUnitCount = 100
        item.updateProgress(progress)
        XCTAssertEqual(item.received, 100)
        XCTAssertEqual(item.total, 1000)
        XCTAssertEqual(item.fraction, 0.1)
        let first = changes
        XCTAssertGreaterThan(first, 0)
        item.updateProgress(progress)
        XCTAssertEqual(changes, first, "The two WebKit observers can deliver the same sample")
        progress.completedUnitCount = 200
        item.updateProgress(progress)
        XCTAssertEqual(item.received, 200)
        XCTAssertGreaterThan(changes, first)
    }

    func testUnknownLengthProgressStillCapturesWrittenBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(directory: directory, sandboxed: true)
        let item = downloads.add(.init(name: "stream.bin", state: "running"))
        let progress = Progress(totalUnitCount: -1)
        progress.completedUnitCount = 128
        item.updateProgress(progress)
        XCTAssertEqual(item.received, 128)
        XCTAssertEqual(item.total, 0)
        XCTAssertFalse(item.spoken.contains("percent"), "Unknown-length transfers must not claim a percentage")
        progress.completedUnitCount = 256
        item.updateProgress(progress)
        XCTAssertEqual(item.received, 256)
    }
}

@MainActor final class Feel06PresentationTests: XCTestCase {
    func testReusesPresentationForUnchangedInputsAndRebuildsAfterEdits() {
        let cache = Feel06PresentationCache<[String], [String]>()
        var builds = 0
        func visible(_ names: [String]) -> [String] {
            cache.value(for: names) { builds += 1; return names.sorted() }
        }
        XCTAssertEqual(visible(["Zulu", "Alpha"]), ["Alpha", "Zulu"])
        for _ in 0..<100 { XCTAssertEqual(visible(["Zulu", "Alpha"]), ["Alpha", "Zulu"]) }
        XCTAssertEqual(builds, 1, "Unrelated redraws must not regroup the list")
        XCTAssertEqual(visible(["Beta", "Alpha"]), ["Alpha", "Beta"])
        XCTAssertEqual(builds, 2, "A metadata edit must invalidate presentation")
        XCTAssertEqual(visible([]), [])
        XCTAssertEqual(builds, 3, "Removing the last entry must clear cached rows")
    }
}

@MainActor final class Feel06PasswordPresentationTests: XCTestCase {
    func testSearchEditsRemovalAndRecencyInvalidateMetadataPresentation() {
        let presentation = Feel06PasswordPresentation()
        let alice = Passwords.Login(host: "mail.example", account: "alice")
        let bob = Passwords.Login(host: "bank.example", account: "bob")
        let logins = [alice, bob]
        func hosts(_ query: String = "", sort: PasswordSort = .website,
                   used: [String: Date] = [:]) -> [String] {
            presentation.groups(logins, query: query, sort: sort, used: used).map(\.host)
        }
        XCTAssertEqual(hosts(), ["bank.example", "mail.example"])
        XCTAssertEqual(hosts("ALICE"), ["mail.example"])
        XCTAssertEqual(hosts("bob"), ["bank.example"])
        XCTAssertEqual(hosts(sort: .recent, used: [alice.id: .now]), ["mail.example", "bank.example"])
        XCTAssertEqual(hosts(sort: .recent, used: [bob.id: .now]), ["bank.example", "mail.example"])
        let renamed = Passwords.Login(host: alice.host, account: "carol")
        XCTAssertEqual(presentation.groups([renamed], query: "carol", sort: .website, used: [:]).first?.logins, [renamed])
        XCTAssertTrue(presentation.groups([], query: "", sort: .website, used: [:]).isEmpty)
    }
}

@MainActor final class Feel06PasswordMetadataTests: XCTestCase {
    func testSlowSupersededProfileReadCannotReplaceTheCurrentProfile() async throws {
        let oldProfile = UUID(), currentProfile = UUID()
        let started = expectation(description: "Old metadata read started")
        let finished = expectation(description: "Old metadata read finished")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let loader = Feel06PasswordMetadata { profile in
            if profile == oldProfile {
                started.fulfill()
                gate.wait()
                finished.fulfill()
                return [.init(host: "old.example", account: "old")]
            }
            return [.init(host: "current.example", account: "current")]
        }
        loader.load(profileID: oldProfile)
        XCTAssertTrue(loader.busy, "Input is acknowledged before the Keychain call starts")
        await fulfillment(of: [started], timeout: 5)
        loader.load(profileID: currentProfile)
        try await compatibilityWait { !loader.busy }
        XCTAssertEqual(loader.logins.map(\.host), ["current.example"])
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        await Task.yield()
        XCTAssertEqual(loader.logins.map(\.host), ["current.example"])
        XCTAssertNil(loader.error)
    }

    func testFailureCanBeRetriedAndClosingDiscardsPendingMetadata() async throws {
        let profile = UUID()
        let loader = Feel06PasswordMetadata { _ in throw NSError(domain: "Feel06", code: 1) }
        loader.load(profileID: profile)
        try await compatibilityWait { !loader.busy }
        XCTAssertNotNil(loader.error)
        loader.load(profileID: profile)
        XCTAssertTrue(loader.busy)
        XCTAssertNil(loader.error)
        loader.cancel()
        XCTAssertFalse(loader.busy)
        await Task.yield()
        XCTAssertTrue(loader.logins.isEmpty)
        XCTAssertNil(loader.error, "A cancelled read cannot publish a late error")
    }
}
