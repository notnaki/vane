import Darwin
import Foundation
import XCTest
@testable import vane

final class ExtensionWorkerResourceTests: XCTestCase {
    private func fixture(_ body: (ExtensionCodeStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-worker-resources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(ExtensionCodeStore(profileID: UUID(), directory: root), root)
    }

    func testSnapshotPreservesNestedResourceBytesAndSource() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("nested/code.js"))
            let resources = try store.resources(in: source)
            XCTAssertEqual(resources, ["nested/code.js": Data("original".utf8)])
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("nested/code.js")), Data("original".utf8))
        }
    }

    func testSnapshotRejectsInternalLinksAndSpecialFiles() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let outside = root.appendingPathComponent("outside")
            try Data("outside must not become a resource".utf8).write(to: outside)
            let link = source.appendingPathComponent("linked.js")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            XCTAssertThrowsError(try store.resources(in: source))
            try FileManager.default.removeItem(at: link)
            XCTAssertEqual(mkfifo(source.appendingPathComponent("pipe").path, 0o600), 0)
            XCTAssertThrowsError(try store.resources(in: source))
            XCTAssertEqual(try Data(contentsOf: outside), Data("outside must not become a resource".utf8))
        }
    }

    func testSnapshotRejectsOversizedFilesBeforeReadingAndExcessiveDepth() throws {
        try fixture { store, root in
            let source = root.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let large = source.appendingPathComponent("large.js")
            XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: Data()))
            let file = try FileHandle(forWritingTo: large)
            try file.truncate(atOffset: UInt64(ExtensionCodeStore.fileLimit + 1))
            try file.close()
            XCTAssertThrowsError(try store.resources(in: source))
            try FileManager.default.removeItem(at: large)
            var nested = source
            for _ in 0..<65 {
                nested.appendPathComponent("d")
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            }
            XCTAssertThrowsError(try store.resources(in: source))
        }
    }
}
