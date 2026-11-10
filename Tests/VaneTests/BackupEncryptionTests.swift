import XCTest
@testable import vane

final class BackupEncryptionTests: XCTestCase {
    func testIndependentPythonAESGCMAndPBKDF2ReferenceCanBeRead() throws {
        // Python plistlib + hashlib.pbkdf2_hmac('sha256', ..., 600000, 32)
        // + cryptography AESGCM; salt 00...0f, nonce 10...1b, header as AAD.
        let encoded = "VkFORUVOQwEAAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobQEF3J+lW1YjJpjc6d7LsGEPvQZ/T0eaOGlvpMpR36jABCRQ5ENHqTD6Sg51/1ytrclKUs1ilXGagjiHeCsvwcW6KzpeZlhBk+yYBVqSyr5nSlAFujyDT6kAiUAsy8hzqSxuBwTSAZNdeaoP1+UwyxWWFgUvuZf6q9/QKUc+ft+TU7FSDz2cChKYwf5zpM+EI3fX+rMbxVboEkA6+HOZp9KBR7Pa471m3KzsofLeAsK0U9ymxohJGDZiS+wOZApjE8A9qvOl/zp4TTbPc35N+Mgwdb0vL3gy3auxVYiH8U+KSM1UwFgy0zxCpF0/4BCInq9ivptodoSPRWCYC0sdRBs2W90WrxFeUjE/TdvCJcfXRIwrIkmDJZG5cDWf5tAljXI1jJDICQ1rN5dejdK2n9NY3iP8i193mo9OYe7zMbK1rHQL3k01mme+fJxIghtumyKmMtjFEMsRwtF0hmFFlopBR20aZWH+kUrHj8nQtGKaCNO7EefJ+9IovLN/I83I3T4Gp6PaKQ9QolHt++D/E07dHhEVXuhqswZysKFNjb9aA8NTOPRbwFZyAd+tLmuRjAesBQaQcn8Y51dBdmoA343xXZU6a0jisOyWnrO4z9U6BkMq+c8+5/1jbS7Jyxh1Mee57ymhU8sciT0qKAEnA1qguhX/0CjR+Km9fRY3ZNGWVRFbvKEipulF7UmImn3irhw=="
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        let restored = try BackupCodec.decode(data, password: "reference password 🔑")
        XCTAssertEqual(restored.id.uuidString, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(restored.preferences, Data("independent reference preferences".utf8))
        XCTAssertEqual(restored.files.first?.data, Data("independent reference profile".utf8))
    }

    private func archive() -> BackupArchive {
        BackupArchive(preferences: Data("sensitive browsing preferences".utf8),
                      files: [.init(name: "profiles.json", data: Data("private profile contents".utf8))])
    }

    func testPasswordProtectsAllArchiveContentsAndRequiresUnlock() throws {
        let original = archive()
        let data = try BackupCodec.encode(original, password: "a long backup password 🔑")
        XCTAssertNil(data.range(of: original.preferences))
        XCTAssertNil(data.range(of: original.files[0].data))
        XCTAssertThrowsError(try BackupCodec.decode(data))
        XCTAssertThrowsError(try BackupCodec.decode(data, password: "wrong password"))
        let restored = try BackupCodec.decode(data, password: "a long backup password 🔑")
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.preferences, original.preferences)
        XCTAssertEqual(restored.files, original.files)
    }

    func testRepeatedEncryptionUsesFreshSaltAndNonce() throws {
        let original = archive()
        let first = try BackupCodec.encode(original, password: "backup password")
        let second = try BackupCodec.encode(original, password: "backup password")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try BackupCodec.decode(second, password: "backup password").id, original.id)
    }

    func testEmptyPasswordCannotSilentlyProducePlaintext() {
        XCTAssertThrowsError(try BackupCodec.encode(archive(), password: ""))
    }

    func testUnencryptedLegacyBackupsRemainReadable() throws {
        let original = archive()
        let data = try BackupCodec.encode(original)
        XCTAssertEqual(try BackupCodec.decode(data).id, original.id)
    }

    func testTamperedOrTruncatedEncryptedFilesCannotBePreviewed() throws {
        let data = try BackupCodec.encode(archive(), password: "backup password")
        // Header, salt, nonce, ciphertext, and authentication tag all affect admission.
        for index in [0, 10, 25, data.count / 2, data.count - 1] {
            var changed = data
            changed[index] ^= 1
            XCTAssertThrowsError(try BackupCodec.decode(changed, password: "backup password"), "Byte \(index)")
        }
        for length in [0, 7, 8, 24, data.count - 1] {
            XCTAssertThrowsError(try BackupCodec.decode(Data(data.prefix(length)), password: "backup password"))
        }
    }
}
