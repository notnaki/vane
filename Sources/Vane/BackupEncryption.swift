import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Version 1: seven magic bytes, one version byte, 16-byte salt, then the
/// AES-GCM combined nonce/ciphertext/tag. The entire header is authenticated.
/// Fixed KDF parameters prevent an untrusted file from selecting unbounded work.
enum BackupEncryption {
    private static let magic = Data("VANEENC".utf8)
    private static let version: UInt8 = 1
    private static let saltSize = 16
    private static let headerSize = 24
    private static let rounds: UInt32 = 600_000

    static func isEncrypted(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ data: Data, password: String) throws -> Data {
        guard !password.isEmpty else { throw BackupError.emptyPassword }
        // Include the salt, nonce and tag in the existing file-size limit.
        guard data.count <= BackupCodec.limit - headerSize - 28 else { throw BackupError.tooLarge }
        var salt = Data(count: saltSize)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }
        guard status == errSecSuccess else { throw BackupError.storage("A secure backup salt could not be created. Try again.") }
        let header = magic + Data([version]) + salt
        let sealed = try AES.GCM.seal(data, using: key(password, salt: salt), authenticating: header)
        guard let combined = sealed.combined else { throw BackupError.storage("The backup could not be encrypted.") }
        return header + combined
    }

    static func open(_ data: Data, password: String?) throws -> Data {
        guard data.count <= BackupCodec.limit else { throw BackupError.tooLarge }
        guard data.count >= headerSize + 28 else { throw BackupError.invalid("The encrypted backup is incomplete.") }
        guard data[data.startIndex + 7] == version else { throw BackupError.futureVersion }
        guard let password else { throw BackupError.passwordRequired }
        let header = Data(data.prefix(headerSize))
        let salt = Data(header.suffix(saltSize))
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data.dropFirst(headerSize)),
                                    using: key(password, salt: salt), authenticating: header)
        } catch { throw BackupError.unlockFailed }
    }

    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        var bytes = Array(password.utf8)
        var derived = Data(count: 32)
        defer {
            _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            derived.resetBytes(in: 0..<derived.count)
        }
        let status = bytes.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { output in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self), bytes.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self), output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.storage("The backup encryption key could not be created.") }
        return SymmetricKey(data: derived)
    }
}
