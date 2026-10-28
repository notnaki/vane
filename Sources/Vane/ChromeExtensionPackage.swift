import CryptoKit
import Foundation
import Security

/// CRX3 wire format and signed context defined by Chromium's components/crx_file.
/// Authenticate both the ID-bound developer and Google's production publisher before
/// returning any ZIP bytes. No archive or manifest-controlled identity is trusted.
enum ChromeExtensionPackage {
    struct Failure: LocalizedError {
        var errorDescription: String? { "The Chrome extension package is invalid or its signature could not be verified. Nothing was installed." }
    }
    static let maximumBytes = 128 * 1024 * 1024
    static let publisherKeyHash = Data([
        0x61, 0xf7, 0xf2, 0xa6, 0xbf, 0xcf, 0x74, 0xcd, 0x0b, 0xc1, 0xfe,
        0x24, 0x97, 0xcc, 0x9b, 0x04, 0x25, 0x4c, 0x65, 0x8f, 0x79, 0xf2,
        0x14, 0x53, 0x92, 0x86, 0x7e, 0xa8, 0x36, 0x63, 0x67, 0xcf
    ])

    static func verifiedZIP(_ data: Data, id: String, publisherKeyHash: Data = publisherKeyHash) throws -> Data {
        guard data.count >= 12, data.count <= maximumBytes, data.prefix(4) == Data("Cr24".utf8),
              uint32(data, 4) == 3, ChromeWebStore.validID(id) else { throw Failure() }
        let headerSize = Int(uint32(data, 8))
        guard headerSize > 0, headerSize <= 1024 * 1024, headerSize < data.count - 12 else { throw Failure() }
        let header = try fields(Data(data[12..<12 + headerSize]))
        let signed = try single(10000, in: header)
        let idBytes = try single(1, in: fields(signed))
        guard idBytes.count == 16, extensionID(idBytes) == id else { throw Failure() }
        let zip = Data(data[(12 + headerSize)...])
        var hash = SHA256()
        hash.update(data: Data("CRX3 SignedData\0".utf8))
        hash.update(data: Data((0..<4).map { UInt8(truncatingIfNeeded: signed.count >> ($0 * 8)) }))
        hash.update(data: signed)
        hash.update(data: zip)
        let digest = hash.finalize()
        let proofs = header.filter { $0.0 == 2 || $0.0 == 3 }
        guard !proofs.isEmpty, proofs.count <= 16 else { throw Failure() }
        var developer = false, publisher = false
        for (type, bytes) in proofs {
            let proof = try fields(bytes)
            let key = try single(1, in: proof), signature = try single(2, in: proof)
            let keyHash = Data(SHA256.hash(data: key))
            let valid: Bool
            if type == 3 {
                let publicKey = try P256.Signing.PublicKey(derRepresentation: key)
                valid = publicKey.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: signature), for: digest)
            } else {
                let raw = try rsaKey(key)
                guard let publicKey = SecKeyCreateWithData(raw as CFData, [
                    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic
                ] as CFDictionary, nil) else { throw Failure() }
                valid = SecKeyVerifySignature(publicKey, .rsaSignatureDigestPKCS1v15SHA256,
                                               Data(digest) as CFData, signature as CFData, nil)
            }
            guard valid else { throw Failure() }
            developer = developer || keyHash.prefix(16) == idBytes
            publisher = publisher || keyHash == publisherKeyHash
        }
        guard developer, publisher else { throw Failure() }
        return zip
    }

    private static func extensionID(_ bytes: Data) -> String {
        String(bytes.flatMap { [Character(UnicodeScalar(97 + Int($0 >> 4))!), Character(UnicodeScalar(97 + Int($0 & 15))!)] })
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }

    /// Bounded protobuf reader. Singular security fields reject duplicates; unknown
    /// primitive fields may be skipped, groups and malformed/overflowing varints fail.
    private static func fields(_ data: Data) throws -> [(Int, Data)] {
        var offset = 0, result: [(Int, Data)] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { throw Failure() }
                let byte = data[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw Failure() }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw Failure()
        }
        while offset < data.count {
            guard result.count < 256 else { throw Failure() }
            let tag = try varint(), number = tag >> 3
            guard number > 0, number <= 536_870_911 else { throw Failure() }
            let count: Int
            switch tag & 7 {
            case 0: _ = try varint(); continue
            case 1: count = 8
            case 2:
                let size = try varint()
                guard size <= UInt64(data.count - offset) else { throw Failure() }
                count = Int(size)
            case 5: count = 4
            default: throw Failure()
            }
            guard count <= data.count - offset else { throw Failure() }
            if tag & 7 == 2 { result.append((Int(number), Data(data[offset..<offset + count]))) }
            offset += count
        }
        return result
    }

    private static func single(_ number: Int, in fields: [(Int, Data)]) throws -> Data {
        let values = fields.filter { $0.0 == number }
        guard values.count == 1, let value = values.first?.1, !value.isEmpty else { throw Failure() }
        return value
    }

    /// Security imports RSA public keys in PKCS#1 form; CRX stores SPKI. Accept only
    /// rsaEncryption with NULL parameters, then unwrap its zero-unused-bits BIT STRING.
    private static func rsaKey(_ spki: Data) throws -> Data {
        func item(_ data: Data, offset: inout Int, tag: UInt8) throws -> Data {
            guard offset + 2 <= data.count, data[offset] == tag else { throw Failure() }
            offset += 1
            let byte = data[offset]; offset += 1
            var count = Int(byte)
            if byte & 128 != 0 {
                let lengthBytes = Int(byte & 127)
                guard lengthBytes > 0, lengthBytes <= 4, lengthBytes <= data.count - offset,
                      data[offset] != 0 else { throw Failure() }
                count = 0
                for _ in 0..<lengthBytes { count = count << 8 | Int(data[offset]); offset += 1 }
                guard count >= 128 else { throw Failure() }
            }
            guard count <= data.count - offset else { throw Failure() }
            defer { offset += count }
            return Data(data[offset..<offset + count])
        }
        var offset = 0
        let sequence = try item(spki, offset: &offset, tag: 0x30)
        guard offset == spki.count else { throw Failure() }
        offset = 0
        let algorithm = try item(sequence, offset: &offset, tag: 0x30)
        guard algorithm == Data([6, 9, 42, 134, 72, 134, 247, 13, 1, 1, 1, 5, 0]) else { throw Failure() }
        let bits = try item(sequence, offset: &offset, tag: 3)
        guard offset == sequence.count, bits.count > 1, bits.first == 0 else { throw Failure() }
        return Data(bits.dropFirst())
    }
}
