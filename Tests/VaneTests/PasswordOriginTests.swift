import XCTest
import Security
@testable import vane

final class PasswordOriginTests: XCTestCase {
    func testDefaultHTTPSRetainsLegacyLoginIdentity() throws {
        let origin = try XCTUnwrap(PasswordOrigin(url: URL(string: "https://EXAMPLE.com:443/login")!))
        XCTAssertEqual(origin, PasswordOrigin(host: "example.com"))
        XCTAssertEqual(Passwords.Login(origin: origin, account: "ada").id,
                       Passwords.key(host: "example.com", account: "ada"))
    }

    func testSchemeAndPortRemainSeparate() throws {
        let origins = try ["https://example.com/", "https://example.com:8443/", "http://example.com/"]
            .map { try XCTUnwrap(PasswordOrigin(url: URL(string: $0)!)) }
        XCTAssertEqual(Set(origins).count, 3)
        XCTAssertEqual(Set(origins.map { Passwords.Login(origin: $0, account: "ada").id }).count, 3)
        XCTAssertEqual(origins[1].url.absoluteString, "https://example.com:8443")
        XCTAssertNil(PasswordOrigin(url: URL(string: "ftp://example.com")!))
    }

    func testLegacyKeychainPortZeroIsDefaultOnlyForItsProtocol() {
        let attributes: [String: Any] = [kSecAttrServer as String: "example.com",
                                       kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
                                       kSecAttrPort as String: 0]
        XCTAssertEqual(PasswordOrigin(attributes: attributes), PasswordOrigin(host: "example.com"))
        var otherPort = attributes
        otherPort[kSecAttrPort as String] = 8443
        XCTAssertNotEqual(PasswordOrigin(attributes: otherPort), PasswordOrigin(host: "example.com"))
    }
    @MainActor func testManualAddAndRenameRespectOrigin() throws {
        let origin = try XCTUnwrap(PasswordsPane.siteOrigin("https://example.com:8443/login"))
        XCTAssertEqual(origin.port, 8443)
        XCTAssertNil(PasswordsPane.siteOrigin("http://example.com"))
        XCTAssertNil(PasswordsPane.siteOrigin("https://user:secret@example.com"))
        XCTAssertNil(PasswordsPane.siteOrigin("not a site"))
        let other = Passwords.Login(origin: origin, account: "ada")
        XCTAssertNil(PasswordsPane.renameClash([other], host: "example.com", from: "bob", to: "ada"))
        XCTAssertNotNil(PasswordsPane.renameClash([other], host: "example.com", from: "bob", to: "ada", origin: origin))
    }

}
