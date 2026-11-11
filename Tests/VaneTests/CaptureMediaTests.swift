import XCTest
@testable import vane

@MainActor final class CaptureMediaTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vane-capture-media-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testSavedCaptureAppearsInExistingMediaAndSurvivesRelaunch() async throws {
        let root = try directory(), profile = UUID()
        let downloads = Downloads(profileID: profile, directory: root, sandboxed: true)
        let library = DownloadLibrary(managers: [downloads])
        let item = try await downloads.saveCapture(png, title: "Example / page", source: URL(string: "https://capture.test"))
        XCTAssertTrue(library.items.contains { $0 === item })
        let presentation = Feel05DownloadPresentation(library)
        XCTAssertTrue(presentation.media(query: "Example").contains { $0 === item })
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(item.url)), png)
        let restored = Downloads(profileID: profile, directory: root, sandboxed: true)
        XCTAssertEqual(restored.items.first?.id, item.id)
        XCTAssertEqual(restored.items.first?.status, .done)
        XCTAssertEqual(restored.items.first?.source?.host, "capture.test")
        let others = DownloadLibrary(managers: [Downloads(profileID: UUID(), directory: root, sandboxed: true)])
        XCTAssertTrue(others.items.isEmpty)
    }
    func testPrivateCapturesNeverEnterMediaOrPersistFiles() async throws {
        let root = try directory()
        let downloads = Downloads(profileID: Profile.incognito.id, directory: root, sandboxed: true)
        do { _ = try await downloads.saveCapture(png, title: "Private", source: nil); XCTFail("Private captures must stay temporary") }
        catch { }
        XCTAssertTrue(downloads.items.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    func testFailedIndexWriteDoesNotPublishCaptureOrLeavePixelsBehind() async throws {
        let root = try directory(), profile = UUID()
        let downloads = Downloads(profileID: profile, directory: root, sandboxed: true)
        try FileManager.default.createDirectory(at: Downloads.listURL(for: profile, in: root), withIntermediateDirectories: true)
        do { _ = try await downloads.saveCapture(png, title: "Should fail", source: nil); XCTFail("An unwritable index must fail the save") }
        catch { }
        XCTAssertTrue(downloads.items.isEmpty)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        XCTAssertFalse(files.contains { $0.pathExtension == "png" })
    }
}
