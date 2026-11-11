import XCTest
@testable import vane

@MainActor final class ICloudControllerTests: XCTestCase {
    private func fixture() throws -> (URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "vane-icloud-controller-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { try? FileManager.default.removeItem(at: directory); UserDefaults.standard.removePersistentDomain(forName: name) }
        return (directory, defaults)
    }
    func testMasterDefaultsOffAndDoesNotContactCloud() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        await controller.syncNow()
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertNil(controller.lastSuccess)
    }
    func testSyncSwitchesAndIdentityStayOutOfPortableBackups() {
        XCTAssertTrue(BackupLibrary.isLocalPreference("icloud.enabled"))
        XCTAssertTrue(BackupLibrary.isLocalPreference("icloud.deviceID"))
        XCTAssertTrue(BackupLibrary.isLocalPreference("icloud.category.passwords"))
    }
    func testExtensionStorageIsExplicitOptInAndCanBeSelected() throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        XCTAssertFalse(controller.enabledCategories.contains(.extensionSyncData))
        controller.setEnabled(true, for: .extensionSyncData)
        XCTAssertTrue(controller.enabledCategories.contains(.extensionSyncData))
        XCTAssertNil(controller.lastError)
        controller.setEnabled(false, for: .extensionSyncData)
        controller.selectAll()
        XCTAssertTrue(controller.enabledCategories.contains(.extensionSyncData))
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertEqual(transport.calls, 0)
    }
    func testRecoveryFailureDoesNotEnableOrUpload() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {
            throw ICloudFailure.storage("Recovery point failed")
        })
        await controller.setMasterEnabled(true)
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertEqual(transport.calls, 0)
        XCTAssertEqual(controller.lastError, "Recovery point failed")
    }
    func testPendingRemovalPreventsEnablingAndLibraryFetch() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud(); transport.pendingRemoval = true
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        await controller.setMasterEnabled(true)
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertTrue(controller.pendingRemoval)
        XCTAssertEqual(transport.calls, 0, "Pending cleanup must be checked locally before cloud fetch/upload")
    }
    func testResumingConfirmedRemovalKeepsLibrarySyncOff() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud(); transport.pendingRemoval = true
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        await controller.setMasterEnabled(true)
        await controller.resumeCloudRemoval()
        XCTAssertEqual(transport.resumes, 1)
        XCTAssertFalse(controller.pendingRemoval)
        XCTAssertFalse(controller.masterEnabled, "Cleanup completion is not permission to re-enable sync")
        XCTAssertEqual(transport.calls, 0)
    }
    func testConfirmedRemovalRejectsReenableBeforeReceiptIsWritten() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        transport.onRemove = {
            XCTAssertTrue(controller.busy)
            await controller.setMasterEnabled(true)
            await controller.mergeWithCurrentAccount()
            await controller.syncNow()
            XCTAssertFalse(controller.masterEnabled, "Confirmed removal must own sync admission before its first receipt exists")
        }
        await controller.removeCloudData([.bookmarks])
        XCTAssertFalse(controller.masterEnabled)
        XCTAssertFalse(controller.busy)
        XCTAssertTrue(transport.enabled.isEmpty, "Removal must not interleave an exchange that reuploads the library")
    }
    func testSecretsOnlyRemovalFinishesEarlierLibraryCleanup() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud(); transport.pendingRemoval = true
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        await controller.removeCloudData([.passwords])
        XCTAssertEqual(transport.resumes, 1)
        XCTAssertFalse(transport.pendingRemoval)
        XCTAssertFalse(controller.pendingRemoval)
        XCTAssertNil(controller.lastError)
    }
    func testSecretsOnlyRemovalKeepsFailedEarlierLibraryCleanupVisible() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud(); transport.pendingRemoval = true; transport.failResume = true
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [], recovery: {})
        await controller.removeCloudData([.passwords])
        XCTAssertEqual(transport.resumes, 1)
        XCTAssertTrue(controller.pendingRemoval)
        XCTAssertTrue(transport.pendingRemoval)
        XCTAssertNotNil(controller.lastError)
        XCTAssertFalse(controller.masterEnabled)
    }
    func testCategoryDisabledDuringFetchCannotApplyLateResponse() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let adapter = ControllerAdapter()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [adapter], recovery: {})
        transport.onExchange = { controller.setEnabled(false, for: .bookmarks) }
        await controller.setMasterEnabled(true)
        XCTAssertEqual(adapter.applications, 0)
        XCTAssertNil(controller.lastSuccess)
        XCTAssertFalse(controller.enabledCategories.contains(.bookmarks))
    }
    func testDisabledCategoriesNeverReachAdapterOrTransport() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let adapter = ControllerAdapter()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [adapter], recovery: {})
        controller.setEnabled(false, for: .bookmarks)
        await controller.setMasterEnabled(true)
        XCTAssertEqual(adapter.captures, 0)
        XCTAssertFalse(transport.enabled.contains(.bookmarks))
        XCTAssertFalse(transport.enabled.contains(.passwords))
        XCTAssertFalse(transport.enabled.contains(.aiKeys))
    }
    func testApplyFailureDoesNotAdvanceSuccessOrAcknowledgeOutgoing() async throws {
        let (directory, defaults) = try fixture()
        let transport = ControllerCloud()
        let adapter = ControllerAdapter()
        adapter.failApply = true
        let controller = ICloudController(directory: directory, defaults: defaults, transport: transport, adapters: [adapter], recovery: {})
        await controller.setMasterEnabled(true)
        XCTAssertNil(controller.lastSuccess)
        XCTAssertNotNil(controller.lastError)
        let journal = try ICloudJournal(directory: directory)
        let pending = await journal.pending(enabled: [.bookmarks])
        XCTAssertEqual(pending.count, 1)
    }
    func testRevocationCancelsInFlightAdapterWork() async throws {
        let (directory, defaults) = try fixture()
        let adapter = ControllerAdapter()
        let controller = ICloudController(directory: directory, defaults: defaults, transport: ControllerCloud(), adapters: [adapter], recovery: {})
        adapter.onApply = {
            controller.setEnabled(false, for: .bookmarks)
            try Task.checkCancellation()
        }
        await controller.setMasterEnabled(true)
        XCTAssertEqual(adapter.applications, 0, "Revoked asynchronous work must receive cancellation before local writes")
    }
}

