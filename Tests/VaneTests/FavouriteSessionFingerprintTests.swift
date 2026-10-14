import XCTest
@testable import vane

final class FavouriteSessionFingerprintTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, domain: String = ".google.com", expires: Date = Date(timeIntervalSince1970: 4_000_000_000)) -> HTTPCookie {
        HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: value, .secure: "TRUE", .expires: expires])!
    }
    func testGoogleRotationAndExpiryRefreshKeepSessionButReplacementAndDeletionRetireIt() {
        let original = FavouriteSessionFingerprint([cookie("SID", "fixture-session"), cookie("__Secure-3PSIDTS", "rotation-one")])
        let rotated = FavouriteSessionFingerprint([cookie("SID", "fixture-session", expires: Date(timeIntervalSince1970: 4_100_000_000)), cookie("__Secure-3PSIDTS", "rotation-two")])
        XCTAssertEqual(original, rotated)
        XCTAssertNotEqual(original, FavouriteSessionFingerprint([cookie("SID", "replacement-session")]))
        XCTAssertNotEqual(original, FavouriteSessionFingerprint([]))
    }
    func testLookalikeHostsCannotSupplySessionProof() {
        XCTAssertEqual(FavouriteSessionFingerprint([cookie("SID", "fixture", domain: ".google.com.example.test")]), FavouriteSessionFingerprint([]))
        XCTAssertEqual(FavouriteSessionFingerprint([cookie("user_session", "fixture", domain: ".github.com.example.test")]), FavouriteSessionFingerprint([]))
    }
}
