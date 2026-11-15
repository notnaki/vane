import Foundation
import XCTest
@testable import vane

@MainActor final class DownloadSecurityTests: XCTestCase {
    override func setUp() async throws { TestEnvironment.prepare() }

    func testTidyTreatsHashAndQuestionMarkAsLiteralFilenameCharacters() {
        for (name, suffix) in [("download.terminal#x.txt", "txt"), ("download.terminal?x.txt", "txt"),
                               ("download.php?id=1", "php?id=1")] {
            XCTAssertEqual(TidyDownloads.parts(of: name).suffix, suffix)
            if let renamed = TidyDownloads.clean(suggested: name, pageTitle: "Invoice", sourceURL: nil) {
                XCTAssertEqual((renamed as NSString).pathExtension, suffix)
            }
        }
    }

    func testTidyApplyRefusesAnyExtensionChangeOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = Downloads(directory: root, sandboxed: true)
        for (name, replacement) in [("download.terminal#x.txt", "Invoice.terminal"),
                                    ("download.txt", "Invoice.command"),
                                    ("download", "Invoice.txt"), ("download.PDF", "Invoice.pdf"),
                                    ("download.pdf\u{202E}", "Invoice.pdf\u{202E}")] {
            let original = root.appendingPathComponent(name)
            try Data("keep".utf8).write(to: original)
            let row = downloads.add(.init(name: name, destination: original, state: "done"))
            XCTAssertFalse(TidyDownloads.apply(replacement, to: row, in: downloads))
            XCTAssertEqual(row.url, original)
            XCTAssertEqual(try? Data(contentsOf: original), Data("keep".utf8))
            XCTAssertFalse(TidyDownloads.canUndo(row))
        }
    }

    func testTidyCanRenameAndUndoWhenTheExtensionIsUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("download.txt")
        try Data("keep".utf8).write(to: file)
        let downloads = Downloads(directory: root, sandboxed: true)
        let row = downloads.add(.init(name: "download.txt", destination: file, state: "done"))
        XCTAssertTrue(TidyDownloads.apply("Invoice.txt", to: row, in: downloads))
        XCTAssertEqual(row.name, "Invoice.txt")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(row.url)), Data("keep".utf8))
        XCTAssertTrue(TidyDownloads.undo(row, in: downloads))
        XCTAssertEqual(row.url, file)
    }

    func testBidiControlsAreStrippedFromSuggestedNames() {
        let controls = "\u{061C}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        let raw = "Invoice\(controls)txt.exe"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(Downloads.uniqueDestination(in: dir, suggested: raw).lastPathComponent, "Invoicetxt.exe")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: raw, server: "file.bin", disposition: nil), "Invoicetxt.exe")
        XCTAssertEqual(Downloads.saveAsFilename(anchor: "ignored", server: raw,
            disposition: "attachment; filename=ignored"), "Invoicetxt.exe")
        XCTAssertEqual(Downloads.uniqueDestination(in: dir, suggested: controls).lastPathComponent, "download")
        XCTAssertEqual(Downloads.uniqueDestination(in: dir, suggested: "فاتورة.txt").lastPathComponent, "فاتورة.txt")
    }

    func testRestoredBidiNameIsSafeToDisplayWithoutChangingFileIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = "Invoice\u{202E}txt.exe"
        let file = root.appendingPathComponent(raw)
        try Data("keep".utf8).write(to: file)
        let downloads = Downloads(directory: root, sandboxed: true)
        downloads.add(.init(name: raw, destination: file, state: "done"))
        downloads.save()
        let restored = Downloads(directory: root, sandboxed: true)
        XCTAssertEqual(restored.items.first?.name, "Invoicetxt.exe")
        XCTAssertEqual(restored.items.first?.url, file)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testETAClampsFiniteValuesBeforeIntegerConversion() {
        for seconds in [Double(Int.max).nextDown, Double(Int.max), 1.8e19, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(Downloads.etaText(seconds: seconds), "More than 999 hours left")
        }
        XCTAssertEqual(Downloads.etaText(seconds: 999 * 3600), "999 hours left")
        XCTAssertEqual(Downloads.etaText(seconds: .nan), "")
        XCTAssertEqual(Downloads.etaText(seconds: .infinity), "")
        XCTAssertEqual(Downloads.etaText(seconds: -1), "")
    }

    func testDownloadStartAndRetryRequestsUseHTTPSOnlyPolicy() throws {
        let suite = "vane-download-request-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults
        HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        let profile = UUID(), other = UUID()
        let source = URL(string: "http://download.example:80/file?token=fixture#part")!
        HTTPSOnly.enabled = true
        XCTAssertEqual(HTTPSOnly.downloadRequest(source, profileID: profile).url?.absoluteString,
                       "https://download.example/file?token=fixture#part")
        HTTPSOnly.allow(host: "download.example", profileID: other)
        XCTAssertEqual(HTTPSOnly.downloadRequest(source, profileID: profile).url?.scheme, "https")
        HTTPSOnly.allow(host: "download.example", profileID: profile)
        XCTAssertEqual(HTTPSOnly.downloadRequest(source, profileID: profile).url, source)
        let local = URL(string: "http://127.0.0.1/file")!
        XCTAssertEqual(HTTPSOnly.downloadRequest(local, profileID: profile).url, local)
        let secure = URL(string: "https://other.example/file")!
        XCTAssertEqual(HTTPSOnly.downloadRequest(secure, profileID: profile).url, secure)
        HTTPSOnly.enabled = false
        let plain = URL(string: "http://other.example/file")!
        XCTAssertEqual(HTTPSOnly.downloadRequest(plain, profileID: profile).url, plain)
    }

    func testDownloadRedirectRejectsUnexceptedHTTPWithHTTPSOnlyEnabled() throws {
        let suite = "vane-download-redirect-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults
        HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let plain = URL(string: "http://download.example/file")!
        HTTPSOnly.enabled = true
        XCTAssertEqual(Downloads.redirectPolicy(for: plain, profileID: profile), .cancel)
        XCTAssertEqual(Downloads.redirectPolicy(for: URL(string: "https://download.example/file")!, profileID: profile), .allow)
        XCTAssertEqual(Downloads.redirectPolicy(for: URL(string: "http://127.0.0.1/file")!, profileID: profile), .allow)
        HTTPSOnly.allow(host: "download.example", profileID: UUID())
        XCTAssertEqual(Downloads.redirectPolicy(for: plain, profileID: profile), .cancel)
        HTTPSOnly.allow(host: "download.example", profileID: profile)
        XCTAssertEqual(Downloads.redirectPolicy(for: plain, profileID: profile), .allow)
        HTTPSOnly.enabled = false
        XCTAssertEqual(Downloads.redirectPolicy(for: URL(string: "http://other.example/file")!, profileID: profile), .allow)
    }

    func testResumeAndResponseDownloadsAreBlockedForUnexceptedHTTP() throws {
        let suite = "vane-download-block-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults
        HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let plain = URL(string: "http://download.example/file")!
        HTTPSOnly.enabled = true
        XCTAssertTrue(HTTPSOnly.blocksDownload(plain, profileID: profile))
        XCTAssertFalse(HTTPSOnly.blocksDownload(URL(string: "https://download.example/file")!, profileID: profile))
        XCTAssertFalse(HTTPSOnly.blocksDownload(URL(string: "http://127.0.0.1/file")!, profileID: profile))
        // Revoking an exception after a download started blocks its resume.
        HTTPSOnly.allow(host: "download.example", profileID: profile)
        XCTAssertFalse(HTTPSOnly.blocksDownload(plain, profileID: profile))
        HTTPSOnly.forget(host: "download.example", profileID: profile)
        XCTAssertTrue(HTTPSOnly.blocksDownload(plain, profileID: profile))
        // Private browsing keeps its own exceptions.
        HTTPSOnly.allow(host: "download.example", profileID: profile)
        XCTAssertTrue(HTTPSOnly.blocksDownload(plain, profileID: Profile.incognito.id))
        HTTPSOnly.enabled = false
        XCTAssertFalse(HTTPSOnly.blocksDownload(plain, profileID: profile))
    }

    func testResumeChecksTheRedirectedTransferAndKeepsItOnDisk() throws {
        let suite = "vane-download-transfer-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let previous = HTTPSOnly.defaults
        HTTPSOnly.defaults = defaults
        defer { HTTPSOnly.defaults = previous; defaults.removePersistentDomain(forName: suite) }
        let profile = UUID()
        let source = URL(string: "https://a.example/file")!
        let transfer = URL(string: "http://b.example/file")!
        HTTPSOnly.enabled = true
        HTTPSOnly.allow(host: "b.example", profileID: profile)
        XCTAssertFalse(Downloads.resumeBlocked(source: source, transfer: transfer, profileID: profile))
        HTTPSOnly.forget(host: "b.example", profileID: profile)
        XCTAssertTrue(Downloads.resumeBlocked(source: source, transfer: transfer, profileID: profile))
        XCTAssertFalse(Downloads.resumeBlocked(source: source, transfer: nil, profileID: profile))
        var record = Downloads.Record(name: "f", state: "paused")
        record.transfer = transfer
        let decoded = try JSONDecoder().decode(Downloads.Record.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.transfer, transfer)
    }
}
