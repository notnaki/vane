import XCTest
@testable import vane

final class PasswordGeneratorTests: XCTestCase {
    func testGeneratedPasswordsHaveTheRequestedLengthAndEveryCharacterGroup() {
        for length in [16, 20, 24, 32] {
            for _ in 0..<20 {
                let password = PasswordGenerator.generate(length: length)
                XCTAssertEqual(password.count, length)
                XCTAssertTrue(password.contains { $0.isLowercase })
                XCTAssertTrue(password.contains { $0.isUppercase })
                XCTAssertTrue(password.contains { $0.isNumber })
                XCTAssertTrue(password.contains { "!@#$%&*-_=+?".contains($0) })
                XCTAssertFalse(password.contains { $0.isWhitespace })
            }
        }
    }

    func testGeneratorBoundsInvalidLengths() {
        XCTAssertEqual(PasswordGenerator.generate(length: -1).count, 12)
        XCTAssertEqual(PasswordGenerator.generate(length: Int.max).count, 64)
    }
}
