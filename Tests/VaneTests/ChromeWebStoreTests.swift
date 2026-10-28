import CryptoKit
import Foundation
import XCTest
@testable import vane

final class ChromeWebStoreTests: XCTestCase {
    private let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"

    func testOnlyStoreDetailURLsAndExactIDsAreAccepted() throws {
        XCTAssertEqual(try ChromeWebStore(input: "  \(id)\n").id, id)
        XCTAssertEqual(try ChromeWebStore(input: "https://chromewebstore.google.com/detail/dark-reader/\(id)?hl=en").id, id)
        XCTAssertEqual(try ChromeWebStore(input: "https://chromewebstore.google.com/detail/\(id)").id, id)
        for bad in ["https://evil.test/detail/\(id)", "http://chromewebstore.google.com/detail/\(id)",
                    "https://chromewebstore.google.com.evil.test/detail/\(id)",
                    "https://user@chromewebstore.google.com/detail/\(id)",
                    "https://chromewebstore.google.com:444/detail/\(id)",
                    "https://chromewebstore.google.com/category/\(id)", id + "a", String(repeating: "q", count: 32)] {
            XCTAssertThrowsError(try ChromeWebStore(input: bad), bad)
        }
        let source = try ChromeWebStore(input: id)
        let components = try XCTUnwrap(URLComponents(url: source.downloadURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "clients2.google.com")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "x" })?.value, "id=\(id)&installsource=ondemand&uc")
    }

    func testDownloadTrustRejectsNonGoogleAndCredentials() {
        for url in ["https://clients2.google.com/service/update2/crx", "https://clients2.googleusercontent.com/crx/test", "https://clients2.google.com:443/service/update2/crx"] {
            XCTAssertTrue(ChromeWebStore.trustedDownload(URL(string: url)!))
        }
        for url in ["http://clients2.google.com/x", "https://clients2.google.com.evil.test/x", "https://evil.googleusercontent.com/x",
                    "https://clients2.google.com:444/x", "https://user@clients2.google.com/x", "file:///tmp/package"] {
            XCTAssertFalse(ChromeWebStore.trustedDownload(URL(string: url)!))
        }
    }

    func testVersionOrderingUsesNumericChromeComponents() {
        XCTAssertTrue(ChromeWebStore.isNewer("1.10", than: "1.9.9"))
        XCTAssertFalse(ChromeWebStore.isNewer("1.0.0", than: "1"))
        XCTAssertFalse(ChromeWebStore.isNewer("0.9", than: "1"))
        XCTAssertFalse(ChromeWebStore.isNewer("nonsense", than: "1"))
        XCTAssertFalse(ChromeWebStore.isNewer("1.0.0.0.1", than: "1"))
    }

    func testBothIdentityAndPublisherProofMustVerify() throws {
        let fixture = try CRXFixture.make()
        XCTAssertEqual(try ChromeExtensionPackage.verifiedZIP(fixture.package, id: fixture.id, publisherKeyHash: fixture.publisherHash), Data("signed archive".utf8))
        XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(fixture.package, id: id, publisherKeyHash: fixture.publisherHash))
        XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(fixture.package, id: fixture.id))
        let noPublisher = try CRXFixture.make(includePublisher: false)
        XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(noPublisher.package, id: noPublisher.id, publisherKeyHash: noPublisher.publisherHash))
        var tampered = fixture.package
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(tampered, id: fixture.id, publisherKeyHash: fixture.publisherHash))
    }

    func testMalformedHeadersFailWithoutReadingBeyondBounds() throws {
        let fixture = try CRXFixture.make()
        for length in [0, 4, 8, 11, 12, 20, fixture.package.count - 1] {
            XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(Data(fixture.package.prefix(length)), id: fixture.id, publisherKeyHash: fixture.publisherHash))
        }
        var hugeHeader = Data("Cr24".utf8)
        hugeHeader.append(contentsOf: [3, 0, 0, 0, 255, 255, 255, 255])
        XCTAssertThrowsError(try ChromeExtensionPackage.verifiedZIP(hugeHeader, id: fixture.id))
    }

    func testRealStorePackageWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["VANE_STORE_PACKAGE_FIXTURE"] else {
            throw XCTSkip("Set VANE_STORE_PACKAGE_FIXTURE to verify a fresh Dark Reader CRX from Google.")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let zip = try ChromeExtensionPackage.verifiedZIP(bytes, id: id)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vane-crx-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive.zip"), destination = root.appendingPathComponent("unpacked")
        try zip.write(to: archive)
        try UpdateArchive.extract(zip: archive, to: destination)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["manifest_version"] as? Int, 3)
        XCTAssertEqual(manifest?["name"] as? String, "Dark Reader")
    }
}

enum CRXFixture {
    struct Value { let package: Data; let id: String; let publisherHash: Data }
    static func make(archive: Data = Data("signed archive".utf8), includePublisher: Bool = true) throws -> Value {
        let developer = P256.Signing.PrivateKey(), publisher = P256.Signing.PrivateKey()
        let developerDER = developer.publicKey.derRepresentation
        let idBytes = Data(SHA256.hash(data: developerDER).prefix(16))
        let id = idBytes.flatMap { [Character(UnicodeScalar(97 + Int($0 >> 4))!), Character(UnicodeScalar(97 + Int($0 & 15))!)] }
        let signed = field(1, idBytes)
        var message = Data("CRX3 SignedData\0".utf8)
        message.append(littleEndian(signed.count)); message.append(signed); message.append(archive)
        func proof(_ key: P256.Signing.PrivateKey) throws -> Data {
            field(3, field(1, key.publicKey.derRepresentation) + field(2, try key.signature(for: message).derRepresentation))
        }
        var header = try proof(developer)
        if includePublisher { header.append(try proof(publisher)) }
        header.append(field(10000, signed))
        return Value(package: Data("Cr24".utf8) + littleEndian(3) + littleEndian(header.count) + header + archive,
                     id: String(id), publisherHash: Data(SHA256.hash(data: publisher.publicKey.derRepresentation)))
    }
    private static func field(_ number: Int, _ value: Data) -> Data { varint(number << 3 | 2) + varint(value.count) + value }
    private static func varint(_ number: Int) -> Data {
        var number = number, result = Data()
        repeat { let byte = UInt8(number & 127); number >>= 7; result.append(byte | (number > 0 ? 128 : 0)) } while number > 0
        return result
    }
    private static func littleEndian(_ number: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }) }
}
