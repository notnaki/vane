import XCTest
@testable import vane

final class UpdaterFailureTests: XCTestCase {
    func testTruncatedAndInvalidArchivesAreTransientAndLeaveDestinationUntouched() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-archive-failure-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("Vane.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("old-version")
        try Data("working".utf8).write(to: marker)
        for bytes in [Data(), Data([0x50, 0x4b, 0x03, 0x04]), Data("not an archive".utf8)] {
            let zip = root.appendingPathComponent("release.zip")
            try bytes.write(to: zip)
            let result = Updater.unpackAndSwap(zip: zip, target: target, tag: "1.0.0")
            XCTAssertFalse(result.ok)
            XCTAssertFalse(result.permanent, "Failed extraction should remain retryable")
            XCTAssertEqual(try Data(contentsOf: marker), Data("working".utf8))
            XCTAssertFalse(fm.fileExists(atPath: zip.path))
        }
    }

    func testMissingOrUntrustedBundleNeverReachesInstaller() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vane-payload-failure-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("destination/Vane.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("old-version")
        try Data("working".utf8).write(to: marker)
        for name in ["Other.app", "Vane.app"] {
            let source = root.appendingPathComponent("payload-\(name)")
            let bundle = source.appendingPathComponent(name)
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try Data("unsigned".utf8).write(to: bundle.appendingPathComponent("fixture"))
            let zip = root.appendingPathComponent("release.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", bundle.path, zip.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let result = Updater.unpackAndSwap(zip: zip, target: target, tag: "1.0.0")
            XCTAssertFalse(result.ok)
            XCTAssertTrue(result.permanent, "An absent or untrusted payload is refused")
            XCTAssertEqual(try Data(contentsOf: marker), Data("working".utf8))
            XCTAssertFalse(fm.fileExists(atPath: zip.path))
        }
    }
}
