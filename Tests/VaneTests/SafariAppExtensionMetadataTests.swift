import Foundation
import Security
import XCTest
@testable import vane

final class SafariAppExtensionMetadataTests: XCTestCase {
    /// A saved app source must never be treated as a loose-folder record or accepted
    /// with unvalidated identity components after corruption or format migration.
    func testMalformedSavedSafariIdentityFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("safari-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ExtensionCodeStore(profileID: UUID(), directory: directory)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let record: [String: Any] = ["identity": UUID().uuidString, "revision": UUID().uuidString,
            "sourcePath": "/Applications/Fixture.app", "name": "Fixture", "version": "1", "summary": "",
            "required": ["permissions": [], "sites": []], "optional": ["permissions": [], "sites": []],
            "compatibility": [],
            "safari": ["appBundleID": "test.vane.fixture", "extensionBundleID": "../impersonated",
                "teamID": "FAKE", "appPath": "/Applications/Fixture.app", "signatureHash": "invalid"]]
        try JSONSerialization.data(withJSONObject: ["/safari-extension/FAKE/../impersonated": record])
            .write(to: store.root.appendingPathComponent("installations.json"))
        XCTAssertThrowsError(try store.records(), "Malformed signed-source metadata must not silently become a folder install")
    }
}

/// Signature verification exercises Security.framework without AppKit/WebKit objects.
final class SafariAppSignatureTests: XCTestCase {
    @MainActor func testAppleSignedIdentityIgnoresClaimedTeamAndRejectsModifiedResources() throws {
        guard let identity = ProcessInfo.processInfo.environment["VANE_TEST_SIGNING_IDENTITY"],
              let team = ProcessInfo.processInfo.environment["VANE_TEST_SIGNING_TEAM"] else {
            throw XCTSkip("Set signing fixture environment to validate an Apple-issued signature")
        }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("vane-signature-\(UUID()).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": "test.vane.signed-fixture", "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL", "TeamIdentifier": "IMPERSONATE"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let resource = contents.appendingPathComponent("Resources/probe.txt")
        try Data("signed".utf8).write(to: resource)
        try FileManager.default.createSymbolicLink(atPath: contents.appendingPathComponent("Resources/internal-link").path, withDestinationPath: "probe.txt")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", identity, "--timestamp=none", bundle.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let signature = try SafariExtensionSource.verify(bundle)
        XCTAssertEqual(signature.identifier, "test.vane.signed-fixture")
        XCTAssertEqual(signature.team, team)
        XCTAssertNotEqual(signature.team, "IMPERSONATE")
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("vane-signed-store-\(UUID())")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let store = ExtensionCodeStore(profileID: UUID(), directory: storage)
        let stage = try store.stage(bundle, appExtension: true)
        let snapshot = stage.url.appendingPathComponent("extension.appex")
        let copiedSignature = try SafariExtensionSource.verify(snapshot)
        XCTAssertEqual(copiedSignature.hash, signature.hash, "Staging must preserve the actual signed code and resource seal")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: snapshot.appendingPathComponent("Contents/MacOS/fixture").path))
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("Contents/Resources/internal-link"), encoding: .utf8), "signed")
        try Data("tampered".utf8).write(to: resource)
        XCTAssertThrowsError(try SafariExtensionSource.verify(bundle))
        XCTAssertNoThrow(try SafariExtensionSource.verify(snapshot), "Source edits cannot change the accepted snapshot")
    }
}

// Read-only opt-in coverage for Apple's Mac App Store re-signing certificate.
// The path must point to an already-installed, unmodified app; this test never
// starts, copies, signs, or modifies that app.
extension SafariAppSignatureTests {
    @MainActor func testMacAppStoreIdentityUsesAppleSignatureTeam() throws {
        guard let path = ProcessInfo.processInfo.environment["VANE_TEST_MAC_APP_STORE_BUNDLE"],
              let team = ProcessInfo.processInfo.environment["VANE_TEST_MAC_APP_STORE_TEAM"] else {
            throw XCTSkip("Set an installed Mac App Store bundle and expected team for read-only verification")
        }
        let url = URL(fileURLWithPath: path)
        var code: SecStaticCode?
        var requirement: SecRequirement?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        XCTAssertEqual(SecRequirementCreateWithString("anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists" as CFString, [], &requirement), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(try XCTUnwrap(code), [], try XCTUnwrap(requirement)), errSecSuccess, "The read-only fixture must actually be signed by Apple's Mac App Store certificate")
        XCTAssertEqual(try SafariExtensionSource.verify(url).team, team)
    }
}