@MainActor private final class ControllerCloud: ICloudTransport {
    var calls = 0
    var enabled: Set<ICloudCategory> = []
    var onExchange: (() -> Void)?
    var onRemove: (() async -> Void)?
    var pendingRemoval = false
    var resumes = 0
    var failResume = false
    func hasPendingRemovals() async throws -> Bool { pendingRemoval }
    func resumeRemovals() async throws {
        resumes += 1
        if failResume { throw ICloudFailure.storage("Earlier library removal is still pending") }
        pendingRemoval = false
    }
    func account() async throws -> String { calls += 1; return "test-account" }
    func exchange(pending: [ICloudRecord], enabled: Set<ICloudCategory>, state: Data?, epochs: [ICloudCategory: String],
                  persistState: @escaping @Sendable (Data) async throws -> Void) async throws -> ICloudExchange {
        calls += 1; self.enabled = enabled; onExchange?()
        return ICloudExchange(received: [], acknowledged: pending, state: Data("saved".utf8))
    }
    func remove(_ categories: Set<ICloudCategory>) async throws { calls += 1; await onRemove?() }
}

@MainActor private final class ControllerAdapter: ICloudAdapter {
    let categories: Set<ICloudCategory> = [.bookmarks]
    var captures = 0
    var applications = 0
    var failApply = false
    var onApply: (() async throws -> Void)?
    func capture(_ enabled: Set<ICloudCategory>) async throws -> [ICloudItem] {
        captures += 1
        return [ICloudItem(category: .bookmarks, id: "local", profileID: nil, parentID: nil, fields: ["title": Data("title".utf8)])]
    }
    func apply(_ items: [ICloudItem], deleted: [ICloudItem], enabled: Set<ICloudCategory>) async throws {
        try await onApply?()
        applications += 1
        if failApply { throw ICloudFailure.storage("Local apply failed") }
    }
}
