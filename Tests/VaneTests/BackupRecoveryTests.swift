import XCTest
@testable import vane

@MainActor final class BackupRecoveryTests: XCTestCase {
    private func fixture() throws -> BackupFixture {
        let f = try BackupFixture(); _ = f.seed()
        addTeardownBlock { await MainActor.run { f.cleanup() } }
        return f
    }
    func testUnchangedContentDoesNotCreateAnotherAutomaticPoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        XCTAssertNotNil(try recovery.automaticPointIfChanged(f.library.capture(reason: .automatic)))
        XCTAssertNil(try recovery.automaticPointIfChanged(f.library.capture(reason: .automatic)))
        f.defaults.set("changed", forKey: "homepage")
        XCTAssertNotNil(try recovery.automaticPointIfChanged(f.library.capture(reason: .automatic)))
        XCTAssertEqual(try recovery.points().count, 2)
    }
    func testRetentionKeepsTenCompletedPointsIncludingMandatoryBeforeRestore() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        var ids: [UUID] = []
        for index in 0..<12 {
            var archive = try f.library.capture(reason: index == 11 ? .beforeRestore : .automatic)
            archive.created = Date(timeIntervalSince1970: Double(index))
            ids.append(archive.id)
            _ = try recovery.save(archive)
        }
        let points = try recovery.points()
        XCTAssertEqual(points.map(\.id), Array(ids.suffix(10).reversed()))
        XCTAssertEqual(points.first?.reason, .beforeRestore)
    }
    func testFailedWriteKeepsLastUsablePoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        let first = try recovery.save(f.library.capture(reason: .automatic))
        let failing = BackupRecovery(library: f.library, writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try failing.save(f.library.capture(reason: .automatic)))
        XCTAssertEqual(try recovery.points().map(\.id), [first.id])
    }
    func testSemanticFingerprintIgnoresDatesFileOrderAndSQLiteSnapshotHeaders() throws {
        let f = try fixture(), id = f.seed().active.id, store = f.database(id)
        store.record(URL(string: "https://example.com")!, title: "Hello")
        var a = try f.library.capture(reason: .automatic)
        let hash = try BackupRecovery.contentDigest(a)
        a.created = .distantPast; a.id = UUID(); a.reason = .beforeRestore; a.files.reverse()
        XCTAssertEqual(try BackupRecovery.contentDigest(a), hash)
        XCTAssertEqual(try BackupRecovery.contentDigest(f.library.capture(reason: .automatic)), hash)
        store.record(URL(string: "https://second.example")!, title: "New")
        XCTAssertNotEqual(try BackupRecovery.contentDigest(f.library.capture(reason: .automatic)), hash)
    }
    func testCorruptPointIsListedAsUnavailableWithoutHidingHealthyPoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        let good = try recovery.save(f.library.capture(reason: .automatic))
        let corrupt = f.root.appendingPathComponent("Recovery/Points/\(UUID().uuidString).vanebackup")
        try Data("broken".utf8).write(to: corrupt)
        let points = try recovery.points()
        XCTAssertEqual(points.count, 2)
        XCTAssertNotNil(points.first { $0.id == good.id && $0.diagnostic == nil })
        XCTAssertNotNil(points.first { $0.id.uuidString == corrupt.deletingPathExtension().lastPathComponent }?.diagnostic)
    }
    func testDamagedPreRestorePointDoesNotPruneOnlyHealthyPoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        let good = try recovery.save(f.library.capture(reason: .automatic))
        try Data("damaged".utf8).write(to: f.root.appendingPathComponent("profiles.json"))
        for _ in 0..<11 { _ = try recovery.save(f.library.capture(reason: .beforeRestore, allowDamaged: true)) }
        let points = try recovery.points()
        XCTAssertEqual(points.count, 10)
        XCTAssertTrue(points.contains { $0.id == good.id })
        XCTAssertNotNil(points.first { $0.diagnostic != nil })
    }
    func testIsolationAndHourlyBoundaries() throws {
        let a = try fixture(), b = try fixture()
        _ = try BackupRecovery(library: a.library).save(a.library.capture(reason: .automatic))
        XCTAssertTrue(try BackupRecovery(library: b.library).points().isEmpty)
        let now = Date.now
        XCTAssertTrue(BackupSchedule.isDue(lastAttempt: nil, now: now))
        XCTAssertFalse(BackupSchedule.isDue(lastAttempt: now, now: now.addingTimeInterval(3599)))
        XCTAssertTrue(BackupSchedule.isDue(lastAttempt: now, now: now.addingTimeInterval(3600)))
    }
    func testPruneFailureReportsErrorAndRetainsUsableNewPoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        for _ in 0..<10 { _ = try recovery.save(f.library.capture(reason: .automatic)) }
        let failing = BackupRecovery(library: f.library, remover: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try failing.save(f.library.capture(reason: .automatic)))
        XCTAssertEqual(try recovery.points().count, 11)
    }
    func testTiedDatesAlwaysKeepTheNewlyCompletedPreRestorePoint() throws {
        let f = try fixture(), recovery = BackupRecovery(library: f.library)
        let date = Date.now
        for index in 1...10 {
            var archive = try f.library.capture(reason: .automatic)
            archive.created = date
            archive.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            _ = try recovery.save(archive)
        }
        var newest = try f.library.capture(reason: .beforeRestore)
        newest.created = date
        newest.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        XCTAssertNoThrow(try recovery.save(newest))
        XCTAssertTrue(try recovery.points().contains { $0.id == newest.id })
        XCTAssertEqual(try recovery.points().count, 10)
    }
}
