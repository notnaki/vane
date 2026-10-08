import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class WebsiteDataTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }
    func testCookiesAndSiteDataIncludesFileSystemStorage() {
        XCTAssertTrue(BrowsingData.dataTypes(cookies: true, cache: false).contains(WKWebsiteDataTypeFileSystem))
    }

    func testSearchAndCategorySelectionCannotDeleteAnotherEntry() {
        let backend = WebsiteDataFixture()
        backend.entries = [
            .init(name: "example.com", types: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage]),
            .init(name: "other.example", types: [WKWebsiteDataTypeCookies])
        ]
        let model = WebsiteDataModel(profileID: UUID(), backend: backend)
        model.refresh()
        model.query = " EXAMPLE.COM "
        XCTAssertEqual(model.filteredEntries.map(\.name), ["example.com"])
        model.select("example.com")
        model.selectedTypes = [WKWebsiteDataTypeCookies]
        model.clearSelection()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.entries.first { $0.name == "example.com" }?.types, [WKWebsiteDataTypeLocalStorage])
        XCTAssertEqual(model.entries.first { $0.name == "other.example" }?.types, [WKWebsiteDataTypeCookies])
        XCTAssertFalse(model.isBusy)
    }

    func testRemovalIsNotSuccessUntilVerificationCompletes() {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        backend.deferRemove = true
        let model = WebsiteDataModel(profileID: UUID(), backend: backend)
        model.refresh()
        model.select("example.com")
        model.clearSelection()
        XCTAssertTrue(model.isBusy)
        XCTAssertNil(model.message)
        model.refresh() // cannot overlap a removal
        backend.completeRemoval()
        XCTAssertFalse(model.isBusy)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testFailedAndIneffectiveRemovalStayVisibleAndCanRetry() {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        let model = WebsiteDataModel(profileID: UUID(), backend: backend)
        model.refresh()
        model.select("example.com")
        backend.removalError = NSError(domain: "Fixture", code: 1)
        model.clearSelection()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.entries.count, 1)
        backend.removalError = nil
        backend.keepData = true
        model.clearSelection()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        backend.keepData = false
        model.clearSelection()
        XCTAssertNil(model.error)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testDeletedProfileAndForeignSelectionNeverReachRemoval() {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        var exists = true
        let model = WebsiteDataModel(profileID: UUID(), backend: backend, isValid: { exists })
        model.refresh()
        model.select("example.com")
        model.selectedTypes = [WKWebsiteDataTypeIndexedDBDatabases]
        model.clearSelection()
        XCTAssertEqual(backend.entries.count, 1)
        model.selectedTypes = [WKWebsiteDataTypeCookies]
        exists = false
        model.clearSelection()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(backend.entries.count, 1)
    }

    func testFetchAndVerificationFailuresNeverClaimSuccess() {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        let model = WebsiteDataModel(profileID: UUID(), backend: backend)
        backend.fetchError = NSError(domain: "Fixture", code: 2)
        model.refresh()
        XCTAssertNotNil(model.error)
        backend.fetchError = nil
        model.refresh()
        model.select("example.com")
        backend.deferRemove = true
        model.clearSelection()
        backend.fetchError = NSError(domain: "Fixture", code: 3)
        backend.completeRemoval()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        XCTAssertFalse(model.isBusy)
    }

    func testSlowRemovalRemainsPendingAndLateCompletionIsVerified() async throws {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        backend.deferRemove = true
        let model = WebsiteDataModel(profileID: UUID(), backend: backend, timeout: .milliseconds(20))
        model.refresh()
        model.select("example.com")
        model.clearSelection()
        try await compatibilityWait { model.error != nil }
        XCTAssertTrue(model.isBusy, "A timed-out removal may still be executing in WebKit")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        backend.completeRemoval()
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testSlowVerificationAllowsRefreshAndIgnoresItsLateSnapshot() async throws {
        let backend = WebsiteDataFixture()
        backend.entries = [.init(name: "example.com", types: [WKWebsiteDataTypeCookies])]
        let model = WebsiteDataModel(profileID: UUID(), backend: backend, timeout: .milliseconds(20))
        model.refresh()
        model.select("example.com")
        backend.deferFetch = true
        model.clearSelection()
        try await compatibilityWait { model.error != nil }
        XCTAssertFalse(model.isBusy, "Removal finished; only the verification read timed out")
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.message)
        backend.deferFetch = false
        model.refresh()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.error)
        backend.completeFetch([.init(name: "stale.invalid", types: [WKWebsiteDataTypeCookies])])
        XCTAssertTrue(model.entries.isEmpty, "The expired verification read cannot replace a fresh snapshot")
    }

    func testPublicUsageAndUnknownCategoriesAreHonest() {
        let entry = WebsiteDataEntry(name: "example.com", types: ["FutureType"])
        XCTAssertNil(entry.diskUsage)
        XCTAssertFalse(WebsiteDataCategory.title("FutureType").isEmpty)
    }
}

@MainActor private final class WebsiteDataFixture: WebsiteDataBackend {
    var entries: [WebsiteDataEntry] = []
    var fetchError: Error?
    var removalError: Error?
    var deferRemove = false
    var keepData = false
    var deferFetch = false
    private var pendingFetch: ((Result<[WebsiteDataEntry], Error>) -> Void)?
    func completeFetch(_ entries: [WebsiteDataEntry]) {
        let completion = pendingFetch; pendingFetch = nil; completion?(.success(entries))
    }
    private var pending: (() -> Void)?
    func fetch(_ completion: @escaping (Result<[WebsiteDataEntry], Error>) -> Void) {
        if deferFetch { pendingFetch = completion; return }
        if let fetchError { completion(.failure(fetchError)) }
        else { completion(.success(entries)) }
    }
    func remove(_ entry: WebsiteDataEntry, types: Set<String>, completion: @escaping (Result<Void, Error>) -> Void) {
        let work = {
            if let error = self.removalError { completion(.failure(error)); return }
            if !self.keepData {
                self.entries = self.entries.compactMap { row in
                    guard row.name == entry.name else { return row }
                    let left = row.types.subtracting(types)
                    return left.isEmpty ? nil : .init(name: row.name, types: left)
                }
            }
            completion(.success(()))
        }
        if deferRemove { pending = work } else { work() }
    }
    func completeRemoval() { let work = pending; pending = nil; work?() }
}
