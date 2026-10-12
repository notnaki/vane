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
    func testCharacterOptionsExcludeUnselectedGroups() {
        for _ in 0..<20 {
            let password = PasswordGenerator.generate(options: .init(length: 30, lowercase: false, uppercase: false, digits: true, symbols: false))
            XCTAssertEqual(password.count, 30)
            XCTAssertTrue(password.allSatisfy(\.isNumber))
        }
    }

    func testNoCharacterGroupsHasUsableDefault() {
        let password = PasswordGenerator.generate(options: .init(length: 20, lowercase: false, uppercase: false, digits: false, symbols: false))
        XCTAssertEqual(password.count, 20)
        XCTAssertTrue(password.allSatisfy(\.isLowercase))
    }

}
