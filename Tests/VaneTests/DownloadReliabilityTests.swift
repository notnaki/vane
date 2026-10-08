import AppKit
import WebKit
import XCTest
@testable import vane

@MainActor final class DownloadReliabilityTests: XCTestCase {
    func testDamagedArchiveWithValidPrefixCannotResume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("partial.bin")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertNotNil(Downloads.resumeBlocker(destination: file,
            resumeData: Data("bplist00".utf8) + Data(repeating: 0, count: 64)))
    }

    func testRepeatedResumeDoesNotMutateCompletedOrRunningRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Downloads(directory: root, sandboxed: true)
        for state in ["running", "done"] {
            let row = manager.add(.init(name: "file.bin", state: state))
            let before = row.status
            XCTAssertFalse(manager.resume(row))
            XCTAssertEqual(row.status, before)
        }
    }

    func testCancelCannotDeleteCompletedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("complete.bin")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: file)
        let manager = Downloads(directory: root, sandboxed: true)
        let row = manager.add(.init(name: file.lastPathComponent, destination: file, state: "done"))
        manager.cancel(row)
        XCTAssertEqual(row.status, .done)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testReloadDoesNotTreatDirectoryAsCompletedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Downloads(directory: root, sandboxed: true)
        manager.add(.init(name: "folder", destination: root, state: "done"))
        let restored = Downloads(directory: root, sandboxed: true)
        XCTAssertNotEqual(restored.items.first?.status, .done)
    }

    func testMissingAndInvalidResumeBlobsExposeRetryAfterReload() throws {
        for blob in [Data(), Data("bplist00invalid".utf8)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("partial.bin")
            try Data([1, 2, 3]).write(to: file)
            var record = Downloads.Record(name: "partial.bin", destination: file,
                source: URL(string: "https://example.invalid/file"), total: 100, received: 3, state: "running", sourceMethod: "GET")
            record.resumeFile = "\(record.id).resume"
            let resume = Downloads.resumeDir(for: ProfileManager.defaultID, in: root)
            try FileManager.default.createDirectory(at: resume, withIntermediateDirectories: true)
            if !blob.isEmpty { try blob.write(to: resume.appendingPathComponent(record.resumeFile!)) }
            try JSONEncoder().encode([record]).write(to: Downloads.listURL(for: ProfileManager.defaultID, in: root))
            let manager = Downloads(directory: root, sandboxed: true)
            let row = try XCTUnwrap(manager.items.first)
            XCTAssertFalse(manager.canResume(row))
            XCTAssertTrue(manager.canRetry(row))
            XCTAssertEqual(row.status, .failed)
            XCTAssertFalse(row.subtitle.hasPrefix("Paused"))
        }
    }

    func testCancellingPausedRowPreservesReplacementFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("partial.bin")
        try Data([1, 2, 3]).write(to: file)
        let manager = Downloads(directory: root, sandboxed: true)
        let row = manager.add(.init(name: file.lastPathComponent, destination: file, received: 3, state: "paused"))
        let replacement = root.appendingPathComponent("replacement.bin")
        let keep = Data("replacement belongs to user".utf8)
        try keep.write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        manager.cancel(row)
        XCTAssertEqual(try Data(contentsOf: file), keep)
    }

    func testEditedCompletedFileRemainsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("finished.bin")
        try Data([1, 2, 3]).write(to: file)
        let manager = Downloads(directory: root, sandboxed: true)
        manager.add(.init(name: file.lastPathComponent, destination: file, total: 3, received: 3, state: "done"))
        try Data([1]).write(to: file)
        manager.refreshMissing()
        XCTAssertEqual(manager.items.first?.status, .done)
        XCTAssertEqual(Downloads(directory: root, sandboxed: true).items.first?.status, .done)
    }

    func testFreshRetryRejectsPostAndNonHTTPDownloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = Downloads(directory: root, sandboxed: true)
        let post = manager.add(.init(name: "report", source: URL(string: "https://example.invalid/report"),
            state: "failed", sourceMethod: "POST"))
        let blob = manager.add(.init(name: "export", source: URL(string: "blob:https://example.invalid/id"), state: "failed"))
        let legacy = manager.add(.init(name: "legacy", source: URL(string: "https://example.invalid/export"), state: "failed"))
        XCTAssertFalse(manager.canRetry(legacy))
        XCTAssertFalse(manager.canRetry(post))
        XCTAssertFalse(manager.retry(post))
        XCTAssertFalse(manager.canRetry(blob))
        XCTAssertFalse(manager.retry(blob))
    }

}
